import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'channels.dart';
import 'channel_control.dart';
import 'models.dart';
import 'peer_activity.dart';

class ChannelCapacityException extends StateError {
  ChannelCapacityException(this.reason) : super(reason);
  final String reason;
}

/// App-private bounded journal. A successful write is flushed before callers ACK.
class PilotStore {
  PilotStore(this.directory, {this.localOwnerId}) {
    if (localOwnerId != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(localOwnerId!)) {
      throw ArgumentError('Expected a local owner fingerprint.');
    }
  }
  final Directory directory;

  /// The local signing key, never private follow/trust preferences. Unknown
  /// ownership retains the conservative legacy policy of rejecting at capacity.
  final String? localOwnerId;
  final Set<String> managedChannelIds = {};
  static const maxBulletins = 256;
  static const maxReceipts = 2048;
  static const maxEvents = 800;
  static const maxPublications = 256;
  static const maxChannels = 128;
  static const maxChannelsPerPublisher = 16;
  static const maxBulletinsPerChannel = 64;
  static const maxBulletinsPerPublisher = 96;
  static const maxJournalRecordBytes = 16 * 1024 * 1024;
  final Map<String, Map<String, dynamic>> peers = {};
  final Map<String, Map<String, dynamic>> bulletins = {};
  final Map<String, Map<String, dynamic>> bulletinObservations = {};
  final Map<String, Map<String, dynamic>> receipts = {};
  final Map<String, Map<String, dynamic>> publications = {};
  final Map<String, Map<String, dynamic>> channels = {};
  final Map<String, Map<String, dynamic>> channelPolicies = {};
  final Map<String, String> _channelPublishers = {};
  final Map<String, int> channelSequences = {};
  final Map<String, String> _bulletinPublishers = {};
  final Map<String, String> _bulletinChannels = {};
  final Map<String, int> _bulletinSequences = {};
  final List<Map<String, dynamic>> events = [];
  final Map<String, int> evictions = {
    'channels': 0,
    'bulletins': 0,
    'receipts': 0,
    'publications': 0,
    'events': 0,
  };
  int sequence = 0;
  int _records = 0;
  int _compactedBytes = 0;
  bool _loaded = false;
  bool _writeFailed = false;
  bool _recovering = false;
  Future<void> _tail = Future<void>.value();
  File get _journal =>
      File('${directory.path}${Platform.pathSeparator}pilot.jsonl');

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load() => _serial(() async {
    if (_loaded) return;
    await directory.create(recursive: true);
    final backup = File('${_journal.path}.bak');
    if (!await _journal.exists() && await backup.exists()) {
      await backup.rename(_journal.path);
    }
    if (await _journal.exists()) {
      // Ignore incomplete records after a crash, then compact before appending.
      _recovering = true;
      try {
        await _recoverJournal();
      } finally {
        _recovering = false;
      }
    }
    _loaded = true;
    await _compact();
  });

  Future<int> nextSequence() => _serial(() async {
    _requireLoaded();
    final next = sequence + 1;
    if (next > 9007199254740991) {
      throw StateError('The diagnostic sequence is exhausted.');
    }
    await _append({'kind': 'sequence', 'value': next});
    return next;
  });

  /// Persist before publishing; a crash may leave a gap, never a reused number.
  Future<int> nextChannelSequence(String channelId) => _serial(() async {
    _requireLoaded();
    if (!channels.containsKey(channelId)) {
      throw StateError('Channel metadata must be stored before publishing.');
    }
    final next = (channelSequences[channelId] ?? 0) + 1;
    if (next > 9007199254740991) {
      throw StateError('The channel sequence is exhausted.');
    }
    await _append({
      'kind': 'channelSequence',
      'channelId': channelId,
      'value': next,
    });
    return next;
  });

  Future<void> setPeers(List<Map<String, dynamic>> values) => _serial(() async {
    _requireLoaded();
    await _append({'kind': 'peers', 'values': values});
  });

  /// Retains immutable ownership metadata in a bounded public relay cache.
  /// Local channels are protected; foreign metadata rotates independently of
  /// private channel choices. Rotation never transfers ownership of an ID.
  Future<bool> putChannel(Map<String, dynamic> value) => _serial(() async {
    _requireLoaded();
    final channel = SignedChannel.fromJson(value);
    if (channels.containsKey(channel.id)) return false;
    final publisherCount = _channelPublishers.values
        .where((ownerId) => ownerId == channel.ownerId)
        .length;
    if (publisherCount >= maxChannelsPerPublisher &&
        (localOwnerId == null || channel.ownerId == localOwnerId)) {
      throw ChannelCapacityException('channel_publisher_capacity');
    }
    if (_channelEvictions(channel) == null) {
      throw ChannelCapacityException('channel_capacity');
    }
    await _append({'kind': 'channel', 'value': channel.toJson()});
    return true;
  });

