import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/tcp_enrollment.dart';

void main() {
  late Identity a, b, firstRelay, secondRelay, wrong;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <RawSocket>[];
  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
    firstRelay = Identity.generate();
    secondRelay = Identity.generate();
    wrong = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('tcp-relay-');
  });
  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  PeerEngine create(
    Identity identity,
    String name, {
    bool relay = false,
    List<PeerCard> seeds = const [],
  }) {
    final engine = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: identity,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      acceptTcpEnrollment: relay,
      bootstrapPeers: seeds,
      deviceState: () async => {},
      onStatus: (_) {},
    );
    engines.add(engine);
    return engine;
  }

  Future<PeerCard> card(PeerEngine relay, {Identity? pin}) async => PeerCard(
    name: 'Configured test relay',
    certificatePem: (pin ?? relay.identity).certPem,
    host: '127.0.0.1',
    port: (await relay.snapshot())['listenPort'] as int,
    tcpEnrollment: true,
  );

  Future<int> connected(PeerEngine engine) async =>
      (await engine.snapshot())['connectedCount'] as int;

  Future<void> expectNews(PeerEngine target, String text) => until(() async {
    final items = (await target.snapshot())['bulletins'] as List;
    return items.any((item) => item['text'] == text);
  });

  Future<RawSocket> raw(PeerEngine target) async {
    final socket = await RawSocket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
    );
    sockets.add(socket);
    return socket;
  }

  test(
    'Unknown outbound clients receive once-published news with UDP disabled',
    () async {
      final relay = create(firstRelay, 'relay', relay: true);
      await relay.start(activeMode: false);
      final seed = await card(relay);
      final sender = create(a, 'sender', seeds: [seed]);
      final receiver = create(b, 'receiver', seeds: [seed]);
      await sender.start(activeMode: false);
      await receiver.start(activeMode: false);
      await until(() async => await connected(relay) == 2);
      final channel = await sender.createChannel(name: 'TCP-only public news');
      await sender.publishToChannel(
        channelId: channel.id,
        text: 'Fresh TCP marker',
      );
      await expectNews(receiver, 'Fresh TCP marker');
      final status = await receiver.snapshot();
      expect(status['bulletins'].single['receivedVia'], 'ip');
      expect(status['bulletins'].single['sourceId'], a.id);
      final relayPeers = (await relay.snapshot())['peers'] as List;
      expect(relayPeers.map((peer) => peer['id']), containsAll([a.id, b.id]));
      expect(relayPeers.every((peer) => peer['host'] == ''), isTrue);
      expect(relayPeers.every((peer) => peer['endpointCount'] == 0), isTrue);
      expect(relayPeers.every((peer) => peer['trust'] == 'unverified'), isTrue);
    },
  );

  test('A relay retains news for a recipient that connects later', () async {
    final relay = create(firstRelay, 'offline-relay', relay: true);
    await relay.start(activeMode: false);
    final seed = await card(relay);
    final sender = create(a, 'offline-sender', seeds: [seed]);
    await sender.start(activeMode: false);
    await until(() async => await connected(relay) == 1);
    final channel = await sender.createChannel(name: 'Offline recipient');
    await sender.publishToChannel(
      channelId: channel.id,
      text: 'Stored only once',
    );
    await expectNews(relay, 'Stored only once');
    await sender.stop();
    final receiver = create(b, 'late-receiver', seeds: [seed]);
    await receiver.start(activeMode: false);
    await expectNews(receiver, 'Stored only once');
  });

  test(
    'Two volunteer relays forward news without exchanging client addresses',
    () async {
      final right = create(secondRelay, 'right-relay', relay: true);
      await right.start(activeMode: false);
      final left = create(
        firstRelay,
        'left-relay',
        relay: true,
        seeds: [await card(right)],
      );
      await left.start(activeMode: false);
      final sender = create(a, 'left-client', seeds: [await card(left)]);
      final receiver = create(b, 'right-client', seeds: [await card(right)]);
      await sender.start(activeMode: false);
      await receiver.start(activeMode: false);
      await until(
        () async => await connected(left) == 2 && await connected(right) == 2,
      );
      final channel = await sender.createChannel(
        name: 'Federated volunteer relays',
      );
      await sender.publishToChannel(
        channelId: channel.id,
        text: 'Two-relay fresh marker',
      );
      await expectNews(receiver, 'Two-relay fresh marker');
      final receiverPeers = (await receiver.snapshot())['peers'] as List;
      expect(receiverPeers.map((peer) => peer['id']), [secondRelay.id]);
    },
  );

  test(
    'Connected secondary relay continues after the first relay stops',
    () async {
      final first = create(firstRelay, 'failover-first', relay: true);
      final second = create(secondRelay, 'failover-second', relay: true);
      await first.start(activeMode: false);
      await second.start(activeMode: false);
      final seeds = [await card(first), await card(second)];
      final sender = create(a, 'failover-sender', seeds: seeds);
      final receiver = create(b, 'failover-receiver', seeds: seeds);
      await sender.start(activeMode: false);
      await receiver.start(activeMode: false);
      await until(
        () async =>
            await connected(sender) == 2 && await connected(receiver) == 2,
      );
      await first.stop();
      await until(
        () async =>
            await connected(sender) == 1 && await connected(receiver) == 1,
      );
      final channel = await sender.createChannel(name: 'Surviving seed');
      await sender.publishToChannel(
        channelId: channel.id,
        text: 'After relay failure',
      );
      await expectNews(receiver, 'After relay failure');
      expect((await receiver.snapshot())['bulletinCount'], 1);
    },
  );

  test(
    'A bad seed cannot stop automatic connection to a reachable seed',
    () async {
      final relay = create(firstRelay, 'healthy-relay', relay: true);
      await relay.start(activeMode: false);
      final unavailable = PeerCard(
        name: 'Unreachable seed',
        certificatePem: secondRelay.certPem,
        host: '127.0.0.1',
        port: 1,
        tcpEnrollment: true,
      );
      final client = create(
        a,
        'fallback-client',
        seeds: [unavailable, await card(relay)],
      );
      await client.start(activeMode: false);
      await until(
        () async => await connected(client) == 1 && await connected(relay) == 1,
      );
      expect((await client.snapshot())['bootstrapConfiguredCount'], 2);
    },
  );

  test('A wrong relay pin is rejected and cannot enroll the client', () async {
    final relay = create(firstRelay, 'pinned-relay', relay: true);
    await relay.start(activeMode: false);
    final client = create(
      a,
      'wrong-pin-client',
      seeds: [await card(relay, pin: wrong)],
    );
    await client.start(activeMode: false);
    await until(() async => (await client.snapshot())['lastError'] != null);
    await until(
      () async => (await relay.snapshot())['incomingHandshakeCount'] == 0,
    );
    expect(await connected(client), 0);
    expect((await relay.snapshot())['peerCount'], 0);
  });

  test(
    'A public preface alone creates no cached pin or dialing endpoint',
    () async {
      final relay = create(firstRelay, 'unproved-relay', relay: true);
      await relay.start(activeMode: false);
      final socket = await raw(relay);
      await TcpEnrollment.write(socket, PeerDiscovery.beacon(a, 45871));
      await until(
        () async => (await relay.snapshot())['incomingHandshakeCount'] == 1,
      );
      // Allow signature parsing to finish, without supplying any TLS key proof.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect((await relay.snapshot())['peerCount'], 0);
      expect(await connected(relay), 0);
    },
  );

  test('A replayed signed preface with another TLS key cannot enroll', () async {
    final relay = create(firstRelay, 'replay-relay', relay: true);
    await relay.start(activeMode: false);
    final socket = await raw(relay);
    final subscription = await TcpEnrollment.write(
      socket,
      PeerDiscovery.beacon(a, 45871),
    );
    RawSecureSocket? secure;
    try {
      secure = await RawSecureSocket.secure(
        socket,
        subscription: subscription,
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(b.certPem))
          ..usePrivateKeyBytes(utf8.encode(b.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(firstRelay.certPem)),
        onBadCertificate: (certificate) =>
            Identity.certificateId(certificate.pem) == firstRelay.id,
      ).timeout(const Duration(seconds: 8));
      secure.listen((_) {}, onError: (Object _) {});
    } on HandshakeException {
      // Expected: the advertised connection identity and the TLS key disagree.
    }
    await until(() async => (await relay.snapshot())['rejectedCount'] > 0);
    expect((await relay.snapshot())['peerCount'], 0);
    await secure?.close();
  });

  test('Oversized or stalled prefaces release admission capacity', () async {
    final relay = create(firstRelay, 'bounded-relay', relay: true);
    await relay.start(activeMode: false);
    final oversized = await raw(relay);
    oversized.write(
      Uint8List.fromList(
        utf8.encode('P${'A' * TcpEnrollment.maxPrefaceBytes}'),
      ),
    );
    oversized.listen((_) {}, onError: (Object _) {});
    await until(() async => (await relay.snapshot())['rejectedCount'] == 1);
    final stalled = await raw(relay);
    stalled.write(utf8.encode('P'));
    stalled.listen((_) {}, onError: (Object _) {});
    await until(() async => (await relay.snapshot())['rejectedCount'] == 2);
    final client = create(a, 'after-bad-prefaces', seeds: [await card(relay)]);
    await client.start(activeMode: false);
    await until(() async => await connected(relay) == 1);
    expect((await relay.snapshot())['peerCount'], 1);
  });

  test(
    'Ordinary strict phone listeners do not enable public enrollment',
    () async {
      final phone = create(firstRelay, 'strict-phone');
      await phone.start(activeMode: false);
      final client = create(a, 'strict-client', seeds: [await card(phone)]);
      await client.start(activeMode: false);
      await until(() async => (await client.snapshot())['lastError'] != null);
      expect((await phone.snapshot())['peerCount'], 0);
      expect(await connected(phone), 0);
    },
  );
}

Future<void> until(Future<bool> Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > const Duration(seconds: 15)) {
      fail('TCP relay condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
