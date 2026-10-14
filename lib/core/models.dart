import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'channels.dart';
import 'channel_control.dart';
import 'media_store.dart';
import 'identity.dart';

const int maxEnvelopeBytes = 16 * 1024;
const int maxBulletinTextBytes = 1024;
const int maxRunIdLength = 64;
const int maxTrustedPeers = 64;
const int defaultPeerPort = 45871;
const String _pairingPrefix = 'farvahartrends:pair:v1:';
final RegExp _idPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _controlPattern = RegExp(r'[\x00-\x1f\x7f]');

/// A certificate identity and, optionally, a numeric dialing address.
/// Human trust comes from contact provenance, never the card's display name.
/// An address is a hint, never authority to publish or a substitute for TLS pins.
class PeerCard {
  factory PeerCard({
    required String name,
    String host = '',
    int port = defaultPeerPort,
    required String certificatePem,
    bool tcpEnrollment = false,
  }) {
    final cleanName = name.trim();
    if (cleanName.isEmpty ||
        cleanName.length > 80 ||
        utf8.encode(cleanName).length > 256 ||
        _controlPattern.hasMatch(cleanName)) {
      throw const FormatException('Peer name must be 1–80 characters.');
    }
    if (port < 1 || port > 65535) {
      throw const FormatException('Peer port must be between 1 and 65535.');
    }
    final cleanHost = host.trim();
    final address = cleanHost.isEmpty
        ? null
        : InternetAddress.tryParse(cleanHost);
    if (cleanHost.isNotEmpty &&
        (address == null ||
            address.isMulticast ||
            address.address == '0.0.0.0' ||
            address.address == '::' ||
            address.address == '255.255.255.255')) {
      throw const FormatException(
        'Use a numeric unicast IP address, or leave it blank.',
      );
    }
    Identity.publicKeyFromCertificate(certificatePem);
    return PeerCard._(
      cleanName,
      address?.address ?? '',
      port,
      certificatePem,
      Identity.certificateId(certificatePem),
      tcpEnrollment,
    );
  }

  const PeerCard._(
    this.name,
    this.host,
    this.port,
    this.certificatePem,
    this.id,
    this.tcpEnrollment,
  );

  final String name;
  final String host;
  final int port;
  final String certificatePem;
  final String id;

  /// An explicit relay capability, never inferred from a remote hostname.
  /// Ordinary peers continue to require prior certificate admission.
  final bool tcpEnrollment;

  factory PeerCard.fromJson(Map<String, dynamic> json) {
    _checkJsonSize(json);
    if (json['version'] is! int ||
        json['version'] != 1 ||
        json['name'] is! String ||
        json['certificatePem'] is! String ||
        (json.containsKey('host') && json['host'] is! String) ||
        (json.containsKey('port') && json['port'] is! int) ||
        (json.containsKey('tcpEnrollment') && json['tcpEnrollment'] is! bool)) {
      throw const FormatException('Invalid peer card.');
    }
    final card = PeerCard(
      name: json['name'] as String,
      host: json['host'] as String? ?? '',
      port: json['port'] as int? ?? defaultPeerPort,
      certificatePem: json['certificatePem'] as String,
      tcpEnrollment: json['tcpEnrollment'] as bool? ?? false,
    );
    if (json['id'] != card.id) {
      throw const FormatException('Peer certificate fingerprint disagrees.');
    }
    return card;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'certificatePem': certificatePem,
    if (tcpEnrollment) 'tcpEnrollment': true,
  };

  String toText() =>
      '$_pairingPrefix${base64UrlEncode(utf8.encode(jsonEncode(toJson())))}';

  factory PeerCard.fromText(String text) {
    if (text.length > maxEnvelopeBytes || !text.startsWith(_pairingPrefix)) {
      throw const FormatException('Invalid FarvaharTrends pairing token.');
    }
    try {
      final bytes = base64Url.decode(text.substring(_pairingPrefix.length));
      if (bytes.length > maxEnvelopeBytes) {
        throw const FormatException('Pairing token is too large.');
      }
      return PeerCard.fromJson(_jsonObject(bytes));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid FarvaharTrends pairing token.');
    }
  }
}

/// An immutable signed object. The exact payload bytes are the signing input.
class SignedBulletin {
  SignedBulletin._(this._envelope, this._body, [this.authorization]);

  final _Envelope _envelope;
  final Map<String, dynamic> _body;
  final Map<String, dynamic>? authorization;

