import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  late Identity local, manual, seed;
  late List<Identity> contacts;
  late List<Uint8List> beacons;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <Socket>[];
  setUpAll(() {
    local = Identity.generate();
    manual = Identity.generate();
    seed = Identity.generate();
    contacts = List.generate(9, (_) => Identity.generate());
    beacons = contacts.map((id) => PeerDiscovery.beacon(id, 45871)).toList();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('automatic-retention-');
  });
  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  PeerEngine create(
    String name, {
    Duration idle = const Duration(seconds: 1),
    Duration window = const Duration(minutes: 1),
    List<PeerCard> bootstrap = const [],
  }) {
    final result = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: local,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      automaticContactIdleTime: idle,
      trafficWindow: window,
      bootstrapPeers: bootstrap,
      deviceState: () async => {},
      onStatus: (_) {},
    );
    engines.add(result);
    return result;
  }

  Future<bool> admit(
    PeerEngine target,
    int index,
    String route, {
    bool keep = false,
  }) async {
    final result = await target.admitNativePeer(
      signedBeacon: beacons[index],
      routeId: route,
      transport: PeerTransport.wifiDirect,
    );
    if (result.accepted && !keep) await target.removeNativeRoute(route);
    return result.accepted;
  }

  Future<void> fill(PeerEngine target, {int? keep}) async {
    for (var i = 0; i < 8; i++) {
      expect(await admit(target, i, 'initial-$i', keep: i == keep), isTrue);
    }
  }

  Future<Set<String>> ids(PeerEngine target) async =>
      ((await target.snapshot())['peers'] as List)
          .map((peer) => (peer as Map)['id'] as String)
          .toSet();

  Future<SecureSocket> connect(PeerEngine target, int index) async {
    final id = contacts[index];
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(id.certPem))
        ..usePrivateKeyBytes(utf8.encode(id.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(local.certPem)),
      onBadCertificate: (cert) => Identity.certificateId(cert.pem) == local.id,
      timeout: const Duration(seconds: 3),
    );
    sockets.add(socket);
    socket.listen((_) {}, onError: (Object _) {});
    await until(() async => (await target.snapshot())['connectedCount'] == 1);
    return socket;
  }

  test('Stale persisted automatic pins rotate despite repeated beacons; manual and seeds survive', () async {
    final bootstrap = [
      PeerCard(
        name: 'Configured seed',
        certificatePem: seed.certPem,
        host: '127.0.0.1',
        port: 1,
      ),
    ];
    final target = create(
      'rotation',
      idle: const Duration(hours: 1),
      bootstrap: bootstrap,
    );
    await target.addPeer(
      PeerCard(name: 'Manual peer', certificatePem: manual.certPem),
    );
    await target.start(activeMode: false);
    await fill(target);
    expect(await admit(target, 8, 'too-early'), isFalse);
    await target.stop();
    // Persisted unverified contacts deliberately start eligible for rotation.
    // A beacon must not renew them: doing so would protect this pin for an hour,
    // independent of the test runner's scheduling or signature-validation cost.
    final reopened = create(
      'rotation',
      idle: const Duration(hours: 1),
      bootstrap: bootstrap,
    );
    await reopened.start(activeMode: false);
    expect(await admit(reopened, 0, 'repeated-beacon'), isTrue);
    expect(await admit(reopened, 8, 'new-contact'), isTrue);
    final retained = await ids(reopened);
    expect(retained, containsAll([manual.id, seed.id, contacts[8].id]));
    expect(retained, isNot(contains(contacts[0].id)));
    expect(retained.length, 10);
    final snapshot = await reopened.snapshot();
    expect(snapshot['discoveredCount'], 8);
    final peers = snapshot['peers'] as List;
    expect(peers.singleWhere((p) => p['id'] == manual.id)['origin'], 'manual');
    expect(peers.singleWhere((p) => p['id'] == seed.id)['origin'], 'bootstrap');
  });

  test(
    'Restarted unverified cache is immediately eligible, with durable rotation',
    () async {
      final first = create('restart', idle: const Duration(hours: 1));
      await first.addPeer(
        PeerCard(name: 'Manual peer', certificatePem: manual.certPem),
      );
      await first.start(activeMode: false);
      await fill(first);
      await first.stop();
      final reopened = create('restart', idle: const Duration(hours: 1));
      await reopened.start(activeMode: false);
      expect(await admit(reopened, 8, 'new-after-restart'), isTrue);
      expect(await ids(reopened), containsAll([manual.id, contacts[8].id]));
      expect(await ids(reopened), isNot(contains(contacts[0].id)));
      await reopened.stop();
      final again = create('restart');
      expect(await ids(again), contains(contacts[8].id));
      expect(await ids(again), isNot(contains(contacts[0].id)));
    },
  );

  test(
    'A new configured seed can replace an old auto pin in a full cache',
    () async {
      final first = create('bootstrap-full', idle: const Duration(hours: 1));
      final manualIdentities = [
        manual,
        contacts[8],
        ...List.generate(6, (_) => Identity.generate()),
      ];
      for (final id in manualIdentities) {
        await first.addPeer(
          PeerCard(name: 'Paired participant', certificatePem: id.certPem),
        );
      }
      await first.start(activeMode: false);
      await fill(first);
      expect((await ids(first)).length, PeerEngine.maxPeers);
      await first.stop();
      final reopened = create(
        'bootstrap-full',
        bootstrap: [
          PeerCard(
            name: 'New starting peer',
            certificatePem: seed.certPem,
            host: '127.0.0.1',
            port: 1,
          ),
        ],
      );
      final retained = await ids(reopened);
      expect(retained.length, PeerEngine.maxPeers);
      expect(retained, contains(seed.id));
      expect(retained, containsAll(manualIdentities.map((id) => id.id)));
      expect(retained, isNot(contains(contacts[0].id)));
    },
  );

  test(
    'Active TLS and admitted native routes protect old automatic pins',
    () async {
      final target = create('protected');
      await target.start(activeMode: false);
      await fill(target, keep: 1);
      await connect(target, 0);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(await admit(target, 8, 'new'), isTrue);
      final retained = await ids(target);
      expect(
        retained,
        containsAll([contacts[0].id, contacts[1].id, contacts[8].id]),
      );
      expect(retained, isNot(contains(contacts[2].id)));
      expect((await target.snapshot())['connectedCount'], 1);
    },
  );

  test(
    'Successful TLS adoption renews an automatic pin after the link closes',
    () async {
      final target = create('tls-renewal');
      await target.start(activeMode: false);
      await fill(target);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final socket = await connect(target, 0);
      socket.destroy();
      await until(() async => (await target.snapshot())['connectedCount'] == 0);
      expect(await admit(target, 8, 'new'), isTrue);
      final retained = await ids(target);
      expect(retained, containsAll([contacts[0].id, contacts[8].id]));
      expect(retained, isNot(contains(contacts[1].id)));
    },
  );

  test('An incomplete inbound TLS handshake keeps its possible pin until completion', () async {
    final target = create('handshake');
    await target.start(activeMode: false);
    await fill(target);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final raw = await Socket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
    );
    sockets.add(raw);
    raw.listen((_) {}, onError: (Object _) {});
    await until(
      () async => (await target.snapshot())['incomingHandshakeCount'] == 1,
    );
    expect(await admit(target, 8, 'during-handshake'), isFalse);
    expect(await ids(target), contains(contacts[0].id));
    raw.destroy();
    await until(
      () async => (await target.snapshot())['incomingHandshakeCount'] == 0,
    );
    expect(await admit(target, 8, 'after-handshake'), isTrue);
  });

  test(
    'New automatic pin churn is bounded, duplicates exempt, then recovers',
    () async {
      final target = create(
        'budget',
        idle: const Duration(microseconds: 1),
        // Signature checks and durable writes share CPU with the full suite.
        // Keep the denial window wider than those operations, then wait it out.
        window: const Duration(seconds: 20),
      );
      await target.start(activeMode: false);
      for (var i = 0; i < 16; i++) {
        expect(await admit(target, i % 9, 'admit-$i'), isTrue);
      }
      expect(await admit(target, 7, 'over-budget'), isFalse);
      expect(await admit(target, 6, 'known-contact'), isTrue);
      expect(
        ((await target.snapshot())['trafficDeferred'] as Map)['contacts'],
        1,
      );
      expect((await ids(target)).length, 8);
      await Future<void>.delayed(const Duration(seconds: 20));
      expect(await admit(target, 7, 'recovered'), isTrue);
    },
  );
}

Future<void> until(Future<bool> Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      fail('Retention condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}
