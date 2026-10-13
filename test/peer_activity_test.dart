import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_activity.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  final peerId = 'a' * 64;
  Map<String, dynamic> event(int index) => {
    'kind': 'connected',
    'peerId': peerId,
    'atWallMs': index + 1,
    'transport': 'overlay',
    'host': '203.0.113.22',
    'name': 'Private peer name',
    'channelId': 'b' * 64,
    'sourceId': 'c' * 64,
    'text': 'Private news text',
  };

  test(
    'activity allowlists local fields, bounds rows, and preserves commit order',
    () {
      final rows = temporaryPeerActivity([
        for (var i = 0; i < 240; i++) event(i),
        // A clock rollback must not reorder the last committed event.
        {
          ...event(0),
          'kind': 'bulletin_verified',
          'transport': null,
          'receivedVia': 'bluetooth',
        },
        {...event(4), 'peerId': 'not-a-fingerprint'},
        {...event(4), 'atWallMs': 'invalid'},
        {...event(4), 'atWallMs': 8640000000000001},
        {...event(4), 'kind': 'unverified_contact_discovered'},
      ]);
      expect(rows, hasLength(maxTemporaryPeerActivity));
      expect(rows.first['atWallMs'], 1);
      expect(rows.first['transport'], 'bluetooth');
      expect(rows.last['atWallMs'], 42);
      for (final row in rows) {
        expect(row.keys.toSet(), {'kind', 'peerId', 'atWallMs', 'transport'});
      }
      final encoded = jsonEncode(rows);
      expect(encoded, isNot(contains('203.0.113.22')));
      expect(encoded, isNot(contains('Private')));
      expect(encoded, isNot(contains('b' * 64)));
      expect(encoded, isNot(contains('c' * 64)));
    },
  );

  test('unknown legacy transport is safe to display', () {
    expect(
      temporaryPeerActivity([
        {...event(0), 'transport': '203.0.113.22'},
      ]).single['transport'],
      'unknown',
    );
  });

  test(
    'clear persists after reopening and preserves news, channels and peers',
    () async {
      final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
      await parent.create(recursive: true);
      final directory = await parent.createTemp('peer-activity-');
      addTearDown(() => directory.delete(recursive: true));
      final identity = Identity.generate();
      final store = PilotStore(directory);
      await store.load();
      final channel = SignedChannel.create(identity, name: 'Keep this channel');
      await store.putChannel(channel.toJson());
      final news = SignedBulletin.create(
        identity,
        runId: 'news',
        text: 'Keep this article',
        sequence: 1,
        channelId: channel.id,
      );
      await store.putBulletin(news.toJson());
      final peer = PeerCard(
        name: 'Keep this contact',
        host: '127.0.0.1',
        port: 45871,
        certificatePem: identity.certPem,
      );
      await store.setPeers([peer.toJson()]);
      for (var i = 0; i < 205; i++) {
        await store.event(event(i));
      }
      expect(
        temporaryPeerActivity(store.events),
        hasLength(maxTemporaryPeerActivity),
      );
      await store.event({'kind': 'engine_started', 'atWallMs': 1});
      await store.clearTemporaryPeerActivity();
      expect(temporaryPeerActivity(store.events), isEmpty);
      final reopened = PilotStore(directory);
      await reopened.load();
      expect(temporaryPeerActivity(reopened.events), isEmpty);
      expect(reopened.events.single['kind'], 'engine_started');
      expect(reopened.channels.keys, contains(channel.id));
      expect(reopened.bulletins.keys, contains(news.id));
      expect(reopened.peers.keys, contains(peer.id));
      final journal = await File('${directory.path}/pilot.jsonl')
          .readAsString();
      expect(journal, isNot(contains('Private peer name')));
      expect(await File('${directory.path}/pilot.jsonl.bak').exists(), isFalse);
      expect(
        await File('${directory.path}/pilot.jsonl.next').exists(),
        isFalse,
      );
    },
  );
}
