import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  late Identity publisher, other;
  late Directory scratch;
  setUpAll(() {
    publisher = Identity.generate();
    other = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('cache-fairness-');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test('one noisy channel retains its newest bounded news without removing another source', () async {
    final store = PilotStore(scratch);
    await store.load();
    final noisy = SignedChannel.create(publisher, name: 'Noisy');
    final quiet = SignedChannel.create(other, name: 'Quiet');
    await store.putChannel(noisy.toJson());
    await store.putChannel(quiet.toJson());
    final quietNews = SignedBulletin.create(
      other,
      runId: 'news',
      text: 'Keep this source',
      sequence: 1,
      channelId: quiet.id,
    );
    await store.putBulletin(
      quietNews.toJson(),
      observation: {'receivedVia': 'lan'},
    );
    SignedBulletin? first, last;
    for (var i = 0; i < PilotStore.maxBulletinsPerChannel + 3; i++) {
      final sequence = await store.nextChannelSequence(noisy.id);
      final bulletin = SignedBulletin.create(
        publisher,
        runId: 'news',
        text: 'Noise $i',
        sequence: sequence,
        channelId: noisy.id,
      );
      first ??= bulletin;
      last = bulletin;
      await store.putPublication(bulletin.toJson(), {'sequence': sequence});
    }
    final receipt = SignedReceipt.create(
      other,
      bulletinId: first!.id,
      sourceId: publisher.id,
      runId: 'news',
      locked: true,
    );
    await store.putReceipt(receipt.toJson(), {'receivedVia': 'ip'});
    expect(store.bulletins.length, PilotStore.maxBulletinsPerChannel + 1);
    expect(store.bulletins.containsKey(quietNews.id), true);
    expect(store.bulletins.containsKey(first.id), false);
    expect(store.bulletins.containsKey(last!.id), true);
    expect(store.publications.containsKey(first.id), true);
    expect(store.receipts.containsKey(receipt.id), true);
    expect(await store.putBulletin(last.toJson()), false);
    final retained = store.bulletins.keys.toSet();
    final journal = File('${scratch.path}/pilot.jsonl');
    final journalLength = await journal.length();
    // Replaying an evicted, correctly signed older object cannot push newer
    // sequence numbers out of the channel or produce another flushed record.
    expect(await store.putBulletin(first.toJson()), false);
    expect(store.bulletins.keys.toSet(), retained);
    expect(await journal.length(), journalLength);
    final reopened = PilotStore(scratch);
    await reopened.load();
    expect(reopened.bulletins.length, store.bulletins.length);
    expect(reopened.bulletins.containsKey(quietNews.id), true);
    expect(reopened.receipts.keys, [receipt.id]);
    expect(await reopened.putBulletin(first.toJson()), false);
    expect(reopened.bulletins.keys.toSet(), retained);
    expect(
      await reopened.nextChannelSequence(noisy.id),
      PilotStore.maxBulletinsPerChannel + 4,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('out-of-order signed sequence uses stable content IDs at the retention cutoff', () async {
    final store = PilotStore(scratch);
    await store.load();
    final channel = SignedChannel.create(publisher, name: 'Out of order');
    await store.putChannel(channel.toJson());
    final news = <SignedBulletin>[
      for (
        var sequence = 1;
        sequence <= PilotStore.maxBulletinsPerChannel + 1;
        sequence++
      )
        SignedBulletin.create(
          publisher,
          runId: 'news',
          text: '$sequence',
          sequence: sequence,
          channelId: channel.id,
        ),
    ];
    // Arrival in reverse order must retain the same highest sequence window.
    for (final bulletin in news.reversed) {
      await store.putBulletin(bulletin.toJson());
    }
    expect(store.bulletins.containsKey(news.first.id), false);
    final tie = SignedBulletin.create(
      publisher,
      runId: 'news',
      text: 'Same sequence, distinct signed object',
      sequence: 2,
      channelId: channel.id,
    );
    final preferredId = tie.id.compareTo(news[1].id) < 0 ? tie.id : news[1].id;
    expect(await store.putBulletin(tie.toJson()), preferredId == tie.id);
    expect(store.bulletins.containsKey(preferredId), true);
    expect(store.bulletins.length, PilotStore.maxBulletinsPerChannel);
    final reopened = PilotStore(scratch);
    await reopened.load();
    expect(reopened.bulletins.keys.toSet(), store.bulletins.keys.toSet());
    expect(reopened.bulletins.containsKey(news.last.id), true);
    expect(reopened.bulletins.containsKey(news.first.id), false);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('multiple noisy channels share a publisher budget and keep another key in cache', () async {
    final store = PilotStore(scratch);
    await store.load();
    final quiet = SignedChannel.create(other, name: 'Quiet');
    await store.putChannel(quiet.toJson());
    final news = SignedBulletin.create(
      other,
      runId: 'news',
      text: 'Independent key',
      sequence: 1,
      channelId: quiet.id,
    );
    await store.putBulletin(news.toJson());
    for (var c = 0; c < 3; c++) {
      final channel = SignedChannel.create(publisher, name: 'Noisy $c');
      await store.putChannel(channel.toJson());
      for (var sequence = 1; sequence <= 40; sequence++) {
        final bulletin = SignedBulletin.create(
          publisher,
          runId: 'news',
          text: '$c / $sequence',
          sequence: sequence,
          channelId: channel.id,
        );
        await store.putBulletin(
          bulletin.toJson(),
          observation: {'receivedVia': 'bluetooth'},
        );
      }
    }
    expect(store.bulletins.length, PilotStore.maxBulletinsPerPublisher + 1);
    expect(store.bulletins.containsKey(news.id), true);
    expect(
      store.bulletinObservations.length,
      lessThanOrEqualTo(store.bulletins.length),
    );
    final reopened = PilotStore(scratch);
    await reopened.load();
    expect(reopened.bulletins.length, PilotStore.maxBulletinsPerPublisher + 1);
    final byChannel = <String?, int>{};
    for (final raw in reopened.bulletins.values) {
      final id = SignedBulletin.fromJson(raw).channelId;
      byChannel[id] = (byChannel[id] ?? 0) + 1;
    }
    expect(
      byChannel.values.every(
        (count) => count <= PilotStore.maxBulletinsPerChannel,
      ),
      true,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('one signing key cannot fill all channel metadata slots', () async {
    final store = PilotStore(scratch);
    await store.load();
    for (var i = 0; i < PilotStore.maxChannelsPerPublisher; i++) {
      await store.putChannel(
        SignedChannel.create(publisher, name: 'Owner $i').toJson(),
      );
    }
    await expectLater(
      store.putChannel(
        SignedChannel.create(publisher, name: 'One too many').toJson(),
      ),
      throwsA(
        isA<ChannelCapacityException>().having(
          (error) => error.reason,
          'reason',
          'channel_publisher_capacity',
        ),
      ),
    );
    final quiet = SignedChannel.create(other, name: 'Other publisher');
    expect(await store.putChannel(quiet.toJson()), true);
    final reopened = PilotStore(scratch);
    await reopened.load();
    expect(reopened.channels.length, PilotStore.maxChannelsPerPublisher + 1);
    expect(reopened.channels.containsKey(quiet.id), true);
  });
}