  Future<bool> putBulletin(
    Map<String, dynamic> value, {
    Map<String, dynamic> observation = const {},
  }) => _serial(() async {
    _requireLoaded();
    _validateStoredBulletin(value);
    final id = value['id'] as String;
    if (bulletins.containsKey(id)) return false;
    if (!_fitsChannelSequenceWindow(value)) return false;
    await _append({
      'kind': 'bulletin',
      'value': value,
      'observation': observation,
    });
    return bulletins.containsKey(id);
  });

  ChannelControl? policyFor(String channelId) {
    final raw = channelPolicies[channelId], channel = channels[channelId];
    return raw == null || channel == null
        ? null
        : ChannelControl.parse(raw, SignedChannel.fromJson(channel));
  }

  Future<bool> putChannelPolicy(ChannelControl policy) => _serial(() async {
    _requireLoaded();
    final channel = channels[policy.channelId];
    if (channel == null || policy.kind != 'policy') {
      throw const FormatException('Channel policy has no channel.');
    }
    final verified = ChannelControl.parse(
      policy.toJson(),
      SignedChannel.fromJson(channel),
    );
    final previous = policyFor(policy.channelId);
    if (previous?.deleted == true && !verified.deleted) return false;
    if (previous != null &&
        (previous.revision > verified.revision ||
            (previous.revision == verified.revision &&
                previous.id.compareTo(verified.id) <= 0))) {
      return false;
    }
    await _append({'kind': 'channelPolicy', 'value': verified.toJson()});
    return true;
  });

  Future<void> advanceChannelSequence(String id, int sequence) =>
      _serial(() async {
        if (sequence < 0 ||
            sequence > 9007199254740991 ||
            !channels.containsKey(id)) {
          throw const FormatException('Invalid channel sequence.');
        }
        if (sequence > (channelSequences[id] ?? 0)) {
          await _append({
            'kind': 'channelSequence',
            'channelId': id,
            'value': sequence,
          });
        }
      });

  Future<void> putPublication(
    Map<String, dynamic> bulletin,
    Map<String, dynamic> metadata,
  ) => _serial(() async {
    _requireLoaded();
    _validateStoredBulletin(bulletin);
    await _append({
      'kind': 'publication',
      'bulletin': bulletin,
      'metadata': metadata,
    });
  });

  Future<bool> putReceipt(
    Map<String, dynamic> value,
    Map<String, dynamic> observation,
  ) => _serial(() async {
    _requireLoaded();
    final id = value['id'] as String;
    if (receipts.containsKey(id)) return false;
    await _append({
      'kind': 'receipt',
      'value': value,
      'observation': observation,
    });
    return true;
  });

  Future<void> event(Map<String, dynamic> value) => _serial(() async {
    _requireLoaded();
    await _append({'kind': 'event', 'value': _flatObject(value)});
  });

  /// Clear just this view's history. Peer contacts and news remain intact.
  Future<void> clearTemporaryPeerActivity() => _serial(() async {
    _requireLoaded();
    await _append({'kind': 'clearPeerActivity'});
    // Do not leave cleared activity in an old journal or its app backup.
    await _compact();
  });

  Future<void> flush() => _serial(() async {});

  void _requireLoaded() {
    if (!_loaded) throw StateError('PilotStore.load must complete first.');
  }

