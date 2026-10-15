/// Typed, null-tolerant views over the engine snapshot map that the reader UI
/// receives through `AppController.snapshot`.
///
/// The engine (`PeerEngine.snapshot()`) and the background service still
/// exchange plain JSON maps; these views only read them. Every accessor copes
/// with a missing, null or mistyped key (legacy snapshots, partial `status`
/// events) and never throws. The underlying map stays reachable through
/// `.raw` for fields that have no typed accessor yet.
library;

/// The whole snapshot as the reader UI consumes it.
class Snapshot {
  Snapshot.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  static final empty = Snapshot.fromJson(null);

  /// The original map; never mutated by this class.
  final Map<String, dynamic> raw;

  // Identity and mode.
  bool get channelKeyManagement => _bool(raw['channelKeyManagement']);
  bool get running => _bool(raw['running']);
  bool get activeMode => _bool(raw['activeMode']);
  int? get listenPort => _intOrNull(raw['listenPort']);
  String? get identityId => _id(raw['identityId']);
  String? get deliveryMode => _string(raw['deliveryMode']);

  // Counters (non-negative, 0 when absent).
  int get peerCount => counter('peerCount');
  int get connectedCount => counter('connectedCount');
  int get helperContactCount => counter('helperContactCount');
  int get helperReconnectCount => counter('helperReconnectCount');
  int get bulletinCount => counter('bulletinCount');
  int get receiptCount => counter('receiptCount');
  int get rejectedCount => counter('rejectedCount');
  int get duplicateCount => counter('duplicateCount');
  int get pendingBulletinCount => counter('pendingBulletinCount');
  int get bootstrapConfiguredCount => counter('bootstrapConfiguredCount');
  int get discoveredCount => counter('discoveredCount');
  bool get advertisingHelper => _bool(raw['advertisingHelper']);
  String? get lastError => _string(raw['lastError']);

  /// Any top-level numeric counter by key; 0 when absent or invalid.
  int counter(String key) => _count(raw[key]);

  /// Connected link counts per transport name (`overlay`, `lan`, ...).
  Map<String, int> get activeTransportCounts =>
      _counts(raw['activeTransportCounts']);

  Map<String, int> get trafficDeferred => _counts(raw['trafficDeferred']);
  Map<String, int> get evictions => _counts(raw['evictions']);

  // Discovery.
  /// Falls back to the UI's historical default when the engine has not
  /// reported a state yet.
  String get discoveryState =>
      _string(raw['discoveryState']) ?? 'waitingForBootstrap';
  String? get discoveryLastError => _string(raw['discoveryLastError']);
  late final OverlaySnapshot overlay = OverlaySnapshot.fromJson(
    _map(raw['overlay']),
  );

  // Collections.
  late final List<NewsItem> bulletins = _maps(raw['bulletins'])
      .map(NewsItem.fromJson)
      .toList(growable: false);
  late final List<ChannelItem> channels = _maps(raw['channels'])
      .map(ChannelItem.fromJson)
      .toList(growable: false);
  late final List<PeerItem> peers = _maps(raw['peers'])
      .map(PeerItem.fromJson)
      .toList(growable: false);
  late final List<TrialItem> trials = _maps(raw['trials'])
      .map(TrialItem.fromJson)
      .toList(growable: false);
  late final List<PeerActivityItem> temporaryPeerActivity = _maps(
    raw['temporaryPeerActivity'],
  ).map(PeerActivityItem.fromJson).toList(growable: false);
  List<Map<String, dynamic>> get publications => _maps(raw['publications']);
  List<Map<String, dynamic>> get events => _maps(raw['events']);

  /// Peers with a live link and a well-formed id, as the temporary log shows.
  List<PeerItem> get connectedPeers =>
      peers.where((peer) => peer.connected && peer.hasValidId).toList();

  ChannelItem? channelById(String id) {
    for (final channel in channels) {
      if (channel.id == id) return channel;
    }
    return null;
  }

  List<NewsItem> bulletinsFor(String channelId) =>
      bulletins.where((news) => news.channelId == channelId).toList();
}

/// `snapshot['overlay']`, written by the service from the Internet overlay.
class OverlaySnapshot {
  OverlaySnapshot.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  /// `starting`, `discovering`, `connecting`, `connected`, `retrying`,
  /// `disabled`, `stopped`, `error` or `unavailable`; null when unreported.
  String? get state => _string(raw['state']);

  /// `bootstrapping`, `connecting` or `discovering` while searching.
  String? get discoveryStage => _string(raw['discoveryStage']);
  String? get error => _string(raw['error']);

  /// Mirrors the reader's "is the overlay doing anything" check.
  bool get isAvailable => raw.isNotEmpty && state != 'unavailable';
}

/// One signed news item (`snapshot['bulletins'][i]`).
class NewsItem {
  NewsItem.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  String get id => _string(raw['id']) ?? '';
  String get sourceId => _string(raw['sourceId']) ?? '';
  String get channelId => _string(raw['channelId']) ?? '';
  String? get runId => _string(raw['runId']);
  String get text => _string(raw['text']) ?? '';

  /// Writer-chosen label, or the channel name the engine substituted.
  String? get byline {
    final value = _string(raw['byline']);
    return value == null || value.isEmpty ? null : value;
  }

  /// Signed UTC send time from the writer's clock; null when unusable.
  int? get createdAtMs => _epochMs(raw['createdAtMs']);

  /// This phone's private first-receive wall time; null for local
  /// publications and legacy items without an observation.
  int? get receivedAtWallMs => _epochMs(raw['receivedAtWallMs']);
  int get sequence => _count(raw['sequence']);
  bool get localPublication => _bool(raw['localPublication']);

