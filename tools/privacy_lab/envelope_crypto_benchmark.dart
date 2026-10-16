// Host microbenchmark only. Never imported by the app; no phone/battery claim.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farvahar_trends/core/envelope_crypto_worker.dart';

import 'measurement.dart';

Future<void> main() async {
  final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
  await parent.create(recursive: true);
  final results = <Map<String, dynamic>>[];
  final cpu = ProcessCpu();
  for (var session = 0; session < 3; session++) {
    final modes = session.isEven
        ? EnvelopeCryptoMode.values
        : EnvelopeCryptoMode.values.reversed;
    for (final mode in modes) {
      final root = await parent.createTemp('envelope-cost-');
      final startup = Stopwatch()..start();
      final workers = <EnvelopeCryptoWorker>[];
      try {
        for (var i = 0; i < 3; i++) {
          workers.add(
            await EnvelopeCryptoWorker.start(
              Directory('${root.path}/$i'),
              mode: mode,
            ),
          );
        }
        final startupMs = startup.elapsedMilliseconds;
        final payload = {
          'o': 'a' * 64,
          'g': 'b' * 32,
          'i': 0,
          'n': 1,
          'p': base64Encode(Uint8List(5600)),
        };
        Future<void> cycle() async {
          final outer = await workers[0].seal(
            payload,
            exitId: 'c' * 64,
            exitKey: workers[2].publicKey,
            guardKey: workers[1].publicKey,
          );
          final entry = await workers[1].openEntry(outer);
          final result = await workers[2].openExit(entry['cell'] as Uint8List);
          if (result['p'] != payload['p']) {
            throw StateError('Crypto benchmark integrity');
          }
        }

        // Every worker warms its actual crypto/IPC path, separately per mode.
        for (var i = 0; i < 20; i++) {
          await cycle();
        }
        final samples = <int>[];
        final begin = cpu.readMs(), wall = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          final tick = Stopwatch()..start();
          await cycle();
          samples.add(tick.elapsedMicroseconds);
        }
        final consumed = cpu.readMs() - begin;
        samples.sort();
        results.add({
          'session': session,
          'mode': mode.name,
          'startupMs': startupMs,
          'cells': samples.length,
          'wallMs': wall.elapsedMilliseconds,
          'processCpuMs': consumed,
          'cpuMsPerCell': consumed / samples.length,
          'cycleMedianMs': samples[50] / 1000,
          'cycleP95Ms': samples[95] / 1000,
          'cycleMaxMs': samples.last / 1000,
          'ciphertextBytesTwoHops':
              EnvelopeCryptoWorker.outerSize + EnvelopeCryptoWorker.innerSize,
          'scope': 'host process; two seals + two opens + IPC + base64/JSON; no TLS, RSA signatures, disk, radios or UI',
        });
        stdout.writeln(jsonEncode(results.last));
      } finally {
        for (final worker in workers) {
          await worker.close();
        }
        if (root.absolute.path.startsWith(
          '${parent.absolute.path}${Platform.pathSeparator}',
        )) {
          await root.delete(recursive: true);
        }
      }
    }
  }
  final file = File(
    'artifacts/privacy-lab/envelope-crypto-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(results));
}