  Future<void> _append(Map<String, dynamic> record) async {
    if (_writeFailed) {
      throw StateError(
        'Journal write failed; reopen the store before retrying.',
      );
    }
    try {
      await _journal.writeAsString(
        '${jsonEncode(record)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Never acknowledge a subsequent write concatenated to a failed tail.
      _writeFailed = true;
      rethrow;
    }
    _apply(record);
    _records++;
    if (_records >= 2048 ||
        await _journal.length() > _compactedBytes + 4 * 1024 * 1024) {
      await _compact();
    }
  }

  Future<void> _recoverJournal() async {
    final line = BytesBuilder(copy: false);
    var discarding = false;
    void append(List<int> bytes) {
      if (discarding) return;
      if (line.length + bytes.length > maxJournalRecordBytes) {
        line.clear();
        discarding = true;
      } else {
        line.add(bytes);
      }
    }

    void recover() {
      if (!discarding && line.isNotEmpty) {
        try {
          // Decode each byte-framed record separately: a torn multibyte UTF-8
          // tail must not prevent recovery of all preceding committed records.
          final value = jsonDecode(utf8.decode(line.takeBytes()));
          if (value is Map<String, dynamic>) {
            _apply(value);
            _records++;
          }
        } on FormatException {
          // A corrupt/incomplete record never becomes an acknowledged object.
        }
      }
      line.clear();
      discarding = false;
    }

    await for (final chunk in _journal.openRead()) {
      var start = 0;
      for (var index = 0; index < chunk.length; index++) {
        if (chunk[index] != 10) continue;
        append(chunk.sublist(start, index));
        recover();
        start = index + 1;
      }
      append(chunk.sublist(start));
    }
    recover();
  }

  Map<String, dynamic> _map(dynamic value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Expected a journal object.');
    }
    return Map<String, dynamic>.from(value);
  }

  void _apply(Map<String, dynamic> record) {
    switch (record['kind']) {
      case 'snapshot':
        _restoreSnapshot(record);
      case 'sequence':
        final value = record['value'];
        if (!_counter(value)) {
          throw const FormatException('Invalid sequence record.');
        }
        if (value > sequence) sequence = value as int;
      case 'channelSequence':
        final id = record['channelId'];
        final value = record['value'];
        if (id is! String ||
            value is! int ||
            value < 0 ||
            value > 9007199254740991) {
          throw const FormatException('Invalid channel sequence record.');
        }
        if (channels.containsKey(id) && value >= (channelSequences[id] ?? 0)) {
          channelSequences[id] = value;
        }
      case 'peers':
        final raw = record['values'];
        if (raw is! List) {
          throw const FormatException('Invalid peer list record.');
        }
        final valid = _validatedPeers(raw);
        peers
          ..clear()
          ..addAll(valid);
      case 'channel':
        final channel = SignedChannel.fromJson(_map(record['value']));
        _admitChannel(channel);
      case 'channelPolicy':
        final raw = _map(record['value']);
        final encoded = utf8.decode(
          base64Decode(raw['payloadBase64'] as String),
        );
        final channelId = (jsonDecode(encoded) as Map)['channelId'] as String;
        final metadata = channels[channelId];
        if (metadata == null) break;
        final policy = ChannelControl.parse(
          raw,
          SignedChannel.fromJson(metadata),
        );
        if (policy.kind != 'policy') {
          throw const FormatException('Expected channel policy.');
        }
        final previous = policyFor(channelId);
        if (previous?.deleted == true && !policy.deleted) break;
        if (previous == null ||
            policy.revision > previous.revision ||
            (policy.revision == previous.revision &&
                policy.id.compareTo(previous.id) < 0)) {
          channelPolicies[channelId] = policy.toJson();
          for (final id in bulletins.keys.toList()) {
            if (!bulletins[id]!.containsKey('payloadBase64')) continue;
            final news = SignedBulletin.fromJson(bulletins[id]!);
            if (news.channelId == channelId &&
                !news.verifyForChannel(
                  SignedChannel.fromJson(metadata),
                  policy: policy,
                )) {
              bulletins.remove(id);
              publications.remove(id);
              bulletinObservations.remove(id);
            }
          }
        }
      case 'bulletin':
        final value = _map(record['value']);
        _validateStoredBulletin(value);
        bulletins[value['id'] as String] = value;
        _indexBulletin(value);
        if (record['observation'] is Map) {
          bulletinObservations.putIfAbsent(
            value['id'] as String,
            () => _bulletinObservation(record['observation']),
          );
        }
      case 'publication':
        final value = _map(record['bulletin']);
        _validateStoredBulletin(value);
        final metadata = _publicationMetadata(
          value['id'] as String,
          record['metadata'],
          bulletin: value,
        );
        bulletins[value['id'] as String] = value;
        _indexBulletin(value);
        publications[value['id'] as String] = metadata;
      case 'receipt':
        final value = _map(record['value']);
        final receipt = SignedReceipt.fromJson(value);
        receipts[receipt.id] = {
          'envelope': receipt.toJson(),
          'observation': _receiptObservation(record['observation'], receipt),
        };
      case 'event':
        events.add(_flatObject(_map(record['value'])));
      case 'clearPeerActivity':
        events.removeWhere(
          (event) => peerActivityKinds.contains(event['kind']),
        );
    }
    if (record['kind'] == 'bulletin' ||
        record['kind'] == 'publication' ||
        record['kind'] == 'snapshot') {
      _retainFairBulletins();
    }
    _trimMap(bulletins, maxBulletins, 'bulletins');
    bulletinObservations.removeWhere((id, _) => !bulletins.containsKey(id));
    _bulletinPublishers.removeWhere((id, _) => !bulletins.containsKey(id));
    _bulletinChannels.removeWhere((id, _) => !bulletins.containsKey(id));
    _bulletinSequences.removeWhere((id, _) => !bulletins.containsKey(id));
    _trimMap(receipts, maxReceipts, 'receipts');
    _trimMap(publications, maxPublications, 'publications');
    while (events.length > maxEvents) {
      events.removeAt(0);
      evictions['events'] = evictions['events']! + 1;
    }
    var activityCount = 0;
    for (var index = events.length - 1; index >= 0; index--) {
      if (peerActivityKinds.contains(events[index]['kind']) &&
          ++activityCount > maxTemporaryPeerActivity) {
        events.removeAt(index);
        evictions['events'] = evictions['events']! + 1;
      }
    }
  }

