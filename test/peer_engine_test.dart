import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

void main() {
  late Identity a;
  late Identity b;
  late Identity stranger;
  late Directory scratch;
  final engines = <PeerEngine>[];

  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
    stranger = Identity.generate();
  });

  setUp(() async {
    final parent = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.tooling'
      '${Platform.pathSeparator}test-tmp',
    );
    await parent.create(recursive: true);
    scratch = await parent.createTemp('peer-engine-');
  });

  tearDown(() async {
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    // Tests only remove the fresh directory returned by createTemp under the
    // explicitly permitted project tree.
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  PeerEngine engine(
    Identity identity,
    String label, {
    int port = 0,
    bool? locked = true,
    bool discovery = false,
    int discoveryPort = 45872,
  }) {
    final clock = Stopwatch()..start();
    final result = PeerEngine(
      directory: Directory('${scratch.path}${Platform.pathSeparator}$label'),
      identity: identity,
      listenPort: port,
      enableLanDiscovery: discovery,
      discoveryPort: discoveryPort,
      deviceState: () async => {
        'elapsedRealtimeMs': clock.elapsedMilliseconds,
        'bootId': 'test-boot',
        'isLocked': locked,
        'wallTimeMs': DateTime.now().millisecondsSinceEpoch,
      },
      onStatus: (_) {},
    );
    engines.add(result);
    return result;
  }

  Future<void> until(Future<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Condition was not reached within 15 seconds.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<(PeerEngine, PeerEngine)> pair({bool? bLocked = true}) async {
    final left = engine(a, 'a');
    final right = engine(b, 'b', locked: bLocked);
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    final rightPort = (await right.snapshot())['listenPort'] as int;
    await left.addPeer(
      PeerCard(
        name: 'Receiver B',
        host: '127.0.0.1',
        port: rightPort,
        certificatePem: b.certPem,
      ),
    );
    // Restarting a port=0 engine allocates a new port, so learn the new one.
    final leftPort = (await left.snapshot())['listenPort'] as int;
    await right.addPeer(
      PeerCard(
        name: 'Source A',
        host: '127.0.0.1',
        port: leftPort,
        certificatePem: a.certPem,
      ),
    );
    final finalRightPort = (await right.snapshot())['listenPort'] as int;
    await left.addPeer(
      PeerCard(
        name: 'Receiver B',
        host: '127.0.0.1',
        port: finalRightPort,
        certificatePem: b.certPem,
      ),
    );
    // Only A needs to dial B; B may accept A without having a current A port.
    await until(() async => (await left.snapshot())['connectedCount'] == 1);
    return (left, right);
  }

  test('local peer activity records a pinned connection and verified news without read receipts', () async {
    final (left, right) = await pair();
    await until(
      () async => ((await right.snapshot())['temporaryPeerActivity'] as List)
          .any((row) => row['kind'] == 'connected'),
    );
    final channel = await left.createChannel(
      name: 'Activity test',
      description: '',
    );
    await left.publishToChannel(
      channelId: channel.id,
      text: 'A public article',
    );
    await until(
      () async => ((await right.snapshot())['temporaryPeerActivity'] as List)
          .any((row) => row['kind'] == 'bulletin_verified'),
    );
    final received = await right.snapshot();
    final log = received['temporaryPeerActivity'] as List;
    expect(
      log.where((row) => row['kind'] == 'bulletin_verified'),
      hasLength(1),
    );
    for (final row in log) {
      expect((row as Map).keys.toSet(), {
        'kind',
        'peerId',
        'atWallMs',
        'transport',
      });
    }
    expect(received['receiptCount'], 0);
    await right.clearTemporaryLog();
    final cleared = await right.snapshot();
    expect(cleared['temporaryPeerActivity'], isEmpty);
    expect(cleared['connectedCount'], 1);
    expect(cleared['bulletinCount'], 1);
    expect(cleared['channels'], hasLength(1));
    await right.removePeer(a.id);
    await until(
      () async => ((await right.snapshot())['temporaryPeerActivity'] as List)
          .any((row) => row['kind'] == 'disconnected'),
    );
    expect((await right.snapshot())['connectedCount'], 0);
  });

  SecurityContext clientContext(Identity client, Identity server) =>
      SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(client.certPem))
        ..usePrivateKeyBytes(utf8.encode(client.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(server.certPem));

  Future<SecureSocket> manualSocket(
    Identity client,
    Identity server,
    int port,
  ) => SecureSocket.connect(
    InternetAddress.loopbackIPv4,
    port,
    context: clientContext(client, server),
    onBadCertificate: (certificate) =>
        Identity.certificateId(certificate.pem) == server.id,
    timeout: const Duration(seconds: 3),
  );

  test(
    'paired TLS delivery is persisted before a signed locked receipt',
    () async {
      final (left, right) = await pair();
      const message = 'آزمایش خبر برای تلفن قفل‌شده';
      await left.publish(runId: 'locked-pilot', text: message);
      await until(() async {
        final trials = (await left.snapshot())['trials'] as List;
        return trials.isNotEmpty && (trials.first as Map)['confirmed'] == 1;
      });
      final receiver = await right.snapshot();
      expect(receiver['bulletinCount'], 1);
      expect((receiver['bulletins'] as List).first['text'], message);
      expect(receiver['receiptCount'], 1);
      final receiverReport = jsonDecode(await right.exportReport()) as Map;
      expect(receiverReport['publications'], isEmpty);
      expect(receiverReport['receivedBulletins'], hasLength(1));
      final receiverRows = receiverReport['receipts'] as List;
      expect(receiverRows, hasLength(1));
      expect(receiverRows.first['locked'], true);
      expect(receiverRows.first['lockStateKnown'], true);
      expect(receiverRows.first['verifiedAtWallMs'], isA<int>());
      expect(receiverRows.first['elapsedRealtimeMs'], isA<int>());
      final signed = SignedReceipt.fromJson(
        Map<String, dynamic>.from(receiverRows.first['signedReceipt'] as Map),
      );
      expect(signed.verifyAgainst({}, b), true);
      final trial = ((await left.snapshot())['trials'] as List).first as Map;
      expect(trial['enrolled'], 1);
      expect(trial['confirmed'], 1);
      expect(trial['unknown'], 0);

      final export = await left.exportReport();
      expect(export, isNot(contains(message)));
      expect(export, isNot(contains('PRIVATE KEY')));
      expect(export, isNot(contains('CERTIFICATE')));
      expect(export, isNot(contains('127.0.0.1')));
      expect(export, isNot(contains('Receiver B')));

      await right.stop();
      final reloaded = PeerEngine(
        directory: Directory('${scratch.path}${Platform.pathSeparator}b'),
        identity: b,
        deviceState: () async => {},
        onStatus: (_) {},
        listenPort: 0,
        enableLanDiscovery: false,
      );
      engines.add(reloaded);
      final restored = await reloaded.snapshot();
      expect(restored['peerCount'], 1);
      expect(restored['bulletinCount'], 1);
      expect(restored['receiptCount'], 1);
    },
  );

  test('timely unlocked receipt never counts as locked confirmation', () async {
    final (left, _) = await pair(bLocked: false);
    await left.publish(runId: 'unlocked-pilot', text: 'Control message');
    await until(() async {
      final trials = (await left.snapshot())['trials'] as List;
      return trials.isNotEmpty && (trials.first as Map)['timelyUnlocked'] == 1;
    });
    final trial = ((await left.snapshot())['trials'] as List).first as Map;
    expect(trial['confirmed'], 0);
    expect(trial['timelyUnlocked'], 1);
  });

  test(
    'removing an unreachable peer retains the publication denominator',
    () async {
      final source = engine(a, 'source');
      // Trust-only enrollment is intentionally included in the frozen roster.
      await source.addPeer(PeerCard(name: 'Absent', certificatePem: b.certPem));
      expect((await source.snapshot())['peerCount'], 1);
      await source.start(activeMode: false);
      await source.publish(runId: 'missing-control', text: 'No path');
      await source.removePeer(b.id);
      final status = await source.snapshot();
      expect(status['peerCount'], 0);
      final trial = (status['trials'] as List).first as Map;
      expect(trial['enrolled'], 1);
      expect(trial['unknown'], 1);
      expect(trial['confirmed'], 0);
    },
  );

  test('unknown client certificate cannot inject a bulletin', () async {
    final source = engine(a, 'source');
    await source.addPeer(PeerCard(name: 'Known B', certificatePem: b.certPem));
    await source.start(activeMode: false);
    final port = (await source.snapshot())['listenPort'] as int;
    SecureSocket? socket;
    try {
      socket = await manualSocket(stranger, a, port);
      socket.listen((_) {}, onError: (_) {});
      socket.add(
        utf8.encode(
          '${jsonEncode({'type': 'bulletin', 'value': SignedBulletin.create(stranger, runId: 'unpaired', text: 'Untrusted', sequence: 1).toJson()})}\n',
        ),
      );
      try {
        await socket.flush();
      } catch (_) {}
    } catch (_) {
      // Either handshake rejection or immediate post-handshake rejection is
      // permitted by TLS versions; no application object may be admitted.
    }
    await until(() async => (await source.snapshot())['rejectedCount'] != 0);
    expect((await source.snapshot())['bulletinCount'], 0);
    socket?.destroy();
  });

  test('paired transport rejects altered signed content', () async {
    final source = engine(a, 'source');
    await source.addPeer(PeerCard(name: 'Known B', certificatePem: b.certPem));
    await source.start(activeMode: false);
    final port = (await source.snapshot())['listenPort'] as int;
    final socket = await manualSocket(b, a, port);
    socket.listen((_) {}, onError: (_) {});
    final valid = SignedBulletin.create(
      b,
      runId: 'tamper',
      text: 'Original',
      sequence: 1,
    ).toJson();
    final body = jsonDecode(
      utf8.decode(base64Decode(valid['payloadBase64'] as String)),
    ) as Map<String, dynamic>;
    body['text'] = 'Altered';
    valid['payloadBase64'] = base64Encode(utf8.encode(jsonEncode(body)));
    socket.add(
      utf8.encode('${jsonEncode({'type': 'bulletin', 'value': valid})}\n'),
    );
    await socket.flush();
    await until(() async => (await source.snapshot())['rejectedCount'] != 0);
    expect((await source.snapshot())['bulletinCount'], 0);
    socket.destroy();
  });

  test(
    'journal recovers a partial tail and enforces cache retention',
    () async {
      final storeDir = Directory(
        '${scratch.path}${Platform.pathSeparator}store',
      );
      final store = PilotStore(storeDir);
      await store.load();
      for (var i = 0; i < PilotStore.maxBulletins + 3; i++) {
        await store.putBulletin({'id': i.toString(), 'test': true});
      }
      final journal = File(
        '${storeDir.path}${Platform.pathSeparator}pilot.jsonl',
      );
      await journal.writeAsString(
        '{"kind":',
        mode: FileMode.append,
        flush: true,
      );
      final restored = PilotStore(storeDir);
      await restored.load();
      expect(restored.bulletins.length, PilotStore.maxBulletins);
      expect(restored.bulletins.containsKey('0'), false);
      expect(restored.evictions['bulletins'], 3);
    },
    // Hundreds of flushed journal writes can be slow alongside emulator/build IO.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('duplicate repairs a committed bulletin lacking its receipt', () async {
    final storeDir = Directory('${scratch.path}/recovery');
    final store = PilotStore(storeDir);
    await store.load();
    final bulletin = SignedBulletin.create(
      a,
      runId: 'recovery',
      text: 'Committed before interruption',
      sequence: 1,
    );
    await store.putBulletin(bulletin.toJson());
    final receiver = PeerEngine(
      directory: storeDir,
      identity: b,
      listenPort: 0,
      enableLanDiscovery: false,
      deviceState: () async => {
        'isLocked': true,
        'elapsedRealtimeMs': 8000,
        'bootId': 'recovery-boot',
      },
      onStatus: (_) {},
    );
    engines.add(receiver);
    await receiver.addPeer(PeerCard(name: 'Origin', certificatePem: a.certPem));
    await receiver.start(activeMode: false);
    final socket = await manualSocket(
      a,
      b,
      (await receiver.snapshot())['listenPort'] as int,
    );
    socket.listen((_) {}, onError: (_) {});
    socket.add(
      utf8.encode(
        '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
      ),
    );
    await socket.flush();
    await until(() async => (await receiver.snapshot())['receiptCount'] == 1);
    final status = await receiver.snapshot();
    expect(status['bulletinCount'], 1);
    expect(status['duplicateCount'], 1);
    socket.destroy();
  });

  test('unavailable lock state is unknown rather than unlocked', () async {
    final (left, _) = await pair(bLocked: null);
    await left.publish(runId: 'unknown-lock', text: 'Control message');
    await until(() async {
      final publications = (await left.snapshot())['publications'] as List;
      return publications.isNotEmpty &&
          (publications.first as Map)['received'] == 1;
    });
    final trial = ((await left.snapshot())['trials'] as List).first as Map;
    expect(trial['confirmed'], 0);
    expect(trial['timelyUnlocked'], 0);
    expect(trial['unknown'], 1);
  });

  test('late signed receipt does not prove the five-minute deadline', () async {
    var nativeElapsed = 1000;
    final left = PeerEngine(
      directory: Directory('${scratch.path}/late'),
      identity: a,
      listenPort: 0,
      enableLanDiscovery: false,
      deviceState: () async => {
        'elapsedRealtimeMs': nativeElapsed,
        'bootId': 'test-boot',
        'isLocked': true,
      },
      onStatus: (_) {},
    );
    engines.add(left);
    await left.addPeer(PeerCard(name: 'Known B', certificatePem: b.certPem));
    await left.start(activeMode: false);
    await left.publish(runId: 'late-control', text: 'Fresh control');
    final status = await left.snapshot();
    final bulletin = (status['bulletins'] as List).first as Map;
    nativeElapsed = 401000;
    final receipt = SignedReceipt.create(
      b,
      bulletinId: bulletin['id'] as String,
      sourceId: a.id,
      runId: 'late-control',
      locked: true,
      elapsedRealtimeMs: 1234,
    );
    final socket = await manualSocket(b, a, status['listenPort'] as int);
    socket.listen((_) {}, onError: (_) {});
    socket.add(
      utf8.encode(
        '${jsonEncode({'type': 'receipt', 'value': receipt.toJson()})}\n',
      ),
    );
    await socket.flush();
    await until(() async {
      final publications = (await left.snapshot())['publications'] as List;
      return (publications.first as Map)['received'] == 1;
    });
    final trial = ((await left.snapshot())['trials'] as List).first as Map;
    expect(trial['confirmed'], 0);
    expect(trial['unknown'], 1);
    expect((trial['receipts'] as List).first['sourceUpperBoundMs'], 400000);
    socket.destroy();
  });

  test(
    'signed bulletin and receipt gossip through an explicit intermediate',
    () async {
      final reservations = await Future.wait(
        List.generate(
          3,
          (_) => ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        ),
      );
      final ports = reservations.map((socket) => socket.port).toList();
      for (final socket in reservations) {
        await socket.close();
      }
      final left = engine(a, 'gossip-a', port: ports[0]);
      final relay = engine(b, 'gossip-b', port: ports[1]);
      final right = engine(stranger, 'gossip-c', port: ports[2]);
      await left.addPeer(
        PeerCard(
          name: 'Relay',
          host: '127.0.0.1',
          port: ports[1],
          certificatePem: b.certPem,
        ),
      );
      await left.addPeer(
        PeerCard(name: 'Receiver', certificatePem: stranger.certPem),
      );
      await relay.addPeer(PeerCard(name: 'Origin', certificatePem: a.certPem));
      await relay.addPeer(
        PeerCard(
          name: 'Receiver',
          host: '127.0.0.1',
          port: ports[2],
          certificatePem: stranger.certPem,
        ),
      );
      await right.addPeer(PeerCard(name: 'Origin', certificatePem: a.certPem));
      await right.addPeer(PeerCard(name: 'Relay', certificatePem: b.certPem));
      await right.start(activeMode: false);
      await relay.start(activeMode: false);
      await left.start(activeMode: false);
      await until(() async => (await relay.snapshot())['connectedCount'] == 2);
      await left.publish(runId: 'three-nodes', text: 'Gossip control');
      await until(() async {
        final trials = (await left.snapshot())['trials'] as List;
        return trials.isNotEmpty && (trials.first as Map)['confirmed'] == 2;
      });
      expect((await right.snapshot())['bulletinCount'], 1);
      final trial = ((await left.snapshot())['trials'] as List).first as Map;
      expect(trial['enrolled'], 2);
      expect(trial['confirmed'], 2);
      expect((await left.snapshot())['connectedCount'], 1);
    },
  );

  test('signed discovery uses observed source, tolerates clock skew and rejects tamper', () {
    final bytes = PeerDiscovery.beacon(b, 45871, nowMs: 1);
    final card = PeerDiscovery.parseBeacon(
      bytes,
      InternetAddress('192.0.2.17'),
    );
    expect(card.host, '192.0.2.17');
    expect(card.id, b.id);
    final altered = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    altered['port'] = 12345;
    expect(
      () => PeerDiscovery.parseBeacon(
        Uint8List.fromList(utf8.encode(jsonEncode(altered))),
        InternetAddress.loopbackIPv4,
      ),
      throwsFormatException,
    );
    altered['host'] = '203.0.113.9';
    expect(
      () => PeerDiscovery.parseBeacon(
        Uint8List.fromList(utf8.encode(jsonEncode(altered))),
        InternetAddress.loopbackIPv4,
      ),
      throwsFormatException,
    );
    expect(
      () => PeerDiscovery.parseBeacon(
        Uint8List(4097),
        InternetAddress.loopbackIPv4,
      ),
      throwsFormatException,
    );
  });

  test(
    'real UDP beacon admission is deduplicated and can be stopped',
    () async {
      final received = <PeerCard>[];
      final discovery = PeerDiscovery(
        identity: a,
        listenPort: 45871,
        port: 0,
        multicast: false,
        onPeer: received.add,
        onDiagnostic: (_) {},
      );
      await discovery.start();
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        final beacon = PeerDiscovery.beacon(b, 32123);
        sender.send(beacon, InternetAddress.loopbackIPv4, discovery.localPort!);
        sender.send(beacon, InternetAddress.loopbackIPv4, discovery.localPort!);
        await until(() async => received.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, hasLength(1));
        expect(received.single.host, '127.0.0.1');
        expect(received.single.port, 32123);
      } finally {
        sender.close();
        await discovery.stop();
      }
      expect(discovery.localPort, isNull);
    },
  );

  test('discovery auto-connects as unverified and excludes auto contacts from trials', () async {
    final reserve = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final udpPort = reserve.port;
    reserve.close();
    final left = engine(a, 'auto-a', discovery: true, discoveryPort: udpPort);
    final right = engine(b, 'auto-b');
    await right.addPeer(
      PeerCard(name: 'A enrolled on B only', certificatePem: a.certPem),
    );
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    final sender = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    sender.send(
      PeerDiscovery.beacon(b, (await right.snapshot())['listenPort'] as int),
      InternetAddress.loopbackIPv4,
      udpPort,
    );
    sender.close();
    await until(() async => (await left.snapshot())['connectedCount'] == 1);
    final status = await left.snapshot();
    expect(status['discoveredCount'], 1);
    expect(status['discoveryState'], 'connected');
    expect(status['bootstrapConfiguredCount'], 0);
    expect((status['peers'] as List).single['trust'], 'unverified');
    final channel = await left.createChannel(name: 'Automatic test');
    await left.publishToChannel(
      channelId: channel.id,
      text: 'Actual signed channel news',
    );
    await until(() async => (await right.snapshot())['bulletinCount'] == 1);
    expect(((await left.snapshot())['trials'] as List), isEmpty);
    expect((await left.snapshot())['receiptCount'], 0);
    expect((await right.snapshot())['receiptCount'], 0);
    expect(
      ((await right.snapshot())['channels'] as List).single['owned'],
      false,
    );
  });

  test('offline channel news catches up across relay without pairing its publisher', () async {
    final left = engine(a, 'channel-a');
    final middle = engine(b, 'channel-b');
    final right = engine(stranger, 'channel-c');
    final channel = await left.createChannel(
      name: 'Publisher key',
      description: 'Unverified person',
    );
    await left.publishToChannel(
      channelId: channel.id,
      text: 'Queued while offline',
    );
    for (final item in [left, middle, right]) {
      await item.start(activeMode: false);
    }
    await left.addPeer(
      PeerCard(
        name: 'B',
        host: '127.0.0.1',
        port: (await middle.snapshot())['listenPort'] as int,
        certificatePem: b.certPem,
      ),
    );
    await middle.addPeer(PeerCard(name: 'A', certificatePem: a.certPem));
    await middle.addPeer(
      PeerCard(
        name: 'C',
        host: '127.0.0.1',
        port: (await right.snapshot())['listenPort'] as int,
        certificatePem: stranger.certPem,
      ),
    );
    await right.addPeer(PeerCard(name: 'B', certificatePem: b.certPem));
    await until(() async => (await right.snapshot())['bulletinCount'] == 1);
    final status = await right.snapshot();
    expect((status['peers'] as List).any((p) => p['id'] == a.id), false);
    expect((status['channels'] as List).single['trust'], 'unverified');
    expect((status['bulletins'] as List).single['channelId'], channel.id);
    expect(status['receiptCount'], 0);
    expect((await middle.snapshot())['receiptCount'], 0);
    expect((await left.snapshot())['receiptCount'], 0);
    expect((await left.snapshot())['connectedCount'], 1);
    await expectLater(
      right.publishToChannel(channelId: channel.id, text: 'Hijack'),
      throwsStateError,
    );
  });

  test('linked bulletin waits for its signed owner announcement', () async {
    final receiver = engine(a, 'pending-channel');
    await receiver.addPeer(
      PeerCard(name: 'Transport B', certificatePem: b.certPem),
    );
    await receiver.start(activeMode: false);
    final socket = await manualSocket(
      b,
      a,
      (await receiver.snapshot())['listenPort'] as int,
    );
    socket.listen((_) {}, onError: (_) {});
    final channel = SignedChannel.create(
      stranger,
      name: 'Unknown person with valid key',
    );
    final bulletin = SignedBulletin.create(
      stranger,
      runId: 'news',
      text: 'Owner signed',
      sequence: 1,
      channelId: channel.id,
    );
    socket.add(
      utf8.encode(
        '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
      ),
    );
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await receiver.snapshot())['bulletinCount'], 0);
    socket.add(
      utf8.encode(
        '${jsonEncode({'type': 'channel', 'value': channel.toJson()})}\n',
      ),
    );
    await socket.flush();
    await until(() async => (await receiver.snapshot())['bulletinCount'] == 1);
    final forged = SignedBulletin.create(
      b,
      runId: 'news',
      text: 'Wrong owner',
      sequence: 2,
      channelId: channel.id,
    );
    socket.add(
      utf8.encode(
        '${jsonEncode({'type': 'bulletin', 'value': forged.toJson()})}\n',
      ),
    );
    await socket.flush();
    await until(() async => (await receiver.snapshot())['rejectedCount'] == 1);
    expect((await receiver.snapshot())['bulletinCount'], 1);
    socket.destroy();
  });

  test(
    'established silent peer is disconnected by the monotonic watchdog',
    () async {
      final server = await SecureServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        clientContext(b, a),
        requestClientCertificate: true,
        requireClientCertificate: true,
      );
      final sockets = <SecureSocket>[];
      final subscription = server.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {}, onError: (_) {});
      }, onError: (_) {});
      final left = PeerEngine(
        directory: Directory('${scratch.path}/idle'),
        identity: a,
        listenPort: 0,
        enableLanDiscovery: false,
        readIdleTimeout: const Duration(milliseconds: 200),
        deviceState: () async => {},
        onStatus: (_) {},
      );
      engines.add(left);
      await left.addPeer(
        PeerCard(
          name: 'Silent known key',
          host: '127.0.0.1',
          port: server.port,
          certificatePem: b.certPem,
        ),
      );
      await left.start(activeMode: false);
      await until(() async => (await left.snapshot())['connectedCount'] == 1);
      await until(
        () async => ((await left.snapshot())['events'] as List).any(
          (e) => e['kind'] == 'read_idle_timeout',
        ),
      );
      expect((await left.snapshot())['connectedCount'], 0);
      await left.stop();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    },
  );

  test('outgoing peer pin rejects a different valid TLS server', () async {
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      clientContext(stranger, a),
      requestClientCertificate: true,
      requireClientCertificate: true,
    );
    final subscription = server.listen((socket) {
      socket.listen((_) {}, onError: (_) {});
    }, onError: (_) {});
    final left = engine(a, 'pinning');
    await left.addPeer(
      PeerCard(
        name: 'Expected B',
        host: '127.0.0.1',
        port: server.port,
        certificatePem: b.certPem,
      ),
    );
    await left.start(activeMode: false);
    await until(() async {
      return ((await left.snapshot())['events'] as List).any(
        (event) => event['kind'] == 'connect_failed',
      );
    });
    expect((await left.snapshot())['connectedCount'], 0);
    await subscription.cancel();
    await server.close();
  });

  test(
    'silent TLS peer times out and releases its underlying connection',
    () async {
      final blackhole = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sockets = <Socket>[];
      var closed = 0;
      final subscription = blackhole.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {}, onDone: () => closed++, onError: (_) {});
      });
      final left = engine(a, 'silent-peer');
      await left.addPeer(
        PeerCard(
          name: 'Silent B',
          host: '127.0.0.1',
          port: blackhole.port,
          certificatePem: b.certPem,
        ),
      );
      await left.start(activeMode: false);
      await until(
        () async => ((await left.snapshot())['events'] as List).any(
          (event) => event['reason'] == 'connection_timeout',
        ),
      );
      await left.stop();
      await until(() async => sockets.isNotEmpty && closed == sockets.length);
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await blackhole.close();
    },
  );
}
