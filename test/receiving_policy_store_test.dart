import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/receiving_policy_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    final root = Directory(
      '${Directory.current.path}/artifacts/receiving-policy-tests',
    );
    await root.create(recursive: true);
    directory = await root.createTemp('case-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  File file() => File('${directory.path}/receiving-policy.json');

  test('defaults to off and round trips an explicit choice', () async {
    final store = ReceivingPolicyStore(directory);
    expect(await store.load(), isFalse);
    expect(store.recovered, isFalse);
    await store.save(restartAfterReboot: true);
    expect(jsonDecode(await file().readAsString()), {
      'version': 1,
      'restartAfterReboot': true,
    });
    expect(await ReceivingPolicyStore(directory).load(), isTrue);
    await store.save(restartAfterReboot: false);
    expect(await ReceivingPolicyStore(directory).load(), isFalse);
    expect(await File('${file().path}.next').exists(), isFalse);
    expect(await File('${file().path}.bak').exists(), isFalse);
  });

  for (final content in [
    '{broken',
    '{"version":1,"restartAfterReboot":"yes"}',
    '{"version":2,"restartAfterReboot":true}',
    '{"version":1,"restartAfterReboot":true,"extra":1}',
    '[]',
  ]) {
    test('corrupt content $content fails closed and is quarantined', () async {
      await file().writeAsString(content);
      final store = ReceivingPolicyStore(directory);
      expect(await store.load(), isFalse);
      expect(store.recovered, isTrue);
      expect(await file().exists(), isFalse);
      final again = ReceivingPolicyStore(directory);
      expect(await again.load(), isFalse);
      expect(again.recovered, isFalse);
    });
  }

  test('an interrupted commit never re-arms the service', () async {
    await ReceivingPolicyStore(directory).save(restartAfterReboot: true);
    await File('${file().path}.next').writeAsString('{}');
    final store = ReceivingPolicyStore(directory);
    expect(await store.load(), isFalse);
    expect(store.recovered, isTrue);
  });

  test('an oversized file fails closed', () async {
    await file().writeAsString(
      '{"version":1,"restartAfterReboot":true,"pad":"${'x' * 300}"}',
    );
    final store = ReceivingPolicyStore(directory);
    expect(await store.load(), isFalse);
    expect(store.recovered, isTrue);
  });
}
