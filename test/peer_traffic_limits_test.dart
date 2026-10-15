import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

void main() {
  late Identity publisher, receiver;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final clients = <_Client>[];
  setUpAll(() {
    publisher = Identity.generate();
    receiver = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('traffic-limits-');
  });
  tearDown(() async {
    for (final client in clients) {
      client.socket.destroy();
    }
    clients.clear();
    for (final engine in engines) {
      await engine.stop();
    }
    engines.clear();
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  PeerEngine engine({
    int egress = 512 * 1024,
    Duration? window,
    Duration? cooldown,
  }) {
    final value = PeerEngine(
      directory: scratch,
      identity: receiver,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      trafficWindow: window ?? const Duration(seconds: 1),
      cooldownDuration: cooldown ?? const Duration(seconds: 1),
      egressBytesPerPeer: egress,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
    engines.add(value);
    return value;
  }

  Future<_Client> connect(PeerEngine target, {Identity? own}) async {
    final local = own ?? publisher;
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(local.certPem))
      ..usePrivateKeyBytes(utf8.encode(local.keyPem))
      ..setTrustedCertificatesBytes(utf8.encode(receiver.certPem));
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
      context: context,
      onBadCertificate: (cert) =>
          Identity.certificateId(cert.pem) == receiver.id,
      timeout: const Duration(seconds: 3),
    );
    final client = _Client(socket);
    clients.add(client);
    return client;
  }

  Future<List<SignedBulletin>> seed(int count, {int textBytes = 20}) async {
    final store = PilotStore(scratch);
    await store.load();
    final channel = SignedChannel.create(
      publisher,
      name: 'Harmless cached news',
    );
    await store.putChannel(channel.toJson());
    final news = <SignedBulletin>[];
    for (var i = 0; i < count; i++) {
      final value = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: '${'x' * (textBytes - 4)} $i',
        sequence: i + 1,
        channelId: channel.id,
      );
      news.add(value);
      await store.putBulletin(value.toJson());
    }
    return news;
  }

  Future<void> pair(PeerEngine target, Identity peer) => target.addPeer(
    PeerCard(name: 'Consenting test peer', certificatePem: peer.certPem),
  );

  test(
    'forgetting and re-admitting a contact cannot erase its cooldown',
    () async {
      final target = engine(cooldown: const Duration(seconds: 10));
      await pair(target, publisher);
      await target.start(activeMode: false);
      for (var i = 0; i < 3; i++) {
        final client = await connect(target);
        client.socket.add(utf8.encode('{broken json\n'));
        await client.socket.flush();
        await until(
          () async => (await target.snapshot())['rejectedCount'] == i + 1,
        );
      }
      await target.removePeer(publisher.id);
      await pair(target, publisher);
      expect((await target.snapshot())['coolingPeerCount'], 1);
      final blocked = await connect(target);
      await until(() async => blocked.closed);
      expect((await target.snapshot())['connectedCount'], 0);
    },
  );

  test('server rejects a TLS 1.2-only ClientHello', () async {
    final target = engine();
    await pair(target, publisher);
    await target.start(activeMode: false);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
    );
    // Valid legacy ClientHello: RSA GCM cipher, P-256, RSA-SHA256 signatures.
    final body = <int>[
      3,
      3,
      ...List.filled(32, 7),
      0,
      0,
      2,
      0xc0,
      0x2f,
      1,
      0,
      0,
      22,
      0,
      10,
      0,
      4,
      0,
      2,
      0,
      23,
      0,
      11,
      0,
      2,
      1,
      0,
      0,
      13,
      0,
      4,
      0,
      2,
      4,
      1,
    ];
    final handshake = <int>[1, 0, 0, body.length, ...body];
    socket.add([22, 3, 1, 0, handshake.length, ...handshake]);
    final records = await socket
        .take(1)
        .toList()
        .timeout(const Duration(seconds: 3));
    socket.destroy();
    if (records.isNotEmpty) {
      expect(records.single[0], 21); // Alert, never a legacy ServerHello.
      expect(records.single.last, 70); // protocol_version
    }
    // RawSecureSocket may close before the generated alert is flushed.
    await until(() async => (await target.snapshot())['rejectedCount'] == 1);
    expect((await target.snapshot())['connectedCount'], 0);
  });

  test(
    'automatic LAN-origin contacts get half the new-channel budget',
    () async {
      final target = engine(window: const Duration(seconds: 30));
      await target.start(activeMode: false);
      final admission = await target.admitNativePeer(
        signedBeacon: PeerDiscovery.beacon(publisher, 45871),
        routeId: 'wifiDirect:budget-check',
        transport: PeerTransport.wifiDirect,
      );
      expect(admission.accepted, true);
      final client = await connect(target);
      for (var i = 0; i < 8; i++) {
        await client.send({
          'type': 'channel',
          'value': SignedChannel.create(
            publisher,
            name: 'LAN channel $i',
          ).toJson(),
        });
      }
      await until(
        () async =>
            ((await target.snapshot())['trafficDeferred'] as Map)['channels'] ==
            4,
      );
      expect((await target.snapshot())['channels'] as List, hasLength(4));
      expect((await target.snapshot())['connectedCount'], 1);
    },
  );

  test('repeat requests and reconnects cannot amplify one cached object', () async {
    final news = await seed(2);
    final target = engine(window: const Duration(seconds: 2));
    await pair(target, publisher);
    await target.start(activeMode: false);
    final first = await connect(target);
    await first.want([news.first.id]);
    await until(() async => first.news.length == 1);
    first.socket.destroy();
    await until(() async => (await target.snapshot())['connectedCount'] == 0);
    final second = await connect(target);
    await second.want(List.filled(16, news.first.id));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(second.news, isEmpty);
    // This is within the frame/queue caps, but exceeds the item-request quota.
    for (var i = 0; i < 33; i++) {
      await second.want(List.filled(16, '0' * 64));
    }
    await second.want(List.filled(15, '0' * 64));
    await second.want([news.last.id]);
    await until(
      () async =>
          ((await target.snapshot())['trafficDeferred'] as Map)['requests'] > 0,
    );
    expect(second.news, isEmpty);
    expect((await target.snapshot())['coolingPeerCount'], 0);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    await second.want([news.last.id]);
    await until(() async => second.news.length == 1);
    expect((second.news.single['value'] as Map)['id'], news.last.id);
    expect((await target.snapshot())['connectedCount'], 1);
  });

  test(
    'egress defers a large cache and missing valid news catches up',
    () async {
      final news = await seed(32, textBytes: 1024);
      final target = engine(egress: PeerEngine.maxFrameBytes);
      await pair(target, publisher);
      await target.start(activeMode: false);
      final client = await connect(target);
      Future<void> requestMissing() async {
        final received = client.news
            .map((f) => (f['value'] as Map)['id'])
            .toSet();
        final missing = news
            .where((v) => !received.contains(v.id))
            .map((v) => v.id)
            .toList();
        for (var i = 0; i < missing.length; i += 16) {
          await client.want(missing.skip(i).take(16).toList());
        }
      }

      await requestMissing();
      await until(
        () async =>
            ((await target.snapshot())['trafficDeferred'] as Map)['egress'] > 0,
      );
      expect(client.news.length, lessThan(news.length));
      for (
        var attempt = 0;
        attempt < 4 && client.news.length < news.length;
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await requestMissing();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        client.news.map((f) => (f['value'] as Map)['id']).toSet(),
        news.map((v) => v.id).toSet(),
      );
      expect((await target.snapshot())['connectedCount'], 1);
      expect((await target.snapshot())['coolingPeerCount'], 0);
    },
  );

  test(
    'three framing violations cool down one identity across reconnects',
    () async {
      final target = engine(window: const Duration(seconds: 10));
      await pair(target, publisher);
      await target.start(activeMode: false);
      for (var i = 0; i < 3; i++) {
        final client = await connect(target);
        client.socket.add(utf8.encode('{broken json\n'));
        await client.socket.flush();
        await until(
          () async => (await target.snapshot())['rejectedCount'] == i + 1,
        );
      }
      expect((await target.snapshot())['coolingPeerCount'], 1);
      final blocked = await connect(target);
      await until(() async => blocked.closed);
      expect((await target.snapshot())['connectedCount'], 0);
      await until(
        () async => (await target.snapshot())['coolingPeerCount'] == 0,
      );
      final resumed = await connect(target);
      await until(
        () async => resumed.frames.any((f) => f['type'] == 'inventory'),
      );
      expect((await target.snapshot())['connectedCount'], 1);
    },
  );

  test(
    'ingress frame budget survives a normal connection replacement',
    () async {
      final target = engine(window: const Duration(seconds: 30));
      await pair(target, publisher);
      await target.start(activeMode: false);
      Future<void> inventories(_Client client, int count) async {
        for (var i = 0; i < count; i++) {
          await client.send({
            'type': 'inventory',
            'channels': <String>[],
            'bulletins': <String>[],
            'receipts': <String>[],
          });
          // Stay below the independent pending-parse queue limit in this test.
          if (i % 20 == 19) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      }

      final first = await connect(target);
      await inventories(first, 400);
      expect((await target.snapshot())['rejectedCount'], 0);
      first.socket.destroy();
      await until(() async => (await target.snapshot())['connectedCount'] == 0);
      final second = await connect(target);
      await inventories(second, 201);
      await until(() async => (await target.snapshot())['rejectedCount'] == 1);
      expect((await target.snapshot())['connectedCount'], 0);
      expect((await target.snapshot())['coolingPeerCount'], 0);
      // Rejection counters change before the asynchronous journal append is
      // durable. Wait for the specific event rather than racing the disk write.
      late Map report;
      await until(() async {
        report = jsonDecode(await target.exportReport()) as Map;
        return (report['events'] as List).any(
          (event) => (event as Map)['kind'] == 'peer_rate_limit',
        );
      });
      expect(
        (report['events'] as List).any(
          (event) => (event as Map)['kind'] == 'peer_rate_limit',
        ),
        isTrue,
      );
    },
  );

  test(
    'bad publisher objects do not blame or disconnect an honest relay',
    () async {
      final target = engine();
      await pair(target, publisher);
      await target.start(activeMode: false);
      final client = await connect(target);
      final channel = SignedChannel.create(publisher, name: 'Real channel');
      for (var i = 0; i < 3; i++) {
        await client.send({
          'type': 'channel',
          'value': <String, dynamic>{'invalid': i},
        });
      }
      await until(() async => (await target.snapshot())['rejectedCount'] == 3);
      expect((await target.snapshot())['coolingPeerCount'], 0);
      expect((await target.snapshot())['connectedCount'], 1);
      await client.send({'type': 'channel', 'value': channel.toJson()});
      final news = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: 'Valid after bad cache',
        sequence: 1,
        channelId: channel.id,
      );
      await client.send({'type': 'bulletin', 'value': news.toJson()});
      await until(() async => (await target.snapshot())['bulletinCount'] == 1);
      expect((await target.snapshot())['connectedCount'], 1);
    },
  );

  test(
    'aggregate budgets bound rejection logs and delivery resumes after reset',
    () async {
      final target = engine(window: const Duration(seconds: 30));
      final identities = [
        publisher,
        for (var i = 0; i < 4; i++) Identity.generate(),
      ];
      for (final identity in identities) {
        await pair(target, identity);
      }
      await target.start(activeMode: false);
      for (final identity in identities) {
        final client = await connect(target, own: identity);
        for (var i = 0; i < 32; i++) {
          await client.want(List.filled(16, '0' * 64));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await until(
        () async =>
            ((await target.snapshot())['trafficDeferred'] as Map)['requests'] >
            0,
      );
      expect((await target.snapshot())['connectedCount'], identities.length);
      expect((await target.snapshot())['coolingPeerCount'], 0);
      // Five peers sent 32 frames each. Another 4*560 reaches the global
      // 2400-frame cap while each individual peer remains below 600 frames.
      for (final client in clients.take(4).toList()) {
        for (var i = 0; i < 560; i++) {
          await client.send({
            'type': 'inventory',
            'channels': <String>[],
            'bulletins': <String>[],
            'receipts': <String>[],
          });
          if (i % 20 == 19) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
      }
      var rejected = clients[4];
      for (var attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) rejected = await connect(target, own: identities.last);
        await rejected.send({
          'type': 'inventory',
          'channels': <String>[],
          'bulletins': <String>[],
          'receipts': <String>[],
        });
        await until(
          () async => (await target.snapshot())['rejectedCount'] == attempt + 1,
        );
      }
      final state = await target.snapshot();
      expect(state['rejectedCount'], 4);
      expect(state['coolingPeerCount'], 0);
      expect(state['trafficLogSuppressedCount'], greaterThanOrEqualTo(5));
      final report = jsonDecode(await target.exportReport()) as Map;
      final events = (report['events'] as List).cast<Map>();
      expect(
        events.where((e) => e['kind'] == 'global_frame_limit'),
        hasLength(1),
      );
      expect(
        events.where((e) => e['kind'] == 'connected').length,
        lessThanOrEqualTo(identities.length + 1),
      );

      // The fifth peer suffered aggregate exhaustion, not its own violation.
      // Once this fixture's window resets, it can reuse the same identity and
      // deliver fresh news without restarting the engine or clearing its data.
      await Future<void>.delayed(const Duration(seconds: 31));
      final recovered = await connect(target, own: identities.last);
      await until(
        () async => recovered.frames.any((f) => f['type'] == 'inventory'),
      );
      final channel = SignedChannel.create(
        identities.last,
        name: 'آزمایش بازیابی پس از ازدحام',
      );
      final news = SignedBulletin.create(
        identities.last,
        channelId: channel.id,
        runId: 'news',
        sequence: 1,
        text: 'خبر تازه پس از پایان محدودیت به خواننده می‌رسد.',
      );
      await recovered.send({'type': 'channel', 'value': channel.toJson()});
      await recovered.send({'type': 'bulletin', 'value': news.toJson()});
      await until(
        () async => clients.first.frames.any(
          (frame) =>
              frame['type'] == 'bulletin' &&
              (frame['value'] as Map)['id'] == news.id,
        ),
      );
      expect((await target.snapshot())['bulletinCount'], 1);
      expect((await target.snapshot())['coolingPeerCount'], 0);
      expect(recovered.closed, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _Client {
  _Client(this.socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => frames.add(jsonDecode(line) as Map<String, dynamic>),
          onError: (Object _) {
            closed = true;
          },
          onDone: () {
            closed = true;
          },
        );
  }
  final SecureSocket socket;
  final frames = <Map<String, dynamic>>[];
  bool closed = false;
  List<Map<String, dynamic>> get news =>
      frames.where((f) => f['type'] == 'bulletin').toList();
  Future<void> send(Map<String, dynamic> value) async {
    socket.add(utf8.encode('${jsonEncode(value)}\n'));
    await socket.flush();
  }

  Future<void> want(List<String> ids) => send({
    'type': 'want',
    'channels': <String>[],
    'bulletins': ids,
    'receipts': <String>[],
  });
}

Future<void> until(Future<bool> Function() condition) async {
  final clock = Stopwatch()..start();
  while (!await condition()) {
    if (clock.elapsed > const Duration(seconds: 8)) {
      fail('Traffic condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
