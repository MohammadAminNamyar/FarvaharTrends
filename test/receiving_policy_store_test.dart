import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/receiving_policy_store.dart';

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

  test('defaults to restart off, announce on; round trips choices', () async {
    final store = ReceivingPolicyStore(directory);
    final initial = await store.load();
    expect(initial.restartAfterReboot, isFalse);
    expect(initial.internetAnnounce, isTrue);
    expect(store.recovered, isFalse);
    await store.save(
      const ReceivingPolicy(restartAfterReboot: true, internetAnnounce: false),
    );
    expect(jsonDecode(await file().readAsString()), {
      'version': 3,
      'restartAfterReboot': true,
      'internetAnnounce': false,
      'publicDiscovery': true,
      'discoveryHelper': false,
    });
    final loaded = await ReceivingPolicyStore(directory).load();
    expect(loaded.restartAfterReboot, isTrue);
    expect(loaded.internetAnnounce, isFalse);
    await store.save(const ReceivingPolicy());
    final reset = await ReceivingPolicyStore(directory).load();
    expect(reset.restartAfterReboot, isFalse);
    expect(reset.internetAnnounce, isTrue);
    expect(await File('${file().path}.next').exists(), isFalse);
    expect(await File('${file().path}.bak').exists(), isFalse);
  });

  test('a version 1 file loads with the default announce setting', () async {
    await file().writeAsString('{"version":1,"restartAfterReboot":true}');
    final store = ReceivingPolicyStore(directory);
    final policy = await store.load();
    expect(policy.restartAfterReboot, isTrue);
    expect(policy.internetAnnounce, isTrue);
    expect(store.recovered, isFalse);
  });

  test('copyWith changes one field at a time', () {
    const base = ReceivingPolicy();
    expect(base.copyWith(internetAnnounce: false).restartAfterReboot, isFalse);
    expect(base.copyWith(internetAnnounce: false).internetAnnounce, isFalse);
    expect(base.copyWith(restartAfterReboot: true).internetAnnounce, isTrue);
  });

  test('existing settings never silently opt into routing; peer-only choice survives restart', () async {
    await file().writeAsString(
      '{"version":2,"restartAfterReboot":true,"internetAnnounce":true}',
    );
    final store = ReceivingPolicyStore(directory);
    final old = await store.load();
    expect(old.discoveryHelper, isFalse);
    expect(old.publicDiscovery, isTrue);
    await store.save(
      old.copyWith(publicDiscovery: false, discoveryHelper: true),
    );
    final restored = await ReceivingPolicyStore(directory).load();
    expect(restored.publicDiscovery, isFalse);
    expect(restored.discoveryHelper, isTrue);
    expect(restored.restartAfterReboot, isTrue);
    expect(restored.internetAnnounce, isTrue);
  });

  for (final content in [
    '{broken',
    '{"version":1,"restartAfterReboot":"yes"}',
    '{"version":2,"restartAfterReboot":true}',
    '{"version":2,"restartAfterReboot":true,"internetAnnounce":"no"}',
    '{"version":3,"restartAfterReboot":true,"internetAnnounce":true}',
    '{"version":1,"restartAfterReboot":true,"extra":1}',
    '[]',
  ]) {
    test('corrupt content $content fails closed and is quarantined', () async {
      await file().writeAsString(content);
      final store = ReceivingPolicyStore(directory);
      final policy = await store.load();
      expect(policy.restartAfterReboot, isFalse);
      expect(policy.internetAnnounce, isFalse);
      expect(policy.publicDiscovery, isFalse);
      expect(policy.discoveryHelper, isFalse);
      expect(store.recovered, isTrue);
      expect(await file().exists(), isTrue);
      final again = ReceivingPolicyStore(directory);
      final restored = await again.load();
      expect(restored.restartAfterReboot, isFalse);
      expect(restored.publicDiscovery, isFalse);
      expect(again.recovered, isFalse);
    });
  }

  test('an interrupted commit never re-arms the service', () async {
    await ReceivingPolicyStore(directory)
        .save(const ReceivingPolicy(restartAfterReboot: true));
    await File('${file().path}.next').writeAsString('{}');
    final store = ReceivingPolicyStore(directory);
    expect((await store.load()).restartAfterReboot, isFalse);
    expect(store.recovered, isTrue);
  });

  test('an oversized file fails closed', () async {
    await file().writeAsString(
      '{"version":1,"restartAfterReboot":true,"pad":"${'x' * 300}"}',
    );
    final store = ReceivingPolicyStore(directory);
    expect((await store.load()).restartAfterReboot, isFalse);
    expect(store.recovered, isTrue);
  });
}
