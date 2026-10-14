import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

void main() {
  test('valid public-news churn cannot evict a followed channel feed', () async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    final directory = await parent.createTemp('followed-retention-');
    addTearDown(() => directory.delete(recursive: true));
    final local = Identity.generate();
    final followed = Identity.generate();
    final channel = SignedChannel.create(followed, name: 'Followed source');
    final store = PilotStore(
      directory,
      localOwnerId: local.id,
      protectedChannelIds: {channel.id},
    );
    await store.load();
    await store.putChannel(channel.toJson());
    final important = SignedBulletin.create(
      followed,
      runId: 'news',
      text: 'خبرِ دنبال‌شده باید در حافظه بماند',
      sequence: 1,
      channelId: channel.id,
    );
    await store.putBulletin(important.toJson());
    final sources = <SignedChannel>[];
    // Distinct signing keys bypass a per-publisher quota. All envelopes are
    // valid, so this exercises retention rather than malformed-input rejection.
    for (var author = 0; author < 3; author++) {
      final identity = Identity.generate();
      for (var n = 0; n < 2; n++) {
        final other = SignedChannel.create(identity, name: 'Public $author/$n');
        sources.add(other);
        await store.putChannel(other.toJson());
        for (var sequence = 1; sequence <= 48; sequence++) {
          final news = SignedBulletin.create(
            identity,
            runId: 'news',
            text: 'Valid unrelated news $sequence',
            sequence: sequence,
            channelId: other.id,
          );
          await store.putBulletin(news.toJson());
        }
      }
    }
    expect(store.bulletins.length, PilotStore.maxBulletins);
    expect(store.bulletins.containsKey(important.id), true);
    final restored = PilotStore(
      directory,
      localOwnerId: local.id,
      protectedChannelIds: {channel.id},
    );
    await restored.load();
    expect(restored.bulletins.containsKey(important.id), true);
    expect(restored.bulletins.length, PilotStore.maxBulletins);
    // Following all busy sources must not eliminate the public relay cache,
    // or allow those sources to evict the quiet followed item first.
    restored.setProtectedChannelIds({channel.id, ...sources.map((s) => s.id)});
    final newcomer = Identity.generate();
    final publicChannel = SignedChannel.create(
      newcomer,
      name: 'New public relay',
    );
    await restored.putChannel(publicChannel.toJson());
    for (
      var sequence = 1;
      sequence <= PilotStore.publicRelayReserve;
      sequence++
    ) {
      await restored.putBulletin(
        SignedBulletin.create(
          newcomer,
          runId: 'news',
          text: 'Public relay $sequence',
          sequence: sequence,
          channelId: publicChannel.id,
        ).toJson(),
      );
    }
    expect(restored.bulletins.containsKey(important.id), true);
    expect(
      restored.bulletins.values
          .map(SignedBulletin.fromJson)
          .where((news) => news.channelId == publicChannel.id)
          .length,
      PilotStore.publicRelayReserve,
    );
    expect(
      await File('${directory.path}/pilot.jsonl').readAsString(),
      isNot(contains('protectedChannelIds')),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