  factory SignedBulletin.create(
    Identity identity, {
    required String runId,
    required String text,
    required int sequence,
    String? channelId,
    ChannelControl? authorization,
    NewsImage? image,
    String? byline,
  }) {
    final body = <String, dynamic>{
      'version': authorization != null || image != null || byline != null
          ? 2
          : 1,
      'kind': 'bulletin',
      'nonce': _nonce(),
      'sourceId': identity.id,
      'createdAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      'runId': runId,
      'seq': sequence,
      'text': text,
      'channelId': ?channelId,
      if (authorization != null) 'authorizationId': authorization.id,
      if (image != null) 'image': image.toJson(),
      if (byline != null) 'byline': byline.trim(),
    };
    _validateBulletin(body);
    return SignedBulletin._(
      _Envelope.create(identity, body),
      Map.unmodifiable(body),
      authorization?.toJson(),
    );
  }

  factory SignedBulletin.fromJson(Map<String, dynamic> json) {
    final proof = json['authorization'];
    if (json.containsKey('authorization') && proof == null) {
      throw const FormatException('Missing authorization.');
    }
    if (proof != null &&
        (proof is! Map<String, dynamic> ||
            utf8.encode(jsonEncode(proof)).length > ChannelControl.maxBytes)) {
      throw const FormatException('Invalid bulletin authorization.');
    }
    final envelope = _Envelope.parse({...json}..remove('authorization'));
    final body = _jsonObject(envelope.bytes);
    _validateBulletin(body);
    if ((body['authorizationId'] != null) != (proof != null) ||
        (proof != null && (proof as Map)['id'] != body['authorizationId'])) {
      throw const FormatException('Bulletin authorization binding disagrees.');
    }
    return SignedBulletin._(
      envelope,
      Map.unmodifiable(body),
      proof == null ? null : Map<String, dynamic>.from(proof as Map),
    );
  }

  String get id => _envelope.id;
  String get payloadBase64 => _envelope.payloadBase64;
  String get signature => _envelope.signature;
  String get sourceId => _body['sourceId'] as String;
  int get createdAtMs => _body['createdAtMs'] as int;
  String get runId => _body['runId'] as String;
  int get sequence => _body['seq'] as int;
  String get text => _body['text'] as String;
  String get nonce => _body['nonce'] as String;
  String? get channelId => _body['channelId'] as String?;
  NewsImage? get image => _body['image'] is Map
      ? NewsImage.fromJson(Map<String, dynamic>.from(_body['image'] as Map))
      : null;
  String? get byline => _body['byline'] as String?;
  String? get authorLabel {
    if (byline != null) return byline;
    if (authorization == null) return null;
    final body = jsonDecode(
      utf8.decode(base64Decode(authorization!['payloadBase64'] as String)),
    ) as Map;
    return body['kind'] == 'editor' ? body['label'] as String : null;
  }

  bool get requiresModernPeer => _body['version'] == 2;

  Map<String, dynamic> toJson() => {
    ..._envelope.toJson(),
    if (authorization != null) 'authorization': authorization,
  };

  bool verifyAgainst(Map<String, PeerCard> trusted, Identity self) =>
      _verifySigner(sourceId, _envelope, trusted, self);

  /// Verifies publishing authority for this exact channel, even through a relay.
  /// Channel metadata identifies a key, not a trusted human/editorial source.
  bool verifyForChannel(SignedChannel channel, {ChannelControl? policy}) {
    if (channelId != channel.id ||
        (policy != null && !policy.permits(id, sourceId, sequence))) {
      return false;
    }
    if (authorization == null) {
      return sourceId == channel.ownerId &&
          Identity.verify(
            channel.ownerCertificatePem,
            _envelope.bytes,
            _envelope.signature,
          );
    }
    try {
      final proof = ChannelControl.parse(authorization!, channel);
      String cert;
      if (proof.kind == 'manager' && proof.managerId == sourceId) {
        cert = proof.managerCertificate;
      } else if (proof.kind == 'editor' && proof.editorId == sourceId) {
        if (policy != null &&
            (policy.signerId != proof.signerId ||
                (policy.revision >= proof.revision &&
                    !policy.activeGrants.contains(proof.id)))) {
          return false;
        }
        cert = proof.editorCertificate;
      } else {
        return false;
      }
      return Identity.verify(cert, _envelope.bytes, _envelope.signature);
    } catch (_) {
      return false;
    }
  }
}

/// Receiver-signed evidence of verification. It is not a trusted clock attestation.
/// The engine must match bulletinId/sourceId/runId against its actual bulletin.
class SignedReceipt {
  SignedReceipt._(this._envelope, this._body);

