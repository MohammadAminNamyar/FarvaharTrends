import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/bootstrap_config.dart';
import 'package:farvahar_trends/core/bootstrap_store.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';

void main() {
  late Directory directory;
  late Identity a, b;
  var now = 1800000000000;

  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
  });
  setUp(() async {
    final root = Directory(
      '${Directory.current.path}/artifacts/bootstrap-store-tests',
    );
    await root.create(recursive: true);
    directory = await root.createTemp('case-');
    now = 1800000000000;
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  BootstrapStore store() => BootstrapStore(directory, now: () => now);
  File file() => File('${directory.path}/bootstrap-imported.json');
  PeerCard card(
    Identity identity, {
    String host = '11.0.113.9',
    int port = 7411,
  }) => PeerCard(
    name: 'Seed',
    host: host,
    port: port,
    certificatePem: identity.certPem,
  );

  test('imported peers and DHT nodes round trip with import times', () async {
    final imported = await store().import(
      BootstrapConfig(
        peers: [card(a)],
        dhtBootstrap: const ['11.0.113.1:49737'],
      ),
    );
    expect(imported.peers.single.importedAtMs, now);
    expect(imported.dhtBootstrap.single.importedAtMs, now);
    final loaded = await store().load();
    expect(loaded.peers.single.card.id, a.id);
    expect(loaded.dhtBootstrap.single.entry, '11.0.113.1:49737');
    expect(loaded.toConfig().peers.single.host, '11.0.113.9');
    expect(await File('${file().path}.next').exists(), isFalse);
    expect(await File('${file().path}.bak').exists(), isFalse);
  });

  test(
    'entries expire after ninety days and re-import refreshes them',
    () async {
      await store().import(BootstrapConfig(peers: [card(a)]));
      now += 89 * 24 * 60 * 60 * 1000;
      await store().import(BootstrapConfig(peers: [card(b)]));
      now += 2 * 24 * 60 * 60 * 1000;
      final loaded = await store().load();
      expect(loaded.peers.map((p) => p.card.id), [b.id]);
      expect(store().recovered, isFalse);
      // A refreshed import extends the entry's lifetime.
      await store().import(BootstrapConfig(peers: [card(b)]));
      now += 89 * 24 * 60 * 60 * 1000;
      expect((await store().load()).peers.single.card.id, b.id);
    },
  );

  test(
    'unsupported legacy DHT addresses do not discard valid contacts',
    () async {
      await store().import(
        BootstrapConfig(
          peers: [card(a)],
          dhtBootstrap: const ['11.0.113.1:49737'],
        ),
      );
      final data =
          jsonDecode(await file().readAsString()) as Map<String, dynamic>;
      (data['dhtBootstrap'] as List).add({
        'entry': '[2001:db8::1]:49737',
        'importedAtMs': now,
      });
      await file().writeAsString(jsonEncode(data));
      final recovered = store();
      final loaded = await recovered.load();
      expect(loaded.peers.single.card.id, a.id);
      expect(loaded.dhtBootstrap.single.entry, '11.0.113.1:49737');
      expect(recovered.recoveryWarning, 'bootstrap_entries_removed');
    },
  );

  test(
    'a corrupt file is quarantined with a warning and startup continues',
    () async {
      await file().writeAsString('{not json');
      final corrupt = store();
      expect((await corrupt.load()).isEmpty, isTrue);
      expect(corrupt.recoveryWarning, 'bootstrap_recovery');
      expect(corrupt.recovered, isTrue);
      expect(await file().exists(), isFalse);
      expect(await File('${file().path}.corrupt').exists(), isTrue);
      // A later load is clean again, and clear removes the quarantined copy.
      final clean = store();
      expect((await clean.load()).isEmpty, isTrue);
      expect(clean.recovered, isFalse);
      await clean.clear();
      expect(await File('${file().path}.corrupt').exists(), isFalse);
    },
  );

  test('a private key or unknown field in a stored card is rejected', () async {
    await file().writeAsString(
      jsonEncode({
        'version': 1,
        'peers': [
          {
            'card': {...card(a).toJson(), 'privateKey': 'x'},
            'importedAtMs': now,
          },
        ],
        'dhtBootstrap': [],
      }),
    );
    final loaded = store();
    expect((await loaded.load()).isEmpty, isTrue);
    expect(loaded.recoveryWarning, 'bootstrap_recovery');
  });

  test('an oversized file is quarantined', () async {
    await file().writeAsString('x' * (BootstrapStore.maxBytes + 1));
    final loaded = store();
    expect((await loaded.load()).isEmpty, isTrue);
    expect(loaded.recoveryWarning, 'bootstrap_recovery');
  });

  test('a surviving backup is restored after an interrupted commit', () async {
    await store().import(BootstrapConfig(peers: [card(a)]));
    await file().rename('${file().path}.bak');
    final loaded = store();
    expect((await loaded.load()).peers.single.card.id, a.id);
    expect(loaded.recoveryWarning, 'bootstrap_backup_restored');
    expect(await file().exists(), isTrue);
  });

  test('caps keep the newest sixteen entries', () async {
    for (var i = 1; i <= 18; i++) {
      now += 1000;
      await store().import(
        BootstrapConfig(
          peers: [card(i.isEven ? a : b, host: '11.0.113.$i')],
          dhtBootstrap: ['11.51.100.$i:49737'],
        ),
      );
    }
    final loaded = await store().load();
    expect(loaded.peers.length, BootstrapStore.maxPeers);
    expect(loaded.dhtBootstrap.length, BootstrapStore.maxDhtBootstrap);
    expect(loaded.peers.first.card.host, '11.0.113.18');
    expect(loaded.peers.any((p) => p.card.host == '11.0.113.1'), isFalse);
    expect(loaded.dhtBootstrap.first.entry, '11.51.100.18:49737');
  });

  test('clear forgets every imported entry', () async {
    await store().import(BootstrapConfig(peers: [card(a)]));
    await store().clear();
    expect((await store().load()).isEmpty, isTrue);
    expect(await file().exists(), isFalse);
  });
}
