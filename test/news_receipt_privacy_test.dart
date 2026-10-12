import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  late Identity publisher;
  late Identity receiver;
  late Identity other;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <SecureSocket>[];

  setUpAll(() {
    publisher = Identity.generate();
    receiver = Identity.generate();
    other = Identity.generate();
  });

  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('receipt-privacy-');
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
    if (await scratch.exists()) {
      await scratch.delete(recursive: true);
    }
  });

  PeerEngine engine(
    Identity identity, {
    Future<Map<String, dynamic>> Function()? state,
  }) {
    final value = PeerEngine(
      directory: scratch,
      identity: identity,
      listenPort: 0,
      enableLanDiscovery: false,
      discoveryPort: 0,
      deviceState: state ?? () async => {'network': 'wifi', 'isLocked': true},
      onStatus: (_) {},
    );
    engines.add(value);
    return value;
  }

  Future<void> until(Future<bool> Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!await condition()) {
      if (DateTime.now().isAfter(end)) {
        fail('Condition was not reached within ten seconds.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<SecureSocket> connect(PeerEngine target, {Identity? client}) async {
    final own = client ?? publisher;
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(own.certPem))
      ..usePrivateKeyBytes(utf8.encode(own.keyPem))
      ..setTrustedCertificatesBytes(utf8.encode(receiver.certPem));
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
      context: context,
      onBadCertificate: (cert) =>
          Identity.certificateId(cert.pem) == receiver.id,
      timeout: const Duration(seconds: 3),
    );
    sockets.add(socket);
    return socket;
  }

  Future<void> frame(SecureSocket socket, Map<String, dynamic> value) async {
    socket.add(utf8.encode('${jsonEncode(value)}\n'));
    await socket.flush();
  }

  test(
    'ordinary publication samples no measurement state or trial roster',
    () async {
      var samples = 0;
      final source = engine(
        publisher,
        state: () async {
          samples++;
          return {'network': 'wifi', 'isLocked': true, 'elapsedRealtimeMs': 12};
        },
      );
      final channel = await source.createChannel(name: 'Public news');
      await source.publishToChannel(
        channelId: channel.id,
        text: 'Offline post',
      );
      expect(samples, 0);
      expect((await source.snapshot())['trials'], isEmpty);
      final store = PilotStore(scratch);
      await store.load();
      final metadata = store.publications.values.single;
      expect(metadata['channelId'], channel.id);
      expect(metadata['recipients'], isEmpty);
      expect(metadata.containsKey('clockToken'), false);
      expect(metadata.containsKey('publishedElapsedRealtimeMs'), false);
    },
  );

  test(
    'old ordinary-news ACKs are hidden and never inventoried or served',
    () async {
      final channel = SignedChannel.create(publisher, name: 'Public news');
      final bulletin = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: 'Cached from an older app',
        sequence: 1,
        channelId: channel.id,
      );
      final oldAck = SignedReceipt.create(
        receiver,
        bulletinId: bulletin.id,
        sourceId: publisher.id,
        runId: bulletin.runId,
        locked: true,
      );
      final store = PilotStore(scratch);
      await store.load();
      await store.setPeers([
        {
          ...PeerCard(
            name: 'Manual source',
            certificatePem: publisher.certPem,
          ).toJson(),
          'origin': 'manual',
        },
      ]);
      await store.putChannel(channel.toJson());
      await store.putBulletin(bulletin.toJson());
      await store.putReceipt(oldAck.toJson(), {
        'localDeviceState': {'isLocked': true},
      });
      final target = engine(receiver);
      expect((await target.snapshot())['receiptCount'], 0);
      expect(
        (jsonDecode(await target.exportReport()) as Map)['receipts'],
        isEmpty,
      );
      await target.start(activeMode: false);
      final socket = await connect(target);
      final frames = <Map<String, dynamic>>[];
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => frames.add(jsonDecode(line) as Map<String, dynamic>),
            onError: (Object _) {},
          );
      await until(() async => frames.any((f) => f['type'] == 'inventory'));
      expect(
        frames.where((f) => f['type'] == 'inventory').first['receipts'],
        isEmpty,
      );
      await frame(socket, {
        'type': 'want',
        'channels': <String>[],
        'bulletins': [bulletin.id],
        'receipts': [oldAck.id],
      });
      await until(() async => frames.any((f) => f['type'] == 'bulletin'));
      await frame(socket, {'type': 'receipt', 'value': oldAck.toJson()});
      await frame(socket, {'type': 'bulletin', 'value': bulletin.toJson()});
      await until(() async => (await target.snapshot())['duplicateCount'] == 1);
      expect((await target.snapshot())['receiptCount'], 0);
      expect(frames.where((f) => f['type'] == 'receipt'), isEmpty);
      expect((await target.snapshot())['connectedCount'], 1);
    },
  );

  test(
    'first ordinary arrival persists only local path and network observation',
    () async {
      final target = engine(receiver);
      await target.addPeer(
        PeerCard(name: 'Source', certificatePem: publisher.certPem),
      );
      await target.start(activeMode: false);
      final channel = SignedChannel.create(
        publisher,
        name: 'Fresh public news',
      );
      final bulletin = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: 'Private local observation',
        sequence: 1,
        channelId: channel.id,
      );
      final socket = await connect(target);
      socket.listen((_) {}, onError: (Object _) {});
      await frame(socket, {'type': 'channel', 'value': channel.toJson()});
      await frame(socket, {'type': 'bulletin', 'value': bulletin.toJson()});
      await until(() async => (await target.snapshot())['bulletinCount'] == 1);
      expect((await target.snapshot())['receiptCount'], 0);
      final store = PilotStore(scratch);
      await store.load();
      expect(store.receipts, isEmpty);
      expect(store.bulletinObservations[bulletin.id], {
        'receivedVia': 'ip',
        'receivedNetwork': 'wifi',
        'receivedAtWallMs': isA<int>(),
      });
    },
  );

  test('an automatic contact cannot collect legacy diagnostic ACKs', () async {
    final target = engine(receiver);
    await target.start(activeMode: false);
    await target.admitNativePeer(
      signedBeacon: PeerDiscovery.beacon(publisher, 45871),
      routeId: 'unverified-source',
      transport: PeerTransport.bluetooth,
    );
    final socket = await connect(target);
    socket.listen((_) {}, onError: (Object _) {});
    final bulletin = SignedBulletin.create(
      publisher,
      runId: 'not-enrolled',
      text: 'No automatic measurements',
      sequence: 1,
    );
    await frame(socket, {'type': 'bulletin', 'value': bulletin.toJson()});
    await until(() async => (await target.snapshot())['rejectedCount'] == 1);
    expect((await target.snapshot())['receiptCount'], 0);
    expect((await target.snapshot())['bulletinCount'], 0);
  });

  test(
    'discarded stale signed replay is neither relayed nor acknowledged',
    () async {
      final store = PilotStore(scratch);
      await store.load();
      final channel = SignedChannel.create(publisher, name: 'Replay protected');
      await store.putChannel(channel.toJson());
      final news = <SignedBulletin>[];
      for (var seq = 1; seq <= PilotStore.maxBulletinsPerChannel + 1; seq++) {
        final value = SignedBulletin.create(
          publisher,
          runId: 'news',
          text: '$seq',
          sequence: seq,
          channelId: channel.id,
        );
        news.add(value);
        await store.putBulletin(value.toJson());
      }
      final target = engine(receiver);
      await target.addPeer(
        PeerCard(name: 'Source', certificatePem: publisher.certPem),
      );
      await target.addPeer(
        PeerCard(name: 'Other relay', certificatePem: other.certPem),
      );
      await target.start(activeMode: false);
      final source = await connect(target);
      source.listen((_) {}, onError: (Object _) {});
      final sink = await connect(target, client: other);
      final frames = <Map<String, dynamic>>[];
      sink
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => frames.add(jsonDecode(line) as Map<String, dynamic>),
            onError: (Object _) {},
          );
      await until(() async => (await target.snapshot())['connectedCount'] == 2);
      await frame(source, {'type': 'bulletin', 'value': news.first.toJson()});
      await until(() async => (await target.snapshot())['duplicateCount'] == 1);
      final fresh = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: 'Fresh',
        sequence: PilotStore.maxBulletinsPerChannel + 2,
        channelId: channel.id,
      );
      await frame(source, {'type': 'bulletin', 'value': fresh.toJson()});
      await until(
        () async => frames.any(
          (value) =>
              value['type'] == 'bulletin' &&
              (value['value'] as Map)['id'] == fresh.id,
        ),
      );
      expect(
        frames.where(
          (value) =>
              value['type'] == 'bulletin' &&
              (value['value'] as Map)['id'] == news.first.id,
        ),
        isEmpty,
      );
      expect(frames.where((value) => value['type'] == 'receipt'), isEmpty);
      expect((await target.snapshot())['receiptCount'], 0);
      expect(
        ((await target.snapshot())['bulletins'] as List).any(
          (value) => value['id'] == news.first.id,
        ),
        false,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('valid foreign metadata rotates its oldest entry without dropping the relay', () async {
    final store = PilotStore(scratch);
    await store.load();
    for (var i = 0; i < PilotStore.maxChannelsPerPublisher; i++) {
      await store.putChannel(
        SignedChannel.create(publisher, name: 'Channel $i').toJson(),
      );
    }
    final oldestId = store.channels.keys.first;
    final target = engine(receiver);
    await target.addPeer(
      PeerCard(name: 'Source', certificatePem: publisher.certPem),
    );
    await target.start(activeMode: false);
    final socket = await connect(target);
    socket.listen((_) {}, onError: (Object _) {});
    final replacement = SignedChannel.create(publisher, name: 'Fresh channel');
    await frame(socket, {'type': 'channel', 'value': replacement.toJson()});
    final quiet = SignedChannel.create(other, name: 'Another publisher');
    await frame(socket, {'type': 'channel', 'value': quiet.toJson()});
    await until(
      () async =>
          ((await target.snapshot())['channels'] as List).length ==
          PilotStore.maxChannelsPerPublisher + 1,
    );
    final state = await target.snapshot();
    expect(state['connectedCount'], 1);
    expect(state['rejectedCount'], 0);
    expect(state['lastError'], isNull);
    final ids = (state['channels'] as List).map((value) => value['id']).toSet();
    expect(ids, containsAll([replacement.id, quiet.id]));
    expect(ids, isNot(contains(oldestId)));
    expect((state['evictions'] as Map)['channels'], 1);
    expect(
      (state['events'] as List).any(
        (event) =>
            event['kind'] == 'channel_cache_limited' &&
            event['reason'] == 'channel_publisher_capacity',
      ),
      false,
    );
  });
}
