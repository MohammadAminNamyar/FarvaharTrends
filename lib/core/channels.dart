import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'identity.dart';

const int maxChannelNameLength = 80;
const int maxChannelDescriptionLength = 500;
const String channelSigningDomain = 'persiantrend/channel/v1';
// Dart DateTime supports at most 100,000,000 days from the Unix epoch.
// Wider JSON-safe integers are valid sequences, but invalid display timestamps.
const int maxSignedWallTimeMs = 8640000000000000;
final RegExp _fingerprint = RegExp(r'^[0-9a-f]{64}$');

/// Immutable, self-authenticating channel metadata.
///
/// The embedded certificate identifies a key, not a trusted human or newsroom.
/// Editing metadata creates another channel ID; v1 has no ownership transfer.
class SignedChannel {
  SignedChannel._(
    this.id,
    this.payloadBase64,
    this.signature,
    this.ownerCertificatePem,
    this._body,
  );

  final String id;
  final String payloadBase64;
  final String signature;
  final String ownerCertificatePem;
  final Map<String, dynamic> _body;

  factory SignedChannel.create(
    Identity identity, {
    required String name,
    String description = '',
  }) {
    final random = Random.secure();
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'channel',
      'domain': channelSigningDomain,
      'nonce': base64UrlEncode(
        List<int>.generate(16, (_) => random.nextInt(256)),
      ).replaceAll('=', ''),
      'ownerId': identity.id,
      'createdAtMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      'name': name.trim(),
      'description': description.trim(),
    };
    _validateBody(body);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return SignedChannel.fromJson({
      'id': sha256.convert(bytes).toString(),
      'payloadBase64': base64Encode(bytes),
      'signature': identity.sign(_signingBytes(bytes)),
      'ownerCertificatePem': identity.certPem,
    });
  }

  /// Validates syntax, content hash, owner binding and the owner's signature.
  /// It deliberately makes no claim about the owner's real-world identity.
  factory SignedChannel.fromJson(Map<String, dynamic> json) {
    try {
      if (utf8.encode(jsonEncode(json)).length > 16 * 1024 ||
          json.length != 4 ||
          !json.keys.every(
            {
              'id',
              'payloadBase64',
              'signature',
              'ownerCertificatePem',
            }.contains,
          )) {
        throw const FormatException('Invalid channel envelope fields or size.');
      }
      final id = json['id'];
      final payload = json['payloadBase64'];
      final signature = json['signature'];
      final certificate = json['ownerCertificatePem'];
      if (id is! String ||
          !_fingerprint.hasMatch(id) ||
          payload is! String ||
          payload.isEmpty ||
          payload.length > 8192 ||
          signature is! String ||
          signature.length != 344 ||
          certificate is! String ||
          certificate.length > 8192) {
        throw const FormatException('Invalid signed channel envelope.');
      }
      final bytes = base64Decode(payload);
      final signatureBytes = base64Decode(signature);
      if (bytes.length > 6144 ||
          base64Encode(bytes) != payload ||
          signatureBytes.length != 256 ||
          base64Encode(signatureBytes) != signature ||
          sha256.convert(bytes).toString() != id) {
        throw const FormatException(
          'Invalid channel content hash or encoding.',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Expected a channel metadata object.');
      }
      _validateBody(decoded);
      final ownerId = decoded['ownerId'] as String;
      if (Identity.certificateId(certificate) != ownerId ||
          !Identity.verify(certificate, _signingBytes(bytes), signature)) {
        throw const FormatException('Invalid channel owner signature.');
      }
      return SignedChannel._(
        id,
        payload,
        signature,
        certificate,
        Map.unmodifiable(decoded),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid signed channel.');
    }
  }

  String get name => _body['name'] as String;
  String get description => _body['description'] as String;
  String get ownerId => _body['ownerId'] as String;
  int get createdAtMs => _body['createdAtMs'] as int;
  bool ownedBy(Identity identity) => ownerId == identity.id;

  Map<String, dynamic> toJson() => {
    'id': id,
    'payloadBase64': payloadBase64,
    'signature': signature,
    'ownerCertificatePem': ownerCertificatePem,
  };
}

Uint8List _signingBytes(List<int> payload) =>
    Uint8List.fromList([...utf8.encode('$channelSigningDomain\n'), ...payload]);

void _validateBody(Map<String, dynamic> body) {
  const fields = {
    'version',
    'kind',
    'domain',
    'nonce',
    'ownerId',
    'createdAtMs',
    'name',
    'description',
  };
  if (body.length != fields.length || !body.keys.every(fields.contains)) {
    throw const FormatException('Unexpected channel metadata fields.');
  }
  final owner = body['ownerId'];
  final created = body['createdAtMs'];
  final name = body['name'];
  final description = body['description'];
  final nonce = body['nonce'];
  if (body['version'] is! int ||
      body['version'] != 1 ||
      body['kind'] != 'channel' ||
      body['domain'] != channelSigningDomain ||
      owner is! String ||
      !_fingerprint.hasMatch(owner) ||
      created is! int ||
      created < 0 ||
      created > maxSignedWallTimeMs ||
      name is! String ||
      name.isEmpty ||
      name != name.trim() ||
      name.length > maxChannelNameLength ||
      utf8.encode(name).length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
      description is! String ||
      description != description.trim() ||
      description.length > maxChannelDescriptionLength ||
      utf8.encode(description).length > 2048 ||
      RegExp(r'[\x00-\x08\x0b-\x1f\x7f]').hasMatch(description) ||
      nonce is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(nonce)) {
    throw const FormatException('Invalid channel metadata.');
  }
  final nonceBytes = base64Url.decode('$nonce==');
  if (nonceBytes.length != 16 ||
      base64UrlEncode(nonceBytes).replaceAll('=', '') != nonce) {
    throw const FormatException('Invalid channel nonce.');
  }
}
