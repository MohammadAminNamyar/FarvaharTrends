import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/delivery_mode.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/local_wifi_transport.dart';
import 'package:farvahar_trends/core/loopback_preface.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  late Identity connection, publisher, receiver;
  late Directory scratch;
  final engines = <PeerEngine>[];
  setUpAll(() {
    connection = Identity.generate();
    publisher = Identity.generate();
    receiver = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('roles-routing-');
  });
  tearDown(() async {
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    await scratch.delete(recursive: true);
  });
  PeerEngine engine(
    String name,
    Identity id, {
    Identity? owner,
    DeliveryMode mode = DeliveryMode.allNetworks,
    LocalWifiTransport? wifi,
    List<PeerCard> seeds = const [],
    int listenPort = 0,
    Duration nearbyDiscoveryInterval = const Duration(seconds: 10),
  }) {
    final result = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: id,
      publisherIdentity: owner,
      deliveryMode: mode,
      localWifiTransport: wifi,
      listenPort: listenPort,
      enableLanDiscovery: false,
      discoveryPort: 0,
      bootstrapPeers: seeds,
      nearbyDiscoveryInterval: nearbyDiscoveryInterval,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
    engines.add(result);
    return result;
  }

  Future<void> until(Future<bool> Function() predicate) async {
    final end = DateTime.now().add(const Duration(seconds: 12));
    while (!await predicate()) {
      if (DateTime.now().isAfter(end)) {
        fail('Real TLS exchange did not complete.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  PeerCard card(Identity id, String host, int port) => PeerCard(
    name: 'test',
    host: host,
    port: port,
    certificatePem: id.certPem,
  );

  test(
    'channel signing key stays separate through real TLS delivery and reopen',
    () async {
      final a = engine('publisher', connection, owner: publisher);
      final b = engine('reader', receiver);
      await a.start(activeMode: true);
      await b.start(activeMode: true);
      final beacon = PeerDiscovery.parseBeacon(
        a.createDiscoveryBeacon(),
        InternetAddress.loopbackIPv4,
      );
      expect(beacon.id, connection.id);
      expect(
        utf8.decode(a.createDiscoveryBeacon()),
        isNot(contains(publisher.certPem)),
      );
      final channel = await a.createChannel(name: 'Owned channel');
      expect(channel.ownerId, publisher.id);
      expect(channel.ownerId, isNot(beacon.id));
      await b.addPeer(
        card(
          connection,
          '127.0.0.1',
          (await a.snapshot())['listenPort'] as int,
        ),
      );
      await a.addPeer(
        card(receiver, '127.0.0.1', (await b.snapshot())['listenPort'] as int),
      );
      await until(() async => (await a.snapshot())['connectedCount'] == 1);
      await a.publishToChannel(
        channelId: channel.id,
        text: 'SPLIT-KEY-DELIVERY',
      );
      await until(
        () async => ((await b.snapshot())['bulletins'] as List).isNotEmpty,
      );
      final received =
          ((await b.snapshot())['bulletins'] as List).single as Map;
      expect(received['sourceId'], publisher.id);
      expect(received['text'], 'SPLIT-KEY-DELIVERY');
      expect(
        ((await b.snapshot())['peers'] as List).single['id'],
        connection.id,
      );
      expect((await b.snapshot())['receiptCount'], 0);
      await expectLater(
        b.publishToChannel(channelId: channel.id, text: 'forged'),
        throwsStateError,
      );
      await a.stop();
      final reopened = engine('publisher', connection, owner: publisher);
      expect(
        ((await reopened.snapshot())['channels'] as List).single['owned'],
        true,
      );
      await reopened.publishToChannel(
        channelId: channel.id,
        text: 'offline after restart',
      );
      final posts = (await reopened.snapshot())['bulletins'] as List;
      expect(posts.first['sourceId'], publisher.id);
      expect(posts.first['sequence'], 2);
      final export = await reopened.exportReport();
      final report = jsonDecode(export) as Map;
      expect(report['receivedBulletins'], isEmpty);
      expect(report['publications'], isEmpty);
      expect(export, isNot(contains(publisher.id.substring(0, 12))));
      for (final post in posts) {
        expect(
          export,
          isNot(contains((post['id'] as String).substring(0, 12))),
        );
      }
    },
  );

  test(
    'nearby has no wildcard listener or direct fallback without native WiFi',
    () async {
      final trap = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      final subscription = trap.listen((socket) {
        connections++;
        socket.destroy();
      });
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final externalPort = reservation.port;
      await reservation.close();
      final a = engine(
        'no-adapter',
        connection,
        listenPort: externalPort,
        owner: publisher,
        mode: DeliveryMode.nearbyOnly,
        seeds: [card(receiver, '127.0.0.1', trap.port)],
      );
      await a.start(activeMode: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connections, 0);
      expect((await a.snapshot())['bootstrapConfiguredCount'], 0);
      expect((await a.snapshot())['deliveryMode'], 'nearbyOnly');
      expect((await a.snapshot())['discoveryState'], 'searching');
      // The external advertised port is not a Dart wildcard listener.
      await expectLater(
        Socket.connect(
          InternetAddress.loopbackIPv4,
          externalPort,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<SocketException>()),
      );
      await subscription.cancel();
      await trap.close();
    },
  );

  test(
    'nearby rejects off-link/private carrier/IPv6 routes through OS gate',
    () async {
      final wifi = _WifiGate();
      final a = engine(
        'blocked',
        connection,
        mode: DeliveryMode.nearbyOnly,
        wifi: wifi,
      );
      await a.start(activeMode: true);
      for (final host in ['203.0.113.10', '10.7.8.9', '2001:db8::10']) {
        await a.addPeer(card(receiver, host, 45871));
        await until(() async => wifi.openHosts.contains(host));
      }
      expect(
        wifi.openHosts,
        containsAll(['203.0.113.10', '10.7.8.9', '2001:db8::10']),
      );
      expect((await a.snapshot())['connectedCount'], 0);
      expect(wifi.started, true);
      expect(wifi.lanIngress, isPositive);
      expect(wifi.directIngress, isPositive);
      expect(wifi.lanIngress, isNot(wifi.directIngress));
      final direct = await a.admitNativePeer(
        signedBeacon: PeerDiscovery.beacon(receiver, 45871),
        routeId: 'wifiDirect:blocked',
        transport: PeerTransport.wifiDirect,
      );
      expect(direct.accepted, false);
      await a.stop();
      expect(wifi.stopped, true);
    },
  );

  test(
    'nearby delivers over native TLS proxy with distinct publisher key',
    () async {
      final b = engine('reader', receiver);
      await b.start(activeMode: true);
      final wifi = _WifiGate(
        allowedPort: (await b.snapshot())['listenPort'] as int,
      );
      final a = engine(
        'nearby',
        connection,
        owner: publisher,
        mode: DeliveryMode.nearbyOnly,
        wifi: wifi,
      );
      await a.start(activeMode: true);
      await b.addPeer(card(connection, '', 45871));
      await a.addPeer(card(receiver, '192.168.20.2', 45871));
      await until(() async => (await a.snapshot())['connectedCount'] == 1);
      final channel = await a.createChannel(name: 'Nearby publisher');
      await a.publishToChannel(channelId: channel.id, text: 'LOCAL-ONLY-FRESH');
      await until(
        () async => ((await b.snapshot())['bulletins'] as List).isNotEmpty,
      );
      expect(
        ((await b.snapshot())['bulletins'] as List).single['sourceId'],
        publisher.id,
      );
      expect(((await a.snapshot())['activeTransportCounts'] as Map)['ip'], 0);
      expect(((await a.snapshot())['activeTransportCounts'] as Map)['lan'], 1);
    },
  );

  test('malformed native proxy never causes a remote raw socket', () async {
    final wifi = _WifiGate(invalidProxy: true);
    final a = engine(
      'bad-proxy',
      connection,
      mode: DeliveryMode.nearbyOnly,
      wifi: wifi,
    );
    await a.start(activeMode: true);
    await a.addPeer(card(receiver, '192.168.20.2', 45871));
    await until(() async => wifi.openHosts.isNotEmpty);
    expect((await a.snapshot())['connectedCount'], 0);
  });

  test('nearby reprobes local seeds after WiFi returns and stops probing when paused', () async {
    final b = engine('wifi-recovery-reader', receiver);
    await b.start(activeMode: true);
    final wifi = _WifiGate(
      allowedPort: (await b.snapshot())['listenPort'] as int,
      available: false,
      discoveryBeacon: PeerDiscovery.beacon(receiver, 45871),
    );
    final a = engine(
      'wifi-recovery-publisher',
      connection,
      owner: publisher,
      mode: DeliveryMode.nearbyOnly,
      wifi: wifi,
      seeds: [card(receiver, '192.168.20.2', 45871)],
      nearbyDiscoveryInterval: const Duration(milliseconds: 50),
    );
    await a.start(activeMode: true);
    await b.addPeer(card(connection, '', 45871));
    await until(() async => wifi.probeHosts.isNotEmpty);
    expect((await a.snapshot())['connectedCount'], 0);
    expect(wifi.successfulProbes, 0);

    // The adapter does not emit multicast. Only a repeated, native-gated seed
    // probe can discover the receiver after the local Wi-Fi link returns.
    wifi.available = true;
    await until(() async => (await a.snapshot())['connectedCount'] == 1);
    expect(wifi.probeHosts.length, greaterThanOrEqualTo(2));
    expect(wifi.successfulProbes, isPositive);
    final channel = await a.createChannel(name: 'Recovered local WiFi');
    await a.publishToChannel(
      channelId: channel.id,
      text: 'FRESH-NEWS-AFTER-WIFI-RETURN',
    );
    await until(
      () async => ((await b.snapshot())['bulletins'] as List).isNotEmpty,
    );
    expect(
      ((await b.snapshot())['bulletins'] as List).single['text'],
      'FRESH-NEWS-AFTER-WIFI-RETURN',
    );
    expect(((await a.snapshot())['activeTransportCounts'] as Map)['ip'], 0);
    expect(((await a.snapshot())['activeTransportCounts'] as Map)['lan'], 1);

    await a.stop();
    final probesAtStop = wifi.probeHosts.length;
    await Future<void>.delayed(const Duration(milliseconds: 180));
    expect(wifi.probeHosts.length, probesAtStop);
    expect(wifi.stopped, true);
  });
}

class _WifiGate implements LocalWifiTransport {
  _WifiGate({
    this.allowedPort,
    this.invalidProxy = false,
    this.available = true,
    this.discoveryBeacon,
  });
  final int? allowedPort;
  final bool invalidProxy;
  bool available;
  final Uint8List? discoveryBeacon;
  final openHosts = <String>[];
  final probeHosts = <String>[];
  int successfulProbes = 0;
  bool _discoveryResponded = false;
  void Function(Uint8List, InternetAddress)? _onBeacon;
  bool started = false, stopped = false;
  int lanIngress = 0, directIngress = 0;
  @override
  Future<void> start({
    required int tcpPort,
    required int ingressPort,
    required int wifiDirectIngressPort,
    required int discoveryPort,
    required Uint8List signedBeacon,
    required Uint8List ingressPreface,
    required Uint8List wifiDirectIngressPreface,
    required void Function(Uint8List, InternetAddress) onBeacon,
    required void Function(String?) onState,
  }) async {
    started = true;
    stopped = false;
    _onBeacon = onBeacon;
    lanIngress = ingressPort;
    directIngress = wifiDirectIngressPort;
  }

  /// Simulates the native single-use loopback proxy: the engine must present
  /// the per-flow preface before its TLS bytes are relayed to [allowedPort].
  @override
  Future<({InternetAddress host, int port, Uint8List preface})> open(
    InternetAddress host,
    int port,
  ) async {
    openHosts.add(host.address);
    if (invalidProxy) {
      return (
        host: InternetAddress('203.0.113.10'),
        port: port,
        preface: LoopbackPreface.newToken(),
      );
    }
    if (!available || allowedPort == null || host.address != '192.168.20.2') {
      throw StateError('not on WiFi link');
    }
    final token = LoopbackPreface.newToken();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      LoopbackPreface.acceptOnce(
            server,
            token,
            deadline: const Duration(seconds: 8),
          )
          .then((flow) async {
            final target = await Socket.connect(
              InternetAddress.loopbackIPv4,
              allowedPort!,
            );
            unawaited(
              target.addStream(flow.data).catchError((Object _) {
                target.destroy();
              }),
            );
            unawaited(
              flow.socket.addStream(target).catchError((Object _) {
                flow.socket.destroy();
              }),
            );
          })
          .catchError((Object _) {}),
    );
    return (
      host: InternetAddress.loopbackIPv4,
      port: server.port,
      preface: token,
    );
  }

  @override
  Future<void> probe(InternetAddress address) async {
    probeHosts.add(address.address);
    if (!available || stopped) throw StateError('Local WiFi is unavailable');
    successfulProbes++;
    if (discoveryBeacon != null && !_discoveryResponded) {
      _discoveryResponded = true;
      _onBeacon?.call(discoveryBeacon!, address);
    }
  }

  @override
  Future<void> updateBeacon(Uint8List beacon) async {}
  @override
  Future<void> stop() async {
    stopped = true;
  }
}
