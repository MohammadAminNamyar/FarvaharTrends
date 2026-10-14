import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

/// Beacon v2: the LAN sees a rotating session token and a port, never the
/// certificate. The certificate is disclosed only inside a TLS handshake to an
/// active connector, and admission needs a completed, fingerprint-checked
/// mTLS handshake exactly like a signed v1 beacon did.
void main() {
  late Identity a;
  late Identity b;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <RawDatagramSocket>[];
  final servers = <RawServerSocket>[];

  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
  });

  setUp(() async {
    final parent = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.tooling'
      '${Platform.pathSeparator}test-tmp',
    );
    await parent.create(recursive: true);
    scratch = await parent.createTemp('discovery-session-');
  });

  tearDown(() async {
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    for (final socket in sockets) {
      socket.close();
    }
    sockets.clear();
    for (final server in servers) {
      await server.close();
    }
    servers.clear();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  Future<void> until(
    Future<bool> Function() condition, {
    Duration limit = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Condition was not reached within $limit.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  Future<int> freeUdpPort() async {
    final reserve = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reserve.port;
    reserve.close();
    return port;
  }

  PeerEngine engine(Identity identity, String label, int discoveryPort) {
    final clock = Stopwatch()..start();
    final result = PeerEngine(
      directory: Directory('${scratch.path}${Platform.pathSeparator}$label'),
      identity: identity,
      listenPort: 0,
      enableLanDiscovery: false,
      discoveryPort: discoveryPort,
      deviceState: () async => {
        'elapsedRealtimeMs': clock.elapsedMilliseconds,
        'bootId': 'test-boot',
        'isLocked': true,
        'wallTimeMs': DateTime.now().millisecondsSinceEpoch,
      },
      onStatus: (_) {},
    );
    engines.add(result);
    return result;
  }

  Future<RawDatagramSocket> sender() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    sockets.add(socket);
    return socket;
  }

  /// A "victim" endpoint: accepts TCP and closes at once, counting attempts.
  Future<(RawServerSocket, List<int>)> victim() async {
    final server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    final hits = <int>[];
    server.listen((socket) {
      hits.add(DateTime.now().millisecondsSinceEpoch);
      unawaited(socket.close());
    });
    return (server, hits);
  }

  test('beacon v2 round trip carries a token and port, never a key', () {
    final session = DiscoverySession();
    final bytes = PeerDiscovery.sessionBeacon(session, 45871, nowMs: 7);
    final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(raw.keys.toSet(), {
      'version',
      'kind',
      'session',
      'port',
      'nonce',
      'issuedAtMs',
      'expiresAtMs',
    });
    expect(raw['version'], 2);
    expect(raw['kind'], 'farvahartrends/discovery/v2');
    expect(raw['session'], session.token);
    expect(raw['expiresAtMs'], 7 + 45000);
    expect(utf8.decode(bytes), isNot(contains('CERTIFICATE')));
    expect(utf8.decode(bytes), isNot(contains('signature')));
    expect(utf8.decode(bytes), isNot(contains(a.id)));
    final hint = PeerDiscovery.parseSessionBeacon(
      bytes,
      InternetAddress('192.168.4.9'),
    );
    expect(hint.session, session.token);
    expect(hint.host.address, '192.168.4.9');
    expect(hint.port, 45871);
    expect(hint.nonce, raw['nonce']);
    expect(DiscoverySession.validToken(hint.session), isTrue);

    Uint8List mutate(void Function(Map<String, dynamic>) change) {
      final copy = Map<String, dynamic>.from(raw);
      change(copy);
      return Uint8List.fromList(utf8.encode(jsonEncode(copy)));
    }

    for (final bad in [
      mutate((m) => m['expiresAtMs'] = 7 + 46000),
      mutate((m) => m['session'] = 'Z' * 32),
      mutate((m) => m['session'] = 'a' * 31),
      mutate((m) => m['port'] = 0),
      mutate((m) => m['port'] = 70000),
      mutate((m) => m['host'] = '203.0.113.9'),
      mutate((m) => m['certificatePem'] = a.certPem),
      mutate((m) => m.remove('nonce')),
      mutate((m) => m['version'] = 1),
      PeerDiscovery.beacon(a, 45871),
    ]) {
      expect(
        () =>
            PeerDiscovery.parseSessionBeacon(bad, InternetAddress.loopbackIPv4),
        throwsFormatException,
      );
    }
    expect(
      () => PeerDiscovery.parseSessionBeacon(bytes, PeerDiscovery.group),
      throwsFormatException,
    );
    // A v2 beacon can never be mistaken for a signed v1 announcement.
    expect(
      () => PeerDiscovery.parseBeacon(bytes, InternetAddress.loopbackIPv4),
      throwsFormatException,
    );
  });

  test(
    'session tokens are random, rotate on demand and expire by age',
    () async {
      final session = DiscoverySession(
        rotation: const Duration(milliseconds: 60),
      );
      final first = session.token;
      expect(DiscoverySession.validToken(first), isTrue);
      expect(first, isNot(DiscoverySession().token));
      session.rotate();
      final second = session.token;
      expect(second, isNot(first));
      expect(session.token, second);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(session.token, isNot(second));
      expect(session.rotations, 3);
    },
  );

  test(
    'listener accepts v1 and v2, ignores replay and answers with v2 only',
    () async {
      final peers = <PeerCard>[];
      final hints = <DiscoverySessionHint>[];
      final discovery = PeerDiscovery(
        identity: a,
        listenPort: 45871,
        port: 0,
        multicast: false,
        onPeer: peers.add,
        onSession: hints.add,
        onDiagnostic: (_) {},
      );
      final socket = await sender();
      final replies = <Uint8List>[];
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          replies.add(packet!.data);
        }
      });
      try {
        await discovery.start();
        final port = discovery.localPort!;
        final remote = DiscoverySession();
        final v2 = PeerDiscovery.sessionBeacon(remote, 32123);
        socket.send(v2, InternetAddress.loopbackIPv4, port);
        await until(() async => hints.length == 1);
        // Same bytes from the same route are a replay; a fresh nonce is not.
        socket.send(v2, InternetAddress.loopbackIPv4, port);
        socket.send(
          PeerDiscovery.sessionBeacon(remote, 32123),
          InternetAddress.loopbackIPv4,
          port,
        );
        await until(() async => hints.length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(hints, hasLength(2));
        expect(hints.map((h) => h.session).toSet(), {remote.token});
        expect(hints.map((h) => h.port).toSet(), {32123});
        expect(hints.first.host.address, '127.0.0.1');
        // Our own token never admits ourselves.
        socket.send(
          PeerDiscovery.sessionBeacon(discovery.session, 1),
          InternetAddress.loopbackIPv4,
          port,
        );
        // Deprecated v1 from an older peer still delivers a pinned card.
        socket.send(
          PeerDiscovery.beacon(b, 32124),
          InternetAddress.loopbackIPv4,
          port,
        );
        await until(() async => peers.length == 1);
        expect(peers.single.id, b.id);
        expect(peers.single.port, 32124);
        expect(hints, hasLength(2));
        await until(() async => replies.length >= 2);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        // One bounded reply per session/source and per identity/source.
        expect(replies, hasLength(2));
        for (final reply in replies) {
          expect(
            PeerDiscovery.parseSessionBeacon(
              reply,
              InternetAddress.loopbackIPv4,
            ).session,
            discovery.session.token,
          );
          expect(utf8.decode(reply), isNot(contains('CERTIFICATE')));
        }
      } finally {
        await discovery.stop();
      }
    },
  );

  test('peers learn certificates only by dialing after a v2 beacon and end up '
      'connected as automatic contacts', () async {
    final portA = await freeUdpPort();
    final portB = await freeUdpPort();
    final left = engine(a, 'a', portA);
    final right = engine(b, 'b', portB);
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    expect(left.discoverySessionToken, isNot(right.discoverySessionToken));
    expect(DiscoverySession.validToken(left.discoverySessionToken), isTrue);
    final tlsA = (await left.snapshot())['listenPort'] as int;
    final tlsB = (await right.snapshot())['listenPort'] as int;
    final socket = await sender();
    // Neither engine has any pin. Each beacon only names a token and port;
    // the first probe fails at the peer's mTLS gate but yields the
    // certificate, so the peer's own probe can then complete mTLS.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while ((await left.snapshot())['connectedCount'] != 1 ||
        (await right.snapshot())['connectedCount'] != 1) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Peers did not connect through beacon v2 probes.');
      }
      socket.send(
        spoofedFrom(right.discoverySessionToken, tlsB),
        InternetAddress.loopbackIPv4,
        portA,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      socket.send(
        spoofedFrom(left.discoverySessionToken, tlsA),
        InternetAddress.loopbackIPv4,
        portB,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    for (final (engine, other) in [(left, b), (right, a)]) {
      final status = await engine.snapshot();
      expect(status['connectedCount'], 1);
      expect(status['discoveredCount'], 1);
      final peer = (status['peers'] as List).single as Map;
      expect(peer['id'], other.id);
      expect(peer['trust'], 'unverified');
      expect(peer['origin'], 'lan');
    }
    // A later beacon from a known session refreshes the route without any
    // new unknown-certificate probe: the link stays, nothing is rejected.
    final rejectedBefore = (await left.snapshot())['rejectedCount'];
    socket.send(
      spoofedFrom(right.discoverySessionToken, tlsB),
      InternetAddress.loopbackIPv4,
      portA,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = await left.snapshot();
    expect(after['connectedCount'], 1);
    expect(after['rejectedCount'], rejectedBefore);
  });

  test('hostile beacons at a victim endpoint are bounded and do not block '
      'discovery of another peer', () async {
    final portA = await freeUdpPort();
    final left = engine(a, 'hostile-a', portA);
    await left.start(activeMode: false);
    final socket = await sender();
    final (closed, hits) = await victim();
    // One token, one victim: a flood of fresh beacons causes one probe and
    // then exponential backoff; no beacon can retrigger a dial early.
    for (var i = 0; i < 12; i++) {
      socket.send(
        PeerDiscovery.sessionBeacon(DiscoverySession(), closed.port),
        InternetAddress.loopbackIPv4,
        portA,
      );
    }
    await until(() async => hits.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(hits, hasLength(1));
    // Many tokens at one victim still share the endpoint backoff and the
    // per-endpoint window budget.
    final many = <(RawServerSocket, List<int>)>[];
    for (var i = 0; i < 6; i++) {
      many.add(await victim());
    }
    // One token aimed at many victims is bounded by its session budget.
    final hostile = DiscoverySession();
    for (final (server, _) in many) {
      socket.send(
        PeerDiscovery.sessionBeacon(hostile, server.port),
        InternetAddress.loopbackIPv4,
        portA,
      );
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final total = many.fold<int>(0, (sum, v) => sum + v.$2.length);
    expect(total, inInclusiveRange(1, PeerEngine.discoveryProbesPerEndpoint));
    expect((await left.snapshot())['connectedCount'], 0);
    expect((await left.snapshot())['discoveredCount'], 0);
    // The honest peer still gets through on the same listener.
    final portB = await freeUdpPort();
    final right = engine(b, 'hostile-b', portB);
    await right.start(activeMode: false);
    final tlsA = (await left.snapshot())['listenPort'] as int;
    final tlsB = (await right.snapshot())['listenPort'] as int;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while ((await left.snapshot())['connectedCount'] != 1) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Honest peer did not connect while hostile beacons existed.');
      }
      socket.send(
        spoofedFrom(right.discoverySessionToken, tlsB),
        InternetAddress.loopbackIPv4,
        portA,
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      socket.send(
        spoofedFrom(left.discoverySessionToken, tlsA),
        InternetAddress.loopbackIPv4,
        portB,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    expect(((await left.snapshot())['peers'] as List).single['id'], b.id);
    expect(hits, hasLength(1));
  });

  test('the engine still admits a deprecated signed v1 beacon', () async {
    final portA = await freeUdpPort();
    final left = engine(a, 'v1-a', portA);
    final right = engine(b, 'v1-b', await freeUdpPort());
    await right.addPeer(PeerCard(name: 'A', certificatePem: a.certPem));
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    final socket = await sender();
    socket.send(
      PeerDiscovery.beacon(b, (await right.snapshot())['listenPort'] as int),
      InternetAddress.loopbackIPv4,
      portA,
    );
    await until(() async => (await left.snapshot())['connectedCount'] == 1);
    expect((await left.snapshot())['discoveredCount'], 1);
  });
}

/// A beacon as another engine would multicast it: token and TLS port only.
Uint8List spoofedFrom(String session, int port) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final nonce = List<int>.generate(16, (_) => DateTime.now().microsecond & 255);
  nonce[0] = now & 255;
  nonce[1] = (now >> 8) & 255;
  nonce[2] = (now >> 16) & 255;
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 2,
        'kind': PeerDiscovery.kindV2,
        'session': session,
        'port': port,
        'nonce': base64UrlEncode(nonce),
        'issuedAtMs': now,
        'expiresAtMs': now + 45000,
      }),
    ),
  );
}
