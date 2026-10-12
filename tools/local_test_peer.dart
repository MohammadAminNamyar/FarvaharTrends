import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';

import 'pc_bluetooth_transport.dart';

/// Optional test relay on this PC. Only its public bootstrap JSON may be shared.
/// Its private identity, journal and lock stay inside .tooling/local-test-peer.
Future<void> main(List<String> arguments) async {
  _Options options;
  try {
    options = _Options.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Use --help for the supported options.');
    exitCode = 64;
    return;
  }
  if (options.help) {
    stdout.writeln(
      'PersianTrend optional local test peer\n'
      '  --host <this-PC-IPv4> [--port 45871] [--prepare-only]\n'
      '  --host <this-PC-IPv4> [--run-for <seconds>]\n'
      '  --host <this-PC-IPv4> --bluetooth-python <absolute-python.exe>\n'
      '  --self-test  Validate signing and discovery without files/listeners.\n'
      '\n--prepare-only writes the public bootstrap and exits without listening.\n'
      'Normal mode listens on TCP peer port and UDP45872 until Ctrl+C.\n'
      'The host must be a numeric IPv4 assigned to this PC. No DNS or scans.',
    );
    return;
  }
  if (options.selfTest) {
    final identity = Identity.generate();
    final restored = Identity.fromJson(identity.toJson());
    final beacon = PeerDiscovery.beacon(restored, 45871);
    final parsed = PeerDiscovery.parseBeacon(
      beacon,
      InternetAddress.loopbackIPv4,
    );
    if (parsed.id != identity.id || parsed.host != '127.0.0.1') {
      throw StateError('Local protocol self-test failed.');
    }
    stdout.writeln(
      'Self-test passed: identity round-trip and signed discovery; no files or listeners.',
    );
    return;
  }

  final project = File.fromUri(Platform.script).parent.parent;
  final directory = Directory('${project.path}/.tooling/local-test-peer');
  final outputDirectory = Directory('${project.path}/artifacts/local-test');
  RandomAccessFile? lock;
  PeerEngine? engine;
  PcBluetoothTransport? bluetooth;
  Timer? heartbeat;
  Timer? deadline;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    final addresses = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    if (!addresses.any(
      (interface) => interface.addresses.any((a) => a.address == options.host),
    )) {
      throw const FormatException(
        'The supplied host IPv4 is not assigned to this PC.',
      );
    }
    await directory.create(recursive: true);
    lock = await File('${directory.path}/peer.lock')
        .open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    final identityFile = File('${directory.path}/identity.json');
    final Identity identity;
    if (await identityFile.exists()) {
      if (await identityFile.length() > 32768) {
        throw const FormatException(
          'Stored local identity is invalid; it was not replaced.',
        );
      }
      try {
        identity = Identity.fromJson(
          jsonDecode(await identityFile.readAsString()) as Map<String, dynamic>,
        );
      } catch (_) {
        throw const FormatException(
          'Stored local identity is invalid; it was not replaced.',
        );
      }
    } else {
      identity = Identity.generate();
      final pending = File('${identityFile.path}.next');
      await pending.writeAsString(jsonEncode(identity.toJson()), flush: true);
      await pending.rename(identityFile.path);
    }
    final card = PeerCard(
      name: 'PersianTrend local test peer',
      host: options.host!,
      port: options.port,
      certificatePem: identity.certPem,
    );
    await outputDirectory.create(recursive: true);
    final bootstrap = File('${outputDirectory.path}/bootstrap.json');
    await bootstrap.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'peers': [card.toJson()],
      }),
      flush: true,
    );
    stdout.writeln('Public bootstrap: ${bootstrap.path}');
    stdout.writeln('Public peer fingerprint: ${identity.id}');
    stdout.writeln(
      'Private local identity stays under .tooling/local-test-peer; never distribute that directory.',
    );
    if (options.prepareOnly) return;

    final clock = Stopwatch()..start();
    String? previousStatus;
    void printStatus(Map<String, dynamic> status, {bool force = false}) {
      final summary = jsonEncode({
        'running': status['running'],
        'contacts': status['peerCount'],
        'connected': status['connectedCount'],
        'channels': (status['channels'] as List?)?.length ?? 0,
        'bulletins': status['bulletinCount'],
        'receipts': status['receiptCount'],
        'discovery': status['discoveryState'],
        'discoveryError': status['discoveryLastError'],
        'lastError': status['lastError'],
        'activeTransports': status['activeTransportCounts'],
      });
      if (force || summary != previousStatus) {
        previousStatus = summary;
        stdout.writeln('status $summary');
      }
    }

    final peer = PeerEngine(
      directory: directory,
      identity: identity,
      listenPort: options.port,
      deviceState: () async => {
        'platform': 'local-test-peer',
        'elapsedRealtimeMs': clock.elapsedMilliseconds,
        'lockStateKnown': false,
      },
      onStatus: printStatus,
    );
    engine = peer;
    await peer.start(activeMode: false);
    if (options.bluetoothPython != null) {
      bluetooth = PcBluetoothTransport(peer, project, options.bluetoothPython!);
      try {
        await bluetooth.start();
      } catch (_) {
        stderr.writeln(
          'Optional Bluetooth bridge could not start; IP relay continues.',
        );
      }
    }
    stdout.writeln(
      'Listening: TCP${options.port}, UDP45872; advertised IPv4 ${options.host}.',
    );
    stdout.writeln(
      'This is a local test relay. It does not establish Iran/NIN reachability or publish fabricated news.',
    );
    printStatus(await peer.snapshot(), force: true);
    heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(
        peer.snapshot().then((status) => printStatus(status, force: true)),
      );
    });
    final stopped = Completer<void>();
    void stop() {
      if (!stopped.isCompleted) stopped.complete();
    }

    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      try {
        signals.add(
          signal.watch().listen(
            (_) => stop(),
            onError: (Object _) {
              stderr.writeln(
                'Optional process signal is unavailable; relay continues.',
              );
            },
          ),
        );
      } on SignalException {
        stderr.writeln(
          'Optional process signal is unavailable; relay continues.',
        );
      } on UnsupportedError {
        stderr.writeln(
          'Optional process signal is unavailable; relay continues.',
        );
      }
    }
    if (options.runForSeconds != null) {
      deadline = Timer(Duration(seconds: options.runForSeconds!), stop);
    }
    await stopped.future;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on SocketException catch (error) {
    stderr.writeln(
      'Local peer socket failed (OS code ${error.osError?.errorCode ?? 'unknown'}).',
    );
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(
      'Local peer storage or instance lock failed (OS code ${error.osError?.errorCode ?? 'unknown'}).',
    );
    exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Local peer failed. No private identity details were logged.',
    );
    exitCode = 1;
  } finally {
    heartbeat?.cancel();
    deadline?.cancel();
    for (final subscription in signals) {
      await subscription.cancel();
    }
    await bluetooth?.stop();
    await engine?.stop();
    await lock?.close();
  }
}

