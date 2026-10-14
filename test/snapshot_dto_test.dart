import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/snapshot_dto.dart';

final _peerA = 'a' * 64, _peerB = 'b' * 64, _channel = 'c' * 64;

/// Shaped like `PeerEngine.snapshot()` plus the service's `overlay` key.
Map<String, dynamic> realisticSnapshot() => jsonDecode(
  jsonEncode({
    'channelKeyManagement': true,
    'running': true,
    'activeMode': false,
    'listenPort': 7331,
    'identityId': _peerB,
    'deliveryMode': 'allNetworks',
    'peerCount': 2,
    'connectedCount': 1,
    'helperContactCount': 3,
    'helperReconnectCount': 1,
    'advertisingHelper': false,
    'activeTransportCounts': {'overlay': 1, 'lan': 0, 'bluetooth': 0},
    'discoveryState': 'connected',
    'discoveryLastError': null,
    'bootstrapConfiguredCount': 4,
    'discoveredCount': 0,
    'overlay': {'state': 'connected', 'discoveryStage': 'discovering'},
    'peers': [
      {
        'version': 1,
        'id': _peerA,
        'name': 'Private peer name',
        'host': '203.0.113.22',
        'port': 7331,
        'certificatePem': '-----BEGIN CERTIFICATE-----',
        'connected': true,
        'transport': 'overlay',
        'routeId': 'route-1',
        'endpointCount': 2,
        'origin': 'manual',
        'trust': 'paired',
      },
      {
        'id': _peerB,
        'name': '',
        'host': '',
        'port': 0,
        'connected': false,
        'transport': null,
        'origin': 'lan',
        'trust': 'unverified',
      },
    ],
    'bulletinCount': 2,
    'receiptCount': 0,
    'rejectedCount': 1,
    'duplicateCount': 5,
    'trafficDeferred': {'egress': 2, 'requests': 0},
    'pendingBulletinCount': 0,
    'lastError': null,
    'bulletins': [
      {
        'id': 'n1',
        'sourceId': _peerA,
        'runId': 'run-1',
        'text': 'خبر',
        'byline': 'الیاس',
        'createdAtMs': 1770000000000,
        'sequence': 7,
        'channelId': _channel,
        'image': {
          'mime': 'image/jpeg',
          'hash': 'd' * 64,
          'bytes': 1200,
          'width': 640,
          'height': 480,
          'path': '/data/media/dd.jpg',
        },
        'localPublication': false,
        'receivedVia': 'overlay',
        'receivedAtWallMs': 1770000065000,
        'receivedNetwork': 'wifi',
      },
      {
        'id': 'n2',
        'sourceId': _peerB,
        'runId': 'run-2',
        'text': 'own post',
        'byline': '',
        'createdAtMs': 1770000100000,
        'sequence': 1,
        'channelId': _channel,
        'localPublication': true,
        'receivedVia': 'local',
        'receivedAtWallMs': null,
        'receivedNetwork': 'unknown',
      },
    ],
    'channels': [
      {
        'id': _channel,
        'name': 'پرشین ترند',
        'description': 'desc',
        'ownerId': _peerB,
        'createdAtMs': 1760000000000,
        'owned': true,
        'canPublish': true,
        'writerNickname': 'me',
        'role': 'owner',
        'editors': [
          {'id': _peerA, 'label': 'Elias'},
        ],
        'trust': 'self',
        'bulletinCount': 2,
        'lastSequence': 7,
      },
    ],
    'publications': [
      {'id': 'n2', 'receipts': []},
    ],
    'trials': [
      {
        'bulletinId': 'n2',
        'runId': 'run-2',
        'enrolled': 3,
        'confirmed': 1,
        'timelyUnlocked': 1,
        'unknown': 1,
        'createdAtMs': 1770000100000,
        'receipts': [
          {'receiverId': _peerA, 'withinFiveMinutes': true},
        ],
      },
    ],
    'events': [
      {'kind': 'connected', 'peerId': _peerA},
    ],
    'temporaryPeerActivity': [
      {
        'kind': 'bulletin_verified',
        'peerId': _peerA,
        'transport': 'overlay',
        'atWallMs': 1770000065000,
      },
    ],
    'evictions': {'bulletins': 1},
  }),
) as Map<String, dynamic>;

