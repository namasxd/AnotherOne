// frontend/lib/worker_app.dart
// App Flutter para tablet del trabajador.
// Modo demo (sin backend) o modo real (con server_worker.py).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

// ─── CONFIG ───
// Tablet -> server_worker.py (puerto 8001) -> server_admin.py (8000, SQLite)
// Ejemplo real: flutter run --dart-define=BACKEND=http://192.168.1.105:8001 --dart-define=DEMO=false
const String kBackendUrl = String.fromEnvironment('BACKEND', defaultValue: 'http://192.168.1.105:8001');
const bool kModoDemo = bool.fromEnvironment('DEMO', defaultValue: true);

/// El QR del bulto es JSON {"b":id,"oc":..,"s":..,"sku":..,"n":..}; extrae el id del bulto.
String bultoFromQr(String raw) {
  try {
    final d = jsonDecode(raw);
    if (d is Map && d['b'] is String) return d['b'] as String;
  } catch (_) {}
  return raw.trim();
}

void main() => runApp(const CedisWorkerApp());

class CedisWorkerApp extends StatelessWidget {
  const CedisWorkerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'CEDIS Flow · Tablet',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B5FA5)),
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
    ),
    home: const HomePage(),
  );
}

// ─── MODELO DE TAREA ───
class Task {
  final String code, kind, origin, destination, bulto, sku;
  String status;
  final int pieces;
  final double weight;
  Task({required this.code, required this.kind, required this.origin,
        required this.destination, required this.bulto, required this.sku,
        required this.pieces, required this.weight, required this.status});
  factory Task.fromJson(Map<String, dynamic> j) => Task(
    code: j['code'], kind: j['kind'], origin: j['origin'], destination: j['destination'],
    bulto: j['bulto'], sku: j['sku'], pieces: (j['pieces'] as num).toInt(), weight: (j['weight'] as num).toDouble(),
    status: j['status'] ?? 'pendiente');
}

// ─── SERVICIO (real o demo) ───
class ApiService {
  final bool demo;
  ApiService({required this.demo});

  // Estado demo en memoria
  static final List<Task> _demoTasks = [
    Task(code: 'T-0001', kind: 'almacenamiento', origin: 'Andén recepción 02',
         destination: 'Pasillo R01, Nivel 2, Pos 3', bulto: 'B-OC-1001-0001',
         sku: 'SKU-ACEITE-1L', pieces: 12, weight: 90, status: 'pendiente'),
    Task(code: 'T-0002', kind: 'almacenamiento', origin: 'Andén recepción 01',
         destination: 'Pasillo R02, Nivel 1, Pos 5', bulto: 'B-OC-1002-0001',
         sku: 'SKU-REFRESCO', pieces: 12, weight: 85, status: 'pendiente'),
    Task(code: 'T-0003', kind: 'cross', origin: 'Andén recepción 01',
         destination: 'Zona embarque · Sucursal 1', bulto: 'B-OC-1003-0002',
         sku: 'SKU-YOGURT', pieces: 12, weight: 30, status: 'pendiente'),
  ];

  Future<List<Task>> fetchTasks() async {
    if (demo) return _demoTasks.where((t) => t.status != 'completada').toList();
    final r = await http.get(Uri.parse('$kBackendUrl/api/tasks')).timeout(const Duration(seconds: 4));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final list = jsonDecode(r.body) as List;
    return list.map((e) => Task.fromJson(e as Map<String, dynamic>)).where((t) => t.status != 'completada').toList();
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) async {
    if (demo) {
      final code = body['code'];
      for (final t in _demoTasks) {
        if (t.code != code) continue;
        if (path.endsWith('start')) t.status = 'en_recogida';
        if (path.endsWith('pick')) t.status = 'en_traslado';
        if (path.endsWith('deliver')) t.status = 'completada';
      }
      return {'ok': true};
    }
    final r = await http.post(Uri.parse('$kBackendUrl$path'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 4));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> scanPackage(String code) async {
    if (demo) {
      final id = bultoFromQr(code);
      final found = _demoTasks.where((x) => x.bulto == id);
      if (found.isEmpty) return {'ok': false, 'error': 'Rechazado: mercancía no solicitada'};
      return {'ok': true, 'bulto': id, 'mensaje': 'Recibido ${found.first.bulto}'};
    }
    return post('/api/scan', {'code': code});
  }
}

// ─── HOME ───
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final api = ApiService(demo: kModoDemo);
  final _wedge = TextEditingController(); // lector físico (emula teclado + Enter)
  final _wedgeFocus = FocusNode();
  List<Task> tasks = [];
  Task? current;
  Timer? _poll;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  @override
  void dispose() { _poll?.cancel(); _wedge.dispose(); _wedgeFocus.dispose(); super.dispose(); }

