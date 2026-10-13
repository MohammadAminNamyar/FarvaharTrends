import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/delivery_mode.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';

void main() {
  late Identity a, b, c;
  late Directory directory;
  final engines = <PeerEngine>[];
  final clients = <SecureSocket>[];
  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
    c = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    directory = await parent.createTemp('overlay-admission-');
  });
  tearDown(() async {
    for (final client in clients) {
      client.destroy();
    }
    clients.clear();
    for (final engine in engines) {
      await engine.stop();
    }
    engines.clear();
    await directory.delete(recursive: true);
  });
  Future<PeerEngine> receiver({
    DeliveryMode mode = DeliveryMode.allNetworks,
  }) async {
    final engine = PeerEngine(
      directory: directory,
      identity: b,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      deliveryMode: mode,
      deviceState: () async => {},
      onStatus: (_) {},
    );
    engines.add(engine);
    await engine.start(activeMode: false);
    return engine;
  }

  Future<NativeAdmission> admit(
    PeerEngine engine,
    Identity key,
    String route,
  ) => engine.admitNativePeer(
    signedBeacon: PeerDiscovery.beacon(key, 45871),
    routeId: route,
    transport: PeerTransport.overlay,
  );
  Future<SecureSocket> connect(Identity key, int port) async {
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      port,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(key.certPem))
        ..usePrivateKeyBytes(utf8.encode(key.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(b.certPem)),
      onBadCertificate: (certificate) =>
          Identity.certificateId(certificate.pem) == b.id,
      timeout: const Duration(seconds: 3),
    );
    clients.add(socket);
    socket.listen((_) {}, onError: (Object _) {});
    return socket;
  }

  Future<void> until(Future<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline))
        fail('Overlay admission condition timed out');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('Each overlay bridge has a separate TLS ingress tied to its admitted identity', () async {
    final engine = await receiver();
    final first = await admit(engine, a, 'overlay-first');
    final second = await admit(engine, c, 'overlay-second');
    expect(first.ingressPort, isNot(second.ingressPort));
    await connect(a, second.ingressPort!);
    await until(() async => (await engine.snapshot())['rejectedCount'] > 0);
    expect((await engine.snapshot())['connectedCount'], 0);
    await connect(a, first.ingressPort!);
    await until(() async => (await engine.snapshot())['connectedCount'] == 1);
    final peer = ((await engine.snapshot())['peers'] as List).singleWhere(
      (peer) => peer['id'] == a.id,
    );
    expect(peer['transport'], 'overlay');
    expect(peer['routeId'], 'overlay-first');
    expect(peer['trust'], 'unverified');
    await engine.removeNativeRoute('overlay-first');
    await until(() async => (await engine.snapshot())['connectedCount'] == 0);
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        first.ingressPort!,
        timeout: const Duration(seconds: 1),
      ),
      throwsA(isA<SocketException>()),
    );
  });
  test(
    'Replayed introductions cannot redirect another route certificate',
    () async {
      final engine = await receiver();
      final legitimate = await admit(engine, a, 'overlay-legitimate');
      await admit(engine, c, 'overlay-other');
      final replay = await admit(engine, a, 'overlay-replayed');
      await connect(a, legitimate.ingressPort!);
      await until(() async => (await engine.snapshot())['connectedCount'] == 1);
      final baseline = (await engine.snapshot())['rejectedCount'] as int;
      await connect(c, replay.ingressPort!);
      await until(
        () async => (await engine.snapshot())['rejectedCount'] > baseline,
      );
      final peer = ((await engine.snapshot())['peers'] as List).singleWhere(
        (peer) => peer['id'] == a.id,
      );
      expect(peer['routeId'], 'overlay-legitimate');
    },
  );
  test('Nearby-only mode rejects Internet-overlay admission', () async {
    final engine = await receiver(mode: DeliveryMode.nearbyOnly);
    final result = await admit(engine, a, 'overlay-disabled');
    expect(result.accepted, false);
    expect(result.ingressPort, null);
    expect((await engine.snapshot())['peers'], isEmpty);
  });
}
