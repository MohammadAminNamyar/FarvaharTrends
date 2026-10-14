import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/loopback_preface.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  late Identity a, b, other;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final proxies = <_ByteProxy>[];
  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
    other = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('multipath-');
  });
  tearDown(() async {
    for (final proxy in proxies) {
      await proxy.close();
    }
    proxies.clear();
    for (final value in engines.reversed) {
      await value.stop();
    }
    engines.clear();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });
  PeerEngine engine(
    Identity identity,
    String name, {
    int discoveryPort = 45872,
  }) {
    final result = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: identity,
      listenPort: 0,
      discoveryPort: discoveryPort,
      enableLanDiscovery: false,
      onStatus: (_) {},
      deviceState: () async => {
        'isLocked': true,
        'lockStateKnown': true,
        'wallTimeMs': DateTime.now().millisecondsSinceEpoch,
        'elapsedRealtimeMs': 10,
        'bootId': 'test',
        'network': 'wifi',
      },
    );
    engines.add(result);
    return result;
  }

  Future<void> until(Future<bool> Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!await predicate()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for a real engine condition.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// Dials a listener; a loopback ingress needs its [preface] before TLS.
  Future<SecureSocket> client(
    Identity local,
    Identity remote,
    int port, {
    Uint8List? preface,
  }) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    if (preface != null) {
      socket.add(preface);
      await socket.flush();
    }
    return SecureSocket.secure(
      socket,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(local.certPem))
        ..usePrivateKeyBytes(utf8.encode(local.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(remote.certPem)),
      onBadCertificate: (certificate) =>
          Identity.certificateId(certificate.pem) == remote.id,
    ).timeout(const Duration(seconds: 3));
  }
  Future<void> frame(
    SecureSocket socket,
    String type,
    Map<String, dynamic> value,
  ) async {
    socket.write('${jsonEncode({'type': type, 'value': value})}\n');
    await socket.flush();
  }

  test(
    'failed saved IP falls back to LAN without rewriting paired card',
    () async {
      final reserved = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final udpPort = reserved.port;
      reserved.close();
      final unavailable = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final closedPort = unavailable.port;
      await unavailable.close();
      final left = engine(a, 'lan-a', discoveryPort: udpPort);
      final right = engine(b, 'lan-b');
      await left.addPeer(
        PeerCard(
          name: 'Saved B',
          certificatePem: b.certPem,
          host: '127.0.0.1',
          port: closedPort,
        ),
      );
      await right.addPeer(PeerCard(name: 'A', certificatePem: a.certPem));
      await left.start(activeMode: false);
      await right.start(activeMode: false);
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sender.send(
        right.createDiscoveryBeacon(),
        InternetAddress.loopbackIPv4,
        udpPort,
      );
      sender.close();
      await until(() async => (await left.snapshot())['connectedCount'] == 1);
      final peer = ((await left.snapshot())['peers'] as List).single as Map;
      expect(peer['port'], closedPort);
      expect(peer['name'], 'Saved B');
      expect(peer['origin'], 'manual');
      expect(peer['trust'], 'paired');
      expect(peer['transport'], 'lan');
      expect(peer['endpointCount'], 2);
      final news = await left.createChannel(name: 'Fallback');
      await left.publishToChannel(
        channelId: news.id,
        text: 'Same signed news over LAN',
      );
      await until(() async => (await right.snapshot())['bulletinCount'] == 1);
      expect(
        ((await left.snapshot())['bulletins'] as List).single['receivedVia'],
        'local',
      );
      expect(
        ((await left.snapshot())['bulletins'] as List)
            .single['localPublication'],
        true,
      );
    },
  );

  test('a healthy IP path takes priority over a Bluetooth candidate', () async {
    final left = engine(a, 'priority-a'), right = engine(b, 'priority-b');
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    await right.addPeer(PeerCard(name: 'A', certificatePem: a.certPem));
    await left.addPeer(
      PeerCard(
        name: 'B',
        certificatePem: b.certPem,
        host: '127.0.0.1',
        port: (await right.snapshot())['listenPort'] as int,
      ),
    );
    await until(() async => (await left.snapshot())['connectedCount'] == 1);
    await left.admitNativePeer(
      signedBeacon: right.createDiscoveryBeacon(),
      routeId: 'lower-priority',
      transport: PeerTransport.bluetooth,
    );
    await right.admitNativePeer(
      signedBeacon: left.createDiscoveryBeacon(),
      routeId: 'lower-priority-ingress',
      transport: PeerTransport.bluetooth,
    );
    final proxy = await _ByteProxy.open(
      right.bluetoothIngressPort!,
      right.bluetoothIngressPreface!,
    );
    proxies.add(proxy);
    await left.registerNativeEndpoint(
      peerId: b.id,
      routeId: 'lower-priority',
      transport: PeerTransport.bluetooth,
      host: InternetAddress.loopbackIPv4,
      port: proxy.port,
      preface: proxy.token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await left.snapshot())['connectedCount'], 1);
    expect(
      ((await left.snapshot())['peers'] as List).single['transport'],
      'ip',
    );
    expect(proxy.sockets, isEmpty);
  });

  test('Bluetooth byte proxy retains pinned TLS and disappears independently of trust', () async {
    final left = engine(a, 'ble-a'), right = engine(b, 'ble-b');
    await left.start(activeMode: false);
    await right.start(activeMode: false);
    final admitted = await left.admitNativePeer(
      signedBeacon: right.createDiscoveryBeacon(),
      routeId: 'central-route',
      transport: PeerTransport.bluetooth,
    );
    final incoming = await right.admitNativePeer(
      signedBeacon: left.createDiscoveryBeacon(),
      routeId: 'peripheral-route',
      transport: PeerTransport.bluetooth,
    );
    expect(admitted.accepted, true);
    expect(incoming.ingressPort, right.bluetoothIngressPort);
    expect(incoming.ingressPreface, right.bluetoothIngressPreface);
    final proxy = await _ByteProxy.open(
      right.bluetoothIngressPort!,
      incoming.ingressPreface!,
    );
    proxies.add(proxy);
    await left.registerNativeEndpoint(
      peerId: b.id,
      routeId: 'central-route',
      transport: PeerTransport.bluetooth,
      host: InternetAddress.loopbackIPv4,
      port: proxy.port,
      preface: proxy.token,
    );
    await until(() async => (await left.snapshot())['connectedCount'] == 1);
    expect(
      (await left.snapshot())['activeTransportCounts'],
      containsPair('bluetooth', 1),
    );
    await until(() async => (await right.snapshot())['connectedCount'] == 1);
    expect(
      ((await right.snapshot())['peers'] as List).single['transport'],
      'bluetooth',
    );
    final channel = await left.createChannel(name: 'TLS over a byte proxy');
    await left.publishToChannel(
      channelId: channel.id,
      text: 'Public signed test',
    );
    await until(() async => (await right.snapshot())['bulletinCount'] == 1);
    expect(
      ((await right.snapshot())['bulletins'] as List).single['receivedVia'],
      'bluetooth',
    );
    expect(((await right.snapshot())['trials'] as List), isEmpty);
    expect(((await left.snapshot())['trials'] as List), isEmpty);
    expect((await left.snapshot())['receiptCount'], 0);
    expect((await right.snapshot())['receiptCount'], 0);
    await left.removeNativeRoute('central-route');
    expect((await left.snapshot())['connectedCount'], 0);
    expect(((await left.snapshot())['peers'] as List).single['host'], '');
    expect(
      ((await left.snapshot())['peers'] as List).single['trust'],
      'unverified',
    );
    await right.stop();
    final reloaded = engine(b, 'ble-b');
    final restored = await reloaded.snapshot();
    expect((restored['bulletins'] as List).single['receivedVia'], 'bluetooth');
    expect((restored['peers'] as List).single['host'], '');
    expect((restored['peers'] as List).single['trust'], 'unverified');
    expect((restored['peers'] as List).single['endpointCount'], 0);
  });

  test('duplicate news over another transport preserves first receipt attribution after reload', () async {
    final receiver = engine(b, 'first-route');
    await receiver.start(activeMode: false);
    await receiver.admitNativePeer(
      signedBeacon: PeerDiscovery.beacon(a, 45871),
      routeId: 'ble-first',
      transport: PeerTransport.bluetooth,
    );
    final channel = SignedChannel.create(a, name: 'Publisher');
    final bulletin = SignedBulletin.create(
      a,
      runId: 'route-test',
      text: 'One immutable ID',
      sequence: 1,
      channelId: channel.id,
    );
    final first = await client(
      a,
      b,
      receiver.bluetoothIngressPort!,
      preface: receiver.bluetoothIngressPreface,
    );
    first.listen((_) {}, onError: (Object _) {});
    await frame(first, 'channel', channel.toJson());
    await frame(first, 'bulletin', bulletin.toJson());
    await until(() async => (await receiver.snapshot())['bulletinCount'] == 1);
    expect((await receiver.snapshot())['receiptCount'], 0);
    final initial =
        ((await receiver.snapshot())['bulletins'] as List).single as Map;
    expect(initial['receivedVia'], 'bluetooth');
    expect(initial['receivedNetwork'], 'wifi');
    first.destroy();
    await receiver.removeNativeRoute('ble-first');
    final second = await client(
      a,
      b,
      (await receiver.snapshot())['listenPort'] as int,
    );
    second.listen((_) {}, onError: (Object _) {});
    await frame(second, 'bulletin', bulletin.toJson());
    await until(() async => (await receiver.snapshot())['duplicateCount'] == 1);
    expect(
      ((await receiver.snapshot())['bulletins'] as List).single['receivedVia'],
      'bluetooth',
    );
    expect((await receiver.snapshot())['receiptCount'], 0);
    second.destroy();
    await receiver.stop();
    final reload = engine(b, 'first-route');
    final saved =
        ((await reload.snapshot())['bulletins'] as List).single as Map;
    expect(saved['id'], bulletin.id);
    expect(saved['receivedVia'], 'bluetooth');
    expect(saved['receivedAtWallMs'], initial['receivedAtWallMs']);
    expect(saved['receivedNetwork'], 'wifi');
    final report = jsonDecode(await reload.exportReport()) as Map;
    // Public news and its arrival metadata stay out of diagnostic exports.
    expect(report['receivedBulletins'], isEmpty);
    expect(jsonEncode(report), isNot(contains('127.0.0.1')));
  });

  test('native admission rejects tamper, identity substitution and external BLE endpoints', () async {
    final value = engine(a, 'validation');
    await value.start(activeMode: false);
    await expectLater(
      value.registerNativeEndpoint(
        peerId: b.id,
        routeId: 'unadmitted',
        transport: PeerTransport.bluetooth,
        host: InternetAddress.loopbackIPv4,
        port: 12345,
      ),
      throwsStateError,
    );
    final json = jsonDecode(utf8.decode(PeerDiscovery.beacon(b, 45871))) as Map;
    json['port'] = 1;
    await expectLater(
      value.admitNativePeer(
        signedBeacon: Uint8List.fromList(utf8.encode(jsonEncode(json))),
        routeId: 'bad',
        transport: PeerTransport.bluetooth,
      ),
      throwsFormatException,
    );
    await value.admitNativePeer(
      signedBeacon: PeerDiscovery.beacon(b, 45871),
      routeId: 'bound',
      transport: PeerTransport.bluetooth,
    );
    await expectLater(
      value.admitNativePeer(
        signedBeacon: PeerDiscovery.beacon(other, 45871),
        routeId: 'bound',
        transport: PeerTransport.bluetooth,
      ),
      throwsFormatException,
    );
    await expectLater(
      value.registerNativeEndpoint(
        peerId: b.id,
        routeId: 'bound',
        transport: PeerTransport.bluetooth,
        host: InternetAddress('192.0.2.1'),
        port: 12345,
        preface: LoopbackPreface.newToken(),
      ),
      throwsArgumentError,
    );
    // A loopback endpoint without its native preface is refused as well.
    await expectLater(
      value.registerNativeEndpoint(
        peerId: b.id,
        routeId: 'bound',
        transport: PeerTransport.bluetooth,
        host: InternetAddress.loopbackIPv4,
        port: 12345,
      ),
      throwsArgumentError,
    );
    expect((await value.snapshot())['peerCount'], 1);
  });

  test('native Bluetooth ingress refuses a paired key without native route admission', () async {
    final value = engine(b, 'ingress');
    await value.addPeer(
      PeerCard(name: 'Manually paired', certificatePem: a.certPem),
    );
    await value.start(activeMode: false);
    final socket = await client(
      a,
      b,
      value.bluetoothIngressPort!,
      preface: value.bluetoothIngressPreface,
    );
    socket.listen((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await value.snapshot())['connectedCount'], 0);
    socket.destroy();
  });

  test('unknown persisted origins remain unverified and old news has unknown transport', () async {
    final directory = Directory('${scratch.path}/legacy');
    final store = PilotStore(directory);
    await store.load();
    await store.setPeers([
      {
        ...PeerCard(
          name: 'Future transport',
          certificatePem: b.certPem,
        ).toJson(),
        'origin': 'future-radio',
      },
    ]);
    final bulletin = SignedBulletin.create(
      b,
      runId: 'old',
      text: 'Legacy stored news',
      sequence: 1,
    );
    await store.putBulletin(bulletin.toJson());
    final value = engine(a, 'legacy');
    final state = await value.snapshot();
    expect((state['peers'] as List).single['trust'], 'unverified');
    expect((state['bulletins'] as List).single['receivedVia'], 'unknown');
  });

  test(
    'native Wi-Fi Direct hints admit no key until a signed source responds',
    () async {
      final reserved = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final udpPort = reserved.port;
      reserved.close();
      final left = engine(a, 'direct-a', discoveryPort: udpPort);
      final right = engine(b, 'direct-b');
      await right.addPeer(PeerCard(name: 'A', certificatePem: a.certPem));
      await left.start(activeMode: false);
      await right.start(activeMode: false);
      await left.probeDiscoveryAddress(
        InternetAddress('127.0.0.3'),
        transport: PeerTransport.wifiDirect,
        routeId: 'os-p2p-interface',
        localAddresses: [
          {'address': '127.0.0.2', 'prefixLength': 8},
        ],
      );
      expect((await left.snapshot())['peerCount'], 0);
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      sender.send(
        right.createDiscoveryBeacon(),
        InternetAddress.loopbackIPv4,
        udpPort,
      );
      sender.close();
      await until(() async => (await left.snapshot())['connectedCount'] == 1);
      expect(
        ((await left.snapshot())['peers'] as List).single['transport'],
        'wifiDirect',
      );
      expect(
        ((await left.snapshot())['peers'] as List).single['trust'],
        'unverified',
      );
      await left.removeNativeRoute('os-p2p-interface');
      expect((await left.snapshot())['connectedCount'], 0);
      expect((await left.snapshot())['peerCount'], 1);
    },
  );

  test(
    'endpoint capacity preserves the manual address and evicts runtime hints',
    () async {
      final value = engine(a, 'bounded');
      await value.addPeer(
        PeerCard(
          name: 'Saved',
          certificatePem: b.certPem,
          host: '127.0.0.1',
          port: 1,
        ),
      );
      await value.start(activeMode: false);
      for (var i = 0; i < 8; i++) {
        final route = 'bounded-$i';
        await value.admitNativePeer(
          signedBeacon: PeerDiscovery.beacon(b, 45871),
          routeId: route,
          transport: PeerTransport.bluetooth,
        );
        await value.registerNativeEndpoint(
          peerId: b.id,
          routeId: route,
          transport: PeerTransport.bluetooth,
          host: InternetAddress.loopbackIPv4,
          port: 1,
          preface: LoopbackPreface.newToken(),
        );
      }
      final peer = ((await value.snapshot())['peers'] as List).single as Map;
      expect(peer['endpointCount'], PeerEngine.maxEndpointsPerPeer);
      expect(peer['host'], '127.0.0.1');
      expect(peer['port'], 1);
      expect(peer['trust'], 'paired');
    },
  );

  test(
    'signed discovery reply is bounded and malformed beacons get no response',
    () async {
      final discovery = PeerDiscovery(
        identity: a,
        listenPort: 45871,
        port: 0,
        multicast: false,
        onPeer: (_) {},
        onDiagnostic: (_) {},
      );
      await discovery.start();
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      var replies = 0;
      final subscription = sender.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? packet;
          while ((packet = sender.receive()) != null) {
            // Replies are v2 session beacons; the certificate stays private.
            expect(
              PeerDiscovery.parseSessionBeacon(
                packet!.data,
                packet.address,
              ).session,
              discovery.session.token,
            );
            replies++;
          }
        }
      });
      try {
        sender.send(
          Uint8List.fromList([1, 2, 3]),
          InternetAddress.loopbackIPv4,
          discovery.localPort!,
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(replies, 0);
        for (var i = 0; i < 4; i++) {
          sender.send(
            PeerDiscovery.beacon(b, 45871),
            InternetAddress.loopbackIPv4,
            discovery.localPort!,
          );
        }
        await until(() async => replies == 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(replies, 1);
      } finally {
        await subscription.cancel();
        sender.close();
        await discovery.stop();
      }
    },
  );
}

/// Simulates a native byte tunnel only. It does not exercise a Bluetooth radio.
/// Like the native bridge it demands its own preface from the dialing engine
/// and presents the ingress preface to the receiving engine.
class _ByteProxy {
  _ByteProxy(this.server);
  final ServerSocket server;
  final List<Socket> sockets = [];
  final Uint8List token = LoopbackPreface.newToken();
  int get port => server.port;
  static Future<_ByteProxy> open(
    int ingressPort,
    Uint8List ingressPreface,
  ) async {
    final result = _ByteProxy(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen((client) async {
      result.sockets.add(client);
      try {
        final data = await LoopbackPreface.readStream(client, result.token);
        final target = await Socket.connect(
          InternetAddress.loopbackIPv4,
          ingressPort,
        );
        result.sockets.add(target);
        target.add(ingressPreface);
        unawaited(
          target.addStream(data).catchError((Object _) {
            target.destroy();
          }),
        );
        unawaited(
          client.addStream(target).catchError((Object _) {
            client.destroy();
          }),
        );
      } catch (_) {
        client.destroy();
      }
    });
    return result;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}
