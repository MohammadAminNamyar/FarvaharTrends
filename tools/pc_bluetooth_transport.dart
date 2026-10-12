import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persian_trend/core/peer_engine.dart';

typedef BluetoothProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

/// The Windows helper sees signed public beacons and TLS ciphertext only.
/// Certificate validation and private keys stay in the existing Dart engine.
class PcBluetoothTransport {
  PcBluetoothTransport(
    this.engine,
    this.project,
    this.python, {
    BluetoothProcessStarter? processStarter,
  }) : _startProcess = processStarter ?? Process.start;
  final PeerEngine engine;
  final Directory project;
  final String python;
  final BluetoothProcessStarter _startProcess;
  final Map<String, String> _admitted = {};
  Process? _process;
  Timer? _timer;
  Future<void> _queue = Future.value();
  Future<void> _lifecycle = Future.value();
  Future<void>? _starting, _stopping;
  int _generation = 0;
  StreamSubscription<String>? _events;
  StreamSubscription<String>? _errors;
  bool _running = false;
  int _queued = 0;
  String? _lastState;

  bool _current(int generation) => _running && _generation == generation;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> start() {
    if (_running) return _starting ?? Future.value();
    _running = true;
    final generation = ++_generation;
    late final Future<void> tracked;
    tracked = _serial(() => _startSession(generation)).whenComplete(() {
      if (identical(_starting, tracked)) _starting = null;
    });
    _starting = tracked;
    return tracked;
  }

