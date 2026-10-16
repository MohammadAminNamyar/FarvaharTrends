import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/envelope_crypto_worker.dart';

void main() {
  for (final mode in EnvelopeCryptoMode.values) {
    test(
      'nested ${mode.name} cells use independent entry and exit keys',
      () async {
        final root = await Directory('.tooling/test-tmp')
            .createTemp('envelope-crypto-');
        final workers = <EnvelopeCryptoWorker>[];
        try {
          final publisher = await EnvelopeCryptoWorker.start(
            Directory('${root.path}/publisher'),
            mode: mode,
          );
          final entry = await EnvelopeCryptoWorker.start(
            Directory('${root.path}/entry'),
            mode: mode,
          );
          final exit = await EnvelopeCryptoWorker.start(
            Directory('${root.path}/exit'),
            mode: mode,
          );
          workers.addAll([publisher, entry, exit]);
          final id = 'a' * 64, payload = {'text': 'خبر آزمایشی', 'n': 1};
          final cell = await publisher.seal(
            payload,
            exitId: id,
            exitKey: exit.publicKey,
            guardKey: entry.publicKey,
          );
          expect(cell.length, 8192);
          final opened = await entry.openEntry(cell);
          expect(opened['exitId'], id);
          final inner = opened['cell'] as Uint8List;
          expect(inner.length, EnvelopeCryptoWorker.innerSize);
          expect(await exit.openExit(inner), payload);
          if (mode == EnvelopeCryptoMode.hpke) {
            await expectLater(
              publisher.openEntry(cell),
              throwsA(isA<FormatException>()),
            );
            await expectLater(
              entry.openExit(inner),
              throwsA(isA<FormatException>()),
            );
            final bad = Uint8List.fromList(cell)..[100] ^= 1;
            await expectLater(
              entry.openEntry(bad),
              throwsA(isA<FormatException>()),
            );
          }
          final previous = List<int>.from(exit.publicKey);
          await exit.close();
          final reopened = await EnvelopeCryptoWorker.start(
            Directory('${root.path}/exit'),
            mode: mode,
          );
          workers.add(reopened);
          expect(reopened.publicKey, previous);
          expect(await reopened.openExit(inner), payload);
          await expectLater(
            publisher.seal(
              {'text': 'x' * 9000},
              exitId: id,
              exitKey: reopened.publicKey,
              guardKey: entry.publicKey,
            ),
            throwsA(isA<FormatException>()),
          );
        } finally {
          for (final worker in workers) {
            await worker.close();
          }
          await root.delete(recursive: true);
        }
      },
    );
  }
}
