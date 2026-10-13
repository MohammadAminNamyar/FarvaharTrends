import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/delivery_mode.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_engine.dart';

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
    await advertise(b);
    final a = create(first, 'cached-a', helper: true, seeds: [await card(b)]);
    await a.start(activeMode: false);
    final reader = create(readerKey, 'cached-reader', seeds: [await card(a)]);
    await reader.start(activeMode: false);
    await until(() async => peers(await reader.snapshot()).contains(second.id));
    await reader.stop();
    await a.stop();
    final restarted = create(readerKey, 'cached-reader');
    await restarted.start(activeMode: false);
    await until(
      () async => (await restarted.snapshot())['connectedCount'] == 1,
    );
    expect((await restarted.snapshot())['bootstrapConfiguredCount'], 0);
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