  bool _counter(dynamic value) =>
      value is int && value >= 0 && value <= 9007199254740991;

  bool _fingerprint(dynamic value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  /// Restore into an isolated staging store. A malformed optional field or row
  /// can never leave half of a snapshot installed in the running store.
  void _restoreSnapshot(Map<String, dynamic> record) {
    for (final field in [
      'peers',
      'channels',
      'channelPolicies',
      'channelSequences',
      'bulletins',
      'bulletinObservations',
      'receipts',
      'publications',
      'evictions',
    ]) {
      if (record.containsKey(field) && record[field] is! Map) {
        throw const FormatException('Invalid snapshot collection.');
      }
    }
    if (record['events'] is! List || !_counter(record['sequence'])) {
      throw const FormatException('Invalid snapshot fields.');
    }
    final staged = PilotStore(directory, localOwnerId: localOwnerId)
      .._recovering = _recovering
      ..managedChannelIds.addAll(managedChannelIds);
    staged.sequence = record['sequence'] as int;
    final savedEvictions = record['evictions'];
    if (savedEvictions is Map) {
      for (final key in staged.evictions.keys) {
        final value = savedEvictions[key];
        if (_counter(value)) staged.evictions[key] = value as int;
      }
    }
    final savedPeers = record['peers'];
    if (savedPeers is Map) {
      staged.peers.addAll(staged._validatedPeers(savedPeers.values));
    }
    staged._restoreChannels(record['channels']);
    final savedPolicies = record['channelPolicies'];
    if (savedPolicies is Map) {
      for (final row in savedPolicies.entries) {
        try {
          final metadata = staged.channels[row.key];
          if (metadata == null || row.value is! Map) continue;
          final policy = ChannelControl.parse(
            Map<String, dynamic>.from(row.value as Map),
            SignedChannel.fromJson(metadata),
          );
          if (policy.kind == 'policy' && policy.channelId == row.key) {
            staged.channelPolicies[row.key as String] = policy.toJson();
          }
        } on FormatException {
          /* Invalid public policy never grants a role. */
        }
      }
    }
    final savedSequences = record['channelSequences'];
    if (savedSequences is Map) {
      for (final entry in savedSequences.entries) {
        if (staged.channels.containsKey(entry.key) && _counter(entry.value)) {
          staged.channelSequences[entry.key as String] = entry.value as int;
        }
      }
    }
    staged.bulletins.addAll(staged._validatedBulletins(record['bulletins']));
    for (final value in staged.bulletins.values) {
      staged._indexBulletin(value);
    }
    final savedObservations = record['bulletinObservations'];
    if (savedObservations is Map) {
      for (final entry in savedObservations.entries) {
        if (staged.bulletins.containsKey(entry.key) && entry.value is Map) {
          staged.bulletinObservations[entry.key as String] = staged
              ._bulletinObservation(entry.value);
        }
      }
    }
    final savedReceipts = record['receipts'];
    if (savedReceipts is Map) {
      for (final entry in savedReceipts.entries) {
        try {
          final raw = staged._map(entry.value);
          final receipt = SignedReceipt.fromJson(staged._map(raw['envelope']));
          if (entry.key != receipt.id) continue;
          staged.receipts[receipt.id] = {
            'envelope': receipt.toJson(),
            'observation': staged._receiptObservation(
              raw['observation'],
              receipt,
            ),
          };
        } on FormatException {
          // One corrupt receipt never prevents opening valid cached news.
        }
      }
    }
    final savedPublications = record['publications'];
    if (savedPublications is Map) {
      for (final entry in savedPublications.entries) {
        if (entry.key is! String) continue;
        try {
          staged.publications[entry.key as String] = staged
              ._publicationMetadata(
                entry.key as String,
                entry.value,
                bulletin: staged.bulletins[entry.key],
              );
        } on FormatException {
          // Discard invalid bookkeeping without inventing test evidence.
        }
      }
    }
    for (final event in record['events'] as List) {
      if (event is Map) staged.events.add(staged._flatObject(event));
    }
    staged._retainFairBulletins();
    // The normal post-apply bounds run after this atomic state replacement.
    for (final pair in [
      (peers, staged.peers),
      (channels, staged.channels),
      (channelPolicies, staged.channelPolicies),
      (bulletins, staged.bulletins),
      (bulletinObservations, staged.bulletinObservations),
      (receipts, staged.receipts),
      (publications, staged.publications),
    ]) {
      pair.$1
        ..clear()
        ..addAll(pair.$2);
    }
    _channelPublishers
      ..clear()
      ..addAll(staged._channelPublishers);
    channelSequences
      ..clear()
      ..addAll(staged.channelSequences);
    _bulletinPublishers
      ..clear()
      ..addAll(staged._bulletinPublishers);
    _bulletinChannels
      ..clear()
      ..addAll(staged._bulletinChannels);
    _bulletinSequences
      ..clear()
      ..addAll(staged._bulletinSequences);
    events
      ..clear()
      ..addAll(staged.events);
    evictions
      ..clear()
      ..addAll(staged.evictions);
    sequence = staged.sequence;
  }

  Map<String, Map<String, dynamic>> _validatedPeers(Iterable<dynamic> raw) {
    final result = <String, Map<String, dynamic>>{};
    for (final entry in raw) {
      if (result.length >= maxTrustedPeers) break;
      try {
        final value = _map(entry);
        final peer = PeerCard.fromJson(value);
        final origin = value['origin'];
        result[peer.id] = {
          ...peer.toJson(),
          // Missing provenance belongs only to pre-discovery legacy journals.
          // An unrecognized explicit provenance can never become manual trust.
          'origin': origin == null
              ? 'manual'
              : {'manual', 'bootstrap', 'lan'}.contains(origin)
              ? origin
              : 'lan',
        };
      } on FormatException {
        // Invalid certificates/addresses are not restored as trusted peers.
      }
    }
    return result;
  }

  Map<String, dynamic> _flatObject(Map raw) {
    final result = <String, dynamic>{};
    var bytes = 2;
    for (final entry in raw.entries.take(64)) {
      if (entry.key is String &&
          (entry.key as String).length <= 80 &&
          (entry.value is bool ||
              (entry.value is String &&
                  (entry.value as String).length <= 1024) ||
              (entry.value is num &&
                  (entry.value as num).isFinite &&
                  (entry.value as num).abs() <= 9007199254740991))) {
        final size = utf8.encode(jsonEncode({entry.key: entry.value})).length;
        if (bytes + size > 8 * 1024) continue;
        result[entry.key as String] = entry.value;
        bytes += size;
      }
    }
    return result;
  }

  Map<String, dynamic> _bulletinObservation(dynamic raw) {
    if (raw is! Map) return {};
    return {
      if ({
        'ip',
        'overlay',
        'lan',
        'wifiDirect',
        'bluetooth',
        'unknown',
      }.contains(raw['receivedVia']))
        'receivedVia': raw['receivedVia'],
      if (raw['receivedNetwork'] is String &&
          (raw['receivedNetwork'] as String).length <= 64)
        'receivedNetwork': raw['receivedNetwork'],
      if (_counter(raw['receivedAtWallMs']) &&
          raw['receivedAtWallMs'] <= maxSignedWallTimeMs)
        'receivedAtWallMs': raw['receivedAtWallMs'],
    };
  }

  Map<String, dynamic> _receiptObservation(dynamic raw, SignedReceipt receipt) {
    if (raw is! Map) return {};
    final timely =
        _counter(raw['sourceUpperBoundMs']) &&
        raw['sourceUpperBoundMs'] <= 300000 &&
        raw['withinFiveMinutes'] == true;
    return {
      if (_counter(raw['observedAtWallMs']) &&
          raw['observedAtWallMs'] <= maxSignedWallTimeMs)
        'observedAtWallMs': raw['observedAtWallMs'],
      if (_counter(raw['sourceUpperBoundMs']))
        'sourceUpperBoundMs': raw['sourceUpperBoundMs'],
      if (raw['withinFiveMinutes'] is bool) 'withinFiveMinutes': timely,
      if (raw['lockedWithinFiveMinutes'] is bool)
        'lockedWithinFiveMinutes':
            timely &&
            receipt.locked &&
            receipt.lockStateKnown &&
            raw['lockedWithinFiveMinutes'] == true,
      if (raw['localDeviceState'] is Map)
        'localDeviceState': _flatObject({
          for (final key in [
            'elapsedRealtimeMs',
            'bootId',
            'wallTimeMs',
            'isLocked',
            'locked',
            'lockStateKnown',
            'screenOn',
            'powerSave',
            'deviceIdle',
            'platform',
            'batteryExempt',
            'lowPowerStandby',
            'batteryPercent',
            'charging',
            'network',
            'internetValidated',
            'manufacturer',
            'model',
            'osVersion',
            'sdk',
            'targetSdk',
            'appVersion',
            'stateUnavailable',
          ])
            key: raw['localDeviceState'][key],
        }),
      if (raw['receivedVia'] is String &&
          (raw['receivedVia'] as String).length <= 32)
        'receivedVia': raw['receivedVia'],
    };
  }

  Map<String, dynamic> _publicationMetadata(
    String id,
    dynamic raw, {
    Map<String, dynamic>? bulletin,
  }) {
    final value = _map(raw);
    if (!_fingerprint(id) || (value.containsKey('id') && value['id'] != id)) {
      throw const FormatException('Invalid publication identity.');
    }
    SignedBulletin? signed;
    if (bulletin != null && bulletin.containsKey('payloadBase64')) {
      signed = SignedBulletin.fromJson(bulletin);
    }
    final channel = signed?.channelId ?? value['channelId'];
    if (channel != null && !_fingerprint(channel)) {
      throw const FormatException('Invalid publication channel.');
    }
    return {
      'id': id,
      'runId':
          signed?.runId ??
          (value['runId'] is String &&
                  (value['runId'] as String).length <= maxRunIdLength
              ? value['runId']
              : 'unknown'),
      'createdAtMs':
          signed?.createdAtMs ??
          (_counter(value['createdAtMs']) &&
                  value['createdAtMs'] <= maxSignedWallTimeMs
              ? value['createdAtMs']
              : 0),
      'recipients': channel != null
          ? <String>[]
          : (value['recipients'] is List
                ? (value['recipients'] as List)
                      .where(_fingerprint)
                      .take(maxTrustedPeers)
                      .toSet()
                      .toList()
                : <String>[]),
      'channelId': ?channel,
      if (channel == null && _counter(value['publishedElapsedRealtimeMs']))
        'publishedElapsedRealtimeMs': value['publishedElapsedRealtimeMs'],
      if (channel == null &&
          value['clockToken'] is String &&
          (value['clockToken'] as String).length <= 256)
        'clockToken': value['clockToken'],
      if (channel == null && value['activeMode'] is bool)
        'activeMode': value['activeMode'],
    };
  }

  void _indexBulletin(Map<String, dynamic> value) {
    try {
      final bulletin = SignedBulletin.fromJson(value);
      _bulletinPublishers[bulletin.id] = bulletin.sourceId;
      _bulletinChannels[bulletin.id] =
          bulletin.channelId ?? 'legacy:${bulletin.sourceId}';
      _bulletinSequences[bulletin.id] = bulletin.sequence;
    } on FormatException {
      // Historical store-only records without a signed envelope still obey the
      // global bound; the engine never accepts them as news from a peer.
    }
  }

  void _validateStoredBulletin(Map<String, dynamic> value) {
    // Historical store-only fixtures lack an envelope. Any object claiming to
    // be a signed bulletin must pass the same bounded hash/schema checks after
    // restart, including newly tightened display timestamp validation.
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        (value['id'] as String).length > 128) {
      throw const FormatException('Invalid cached bulletin identity.');
    }
    if (value.containsKey('payloadBase64') || value.containsKey('signature')) {
      final bulletin = SignedBulletin.fromJson(value);
      if (_recovering && bulletin.channelId != null) {
        final metadata = channels[bulletin.channelId];
        if (metadata == null ||
            !bulletin.verifyForChannel(
              SignedChannel.fromJson(metadata),
              policy: policyFor(bulletin.channelId!),
            )) {
          throw const FormatException('Invalid cached channel news signature.');
        }
      }
    } else if (localOwnerId != null) {
      // Production engines always provide their owner ID. Unsigned store-only
      // utility records must never enter the application feed after recovery.
      throw const FormatException('Missing signed bulletin envelope.');
    }
  }