class _Options {
  bool help = false;
  bool selfTest = false;
  bool prepareOnly = false;
  String? host;
  int port = 45871;
  int? runForSeconds;
  String? bluetoothPython;

  static _Options parse(List<String> arguments) {
    final result = _Options();
    final seen = <String>{};
    for (var i = 0; i < arguments.length; i++) {
      final option = arguments[i];
      if (!seen.add(option)) throw const FormatException('Duplicate option.');
      String value() {
        if (++i >= arguments.length) {
          throw const FormatException('Missing option value.');
        }
        return arguments[i];
      }

      switch (option) {
        case '--bluetooth-python':
          result.bluetoothPython = value();
        case '--help':
        case '-h':
          result.help = true;
        case '--self-test':
          result.selfTest = true;
        case '--prepare-only':
          result.prepareOnly = true;
        case '--host':
          result.host = value();
        case '--port':
          result.port = int.tryParse(value()) ?? 0;
        case '--run-for':
          result.runForSeconds = int.tryParse(value()) ?? 0;
        default:
          throw const FormatException('Unknown option.');
      }
    }
    if (result.help) return result;
    if (result.selfTest) {
      if (arguments.length != 1) {
        throw const FormatException('Use --self-test alone.');
      }
      return result;
    }
    final address = result.host == null
        ? null
        : InternetAddress.tryParse(result.host!);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        address.isLoopback ||
        address.isMulticast ||
        address.address == '0.0.0.0' ||
        address.address == '255.255.255.255') {
      throw const FormatException(
        '--host must be this PC\'s numeric non-loopback IPv4.',
      );
    }
    result.host = address.address;
    if (result.port < 1 ||
        result.port > 65535 ||
        (result.runForSeconds != null && result.runForSeconds! < 1)) {
      throw const FormatException('Invalid port or run duration.');
    }
    if (result.prepareOnly && result.runForSeconds != null) {
      throw const FormatException(
        '--prepare-only and --run-for cannot be combined.',
      );
    }
    return result;
  }
}
