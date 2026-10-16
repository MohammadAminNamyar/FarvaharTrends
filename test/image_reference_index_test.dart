import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/channel_control.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/media_store.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

class CountedMap extends MapBase<String, dynamic> {
  CountedMap(this.valuesMap);
  final Map<String, dynamic> valuesMap;
  int reads = 0;
  @override
  dynamic operator [](Object? key) {
    reads++;
    return valuesMap[key];
  }

  @override
  void operator []=(String key, dynamic value) => valuesMap[key] = value;
  @override
  Iterable<String> get keys {
    reads++;
    return valuesMap.keys;
  }

  @override
  void clear() => valuesMap.clear();
  @override
  dynamic remove(Object? key) => valuesMap.remove(key);
}

void main() {
  late Directory dir;
  late Identity owner;
  late NewsImage image;
  setUpAll(() async {
    owner = Identity.generate();
    image = NewsImage.inspect(
      await File('test/fixtures/news-small.jpg').readAsBytes(),
    );
  });
  setUp(() async {
    final parent = Directory('.tooling/test-tmp');
    await parent.create(recursive: true);
    dir = await parent.createTemp('image-index-');
  });
  tearDown(() async => dir.delete(recursive: true));
  test('shared hash keeps local priority, survives reload, drops revoked references', () async {
    final channel = SignedChannel.create(owner, name: 'تصویر');
    var store = PilotStore(dir, localOwnerId: owner.id);
    await store.load();
    await store.putChannel(channel.toJson());
    SignedBulletin news(int n) => SignedBulletin.create(
      owner,
      runId: 'news',
      text: 'خبر $n',
      sequence: n,
      channelId: channel.id,
      image: image,
    );
    final remote = news(1), own = news(2);
    await store.putBulletin(remote.toJson());
    expect(store.referencedImage(image.hash)?.$2, false);
    await store.putPublication(own.toJson(), {
      'id': own.id,
      'channelId': channel.id,
      'recipients': <String>[],
    });
    expect(store.referencedImage(image.hash)?.$2, true);
    store = PilotStore(dir, localOwnerId: owner.id);
    await store.load();
    expect(store.referencedImage(image.hash)?.$2, true);
    final policy = ChannelControl.create(
      owner,
      channel,
      kind: 'policy',
      data: {
        'revision': 1,
        'activeGrants': <String>[],
        'removed': [
          {'id': own.id, 'authorId': owner.id, 'sequence': 2},
        ],
        'floors': <String, int>{},
        'deleted': false,
      },
    );
    await store.putChannelPolicy(policy);
    expect(store.referencedImage(image.hash)?.$2, false);
    final deletion = ChannelControl.create(
      owner,
      channel,
      kind: 'policy',
      data: {
        'revision': 2,
        'activeGrants': <String>[],
        'removed': <Map<String, dynamic>>[],
        'floors': <String, int>{},
        'deleted': true,
      },
    );
    await store.putChannelPolicy(deletion);
    expect(store.referencedImage(image.hash), isNull);
    expect(store.referencedImageHashes, isEmpty);
  });
  test('64 advertised hashes do not parse any cached bulletin', () async {
    final store = PilotStore(dir, localOwnerId: owner.id);
    await store.load();
    final channel = SignedChannel.create(owner, name: 'Index');
    await store.putChannel(channel.toJson());
    final news = SignedBulletin.create(
      owner,
      runId: 'news',
      text: 'خبر',
      sequence: 1,
      channelId: channel.id,
      image: image,
    );
    await store.putBulletin(news.toJson());
    final counted = CountedMap(store.bulletins[news.id]!);
    store.bulletins[news.id] = counted;
    for (var inventory = 0; inventory < 100; inventory++) {
      for (var i = 0; i < 64; i++) {
        store.referencedImage(i == 0 ? image.hash : '$i');
      }
      expect(store.referencedImageHashes.toList(), [image.hash]);
    }
    expect(
      counted.reads,
      0,
      reason: 'Inventory work must not depend on bulletin decoding',
    );
  });
  test(
    'channel retention eviction removes an unshared image reference',
    () async {
      final store = PilotStore(dir, localOwnerId: owner.id);
      await store.load();
      final channel = SignedChannel.create(owner, name: 'Eviction');
      await store.putChannel(channel.toJson());
      for (var i = 1; i <= 65; i++) {
        await store.putBulletin(
          SignedBulletin.create(
            owner,
            runId: 'news',
            text: '$i',
            sequence: i,
            channelId: channel.id,
            image: i == 1 ? image : null,
          ).toJson(),
        );
      }
      expect(store.bulletins.length, 64);
      expect(store.referencedImage(image.hash), isNull);
      final reopened = PilotStore(dir, localOwnerId: owner.id);
      await reopened.load();
      expect(reopened.referencedImageHashes, isEmpty);
    },
  );
}