  Map<String, Map<String, dynamic>> _validatedBulletins(dynamic raw) {
    final result = <String, Map<String, dynamic>>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      try {
        final value = _map(entry.value);
        _validateStoredBulletin(value);
        if (value['id'] == entry.key) result[entry.key as String] = value;
      } on FormatException {
        // Corrupt cached envelopes cannot poison every future feed rendering.
      }
    }
    return result;
  }

  void _retainFairBulletins() {
    final byChannel = <String, List<String>>{};
    for (final id in bulletins.keys) {
      final channel = _bulletinChannels[id];
      if (channel != null) (byChannel[channel] ??= []).add(id);
    }
    for (final ids in byChannel.values) {
      final authors = <String, List<String>>{};
      for (final id in ids) {
        (authors[_bulletinPublishers[id]!] ??= []).add(id);
      }
      for (final group in authors.values) {
        group.sort((a, b) {
          final order = _bulletinSequences[b]!.compareTo(
            _bulletinSequences[a]!,
          );
          return order != 0 ? order : a.compareTo(b);
        });
      }
      final orderedAuthors = authors.keys.toList()..sort();
      final keep = <String>{};
      for (var i = 0; keep.length < maxBulletinsPerChannel; i++) {
        var added = false;
        for (final author in orderedAuthors) {
          if (i < authors[author]!.length &&
              keep.length < maxBulletinsPerChannel) {
            keep.add(authors[author]![i]);
            added = true;
          }
        }
        if (!added) break;
      }
      for (final id in ids.where((id) => !keep.contains(id))) {
        bulletins.remove(id);
        evictions['bulletins'] = evictions['bulletins']! + 1;
      }
    }
    final publisherCounts = <String, int>{};
    for (final id in bulletins.keys.toList().reversed) {
      final publisher = _bulletinPublishers[id];
      if (publisher == null) continue;
      if ((publisherCounts[publisher] ?? 0) >= maxBulletinsPerPublisher) {
        bulletins.remove(id);
        evictions['bulletins'] = evictions['bulletins']! + 1;
      } else {
        publisherCounts[publisher] = (publisherCounts[publisher] ?? 0) + 1;
      }
    }
  }

  bool _fitsChannelSequenceWindow(Map<String, dynamic> value) {
    final SignedBulletin incoming;
    try {
      incoming = SignedBulletin.fromJson(value);
    } on FormatException {
      return true; // Historical store-only records keep the existing bound.
    }
    // Metadata can rotate while another link awaits a local observation. Do
    // not let an in-flight foreign object recreate an orphaned relay entry.
    if (incoming.channelId != null &&
        !channels.containsKey(incoming.channelId)) {
      return false;
    }
    if (incoming.channelId != null &&
        !incoming.verifyForChannel(
          SignedChannel.fromJson(channels[incoming.channelId]!),
          policy: policyFor(incoming.channelId!),
        )) {
      return false;
    }
    final channel = incoming.channelId ?? 'legacy:${incoming.sourceId}';
    final ids = bulletins.keys
        .where(
          (id) =>
              _bulletinChannels[id] == channel &&
              _bulletinPublishers[id] == incoming.sourceId,
        )
        .toList();
    if (ids.length < maxBulletinsPerChannel) return true;
    ids.sort((a, b) {
      final sequence = _bulletinSequences[b]!.compareTo(_bulletinSequences[a]!);
      return sequence != 0 ? sequence : a.compareTo(b);
    });
    final cutoff = ids[maxBulletinsPerChannel - 1];
    return incoming.sequence > _bulletinSequences[cutoff]! ||
        (incoming.sequence == _bulletinSequences[cutoff] &&
            incoming.id.compareTo(cutoff) < 0);
  }

  void _restoreChannels(dynamic raw) {
    _channelPublishers.clear();
    if (raw is! Map) return; // Older journals had no channel metadata.
    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      try {
        final channel = SignedChannel.fromJson(_map(entry.value));
        if (entry.key == channel.id) {
          _admitChannel(channel);
        }
      } on FormatException {
        // Corrupt metadata never grants publishing authority after restart.
      }
    }
  }

  List<String>? _channelEvictions(SignedChannel incoming) {
    final publisherIds = channels.keys
        .where((id) => _channelPublishers[id] == incoming.ownerId)
        .toList();
    final remove = <String>[];
    if (publisherIds.length >= maxChannelsPerPublisher) {
      if (localOwnerId == null || incoming.ownerId == localOwnerId) return null;
      remove.add(publisherIds.first);
    }
    if (channels.length - remove.length >= maxChannels) {
      if (localOwnerId == null) return null;
      final oldestForeign = channels.keys.where(
        (id) =>
            _channelPublishers[id] != localOwnerId &&
            !managedChannelIds.contains(id) &&
            !remove.contains(id),
      );
      if (oldestForeign.isEmpty) return null;
      remove.add(oldestForeign.first);
    }
    return remove;
  }

  void _admitChannel(SignedChannel channel) {
    if (channels.containsKey(channel.id)) return;
    final remove = _channelEvictions(channel);
    if (remove == null) return;
    for (final id in remove) {
      channels.remove(id);
      channelPolicies.remove(id);
      _channelPublishers.remove(id);
      channelSequences.remove(id);
      evictions['channels'] = evictions['channels']! + 1;
      for (final bulletinId in bulletins.keys.toList()) {
        if (_bulletinChannels[bulletinId] != id) continue;
        bulletins.remove(bulletinId);
        bulletinObservations.remove(bulletinId);
        _bulletinPublishers.remove(bulletinId);
        _bulletinChannels.remove(bulletinId);
        _bulletinSequences.remove(bulletinId);
        evictions['bulletins'] = evictions['bulletins']! + 1;
      }
    }
    channels[channel.id] = channel.toJson();
    _channelPublishers[channel.id] = channel.ownerId;
  }

  void _trimMap(
    Map<String, Map<String, dynamic>> map,
    int limit,
    String counter,
  ) {
    while (map.length > limit) {
      // Keep the local author's recent outbox within its existing publisher
      // quota. Public foreign cache churn must not erase locally written news.
      final id = counter == 'bulletins' && localOwnerId != null
          ? map.keys.firstWhere(
              (id) =>
                  _bulletinPublishers[id] != localOwnerId &&
                  !publications.containsKey(id),
              orElse: () => map.keys.first,
            )
          : map.keys.first;
      map.remove(id);
      evictions[counter] = evictions[counter]! + 1;
    }
  }

  Future<void> _compact() async {
    final next = File('${_journal.path}.next');
    final backup = File('${_journal.path}.bak');
    // Counts alone do not bound variable-size diagnostic observations/logs.
    // These optional histories never displace channel keys or owner policies.
    var receiptBytes = receipts.values.fold<int>(
      0,
      (sum, row) => sum + utf8.encode(jsonEncode(row)).length,
    );
    while (receiptBytes > 2 * 1024 * 1024 && receipts.isNotEmpty) {
      receiptBytes -= utf8
          .encode(jsonEncode(receipts.remove(receipts.keys.first)))
          .length;
      evictions['receipts'] = evictions['receipts']! + 1;
    }
    var eventBytes = events.fold<int>(
      0,
      (sum, row) => sum + utf8.encode(jsonEncode(row)).length,
    );
    while (eventBytes > 512 * 1024 && events.isNotEmpty) {
      eventBytes -= utf8.encode(jsonEncode(events.removeAt(0))).length;
      evictions['events'] = evictions['events']! + 1;
    }
    final encoded = utf8.encode(
      '${jsonEncode({'kind': 'snapshot', 'peers': peers, 'channels': channels, 'channelPolicies': channelPolicies, 'channelSequences': channelSequences, 'bulletins': bulletins, 'bulletinObservations': bulletinObservations, 'receipts': receipts, 'publications': publications, 'events': events, 'sequence': sequence, 'evictions': evictions})}\n',
    );
    if (encoded.length > maxJournalRecordBytes) {
      throw StateError('Snapshot exceeds recovery limit; journal retained.');
    }
    await next.writeAsBytes(encoded, flush: true);
    if (await backup.exists()) await backup.delete();
    if (await _journal.exists()) await _journal.rename(backup.path);
    try {
      await next.rename(_journal.path);
    } catch (_) {
      if (!await _journal.exists() && await backup.exists()) {
        await backup.rename(_journal.path);
      }
      rethrow;
    }
    _records = 1;
    _compactedBytes = encoded.length;
    if (await backup.exists()) await backup.delete();
  }
}
