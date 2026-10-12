import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/peer_engine.dart';

import '../tools/pc_bluetooth_transport.dart';

void main() {
  late Identity identity;
  late Directory directory;
  late PeerEngine engine;
  late PcBluetoothTransport bluetooth;
  final processes = <_Process>[];
  final calls = <String>[];
  Completer<Process>? launching;
  setUpAll(() => identity = Identity.generate());
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    directory = await parent.createTemp('pc-ble-lifecycle-');
    await Directory('${directory.path}/tools').create();
    await File('${directory.path}/tools/ble_pc_bridge.py')
        .writeAsString('test');
    final executable = File('${directory.path}/fake-python.exe');
    await executable.writeAsString('not executed');
    engine = PeerEngine(
      directory: Directory('${directory.path}/store'),
      identity: identity,
      listenPort: 0,
      enableLanDiscovery: false,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
    await engine.start(activeMode: false);
    calls.clear();
    processes.clear();
    launching = null;
    bluetooth = PcBluetoothTransport(
      engine,
      directory,
      executable.path,
      processStarter:
          (executable, arguments, {workingDirectory, environment}) async {
            calls.add('launch');
            final pending = launching;
            launching = null;
            if (pending != null) return pending.future;
            final process = _Process(() => calls.add('exit'));
            processes.add(process);
            return process;
          },
    );
  });
  tearDown(() async {
    await bluetooth.stop();
    for (final process in processes) {
      process.finish(0);
    }
    await engine.stop();
    await directory.delete(recursive: true);
  });

  test(
    'stop before queued helper startup prevents a later process launch',
    () async {
      final started = bluetooth.start();
      final stopped = bluetooth.stop();
      await Future.wait([started, stopped]);
      expect(calls, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'delayed helper launch is closed before replacement can launch',
    () async {
      final pending = Completer<Process>();
      launching = pending;
      final started = bluetooth.start();
      await until(() => calls.length == 1);
      final stopped = bluetooth.stop();
      final replacement = bluetooth.start();
      final old = _Process(() => calls.add('exit'));
      processes.add(old);
      pending.complete(old);
      await Future.wait([started, stopped, replacement]);
      expect(calls, ['launch', 'exit', 'launch']);
      expect(old.stdinClosed, true);
      expect(processes.last.stdinClosed, false);
      await bluetooth.stop();
      expect(processes.last.stdinClosed, true);
    },
    skip: !Platform.isWindows,
  );

  test(
    'concurrent startup shares one helper and one configure command',
    () async {
      await Future.wait(List.generate(10, (_) => bluetooth.start()));
      await until(() => processes.single.commands.isNotEmpty);
      expect(calls, ['launch']);
      expect(processes.single.commands.map((value) => value['type']), [
        'configure',
      ]);
    },
    skip: !Platform.isWindows,
  );
}

class _Process implements Process {
  _Process(this.onExit) {
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => commands.add(jsonDecode(line) as Map),
          onDone: () {
            stdinClosed = true;
            finish(0);
          },
        );
    input = IOSink(_input.sink);
  }
  final void Function() onExit;
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _errors = StreamController<List<int>>();
  final _exit = Completer<int>();
  final commands = <Map>[];
  late final IOSink input;
  bool stdinClosed = false;
  void finish(int code) {
    if (_exit.isCompleted) return;
    onExit();
    _exit.complete(code);
    unawaited(_output.close());
    unawaited(_errors.close());
  }

  @override
  IOSink get stdin => input;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    finish(-9);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 8)) {
      fail('PC Bluetooth lifecycle condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
