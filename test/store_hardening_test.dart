import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  late Identity local, remote;
  late Directory scratch;

  setUpAll(() {
    local = Identity.generate();
    remote = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('store-hardening-');
  });
  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test(
    'diagnostic history has byte bounds and compaction removes backup',
    () async {
      final store = PilotStore(scratch, localOwnerId: local.id);
      await store.load();
      for (var i = 0; i < 90; i++) {
        await store.event({
          'kind': 'bounded',
          'index': i,
          for (var n = 0; n < 64; n++) 'field-$n': 'ع' * 1024,
        });
      }
      final reopened = PilotStore(scratch, localOwnerId: local.id);
      await reopened.load();
      final bytes = reopened.events.fold<int>(
        0,
        (sum, row) => sum + utf8.encode(jsonEncode(row)).length,
      );
      expect(bytes, lessThanOrEqualTo(512 * 1024));
      expect(reopened.events, isNotEmpty);
      expect(reopened.events.last['index'], 89);
      expect(await File('${scratch.path}/pilot.jsonl.bak').exists(), isFalse);
      expect(
        await File('${scratch.path}/pilot.jsonl').length(),
        lessThan(600 * 1024),
      );
    },
  );

  test('overlay arrival path survives persistence and reopening', () async {
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    final channel = SignedChannel.create(remote, name: 'Network news');
    await store.putChannel(channel.toJson());
    final news = SignedBulletin.create(
      remote,
      runId: 'news',
      text: 'Fresh network news',
      sequence: 1,
      channelId: channel.id,
    );
    final observation = {
      'receivedVia': 'overlay',
      'receivedNetwork': 'cellular',
      'receivedAtWallMs': DateTime.now().millisecondsSinceEpoch,
    };
    expect(
      await store.putBulletin(news.toJson(), observation: observation),
      isTrue,
    );
    expect(store.bulletinObservations[news.id], observation);
    final reopened = PilotStore(scratch, localOwnerId: local.id);
    await reopened.load();
    expect(reopened.bulletinObservations[news.id], observation);
  });

  test(
    'torn UTF-8 tail cannot prevent recovery of committed records',
    () async {
      final store = PilotStore(scratch, localOwnerId: local.id);
      await store.load();
      expect(await store.nextSequence(), 1);
      await File('${scratch.path}/pilot.jsonl').writeAsBytes(
        [...utf8.encode('{"kind":"event","value":{"text":"'), 0xd8],
        mode: FileMode.append,
        flush: true,
      );
      final reopened = PilotStore(scratch, localOwnerId: local.id);
      await reopened.load();
      expect(reopened.sequence, 1);
      expect(reopened.events, isEmpty);
      expect(await reopened.nextSequence(), 2);
      final compacted = PilotStore(scratch, localOwnerId: local.id);
      await compacted.load();
      expect(compacted.sequence, 2);
    },
  );

  test('invalid UTF-8 record does not swallow the next valid record', () async {
    await scratch.create(recursive: true);
    await File('${scratch.path}/pilot.jsonl').writeAsBytes([
      ...utf8.encode('{"kind":"sequence","value":1}\n'),
      0xff,
      10,
      ...utf8.encode('{"kind":"sequence","value":2}\n'),
    ], flush: true);
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    expect(store.sequence, 2);
    expect(await store.nextSequence(), 3);
  });

  test('oversized journal record is discarded before decoding', () async {
    await scratch.create(recursive: true);
    final file = File('${scratch.path}/pilot.jsonl');
    await file.writeAsBytes(
      List.filled(PilotStore.maxJournalRecordBytes + 1, 0x20),
      flush: true,
    );
    await file.writeAsString(
      '\n{"kind":"sequence","value":4}\n',
      mode: FileMode.append,
      flush: true,
    );
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    expect(store.sequence, 4);
    expect(await file.length(), lessThan(2048));
  });

  test(
    'wrong-shaped records cannot partially replace committed state',
    () async {
      final peer = PeerCard(
        name: 'Known contact',
        certificatePem: remote.certPem,
      );
      final channel = SignedChannel.create(local, name: 'Committed channel');
      final news = SignedBulletin.create(
        local,
        runId: 'news',
        text: 'Committed news',
        sequence: 1,
        channelId: channel.id,
      );
      final store = PilotStore(scratch, localOwnerId: local.id);
      await store.load();
      await store.setPeers([
        {...peer.toJson(), 'origin': 'manual'},
      ]);
      await store.putChannel(channel.toJson());
      await store.putPublication(news.toJson(), {
        'id': news.id,
        'channelId': channel.id,
        'recipients': <String>[],
      });
      await store.nextSequence();
      final records = <Map<String, dynamic>>[
        for (final field in [
          'peers',
          'channels',
          'channelSequences',
          'bulletins',
          'bulletinObservations',
          'receipts',
          'publications',
          'evictions',
          'events',
          'sequence',
        ])
          {
            'kind': 'snapshot',
            'peers': {},
            'channels': {},
            'bulletins': {},
            'receipts': {},
            'publications': {},
            'events': [],
            'sequence': 0,
            field: field == 'events'
                ? {}
                : field == 'sequence'
                ? 'bad'
                : [],
          },
        {'kind': 'peers', 'values': {}},
        {'kind': 'sequence', 'value': 'bad'},
        {'kind': 'channelSequence', 'channelId': channel.id, 'value': []},
        {
          'kind': 'bulletin',
          'value': {'id': {}},
        },
        {'kind': 'receipt', 'value': null},
        {'kind': 'publication', 'bulletin': news.toJson(), 'metadata': []},
        {'kind': 'event', 'value': []},
        {'kind': 'sequence', 'value': 7},
      ];
      await File('${scratch.path}/pilot.jsonl').writeAsString(
        records.map((value) => '${jsonEncode(value)}\n').join(),
        mode: FileMode.append,
        flush: true,
      );
      final recovered = PilotStore(scratch, localOwnerId: local.id);
      await recovered.load();
      expect(recovered.peers.keys, [peer.id]);
      expect(recovered.channels.keys, [channel.id]);
      expect(recovered.bulletins.keys, [news.id]);
      expect(recovered.publications.keys, [news.id]);
      expect(recovered.sequence, 7);
      expect(recovered.receipts, isEmpty);
      expect(recovered.events, isEmpty);
      expect(await recovered.nextSequence(), 8);
    },
  );

  test(
    'mixed snapshot rows recover without granting trust or timing evidence',
    () async {
      final peer = PeerCard(
        name: 'Discovered key',
        certificatePem: remote.certPem,
      );
      final channel = SignedChannel.create(local, name: 'Public channel');
      final news = SignedBulletin.create(
        local,
        runId: 'news',
        text: 'Ordinary news',
        sequence: 1,
        channelId: channel.id,
      );
      final diagnostic = SignedBulletin.create(
        local,
        runId: 'explicit-diagnostic',
        text: 'Legacy test',
        sequence: 1,
      );
      final receipt = SignedReceipt.create(
        remote,
        bulletinId: diagnostic.id,
        sourceId: local.id,
        runId: diagnostic.runId,
        locked: false,
      );
      final valid = {
        'kind': 'snapshot',
        'peers': {
          peer.id: {...peer.toJson(), 'origin': 'unrecognized'},
          'wrong-shape': [],
          'bad-certificate': {...peer.toJson(), 'certificatePem': 'corrupt'},
        },
        'channels': {channel.id: channel.toJson(), 'bad': null},
        'channelSequences': {channel.id: 4, 'bad': []},
        'bulletins': {
          news.id: news.toJson(),
          diagnostic.id: diagnostic.toJson(),
          'unsigned': {'id': 'unsigned'},
          'wrong-shape': [],
        },
        'bulletinObservations': {
          news.id: {
            'receivedVia': 'bluetooth',
            'receivedNetwork': 'wifi',
            'receivedAtWallMs': [],
            'localDeviceState': {'isLocked': true},
          },
          diagnostic.id: [],
        },
        'receipts': {
          receipt.id: {
            'envelope': receipt.toJson(),
            'observation': {
              'sourceUpperBoundMs': 'bad',
              'withinFiveMinutes': true,
              'lockedWithinFiveMinutes': true,
              'localDeviceState': {
                'network': 'wifi',
                'privateKey': 'not exported',
              },
            },
          },
          'wrong-shape': [],
          'wrong-envelope': {'envelope': {}},
          'wrong-binding': {'envelope': receipt.toJson(), 'observation': {}},
        },
        'publications': {
          news.id: {
            'id': news.id,
            'channelId': channel.id,
            'recipients': [remote.id],
            'clockToken': 'unwanted measurement',
            'publishedElapsedRealtimeMs': 123,
          },
          diagnostic.id: {
            'id': diagnostic.id,
            'runId': diagnostic.runId,
            'recipients': [remote.id, [], 'bad'],
            'publishedElapsedRealtimeMs': [],
            'clockToken': {},
            'createdAtMs': [],
          },
          'bad': [],
        },
        'events': [
          [],
          {'kind': 'recovered', 'atWallMs': 1, 'nested': []},
        ],
        'sequence': 2,
        'evictions': {'bulletins': [], 'events': -1},
      };
      await File('${scratch.path}/pilot.jsonl')
          .writeAsString('${jsonEncode(valid)}\n', flush: true);
      final recovered = PilotStore(scratch, localOwnerId: local.id);
      await recovered.load();
      expect(recovered.peers.keys, [peer.id]);
      expect(recovered.peers[peer.id]!['origin'], 'lan');
      expect(PeerCard.fromJson(recovered.peers[peer.id]!).id, peer.id);
      expect(recovered.bulletins.keys.toSet(), {news.id, diagnostic.id});
      expect(recovered.receipts.keys, [receipt.id]);
      final observation = recovered.receipts[receipt.id]!['observation'] as Map;
      expect(observation['withinFiveMinutes'], isFalse);
      expect(observation['lockedWithinFiveMinutes'], isFalse);
      expect(observation['localDeviceState'], {'network': 'wifi'});
      expect(recovered.bulletinObservations[news.id], {
        'receivedVia': 'bluetooth',
        'receivedNetwork': 'wifi',
      });
      final ordinary = recovered.publications[news.id]!;
      expect(ordinary['channelId'], channel.id);
      expect(ordinary['recipients'], isEmpty);
      expect(ordinary.containsKey('clockToken'), isFalse);
      expect(ordinary.containsKey('publishedElapsedRealtimeMs'), isFalse);
      final legacy = recovered.publications[diagnostic.id]!;
      expect(legacy['recipients'], [remote.id]);
      expect(legacy.containsKey('publishedElapsedRealtimeMs'), isFalse);
      expect(legacy.containsKey('clockToken'), isFalse);
      expect(recovered.events, [
        {'kind': 'recovered', 'atWallMs': 1},
      ]);
      expect(await recovered.nextChannelSequence(channel.id), 5);
      final compacted = PilotStore(scratch, localOwnerId: local.id);
      await compacted.load();
      expect(compacted.bulletins.keys.toSet(), {news.id, diagnostic.id});
      expect(compacted.receipts.keys, [receipt.id]);
      expect(compacted.peers[peer.id]!['origin'], 'lan');
    },
  );

  test('cached signature corruption and unsafe signed timestamps fail closed', () async {
    final channel = SignedChannel.create(local, name: 'Recovery integrity');
    final valid = SignedBulletin.create(
      local,
      runId: 'news',
      text: 'Valid cached news survives',
      sequence: 1,
      channelId: channel.id,
    );
    final body =
        jsonDecode(utf8.decode(base64Decode(valid.payloadBase64))) as Map;
    Map<String, dynamic> signed(Map<String, dynamic> updates) {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({...body, ...updates})),
      );
      return {
        'id': sha256.convert(bytes).toString(),
        'payloadBase64': base64Encode(bytes),
        'signature': local.sign(bytes),
      };
    }

    final unsafeTime = signed({
      'createdAtMs': maxSignedWallTimeMs + 1,
      'seq': 2,
    });
    final badSignature = signed({'text': 'Corrupt signature', 'seq': 3});
    final bytes = base64Decode(badSignature['signature'] as String);
    bytes[0] ^= 1;
    badSignature['signature'] = base64Encode(bytes);
    await File('${scratch.path}/pilot.jsonl').writeAsString(
      '${jsonEncode({
        'kind': 'snapshot',
        'peers': {},
        'channels': {channel.id: channel.toJson()},
        'bulletins': {valid.id: valid.toJson(), unsafeTime['id']: unsafeTime, badSignature['id']: badSignature},
        'receipts': {},
        'publications': {},
        'events': [],
        'sequence': 0,
      })}\n'
      '${jsonEncode({'kind': 'bulletin', 'value': unsafeTime})}\n'
      '${jsonEncode({'kind': 'bulletin', 'value': badSignature})}\n',
      flush: true,
    );
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    expect(store.bulletins.keys, [valid.id]);
    expect(
      SignedBulletin.fromJson(store.bulletins[valid.id]!)
          .verifyForChannel(channel),
      isTrue,
    );
    final reopened = PilotStore(scratch, localOwnerId: local.id);
    await reopened.load();
    expect(reopened.bulletins.keys, [valid.id]);
  });

  test(
    'foreign publisher rotation removes dependent news and protects local data',
    () async {
      final store = PilotStore(scratch, localOwnerId: local.id);
      await store.load();
      final own = SignedChannel.create(local, name: 'Local channel');
      await store.putChannel(own.toJson());
      final ownSequence = await store.nextChannelSequence(own.id);
      final ownNews = SignedBulletin.create(
        local,
        runId: 'news',
        text: 'Protected local publication',
        sequence: ownSequence,
        channelId: own.id,
      );
      await store.putPublication(ownNews.toJson(), {
        'id': ownNews.id,
        'channelId': own.id,
      });
      final foreign = <SignedChannel>[
        for (var i = 0; i < PilotStore.maxChannelsPerPublisher; i++)
          SignedChannel.create(remote, name: 'Foreign $i'),
      ];
      await store.putChannel(foreign.first.toJson());
      final oldNews = SignedBulletin.create(
        remote,
        runId: 'news',
        text: 'Evict together with its foreign metadata',
        sequence: 1,
        channelId: foreign.first.id,
      );
      await store.putBulletin(
        oldNews.toJson(),
        observation: {'receivedVia': 'bluetooth'},
      );
      // Later channel arrivals leave the first source least recently active.
      for (final channel in foreign.skip(1)) {
        await store.putChannel(channel.toJson());
      }
      final diagnostic = SignedBulletin.create(
        remote,
        runId: 'explicit-diagnostic',
        text: 'Legacy record is unrelated to a foreign channel',
        sequence: 1,
      );
      await store.putBulletin(diagnostic.toJson());
      final receipt = SignedReceipt.create(
        local,
        bulletinId: diagnostic.id,
        sourceId: remote.id,
        runId: diagnostic.runId,
        locked: false,
      );
      await store.putReceipt(receipt.toJson(), {});

      final replacement = SignedChannel.create(remote, name: 'New foreign');
      expect(await store.putChannel(replacement.toJson()), isTrue);
      expect(store.channels.length, PilotStore.maxChannelsPerPublisher + 1);
      expect(store.channels.containsKey(foreign.first.id), isFalse);
      expect(store.channels.containsKey(replacement.id), isTrue);
      expect(store.channels.containsKey(own.id), isTrue);
      expect(store.bulletins.containsKey(oldNews.id), isFalse);
      expect(store.bulletinObservations.containsKey(oldNews.id), isFalse);
      expect(await store.putBulletin(oldNews.toJson()), isFalse);
      expect(store.bulletins.containsKey(oldNews.id), isFalse);
      expect(store.bulletins.containsKey(ownNews.id), isTrue);
      expect(store.publications.containsKey(ownNews.id), isTrue);
      expect(store.bulletins.containsKey(diagnostic.id), isTrue);
      expect(store.receipts.containsKey(receipt.id), isTrue);
      expect(store.evictions['channels'], 1);
      expect(store.evictions['bulletins'], 1);
      final retained = store.channels.keys.toList();

      // Replays the actual pre-rotation snapshot plus all journal mutations.
      final reopened = PilotStore(scratch, localOwnerId: local.id);
      await reopened.load();
      expect(reopened.channels.keys, retained);
      expect(reopened.bulletins.keys.toSet(), {ownNews.id, diagnostic.id});
      expect(reopened.publications.containsKey(ownNews.id), isTrue);
      expect(reopened.receipts.containsKey(receipt.id), isTrue);
      expect(await reopened.nextChannelSequence(own.id), 2);
      expect(reopened.evictions['channels'], 1);
      final freshOwnNews = SignedBulletin.create(
        local,
        runId: 'news',
        text: 'Original owner can still publish',
        sequence: 2,
        channelId: own.id,
      );
      expect(freshOwnNews.verifyForChannel(own), isTrue);
      expect(await reopened.putBulletin(freshOwnNews.toJson()), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('full foreign metadata cache cannot permanently prevent local creation', () async {
    final foreignOwners = [
      remote,
      for (var i = 1; i < 8; i++) Identity.generate(),
    ];
    final foreign = [
      for (var i = 0; i < PilotStore.maxChannels; i++)
        SignedChannel.create(
          foreignOwners[i ~/ PilotStore.maxChannelsPerPublisher],
          name: 'Foreign cache $i',
        ),
    ];
    await File('${scratch.path}/pilot.jsonl').writeAsString(
      '${jsonEncode({
        'kind': 'snapshot',
        'peers': {},
        'channels': {for (final channel in foreign) channel.id: channel.toJson()},
        'channelSequences': {},
        'bulletins': {},
        'receipts': {},
        'publications': {},
        'events': [],
        'sequence': 0,
      })}\n',
      flush: true,
    );
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    expect(store.channels.length, PilotStore.maxChannels);
    final own = SignedChannel.create(local, name: 'Create despite old spam');
    expect(await store.putChannel(own.toJson()), isTrue);
    expect(await store.nextChannelSequence(own.id), 1);
    expect(store.channels.length, PilotStore.maxChannels);
    expect(store.channels.containsKey(foreign.first.id), isFalse);
    final newForeign = SignedChannel.create(remote, name: 'A new announcement');
    expect(await store.putChannel(newForeign.toJson()), isTrue);
    expect(store.channels.containsKey(own.id), isTrue);
    expect(store.channels.length, PilotStore.maxChannels);
    expect(store.evictions['channels'], 2);
    final reopened = PilotStore(scratch, localOwnerId: local.id);
    await reopened.load();
    expect(reopened.channels.keys, store.channels.keys);
    expect(reopened.channels.containsKey(own.id), isTrue);
    expect(await reopened.nextChannelSequence(own.id), 2);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'local publisher limit rejects without deleting any owned channel',
    () async {
      final store = PilotStore(scratch, localOwnerId: local.id);
      await store.load();
      for (var i = 0; i < PilotStore.maxChannelsPerPublisher; i++) {
        await store.putChannel(
          SignedChannel.create(local, name: 'Own $i').toJson(),
        );
      }
      final before = store.channels.keys.toList();
      await expectLater(
        store.putChannel(
          SignedChannel.create(local, name: 'Over local limit').toJson(),
        ),
        throwsA(
          isA<ChannelCapacityException>().having(
            (error) => error.reason,
            'reason',
            'channel_publisher_capacity',
          ),
        ),
      );
      expect(store.channels.keys, before);
      expect(store.evictions['channels'], 0);
    },
  );

  test('foreign global cache churn preserves the bounded local outbox', () async {
    final owners = [remote, for (var i = 0; i < 3; i++) Identity.generate()];
    final ownChannel = SignedChannel.create(local, name: 'Local outbox');
    final ownNews = SignedBulletin.create(
      local,
      runId: 'news',
      text: 'Keep the local author copy',
      sequence: 1,
      channelId: ownChannel.id,
    );
    final foreignChannels = [
      for (var i = 0; i < owners.length; i++)
        SignedChannel.create(owners[i], name: 'Foreign publisher $i'),
    ];
    final foreignNews = [
      for (var i = 0; i < PilotStore.maxBulletins; i++)
        SignedBulletin.create(
          owners[i ~/ PilotStore.maxBulletinsPerChannel],
          runId: 'news',
          text: 'Foreign cache $i',
          sequence: i % PilotStore.maxBulletinsPerChannel + 1,
          channelId: foreignChannels[i ~/ PilotStore.maxBulletinsPerChannel].id,
        ),
    ];
    await File('${scratch.path}/pilot.jsonl').writeAsString(
      '${jsonEncode({
        'kind': 'snapshot', 'peers': {},
        'channels': {ownChannel.id: ownChannel.toJson(), for (final channel in foreignChannels) channel.id: channel.toJson()},
        'channelSequences': {ownChannel.id: 1},
        // Local news is deliberately the oldest entry in the snapshot.
        'bulletins': {ownNews.id: ownNews.toJson(), for (final news in foreignNews) news.id: news.toJson()},
        'publications': {
          ownNews.id: {'id': ownNews.id, 'channelId': ownChannel.id},
        },
        'receipts': {}, 'events': [], 'sequence': 0,
      })}\n',
      flush: true,
    );
    final store = PilotStore(scratch, localOwnerId: local.id);
    await store.load();
    expect(store.bulletins.length, PilotStore.maxBulletins);
    expect(store.bulletins.containsKey(ownNews.id), isTrue);
    expect(store.bulletins.containsKey(foreignNews.first.id), isFalse);
    final newcomer = SignedChannel.create(remote, name: 'More foreign traffic');
    await store.putChannel(newcomer.toJson());
    final freshForeign = SignedBulletin.create(
      remote,
      runId: 'news',
      text: 'Another key-owned channel',
      sequence: 1,
      channelId: newcomer.id,
    );
    expect(await store.putBulletin(freshForeign.toJson()), isTrue);
    expect(store.bulletins.length, PilotStore.maxBulletins);
    expect(store.bulletins.containsKey(ownNews.id), isTrue);
    expect(store.bulletins.containsKey(foreignNews[1].id), isFalse);
    expect(store.publications.containsKey(ownNews.id), isTrue);
    expect(store.evictions['bulletins'], 2);
    final reopened = PilotStore(scratch, localOwnerId: local.id);
    await reopened.load();
    expect(reopened.bulletins.keys, store.bulletins.keys);
    expect(reopened.bulletins.containsKey(ownNews.id), isTrue);
    expect(reopened.publications.containsKey(ownNews.id), isTrue);
    expect(await reopened.nextChannelSequence(ownChannel.id), 2);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
