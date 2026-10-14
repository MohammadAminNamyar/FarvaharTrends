import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/delivery_mode.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/peer_contact_store.dart';

void main() {
  final engines = <PeerEngine>[];
  late Directory scratch;
  late Identity first, second, senderKey, readerKey, publisher;
  setUpAll(() {
    first = Identity.generate();
    second = Identity.generate();
    senderKey = Identity.generate();
    readerKey = Identity.generate();
    publisher = Identity.generate();
  });

  setUp(() async {
    final root = Directory('${Directory.current.path}/.tooling/test-tmp');
    await root.create(recursive: true);
    scratch = await root.createTemp('mesh-referral-');
  });
  tearDown(() async {
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    await scratch.delete(recursive: true);
  });
  PeerEngine create(
    Identity key,
    String name, {
    bool helper = false,
    List<PeerCard> seeds = const [],
    DeliveryMode mode = DeliveryMode.allNetworks,
    bool referrals = true,
  }) {
    final engine = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: key,
      publisherIdentity: key == senderKey ? publisher : null,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      bootstrapPeers: seeds,
      acceptTcpEnrollment: helper,
      enablePeerReferrals: referrals,
      allowLoopbackContactsForTesting: true,
      deliveryMode: mode,
      deviceState: () async => {},
      onStatus: (_) {},
    );
    engines.add(engine);
    return engine;
  }

  Future<PeerCard> card(PeerEngine helper) async => PeerCard(
    name: 'Initial test contact',
    certificatePem: helper.identity.certPem,
    host: '127.0.0.1',
    port: (await helper.snapshot())['listenPort'] as int,
    tcpEnrollment: true,
  );
  Future<void> advertise(PeerEngine helper, {int lifetime = 120000}) async =>
      helper.publishHelperEndpoint(
        host: '127.0.0.1',
        port: (await helper.snapshot())['listenPort'] as int,
        lifetimeMs: lifetime,
      );

  test('news and signed discovery introductions survive A leaving and B restarting before C joins', () async {
    final a = create(first, 'carry-a', helper: true);
    await a.start(activeMode: false);
    await a.publishDiscoveryEndpoint('11.2.3.4', 49737);
    final b = create(second, 'carry-b', helper: true, seeds: [await card(a)]);
    await b.start(activeMode: false);
    final channel = await a.createChannel(name: 'Offline forwarding');
    await a.publishToChannel(
      channelId: channel.id,
      text: 'PT-OFFLINE-CARRY-001',
    );
    await until(
      () async =>
          b.discoveryContacts.isNotEmpty &&
          ((await b.snapshot())['bulletins'] as List).any(
            (v) => v['text'] == 'PT-OFFLINE-CARRY-001',
          ),
    );
    await a.stop();
    await b.stop();
    final restarted = create(second, 'carry-b', helper: true);
    await restarted.start(activeMode: false);
    final c = create(readerKey, 'carry-c', seeds: [await card(restarted)]);
    await c.start(activeMode: false);
    await until(
      () async =>
          c.discoveryContacts.isNotEmpty &&
          ((await c.snapshot())['bulletins'] as List).any(
            (v) => v['text'] == 'PT-OFFLINE-CARRY-001',
          ),
    );
    expect(c.discoveryContacts.single.id, first.id);
    expect(c.discoveryContacts.single.endpoint, '11.2.3.4:49737');
    expect((await a.snapshot())['running'], isFalse);
    expect((await c.snapshot())['connectedCount'], 1);
  });

  test('Peers learn an unconfigured helper and receive new news after losing their initial helper', () async {
    final b = create(second, 'b', helper: true);
    await b.start(activeMode: false);
    await advertise(b);
    final a = create(first, 'a', helper: true, seeds: [await card(b)]);
    await a.start(activeMode: false);
    final seed = await card(a);
    final sender = create(senderKey, 'sender', seeds: [seed]);
    final reader = create(readerKey, 'reader', seeds: [seed]);
    await sender.start(activeMode: false);
    await reader.start(activeMode: false);
    await until(
      () async =>
          peers(await sender.snapshot()).contains(second.id) &&
          peers(await reader.snapshot()).contains(second.id),
    );
    await until(() async => (await b.snapshot())['connectedCount'] == 3);
    await a.stop();
    await until(
      () async =>
          (await sender.snapshot())['connectedCount'] == 1 &&
          (await reader.snapshot())['connectedCount'] == 1,
    );
    final channel = await sender.createChannel(name: 'خبر پس از قطع همتای اول');
    const text = 'این خبر بعد از قطع همتای اولیه، از مسیر یادگرفته‌شده رسید.';
    await sender.publishToChannel(channelId: channel.id, text: text);
    await until(
      () async => ((await reader.snapshot())['bulletins'] as List).any(
        (value) => value['text'] == text,
      ),
    );
    final status = await reader.snapshot();
    final news = (status['bulletins'] as List).single;
    expect(news['sourceId'], publisher.id);
    expect(news['sourceId'], isNot(senderKey.id));
    expect(status['bootstrapConfiguredCount'], 1);
    expect(status['helperContactCount'], 1);
    expect(
      (status['peers'] as List).singleWhere(
        (value) => value['id'] == second.id,
      )['trust'],
      'unverified',
    );
  });

  test('A restarted reader reconnects using its learned cache with no configured seeds', () async {
    final b = create(second, 'cached-b', helper: true);
    await b.start(activeMode: false);
    await advertise(b, lifetime: 3000);
    final a = create(first, 'cached-a', helper: true, seeds: [await card(b)]);
    await a.start(activeMode: false);
    final reader = create(readerKey, 'cached-reader', seeds: [await card(a)]);
    await reader.start(activeMode: false);
    await until(
      () async => ((await reader.snapshot())['peers'] as List).any(
        (peer) => peer['id'] == second.id && peer['connected'] == true,
      ),
    );
    await reader.stop();
    await a.stop();
    // The public hint has expired: reconnection must use the private cached pin,
    // and the old address must not be advertised to other phones as fresh.
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    final restarted = create(readerKey, 'cached-reader');
    await restarted.start(activeMode: false);
    await until(
      () async => (await restarted.snapshot())['connectedCount'] == 1,
    );
    expect((await restarted.snapshot())['bootstrapConfiguredCount'], 0);
    expect((await restarted.snapshot())['helperContactCount'], 0);
    final channel = await b.createChannel(name: 'Cached route');
    await b.publishToChannel(
      channelId: channel.id,
      text: 'Fresh after process restart',
    );
    await until(
      () async => ((await restarted.snapshot())['bulletins'] as List).any(
        (item) => item['text'] == 'Fresh after process restart',
      ),
    );
  });

  test(
    'cache write failure preserves live authenticated news delivery',
    () async {
      final helper = create(second, 'disk-helper', helper: true);
      await helper.start(activeMode: false);
      await advertise(helper);
      // Simulate a local filesystem failure without changing host permissions.
      await Directory('${scratch.path}/disk-reader/helper-contacts.json.next')
          .create(recursive: true);
      final reader = create(
        readerKey,
        'disk-reader',
        seeds: [await card(helper)],
      );
      await reader.start(activeMode: false);
      await until(
        () async =>
            (await reader.snapshot())['lastError'] ==
            'helper_contact_cache_unavailable',
      );
      final channel = await helper.createChannel(name: 'Storage failure');
      await helper.publishToChannel(
        channelId: channel.id,
        text: 'Still receiving',
      );
      await until(
        () async => ((await reader.snapshot())['bulletins'] as List).any(
          (b) => b['text'] == 'Still receiving',
        ),
      );
      expect((await reader.snapshot())['connectedCount'], 1);
    },
  );

  test('Only an enabled helper may publish a reachable endpoint', () async {
    final ordinary = create(readerKey, 'ordinary');
    await ordinary.start(activeMode: false);
    await expectLater(advertise(ordinary), throwsStateError);
    final disabled = create(first, 'disabled', helper: true, referrals: false);
    await disabled.start(activeMode: false);
    await expectLater(advertise(disabled), throwsStateError);
    final nearby = create(
      second,
      'nearby',
      helper: true,
      mode: DeliveryMode.nearbyOnly,
    );
    await nearby.start(activeMode: false);
    await expectLater(advertise(nearby), throwsStateError);
    expect((await nearby.snapshot())['helperContactCount'], 0);
  });

  test(
    'a signed false address is not forwarded or persisted as a recovery route',
    () async {
      final liar = create(second, 'false-address', helper: true);
      await liar.start(activeMode: false);
      final a = create(
        first,
        'verifier',
        helper: true,
        seeds: [await card(liar)],
      );
      await a.start(activeMode: false);
      await until(() async => (await a.snapshot())['connectedCount'] == 1);
      // The claimed port belongs to a different TLS identity. An established
      // connection to the signer at its real port must not validate this claim.
      await liar.publishHelperEndpoint(
        host: '127.0.0.1',
        port: (await a.snapshot())['listenPort'] as int,
        lifetimeMs: 120000,
      );
      await until(() async => (await a.snapshot())['helperContactCount'] == 1);
      final reader = create(
        readerKey,
        'isolated-reader',
        seeds: [await card(a)],
      );
      await reader.start(activeMode: false);
      final channel = await a.createChannel(name: 'Referral rejection barrier');
      await a.publishToChannel(
        channelId: channel.id,
        text: 'Inventory received',
      );
      await until(
        () async => ((await reader.snapshot())['bulletins'] as List).any(
          (b) => b['text'] == 'Inventory received',
        ),
      );
      expect(peers(await reader.snapshot()), isNot(contains(second.id)));
      expect((await reader.snapshot())['helperContactCount'], 0);
      expect(
        await PeerContactStore(
          Directory('${scratch.path}/verifier'),
          allowLoopbackForTesting: true,
        ).loadForReconnect(),
        isEmpty,
      );
    },
  );
}

Set<String> peers(Map<String, dynamic> state) =>
    (state['peers'] as List).map((value) => value['id'] as String).toSet();
Future<void> until(Future<bool> Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(limit)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  fail('Peer state did not converge within the test deadline');
}
