#!/usr/bin/env python3
"""CEDIS Flow · server_worker.py (puerto 8001)
Proxy para la tablet Flutter: reenvía /api/* a server_admin.py. Python estándar.
Uso: python3 server_worker.py [puerto_worker] [url_admin]
"""
import sys, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
ADMIN = sys.argv[2] if len(sys.argv) > 2 else 'http://127.0.0.1:8000'
ALLOWED = ('/api/tasks', '/api/scan', '/api/incident', '/api/health')  # la tablet no toca /api/state ni /api/reset


class P(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _fwd(self, method):
        if not self.path.split('?')[0].startswith(ALLOWED):
            return self._out(403, b'{"ok":false,"error":"ruta no permitida"}')
        data = None
        if method == 'POST':
            data = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        req = urllib.request.Request(ADMIN + self.path, data=data, method=method, headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=4) as r:
                self._out(r.status, r.read())
        except urllib.error.HTTPError as e:
            self._out(e.code, e.read())
        except Exception:
            self._out(502, b'{"ok":false,"error":"server_admin no responde"}')

    def _out(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self): self._fwd('GET')
    def do_POST(self): self._fwd('POST')


if __name__ == '__main__':
    print('server_worker en :%d -> %s' % (PORT, ADMIN))
    ThreadingHTTPServer(('0.0.0.0', PORT), P).serve_forever()