  Future<void> _load({bool silent = false}) async {
    try {
      final t = await api.fetchTasks();
      if (mounted) setState(() { tasks = t; _err = null; });
    } catch (e) {
      if (mounted) setState(() => _err = 'Sin conexión con el servidor');
    }
  }

  /// Recepción: el servidor valida el QR (no solicitado / excedente / no coincide).
  Future<bool> _receive(String raw) async {
    String msg;
    bool ok = false;
    try {
      final r = await api.scanPackage(raw);
      ok = r['ok'] == true;
      msg = ok ? (r['mensaje']?.toString() ?? 'Recibido') : (r['error']?.toString() ?? 'Rechazado');
    } catch (e) {
      msg = 'Error de conexión';
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: ok ? Colors.green[700] : Colors.red[700], content: Text(msg)));
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    if (current != null) {
      return TaskDetailPage(
        task: current!,
        api: api,
        onBack: () { setState(() => current = null); _load(); },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis instrucciones'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: Text(kModoDemo ? 'DEMO' : 'ONLINE',
                style: TextStyle(fontSize: 12,
                  color: kModoDemo ? Colors.orange : Colors.green)),
            ),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _load()),
        ],
      ),
      body: Column(
        children: [
          if (_err != null)
            Container(width: double.infinity, color: Colors.red[50],
              padding: const EdgeInsets.all(12),
              child: Text(_err!, style: const TextStyle(color: Colors.red))),
          Expanded(
            child: tasks.isEmpty
              ? const Center(child: Text('Sin tareas pendientes.\nEsperando al supervisor...',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
              : ListView.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final t = tasks[i];
                    return ListTile(
                      minVerticalPadding: 20,
                      leading: CircleAvatar(
                        backgroundColor: t.kind == 'cross'
                            ? Colors.orange[100] : Colors.blue[100],
                        child: Icon(
                          t.kind == 'cross' ? Icons.swap_horiz :
                          t.kind == 'pick' ? Icons.outbox : Icons.move_to_inbox,
                          color: t.kind == 'cross' ? Colors.orange[900] : Colors.blue[900],
                        ),
                      ),
                      title: Text(t.bulto, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${t.kind == 'cross' ? "Cross-docking" : t.kind == "pick" ? "Retirar" : "Almacenar"}\n'
                          '${t.origin} → ${t.destination}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() => current = t),
                    );
                  },
                ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _wedge,
              focusNode: _wedgeFocus,
              autofocus: true,
              keyboardType: TextInputType.none, // no abre teclado; el lector físico envía el texto + Enter
              decoration: const InputDecoration(
                labelText: 'Lector físico: escanea el bulto aquí',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.barcode_reader),
              ),
              onSubmitted: (v) async {
                final raw = v.trim();
                _wedge.clear();
                if (raw.isNotEmpty) { await _receive(raw); _load(); }
                _wedgeFocus.requestFocus();
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Escanear QR'),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                    onPressed: () async {
                      await Navigator.push(context, MaterialPageRoute(
                        builder: (_) => ScanPage(title: 'Recepción: escanear bulto', onCode: _receive)));
                      _load();
                    },
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── DETALLE DE TAREA ───
class TaskDetailPage extends StatefulWidget {
  final Task task;
  final ApiService api;
  final VoidCallback onBack;
  const TaskDetailPage({super.key, required this.task, required this.api, required this.onBack});
  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  final _scanCtrl = TextEditingController();
  @override
  void dispose() { _scanCtrl.dispose(); super.dispose(); }
  late String _status = widget.task.status;
  String? _message;

  Future<void> _action(String path, Map<String, dynamic> body) async {
    try {
      final r = await widget.api.post(path, body);
      if (r['ok'] == true) {
        setState(() {
          _status = path.endsWith('start') ? 'en_recogida'
                  : path.endsWith('pick')  ? 'en_traslado'
                  : 'completada';
          _message = null;
        });
      } else {
        setState(() => _message = r['error']?.toString() ?? 'Acción rechazada');
      }
    } catch (e) {
      setState(() => _message = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onBack),
        title: const Text('Tarea actual'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _card(
            icon: Icons.inventory_2, label: 'BULTO', value: t.bulto,
            subtitle: '${t.sku} · ${t.pieces} piezas · ${t.weight} kg',
          ),
          const SizedBox(height: 12),
          _route('1 · RECOGER EN', t.origin, false),
          const Padding(padding: EdgeInsets.symmetric(vertical: 8),
            child: Icon(Icons.arrow_downward, size: 32, color: Colors.blue)),
          _route('2 · ENTREGAR EN', t.destination, true),
          const SizedBox(height: 16),
          if (_message != null)
            Container(padding: const EdgeInsets.all(12), color: Colors.red[50],
              child: Text(_message!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 16),
          TextField(
            controller: _scanCtrl,
            decoration: const InputDecoration(
              labelText: 'Escanea o escribe el código del bulto',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.qr_code),
            ),
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Abrir cámara'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => ScanPage(title: 'Escanear bulto de la tarea', onCode: (raw) async {
                setState(() => _scanCtrl.text = bultoFromQr(raw));
                return true;
              }))),
          ),
          const SizedBox(height: 16),
          if (_status == 'pendiente')
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64),
                  backgroundColor: Colors.blue[700]),
              onPressed: () => _action('/api/tasks/start', {'code': t.code}),
              child: const Text('INICIAR TAREA', style: TextStyle(fontSize: 18)),
            ),
          if (_status == 'en_recogida')
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64),
                  backgroundColor: Colors.green[700]),
              onPressed: () {
                if (bultoFromQr(_scanCtrl.text) != t.bulto) {
                  setState(() => _message = 'El código no corresponde al bulto.');
                  return;
                }
                _action('/api/tasks/pick', {'code': t.code, 'bulto': t.bulto});
              },
              child: const Text('CONFIRMAR RECOGIDA', style: TextStyle(fontSize: 18)),
            ),
          if (_status == 'en_traslado')
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(64),
                  backgroundColor: Colors.green[700]),
              onPressed: () => _action('/api/tasks/deliver', {'code': t.code}),
              child: const Text('CONFIRMAR ENTREGA', style: TextStyle(fontSize: 18)),
            ),
          if (_status == 'completada')
            Container(padding: const EdgeInsets.all(16), color: Colors.green[50],
              child: const Row(children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text('Tarea completada', style: TextStyle(fontSize: 18)),
              ])),
          const SizedBox(height: 12),
          TextButton.icon(
            icon: const Icon(Icons.report_problem, color: Colors.red),
            label: const Text('Reportar incidencia', style: TextStyle(color: Colors.red)),
            onPressed: () => _showIncidentDialog(context, t),
          ),
        ]),
      ),
    );
  }

  Widget _card({required IconData icon, required String label, required String value,
                 required String subtitle}) =>
      Card(
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(icon, size: 40, color: Colors.blue[700]),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700],
                  fontWeight: FontWeight.bold, letterSpacing: 1)),
              Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              Text(subtitle, style: TextStyle(fontSize: 14, color: Colors.grey[700])),
            ])),
          ]),
        ),
      );

  Widget _route(String label, String value, bool dest) =>
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: dest ? Colors.blue[50] : Colors.grey[100],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: dest ? Colors.blue : Colors.grey[300]!),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[700],
              fontWeight: FontWeight.bold, letterSpacing: 1)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ]),
      );

  void _showIncidentDialog(BuildContext context, Task t) {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Reportar incidencia'),
      content: TextField(controller: ctrl, maxLines: 3,
        decoration: const InputDecoration(hintText: 'Bulto dañado, no encontrado, rack ocupado...')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(onPressed: () {
          Navigator.pop(ctx);
          widget.api.post('/api/incident', {'code': t.code, 'bulto': t.bulto, 'text': ctrl.text}).catchError((_) => <String, dynamic>{});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Incidencia reportada: ${ctrl.text}')));
        }, child: const Text('Enviar')),
      ],
    ));
  }
}