void main() {
  test('realistic snapshot exposes typed views and keeps raw access', () {
    final json = realisticSnapshot();
    final snapshot = Snapshot.fromJson(json);
    expect(identical(snapshot.raw, json), isTrue);
    expect(snapshot.channelKeyManagement, isTrue);
    expect(snapshot.running, isTrue);
    expect(snapshot.activeMode, isFalse);
    expect(snapshot.listenPort, 7331);
    expect(snapshot.identityId, _peerB);
    expect(snapshot.deliveryMode, 'allNetworks');
    expect(snapshot.peerCount, 2);
    expect(snapshot.connectedCount, 1);
    expect(snapshot.helperContactCount, 3);
    expect(snapshot.counter('duplicateCount'), 5);
    expect(snapshot.activeTransportCounts, {
      'overlay': 1,
      'lan': 0,
      'bluetooth': 0,
    });
    expect(snapshot.trafficDeferred['egress'], 2);
    expect(snapshot.evictions, {'bulletins': 1});
    expect(snapshot.discoveryState, 'connected');
    expect(snapshot.discoveryLastError, isNull);
    expect(snapshot.overlay.state, 'connected');
    expect(snapshot.overlay.discoveryStage, 'discovering');
    expect(snapshot.overlay.isAvailable, isTrue);

    expect(snapshot.peers, hasLength(2));
    final peer = snapshot.peers.first;
    expect(peer.id, _peerA);
    expect(peer.hasValidId, isTrue);
    expect(peer.connected, isTrue);
    expect(peer.transport, 'overlay');
    expect(peer.routeId, 'route-1');
    expect(peer.endpointCount, 2);
    expect(peer.origin, 'manual');
    expect(peer.trust, 'paired');
    expect(peer.host, '203.0.113.22');
    expect(peer.port, 7331);
    expect(peer.raw['certificatePem'], isNotNull);
    expect(snapshot.peers.last.transport, isNull);
    expect(snapshot.peers.last.connected, isFalse);
    expect(snapshot.connectedPeers.map((p) => p.id), [_peerA]);

    expect(snapshot.bulletins, hasLength(2));
    final news = snapshot.bulletins.first;
    expect(news.id, 'n1');
    expect(news.sourceId, _peerA);
    expect(news.channelId, _channel);
    expect(news.runId, 'run-1');
    expect(news.text, 'خبر');
    expect(news.byline, 'الیاس');
    expect(news.createdAtMs, 1770000000000);
    expect(news.receivedAtWallMs, 1770000065000);
    expect(news.sequence, 7);
    expect(news.localPublication, isFalse);
    expect(news.receivedVia, 'overlay');
    expect(news.receivedNetwork, 'wifi');
    expect(news.isLocal, isFalse);
    expect(news.image, isNotNull);
    expect(news.image!.hash, 'd' * 64);
    expect(news.image!.path, '/data/media/dd.jpg');
    expect(news.image!.mime, 'image/jpeg');
    expect(news.image!.bytes, 1200);
    expect(news.image!.width, 640);
    expect(news.image!.height, 480);
    final own = snapshot.bulletins.last;
    expect(own.byline, isNull);
    expect(own.receivedAtWallMs, isNull);
    expect(own.isLocal, isTrue);
    expect(own.image, isNull);

    final channel = snapshot.channels.single;
    expect(channel.id, _channel);
    expect(channel.hasValidId, isTrue);
    expect(channel.name, 'پرشین ترند');
    expect(channel.description, 'desc');
    expect(channel.ownerId, _peerB);
    expect(channel.createdAtMs, 1760000000000);
    expect(channel.owned, isTrue);
    expect(channel.canPublish, isTrue);
    expect(channel.writerNickname, 'me');
    expect(channel.role, 'owner');
    expect(channel.trust, 'self');
    expect(channel.bulletinCount, 2);
    expect(channel.lastSequence, 7);
    expect(channel.editors.single['label'], 'Elias');
    expect(snapshot.channelById(_channel)?.name, channel.name);
    expect(snapshot.channelById('missing'), isNull);
    expect(snapshot.bulletinsFor(_channel).map((n) => n.id), ['n1', 'n2']);

    final trial = snapshot.trials.single;
    expect(trial.bulletinId, 'n2');
    expect(trial.runId, 'run-2');
    expect(trial.enrolled, 3);
    expect(trial.confirmed, 1);
    expect(trial.timelyUnlocked, 1);
    expect(trial.unknown, 1);
    expect(trial.createdAtMs, 1770000100000);
    expect(trial.receipts.single['receiverId'], _peerA);

    final activity = snapshot.temporaryPeerActivity.single;
    expect(activity.kind, 'bulletin_verified');
    expect(activity.peerId, _peerA);
    expect(activity.hasValidPeerId, isTrue);
    expect(activity.transport, 'overlay');
    expect(activity.atWallMs, 1770000065000);
    expect(snapshot.publications.single['id'], 'n2');
    expect(snapshot.events.single['kind'], 'connected');
  });

  test('empty and legacy snapshots never throw', () {
    for (final json in <Map<String, dynamic>?>[
      null,
      {},
      {
        'bulletins': null,
        'channels': 'oops',
        'peers': [
          1,
          'x',
          null,
          {'id': 5, 'connected': 'yes', 'port': 'p'},
        ],
        'trials': {'not': 'a list'},
        'overlay': 'starting',
        'activeTransportCounts': ['overlay'],
        'connectedCount': -4,
        'peerCount': double.nan,
        'discoveryState': 7,
        'temporaryPeerActivity': [{}],
        'evictions': {'bulletins': 'many', 3: 1},
      },
    ]) {
      final snapshot = Snapshot.fromJson(json);
      expect(snapshot.channelKeyManagement, isFalse);
      expect(snapshot.running, isFalse);
      expect(snapshot.listenPort, isNull);
      expect(snapshot.identityId, isNull);
      expect(snapshot.deliveryMode, isNull);
      expect(snapshot.connectedCount, 0);
      expect(snapshot.peerCount, 0);
      expect(snapshot.counter('nothing'), 0);
      expect(snapshot.activeTransportCounts, isEmpty);
      expect(snapshot.discoveryState, 'waitingForBootstrap');
      expect(snapshot.discoveryLastError, isNull);
      expect(snapshot.overlay.state, isNull);
      expect(snapshot.overlay.isAvailable, isFalse);
      expect(snapshot.bulletins, isEmpty);
      expect(snapshot.channels, isEmpty);
      expect(snapshot.trials, isEmpty);
      expect(snapshot.publications, isEmpty);
      expect(snapshot.events, isEmpty);
      expect(snapshot.connectedPeers, isEmpty);
      expect(snapshot.channelById('x'), isNull);
      expect(snapshot.bulletinsFor('x'), isEmpty);
      for (final peer in snapshot.peers) {
        expect(peer.id, '');
        expect(peer.hasValidId, isFalse);
        expect(peer.connected, isFalse);
        expect(peer.port, isNull);
        expect(peer.origin, 'manual');
      }
      for (final row in snapshot.temporaryPeerActivity) {
        expect(row.kind, '');
        expect(row.hasValidPeerId, isFalse);
        expect(row.atWallMs, isNull);
      }
      expect(snapshot.evictions['bulletins'] ?? 0, 0);
    }
    expect(Snapshot.empty.raw, isEmpty);
  });

  test('legacy items tolerate missing and out-of-range fields', () {
    final news = NewsItem.fromJson({
      'id': 'legacy',
      'createdAtMs': -5,
      'receivedAtWallMs': 253402300800000,
      'sequence': '3',
      'image': 'not a map',
    });
    expect(news.createdAtMs, isNull);
    expect(news.receivedAtWallMs, isNull);
    expect(news.sequence, 0);
    expect(news.image, isNull);
    expect(news.receivedVia, 'unknown');
    expect(news.receivedNetwork, 'unknown');
    expect(news.byline, isNull);
    expect(news.text, '');
    expect(news.runId, isNull);

    final reader = ChannelItem.fromJson({'id': _channel, 'canPublish': true});
    expect(reader.role, 'editor');
    expect(ChannelItem.fromJson({'owned': true}).role, 'owner');
    expect(ChannelItem.fromJson(null).role, 'reader');
    expect(ChannelItem.fromJson(null).hasValidId, isFalse);
    expect(ChannelItem.fromJson(null).editors, isEmpty);
    expect(TrialItem.fromJson(null).receipts, isEmpty);
    expect(PeerItem.fromJson({'id': _peerA, 'port': 7331.0}).port, 7331);
    expect(NewsImageRef.fromJson(null).path, isNull);
    expect(
      OverlaySnapshot.fromJson({'state': 'unavailable'}).isAvailable,
      isFalse,
    );
  });
}