  final _Envelope _envelope;
  final Map<String, dynamic> _body;

  factory SignedReceipt.create(
    Identity identity, {
    required String bulletinId,
    required String sourceId,
    required String runId,
    required bool locked,
    bool lockStateKnown = true,
    int? elapsedRealtimeMs,
  }) {
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'receipt',
      'bulletinId': bulletinId,
      'sourceId': sourceId,
      'receiverId': identity.id,
      'runId': runId,
      'verifiedAtWallMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      'locked': locked,
      'lockStateKnown': lockStateKnown,
      'elapsedRealtimeMs': elapsedRealtimeMs,
    };
    _validateReceipt(body);
    return SignedReceipt._(
      _Envelope.create(identity, body),
      Map.unmodifiable(body),
    );
  }

  factory SignedReceipt.fromJson(Map<String, dynamic> json) {
    final envelope = _Envelope.parse(json);
    final body = _jsonObject(envelope.bytes);
    _validateReceipt(body);
    return SignedReceipt._(envelope, Map.unmodifiable(body));
  }

  String get id => _envelope.id;
  String get payloadBase64 => _envelope.payloadBase64;
  String get signature => _envelope.signature;
  String get bulletinId => _body['bulletinId'] as String;
  String get sourceId => _body['sourceId'] as String;
  String get receiverId => _body['receiverId'] as String;
  String get runId => _body['runId'] as String;
  int get verifiedAtWallMs => _body['verifiedAtWallMs'] as int;
  bool get locked => _body['locked'] as bool;
  bool get lockStateKnown => _body['lockStateKnown'] as bool;
  int? get elapsedRealtimeMs => _body['elapsedRealtimeMs'] as int?;

  Map<String, dynamic> toJson() => _envelope.toJson();

  bool verifyAgainst(Map<String, PeerCard> trusted, Identity self) =>
      _verifySigner(receiverId, _envelope, trusted, self);
}

class _Envelope {
  const _Envelope(this.id, this.payloadBase64, this.signature, this.bytes);

  final String id;
  final String payloadBase64;
  final String signature;
  final Uint8List bytes;

  factory _Envelope.create(Identity identity, Map<String, dynamic> body) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return _Envelope.parse({
      'id': sha256.convert(bytes).toString(),
      'payloadBase64': base64Encode(bytes),
      'signature': identity.sign(bytes),
    });
  }

  factory _Envelope.parse(Map<String, dynamic> json) {
    _checkJsonSize(json);
    _exactKeys(json, {'id', 'payloadBase64', 'signature'});
    final id = _requireId(json, 'id');
    final payload = json['payloadBase64'];
    final signature = json['signature'];
    if (payload is! String ||
        payload.isEmpty ||
        payload.length > 8192 ||
        signature is! String ||
        signature.length != 344) {
      throw const FormatException('Invalid signed envelope.');
    }
    try {
      final bytes = base64Decode(payload);
      final signatureBytes = base64Decode(signature);
      if (bytes.length > 6144 ||
          base64Encode(bytes) != payload ||
          signatureBytes.length != 256 ||
          base64Encode(signatureBytes) != signature ||
          sha256.convert(bytes).toString() != id) {
        throw const FormatException('Signed envelope integrity check failed.');
      }
      return _Envelope(id, payload, signature, bytes);
    } on FormatException {
      throw const FormatException('Invalid signed envelope encoding or ID.');
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'payloadBase64': payloadBase64,
    'signature': signature,
  };
}

bool _verifySigner(
  String signer,
  _Envelope envelope,
  Map<String, PeerCard> trusted,
  Identity self,
) {
  final card = trusted[signer];
  final certPem = signer == self.id
      ? self.certPem
      : card != null && card.id == signer
      ? card.certificatePem
      : null;
  return certPem != null &&
      Identity.verify(certPem, envelope.bytes, envelope.signature);
}

