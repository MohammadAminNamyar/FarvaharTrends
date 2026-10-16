part of 'peer_engine.dart';

// Section 9.2 staging experiment (docs/PUBLISHER-DESIGN-REVIEW.md). Laboratory
// only: an engine constructed without an [EnvelopeExperiment] has none of this
// behaviour and rejects envelope frames as unknown, exactly as before. HPKE is
// the default; an explicitly selected insecure stub exists only for comparison.
// The guard's exit list and recipient keys are configured by the harness. Nothing in
// this file hides a publisher from an observer of its own connection.

/// Harness-controlled configuration, fault injection and counters.
class EnvelopeExperiment {
  EnvelopeExperiment({
    this.guardPeerId,
    List<String> exitPeerIds = const [],
    this.ackDeadline = const Duration(seconds: 10),
    this.echoDeadline = const Duration(seconds: 30),
    this.maxAttempts = 3,
    this.cryptoMode = EnvelopeCryptoMode.hpke,
  }) : exitPeerIds = List.of(exitPeerIds);

  String? guardPeerId;
  List<String> exitPeerIds;
  final Duration ackDeadline;
  final Duration echoDeadline;
  final int maxAttempts;
  final EnvelopeCryptoMode cryptoMode;
  String get feature => cryptoMode == EnvelopeCryptoMode.hpke
      ? 'envelope-x2'
      : 'envelope-x2-stub';
  // Laboratory pinned recipient keys, populated independently of network input.
  // Production discovery/key rotation is intentionally not inferred here.
  final Map<String, List<int>> recipientKeys = {};
  // Local-only timestamp hook: never a network receipt or classifier feature.
  void Function(String id)? onPublicAdmission;
  void Function(String id)? onLocalPublication;
  void count(String key, [int amount = 1]) =>
      stats[key] = (stats[key] ?? 0) + amount;

  /// Entry fault injection: journal and acknowledge, never forward.
  bool dropAtEntry = false;

  /// Entry fault injection: no journal, no acknowledgement, no forward.
  bool silentAtEntry = false;

  /// Exit fault injection: journal and acknowledge, never admit.
  bool dropAtExit = false;

  /// Exit fault injection: journal and acknowledge, admit only when the
  /// harness calls [PeerEngine.releaseHeldRelayedObjects] (restart recovery).
  bool holdAtExit = false;

  /// Harness override for the next staged object's first exit index.
  int? nextExitIndex;

  final Map<String, int> stats = {
    'cellsSent': 0,
    'cellsReceivedAtEntry': 0,
    'cellsForwarded': 0,
    'cellsReceivedAtExit': 0,
    'objectsReleased': 0,
    'entryAcks': 0,
    'exitAcks': 0,
    'resends': 0,
    'failed': 0,
    'echoed': 0,
    'envelopeBytesSent': 0,
    'envelopeBytesReceived': 0,
    'imageFetchesCompleted': 0,
    'exitUnreachable': 0,
    'cellSendRefused': 0,
  };

  /// Image hashes this engine fetched from the network (completion events).
  final List<String> fetchedImages = [];

  /// Bounded laboratory event log (monotonic ms since engine clock start).
  final List<Map<String, dynamic>> log = [];
  void note(String kind, int atMs, [Map<String, dynamic> extra = const {}]) {
    if (log.length >= 4096) log.removeAt(0);
    log.add({'kind': kind, 'atMs': atMs, ...extra});
  }
}

/// Digest of a laboratory envelope for bounded durable acknowledgements.
class EnvelopeCell {
  static String hash(Uint8List cell) => sha256.convert(cell).toString();
}

/// One staged publisher object (bulletin or channel) and its progress.
class PendingPublication {
  PendingPublication({
    required this.id,
    required this.type,
    required this.value,
    this.imageHash,
    this.imageDescriptor,
    required this.composedMs,
  });
  final String id;
  final String type;
  final Map<String, dynamic> value;
  final String? imageHash;
  final Map<String, dynamic>? imageDescriptor;
  final int composedMs;
  String state = 'composed';
  int attempts = 0;
  int exitIndex = 0;
  String? exitPeerId;
  String? lastCellHash;
  int? sealedMs, ackedMs, exitAckedMs, echoedMs, failedMs;
  int? sealedWallMs, ackedWallMs, echoedWallMs;
  final Map<String, int> timings = {};

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'value': value,
    'imageHash': ?imageHash,
    'imageDescriptor': ?imageDescriptor,
    'composedMs': composedMs,
    'state': state,
    'attempts': attempts,
    'exitIndex': exitIndex,
    'exitPeerId': ?exitPeerId,
    'lastCellHash': ?lastCellHash,
    'sealedWallMs': ?sealedWallMs,
    'ackedWallMs': ?ackedWallMs,
    'echoedWallMs': ?echoedWallMs,
    'timingsMs': timings,
  };

  static PendingPublication fromJson(Map<String, dynamic> json) {
    final record = PendingPublication(
      id: json['id'] as String,
      type: json['type'] as String,
      value: Map<String, dynamic>.from(json['value'] as Map),
      imageHash: json['imageHash'] as String?,
      imageDescriptor: json['imageDescriptor'] == null
          ? null
          : Map<String, dynamic>.from(json['imageDescriptor'] as Map),
      composedMs: json['composedMs'] as int,
    );
    record.state = json['state'] as String;
    record.attempts = json['attempts'] as int;
    record.exitIndex = json['exitIndex'] as int;
    record.exitPeerId = json['exitPeerId'] as String?;
    record.lastCellHash = json['lastCellHash'] as String?;
    record.sealedWallMs = json['sealedWallMs'] as int?;
    record.ackedWallMs = json['ackedWallMs'] as int?;
    record.echoedWallMs = json['echoedWallMs'] as int?;
    record.timings.addAll(
      Map<String, int>.from(json['timingsMs'] as Map? ?? {}),
    );
    return record;
  }

  Map<String, dynamic> summary() => {
    'id': id,
    'type': type,
    'state': state,
    'attempts': attempts,
    'exitPeerId': exitPeerId,
    'composedMs': composedMs,
    'sealedMs': sealedMs,
    'ackedMs': ackedMs,
    'exitAckedMs': exitAckedMs,
    'echoedMs': echoedMs,
    'failedMs': failedMs,
    'timingsMs': Map.of(timings),
  };
}
