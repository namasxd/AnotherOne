#!/usr/bin/env python3
"""CEDIS Flow · server_admin.py  (puerto 8000)
Backend central en Python estándar + SQLite. Sin dependencias externas.
- El panel PC (admin_panel.html) publica catálogo de bultos y tareas (POST /api/state).
- Valida escaneos de recepción (reglas 5: no se recibe mercancía no solicitada ni excedente).
- Gestiona el ciclo de las tareas de la tablet y registra eventos para sincronizar.
Uso: python3 server_admin.py [puerto]
"""
import json, sqlite3, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DB = 'cedis_flow.db'
LOCK = threading.Lock()
con = sqlite3.connect(DB, check_same_thread=False)
con.row_factory = sqlite3.Row


def init():
    con.executescript("""
    CREATE TABLE IF NOT EXISTS bultos(id TEXT PRIMARY KEY, oc TEXT, sku TEXT, n INTEGER, suc INTEGER, received INTEGER DEFAULT 0);
    CREATE TABLE IF NOT EXISTS tasks(code TEXT PRIMARY KEY, data TEXT, status TEXT);
    CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT);
    """)
    con.commit()


def add_event(ev):
    con.execute('INSERT INTO events(data) VALUES(?)', (json.dumps(ev),))


def validate_scan(raw, source):
    try:
        d = json.loads(raw)
        if not isinstance(d, dict):
            d = {'b': str(raw).strip()}
    except Exception:
        d = {'b': str(raw).strip()}
    bid = d.get('b')
    row = con.execute('SELECT * FROM bultos WHERE id=?', (bid,)).fetchone()
    if source == 'panel':  # el panel ya validó; solo se registra
        if row:
            con.execute('UPDATE bultos SET received=1 WHERE id=?', (bid,))
        return {'ok': True, 'bulto': bid}
    if not row or (d.get('oc') and d['oc'] != row['oc']):
        return {'ok': False, 'error': 'Rechazado: mercancía no solicitada en esta OC'}
    if row['received']:
        return {'ok': False, 'error': 'Rechazado: excedente, el bulto ya fue recibido'}
    if (d.get('sku') and d['sku'] != row['sku']) or (d.get('n') and d['n'] != row['n']) or (d.get('s') and d['s'] != row['suc']):
        return {'ok': False, 'error': 'Rechazado: no coincide con la factura'}
    con.execute('UPDATE bultos SET received=1 WHERE id=?', (bid,))
    add_event({'type': 'scan', 'package_code': bid})
    return {'ok': True, 'bulto': bid, 'mensaje': 'Recibido: sucursal %s' % row['suc']}


NEXT = {'start': ('pendiente', 'en_recogida'), 'pick': ('en_recogida', 'en_traslado'), 'deliver': ('en_traslado', 'completada')}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.end_headers()
        self.wfile.write(b)

    def do_OPTIONS(self):
        self._send(200, {})

    def do_GET(self):
        u = urlparse(self.path)
        with LOCK:
            if u.path == '/api/health':
                return self._send(200, {'ok': True})
            if u.path == '/api/events':
                since = int(parse_qs(u.query).get('since', ['0'])[0])
                rows = con.execute('SELECT id,data FROM events WHERE id>? ORDER BY id', (since,)).fetchall()
                return self._send(200, {'events': [dict(json.loads(r['data']), id=r['id']) for r in rows]})
            if u.path == '/api/tasks':
                rows = con.execute("SELECT data,status FROM tasks WHERE status!='completada' ORDER BY rowid").fetchall()
                return self._send(200, [dict(json.loads(r['data']), status=r['status']) for r in rows])
        self._send(404, {'ok': False, 'error': 'no existe'})

    def do_POST(self):
        try:
            n = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            return self._send(400, {'ok': False, 'error': 'JSON inválido'})
        path = urlparse(self.path).path
        with LOCK:
            try:
                r = self.route(path, body)
                con.commit()
            except Exception as e:
                con.rollback()
                return self._send(500, {'ok': False, 'error': str(e)})
        self._send(200 if r is not None else 404, r or {'ok': False, 'error': 'no existe'})

    def route(self, path, b):
        if path == '/api/scan':
            return validate_scan(b.get('code', ''), b.get('source'))
        if path == '/api/state':
            for x in b.get('bultos', []):
                con.execute("""INSERT INTO bultos(id,oc,sku,n,suc,received) VALUES(?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET oc=excluded.oc,sku=excluded.sku,n=excluded.n,suc=excluded.suc,
                    received=MAX(received,excluded.received)""",
                            (x['id'], x['oc'], x['sku'], x['n'], x['suc'], 1 if x.get('received') else 0))
            codes = [t['code'] for t in b.get('tasks', [])]
            for t in b.get('tasks', []):
                con.execute("INSERT OR IGNORE INTO tasks(code,data,status) VALUES(?,?,'pendiente')", (t['code'], json.dumps(t)))
            for r in con.execute('SELECT code FROM tasks').fetchall():
                if r['code'] not in codes:
                    con.execute('DELETE FROM tasks WHERE code=?', (r['code'],))
            return {'ok': True}
        if path.startswith('/api/tasks/'):
            act = path.rsplit('/', 1)[1]
            if act not in NEXT:
                return None
            row = con.execute('SELECT * FROM tasks WHERE code=?', (b.get('code'),)).fetchone()
            if not row:
                return {'ok': False, 'error': 'Tarea inexistente (ya fue confirmada o cancelada)'}
            frm, to = NEXT[act]
            if row['status'] != frm:
                return {'ok': False, 'error': 'Estado inválido: la tarea está "%s"' % row['status']}
            t = json.loads(row['data'])
            if act == 'pick' and b.get('bulto') != t['bulto']:
                return {'ok': False, 'error': 'El código no corresponde al bulto de la tarea'}
            con.execute('UPDATE tasks SET status=? WHERE code=?', (to, row['code']))
            add_event({'type': 'task', 'action': act, 'code': row['code'], 'bulto': t['bulto']})
            return {'ok': True, 'status': to}
        if path == '/api/incident':
            add_event({'type': 'incident', 'code': b.get('code'), 'bulto': b.get('bulto'), 'text': str(b.get('text', ''))[:300]})
            return {'ok': True}
        if path == '/api/reset':
            con.executescript('DELETE FROM bultos; DELETE FROM tasks; DELETE FROM events;')
            return {'ok': True}
        return None


if __name__ == '__main__':
    init()
    print('server_admin en http://0.0.0.0:%d  (SQLite: %s)' % (PORT, DB))
    ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
