import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/delivery_mode.dart';
import 'package:persian_trend/core/delivery_mode_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    final root = Directory(
      '${Directory.current.path}/artifacts/delivery-mode-tests',
    );
    await root.create(recursive: true);
    directory = await root.createTemp('case-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'New installations commit automatic all-networks routing on first load',
    () async {
      final store = DeliveryModeStore(directory);
      expect(await store.load(), DeliveryMode.allNetworks);
      expect(store.recovered, isFalse);
      final preference = jsonDecode(
        await File('${directory.path}/delivery-mode.json').readAsString(),
      );
      expect(preference, {'version': 1, 'mode': 'allNetworks'});
      expect(
        await DeliveryModeStore(directory).load(),
        DeliveryMode.allNetworks,
      );
    },
  );

  test(
    'A missing preference after first load cannot reset to automatic routing',
    () async {
      expect(
        await DeliveryModeStore(directory).load(),
        DeliveryMode.allNetworks,
      );
      await File('${directory.path}/delivery-mode.json').delete();
      final store = DeliveryModeStore(directory);
      expect(await store.load(), DeliveryMode.nearbyOnly);
      expect(store.recovered, isTrue);
    },
  );

  test(
    'An interrupted first-use commit fails closed on the next load',
    () async {
      await File('${directory.path}/delivery-mode.initialized')
          .writeAsString('1');
      final store = DeliveryModeStore(directory);
      expect(await store.load(), DeliveryMode.nearbyOnly);
      expect(store.recovered, isTrue);
    },
  );

  for (final mode in DeliveryMode.values) {
    test(
      'An explicit legacy ${mode.name} choice survives upgrade and restart',
      () async {
        await File('${directory.path}/delivery-mode.json')
            .writeAsString(jsonEncode({'version': 1, 'mode': mode.name}));
        final store = DeliveryModeStore(directory);
        expect(await store.load(), mode);
        expect(store.recovered, isFalse);
        expect(await DeliveryModeStore(directory).load(), mode);
        await File('${directory.path}/delivery-mode.json').delete();
        expect(
          await DeliveryModeStore(directory).load(),
          DeliveryMode.nearbyOnly,
        );
      },
    );
  }

  for (final suffix in ['next', 'bak']) {
    for (final primaryExists in [false, true]) {
      test(
        'Interrupted .$suffix fails closed with primary=$primaryExists',
        () async {
          if (primaryExists) {
            await File(
              '${directory.path}/delivery-mode.json',
            ).writeAsString(jsonEncode({'version': 1, 'mode': 'allNetworks'}));
          }
          await File('${directory.path}/delivery-mode.json.$suffix')
              .writeAsString(jsonEncode({'version': 1, 'mode': 'allNetworks'}));
          final store = DeliveryModeStore(directory);
          expect(await store.load(), DeliveryMode.nearbyOnly);
          expect(store.recovered, isTrue);
        },
      );
    }
  }

  test(
    'A failed first-use default commit does not enable automatic routing',
    () async {
      final blockedDirectory = Directory('${directory.path}/blocked');
      await File(blockedDirectory.path).writeAsString('not a directory');
      final store = DeliveryModeStore(blockedDirectory);
      expect(await store.load(), DeliveryMode.nearbyOnly);
      expect(store.recovered, isTrue);
    },
  );

  test('Mode choices survive restart through a durable commit', () async {
    await DeliveryModeStore(directory).save(DeliveryMode.allNetworks);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.allNetworks);
    await DeliveryModeStore(directory).save(DeliveryMode.nearbyOnly);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
    expect(
      await File('${directory.path}/delivery-mode.json.bak').exists(),
      isFalse,
    );
  });

  for (final data in [
    '{',
    '[]',
    '{"version":1,"mode":"unknown"}',
    '{"version":2,"mode":"allNetworks"}',
    '{"version":1,"mode":"allNetworks","extra":true}',
    '{"version":1,"mode":true}',
    'x' * (DeliveryModeStore.maxBytes + 1),
  ]) {
    test(
      'An invalid primary fails closed without a backup (${data.length} bytes)',
      () async {
        await File('${directory.path}/delivery-mode.json').writeAsString(data);
        final store = DeliveryModeStore(directory);
        expect(await store.load(), DeliveryMode.nearbyOnly);
        expect(store.recovered, isTrue);
      },
    );
    test(
      'Invalid primary cannot restore a broader backup (${data.length} bytes)',
      () async {
        await File('${directory.path}/delivery-mode.json').writeAsString(data);
        await File('${directory.path}/delivery-mode.json.bak')
            .writeAsString(jsonEncode({'version': 1, 'mode': 'allNetworks'}));
        final store = DeliveryModeStore(directory);
        expect(await store.load(), DeliveryMode.nearbyOnly);
        expect(store.recovered, isTrue);
      },
    );
  }

  test(
    'An interrupted preference replacement cannot enable all networks',
    () async {
      await File('${directory.path}/delivery-mode.json.bak')
          .writeAsString(jsonEncode({'version': 1, 'mode': 'allNetworks'}));
      await File('${directory.path}/delivery-mode.json.next')
          .writeAsString(jsonEncode({'version': 1, 'mode': 'allNetworks'}));
      expect(
        await DeliveryModeStore(directory).load(),
        DeliveryMode.nearbyOnly,
      );
    },
  );

  test(
    'A failed commit is observable and cannot silently change selected mode',
    () async {
      final store = DeliveryModeStore(directory);
      await store.save(DeliveryMode.nearbyOnly);
      await Directory('${directory.path}/delivery-mode.json.next').create();
      await expectLater(
        store.save(DeliveryMode.allNetworks),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await DeliveryModeStore(directory).load(),
        DeliveryMode.nearbyOnly,
      );
    },
  );

  test('A failed restrictive commit cannot resume old all-networks mode after restart', () async {
    await DeliveryModeStore(directory).save(DeliveryMode.allNetworks);
    await Directory('${directory.path}/delivery-mode.json.next').create();
    await expectLater(
      DeliveryModeStore(directory).save(DeliveryMode.nearbyOnly),
      throwsA(isA<FileSystemException>()),
    );
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
  });

  test('A restrictive latch defeats a committed broader preference until explicitly changed', () async {
    await DeliveryModeStore(directory).save(DeliveryMode.allNetworks);
    await File('${directory.path}/delivery-mode.nearby-only')
        .writeAsString('1', flush: true);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
    await DeliveryModeStore(directory).save(DeliveryMode.allNetworks);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.allNetworks);
    expect(
      await File('${directory.path}/delivery-mode.nearby-only').exists(),
      isFalse,
    );
  });
}