  Future<void> _startSession(int generation) async {
    if (!_current(generation)) return;
    try {
      if (!Platform.isWindows ||
          !File(python).isAbsolute ||
          !await File(python).exists()) {
        throw const FormatException(
          'A valid Windows Python executable is required for the optional Bluetooth bridge.',
        );
      }
      final helper = File('${project.path}/tools/ble_pc_bridge.py');
      if (!await helper.exists()) {
        throw const FormatException('Bluetooth helper is not installed.');
      }
      if (!_current(generation)) return;
      final process = await _startProcess(
        python,
        ['-B', helper.path],
        workingDirectory: project.path,
        environment: {
          'PYTHONPATH': '${project.path}/.tooling/ble-python',
          'PYTHONDONTWRITEBYTECODE': '1',
          'PYTHONNOUSERSITE': '1',
          'TEMP': '${project.path}/.tooling/temp',
          'TMP': '${project.path}/.tooling/temp',
        },
      );
      _process = process;
      _lastState = null;
      unawaited(process.stdin.done.catchError((Object _) {}));
      if (!_current(generation)) return;
      _events = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!_current(generation) ||
                  line.length > 8192 ||
                  _queued >= 32) {
                return;
              }
              _queued++;
              _queue = _queue
                  .then((_) async {
                    if (!_current(generation)) return;
                    final event = jsonDecode(line);
                    if (event is Map) {
                      await _handle(
                        Map<String, dynamic>.from(event),
                        generation,
                      );
                    }
                  })
                  .catchError((Object _) {
                    stderr.writeln('Bluetooth bridge event rejected.');
                  })
                  .whenComplete(() => _queued--);
            },
            onError: (Object _) {
              stderr.writeln('Bluetooth bridge event stream unavailable.');
            },
          );
      // Avoid forwarding arbitrary adapter/device information into relay logs.
      _errors = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {
            if (_current(generation)) {
              stderr.writeln('Bluetooth helper reported a diagnostic error.');
            }
          }, onError: (Object _) {});
      _send({
        'type': 'configure',
        'beaconBase64': base64Encode(engine.createDiscoveryBeacon()),
        'localTlsPort': engine.bluetoothIngressPort,
      });
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_current(generation)) {
          _send({
            'type': 'updateBeacon',
            'beaconBase64': base64Encode(engine.createDiscoveryBeacon()),
          });
        }
      });
      unawaited(
        process.exitCode.then((code) async {
          if (_current(generation) && identical(_process, process)) {
            stderr.writeln(
              'Bluetooth helper exited ($code); IP relay remains available.',
            );
            await stop();
          }
        }),
      );
    } catch (_) {
      if (_current(generation)) {
        _running = false;
        ++_generation;
        await _stopResources(_events, _errors, _queue);
        _events = null;
        _errors = null;
      }
      rethrow;
    }
  }

  void _send(Map<String, dynamic> command) {
    try {
      _process?.stdin.writeln(jsonEncode(command));
    } catch (_) {
      stderr.writeln('Bluetooth helper command unavailable.');
    }
  }

  Future<void> _handle(Map<String, dynamic> event, int generation) async {
    final type = event['type'];
    final route = event['routeId'];
    if (type == 'status' || type == 'state') {
      final state = event['state'];
      if (state is String && state.length <= 64 && state != _lastState) {
        _lastState = state;
        stdout.writeln('bluetooth ${jsonEncode({'state': state})}');
      }
      return;
    }
    if (event['transport'] != 'bluetooth' ||
        route is! String ||
        route.length > 160) {
      return;
    }
    if (type == 'peerDiscovered') {
      var accepted = false;
      try {
        final encoded = event['beaconBase64'];
        if (encoded is! String || encoded.length > 5500) {
          throw const FormatException('Invalid beacon');
        }
        final admission = await engine.admitNativePeer(
          signedBeacon: base64Decode(encoded),
          routeId: route,
          transport: PeerTransport.bluetooth,
        );
        accepted = admission.accepted && admission.peerId != null;
        if (accepted) {
          for (final oldRoute in _admitted.keys.toList()) {
            if (oldRoute != route) {
              await engine.removeNativeRoute(oldRoute);
              _admitted.remove(oldRoute);
            }
          }
          if (_current(generation)) {
            _admitted[route] = admission.peerId!;
          } else {
            await engine.removeNativeRoute(route);
            accepted = false;
          }
        }
      } catch (_) {
        accepted = false;
        stderr.writeln('Bluetooth peer failed identity admission.');
      }
      _send({
        'type': accepted && _current(generation) ? 'accept' : 'reject',
        'routeId': route,
      });
    } else if (type == 'endpointReady') {
      final peerId = _admitted[route];
      final host = InternetAddress.tryParse('${event['host'] ?? ''}');
      final port = event['port'];
      if (peerId == null ||
          host == null ||
          !host.isLoopback ||
          port is! int ||
          port < 1 ||
          port > 65535) {
        _send({'type': 'reject', 'routeId': route});
        return;
      }
      await engine.registerNativeEndpoint(
        peerId: peerId,
        routeId: route,
        transport: PeerTransport.bluetooth,
        host: host,
        port: port,
      );
    } else if (type == 'endpointLost') {
      _admitted.remove(route);
      await engine.removeNativeRoute(route);
    }
  }

  Future<void> stop() {
    if (!_running && _stopping != null) return _stopping!;
    _running = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final events = _events, errors = _errors;
    _events = null;
    _errors = null;
    final queue = _queue;
    late final Future<void> tracked;
    tracked = _serial(() => _stopResources(events, errors, queue))
        .whenComplete(() {
          if (identical(_stopping, tracked)) _stopping = null;
        });
    _stopping = tracked;
    return tracked;
  }

  Future<void> _stopResources(
    StreamSubscription<String>? events,
    StreamSubscription<String>? errors,
    Future<void> queue,
  ) async {
    await events?.cancel();
    await errors?.cancel();
    await queue;
    final process = _process;
    _send({'type': 'stop'});
    if (process != null) {
      try {
        await (() async {
          await process.stdin.flush();
          await process.stdin.close();
          await process.exitCode;
        })().timeout(const Duration(seconds: 5));
      } catch (_) {
        process.kill();
      }
    }
    _process = null;
    for (final route in _admitted.keys.toList()) {
      try {
        await engine.removeNativeRoute(route);
      } catch (_) {
        stderr.writeln('Bluetooth route cleanup unavailable.');
      }
    }
    _admitted.clear();
  }
}