// ─── ESCÁNER QR ───
// onCode recibe el texto crudo del QR; devuelve true para cerrar el escáner (aceptado).
class ScanPage extends StatefulWidget {
  final String title;
  final Future<bool> Function(String raw) onCode;
  const ScanPage({super.key, required this.title, required this.onCode});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _ctrl = MobileScannerController();
  bool _handled = false;
  final _manual = TextEditingController();

  void _onDetect(BarcodeCapture cap) {
    if (_handled) return;
    final code = cap.barcodes.isEmpty ? null : cap.barcodes.first.rawValue;
    if (code == null) return;
    _process(code);
  }

  Future<void> _process(String raw) async {
    if (_handled) return;
    _handled = true;
    final ok = await widget.onCode(raw);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      await Future.delayed(const Duration(seconds: 2)); // evita relecturas en bucle
      _handled = false;
    }
  }

  @override
  void dispose() { _ctrl.dispose(); _manual.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        Expanded(flex: 3, child: MobileScanner(controller: _ctrl, onDetect: _onDetect)),
        Expanded(
          flex: 1,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              const Text('¿La cámara no funciona? Pega el código:'),
              const SizedBox(height: 8),
              TextField(
                controller: _manual,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'B-OC-1001-0001',
                  suffixIcon: Icon(Icons.send),
                ),
                onSubmitted: (v) { if (v.trim().isNotEmpty) _process(v.trim()); },
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