  /// `local`, `overlay`, `ip`, `lan`, `wifiDirect`, `bluetooth` or `unknown`.
  String get receivedVia => _string(raw['receivedVia']) ?? 'unknown';
  String get receivedNetwork => _string(raw['receivedNetwork']) ?? 'unknown';
  bool get isLocal => receivedVia == 'local';

  late final NewsImageRef? image = raw['image'] is Map
      ? NewsImageRef.fromJson(_map(raw['image']))
      : null;
}

/// Optional image attached to a news item.
class NewsImageRef {
  NewsImageRef.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  String? get hash => _string(raw['hash']);

  /// Local file path once the media store holds the bytes; null otherwise.
  String? get path => _string(raw['path']);
  String? get mime => _string(raw['mime']);
  int get bytes => _count(raw['bytes']);
  int get width => _count(raw['width']);
  int get height => _count(raw['height']);
}

/// One channel (`snapshot['channels'][i]`).
class ChannelItem {
  ChannelItem.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  String get id => _string(raw['id']) ?? '';
  String get name => _string(raw['name']) ?? '';
  String get description => _string(raw['description']) ?? '';
  String get ownerId => _string(raw['ownerId']) ?? '';
  bool get recoverable => _bool(raw['recoverable']);
  String get recoveryId => _string(raw['recoveryId']) ?? '';
  String get ownerAuthorityState =>
      _string(raw['ownerAuthorityState']) ?? 'unknown';
  int? get createdAtMs => _epochMs(raw['createdAtMs']);
  bool get owned => _bool(raw['owned']);
  bool get canPublish => _bool(raw['canPublish']);
  String get writerNickname => _string(raw['writerNickname']) ?? '';

  /// `owner`, `editor` or `reader`; derived when a legacy snapshot omits it.
  String get role =>
      _string(raw['role']) ??
      (owned
          ? 'owner'
          : canPublish
          ? 'editor'
          : 'reader');

  /// `self`, `paired` or `unverified`.
  String? get trust => _string(raw['trust']);
  int get bulletinCount => _count(raw['bulletinCount']);
  int get lastSequence => _count(raw['lastSequence']);
  List<Map<String, dynamic>> get editors => _maps(raw['editors']);
  bool get hasValidId => _id(id) != null;
}

/// One paired or discovered peer (`snapshot['peers'][i]`). The certificate
/// PEM stays in `raw` only; nothing here surfaces it.
class PeerItem {
  PeerItem.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  String get id => _string(raw['id']) ?? '';
  bool get hasValidId => _id(id) != null;
  String get name => _string(raw['name']) ?? '';
  String get host => _string(raw['host']) ?? '';
  int? get port => _intOrNull(raw['port']);
  bool get connected => _bool(raw['connected']);

  /// Transport name of the live link; null when not connected.
  String? get transport => _string(raw['transport']);
  String? get routeId => _string(raw['routeId']);
  int get endpointCount => _count(raw['endpointCount']);

  /// `manual`, `lan` or `bootstrap`.
  String get origin => _string(raw['origin']) ?? 'manual';

  /// `paired`, `unverified` or `configured`.
  String? get trust => _string(raw['trust']);
  bool get tcpEnrollment => _bool(raw['tcpEnrollment']);
}

/// One publication trial summary (`snapshot['trials'][i]`, legacy
/// diagnostics).
class TrialItem {
  TrialItem.fromJson(Map<String, dynamic>? json) : raw = json ?? const {};

  final Map<String, dynamic> raw;

  String? get bulletinId => _string(raw['bulletinId']);
  String? get runId => _string(raw['runId']);
  int get enrolled => _count(raw['enrolled']);
  int get confirmed => _count(raw['confirmed']);
  int get timelyUnlocked => _count(raw['timelyUnlocked']);
  int get unknown => _count(raw['unknown']);
  int? get createdAtMs => _epochMs(raw['createdAtMs']);
  List<Map<String, dynamic>> get receipts => _maps(raw['receipts']);
}

/// One temporary-log row (`snapshot['temporaryPeerActivity'][i]`).
class PeerActivityItem {
  PeerActivityItem.fromJson(Map<String, dynamic>? json)
    : raw = json ?? const {};

  final Map<String, dynamic> raw;

  /// `connected`, `disconnected` or `bulletin_verified`.
  String get kind => _string(raw['kind']) ?? '';
  String get peerId => _string(raw['peerId']) ?? '';
  bool get hasValidPeerId => _id(peerId) != null;
  String? get transport => _string(raw['transport']);

  /// Local wall time of this phone's own observation.
  int? get atWallMs => _epochMs(raw['atWallMs']);
}

// Tolerant readers shared by the views above.

final _idPattern = RegExp(r'^[a-f0-9]{64}$');

String? _string(dynamic value) => value is String ? value : null;

String? _id(dynamic value) =>
    value is String && _idPattern.hasMatch(value) ? value : null;

bool _bool(dynamic value) => value == true;

int? _intOrNull(dynamic value) => value is int
    ? value
    : (value is num && value.isFinite ? value.toInt() : null);

/// Non-negative integer, clamped to the safe-integer range; 0 otherwise.
int _count(dynamic value) => value is num && value.isFinite && value >= 0
    ? value.toInt().clamp(0, 9007199254740991)
    : 0;

/// Epoch milliseconds within the signed-timestamp contract; null otherwise.
int? _epochMs(dynamic value) =>
    value is int && value >= 0 && value <= 253402300799999 ? value : null;

Map<String, dynamic>? _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> _maps(dynamic raw) => raw is List
    ? raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : const [];

Map<String, int> _counts(dynamic value) => value is Map
    ? {
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: _count(entry.value),
      }
    : const {};