void _validateBulletin(Map<String, dynamic> body) {
  _exactKeys(body, {
    'version',
    'kind',
    'nonce',
    'sourceId',
    'createdAtMs',
    'runId',
    'seq',
    'text',
    if (body.containsKey('channelId')) 'channelId',
    if (body.containsKey('authorizationId')) 'authorizationId',
    if (body.containsKey('image')) 'image',
    if (body.containsKey('byline')) 'byline',
  });
  if (body['kind'] != 'bulletin' ||
      body['version'] is! int ||
      !{1, 2}.contains(body['version']) ||
      (body['version'] == 1 &&
          (body.containsKey('authorizationId') ||
              body.containsKey('image') ||
              body.containsKey('byline'))) ||
      (body['version'] == 2 &&
          (body['channelId'] == null ||
              (!body.containsKey('authorizationId') &&
                  !body.containsKey('image') &&
                  !body.containsKey('byline'))))) {
    throw const FormatException('Invalid bulletin version.');
  }
  if (body.containsKey('byline')) {
    if (body['byline'] is! String) {
      throw const FormatException('Invalid writer nickname.');
    }
    validateNewsByline(body['byline'] as String);
  }
  if (body.containsKey('authorizationId')) _requireId(body, 'authorizationId');
  if (body.containsKey('image')) {
    if (body['image'] is! Map) {
      throw const FormatException('Invalid image descriptor.');
    }
    NewsImage.fromJson(Map<String, dynamic>.from(body['image'] as Map));
  }
  _requireId(body, 'sourceId');
  if (body.containsKey('channelId')) _requireId(body, 'channelId');
  _requireRun(body);
  _requireInt(body, 'createdAtMs', maximum: maxSignedWallTimeMs);
  _requireInt(body, 'seq', minimum: 1);
  final text = body['text'];
  final nonce = body['nonce'];
  if (text is! String ||
      text.trim().isEmpty ||
      utf8.encode(text).length > maxBulletinTextBytes ||
      nonce is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(nonce)) {
    throw const FormatException('Invalid bulletin text or nonce.');
  }
  try {
    final decoded = base64Url.decode('$nonce==');
    if (decoded.length != 16 ||
        base64UrlEncode(decoded).replaceAll('=', '') != nonce) {
      throw const FormatException('Invalid bulletin nonce.');
    }
  } on FormatException {
    throw const FormatException('Invalid bulletin nonce.');
  }
}

void _validateReceipt(Map<String, dynamic> body) {
  _exactKeys(body, {
    'version',
    'kind',
    'bulletinId',
    'sourceId',
    'receiverId',
    'runId',
    'verifiedAtWallMs',
    'locked',
    'lockStateKnown',
    'elapsedRealtimeMs',
  });
  _versionAndKind(body, 'receipt');
  _requireId(body, 'bulletinId');
  _requireId(body, 'sourceId');
  _requireId(body, 'receiverId');
  _requireRun(body);
  _requireInt(body, 'verifiedAtWallMs', maximum: maxSignedWallTimeMs);
  if (body['locked'] is! bool || body['lockStateKnown'] is! bool) {
    throw const FormatException('Invalid receipt lock state.');
  }
  if (body['elapsedRealtimeMs'] != null) {
    _requireInt(body, 'elapsedRealtimeMs');
  }
}

void _versionAndKind(Map<String, dynamic> body, String kind) {
  if (body['version'] is! int || body['version'] != 1 || body['kind'] != kind) {
    throw const FormatException('Unsupported signed payload type or version.');
  }
}

void _requireRun(Map<String, dynamic> body) {
  final run = body['runId'];
  if (run is! String ||
      run.trim().isEmpty ||
      run.length > maxRunIdLength ||
      utf8.encode(run).length > 256 ||
      _controlPattern.hasMatch(run)) {
    throw const FormatException('Invalid pilot run ID.');
  }
}

String _requireId(Map<String, dynamic> body, String key) {
  final value = body[key];
  if (value is! String || !_idPattern.hasMatch(value)) {
    throw FormatException('Invalid $key fingerprint.');
  }
  return value;
}

void _requireInt(
  Map<String, dynamic> body,
  String key, {
  int minimum = 0,
  int maximum = 9007199254740991,
}) {
  final value = body[key];
  if (value is! int || value < minimum || value > maximum) {
    throw FormatException('Invalid $key integer.');
  }
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.length != expected.length || !json.keys.every(expected.contains)) {
    throw const FormatException('Unexpected or missing object fields.');
  }
}

void _checkJsonSize(Map<String, dynamic> json) {
  try {
    if (utf8.encode(jsonEncode(json)).length > maxEnvelopeBytes) {
      throw const FormatException('Object exceeds the 16 KB limit.');
    }
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Invalid JSON object.');
  }
}

Map<String, dynamic> _jsonObject(List<int> bytes) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }
    return value;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('Invalid JSON payload.');
  }
}

String _nonce() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

void validateNewsByline(String value) {
  if (value.trim() != value ||
      value.isEmpty ||
      value.runes.length > 60 ||
      utf8.encode(value).length > 240 ||
      RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(value)) {
    throw const FormatException('Use a nickname of 1–60 characters.');
  }
}
