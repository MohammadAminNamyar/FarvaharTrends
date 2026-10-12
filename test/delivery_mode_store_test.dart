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

  test('New installations and upgrades default to nearby only', () async {
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
  });

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
