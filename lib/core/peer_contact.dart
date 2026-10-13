import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'identity.dart';
import 'models.dart';

/// An opt-in helper's short-lived, self-signed dialing hint. It authenticates
/// the connection key, not address ownership, human trust or publisher rights.
class PeerContact {
  PeerContact._(this._value, this.peer, this.issuedAtMs, this.expiresAtMs);

  static const maxBytes = 4096;
  static const maxLifetimeMs = 5 * 60 * 1000;
  static const clockSkewMs = 30 * 1000;
  final Map<String, dynamic> _value;
  final PeerCard peer;
  final int issuedAtMs;
  final int expiresAtMs;
  String get id => peer.id;

  static PeerContact create(
    Identity connection, {
    required String host,
    required int port,
    required int lifetimeMs,
    int? nowMs,
    bool allowLoopbackForTesting = false,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure();
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'persiantrend/helper-contact/v1',
      'certificatePem': connection.certPem,
      'host': host,
      'port': port,
      'issuedAtMs': now,
      'expiresAtMs': now + lifetimeMs,
      'nonce': base64UrlEncode(List.generate(16, (_) => random.nextInt(256))),
    };
    return parse(
      {
        ...body,
        'signature': connection.sign(
          Uint8List.fromList(utf8.encode(jsonEncode(body))),
        ),
      },
      nowMs: now,
      allowLoopbackForTesting: allowLoopbackForTesting,
    );
  }

  static PeerContact parse(
    Map<String, dynamic> value, {
    int? nowMs,
    bool allowLoopbackForTesting = false,
  }) {
    if (utf8.encode(jsonEncode(value)).length > maxBytes ||
        value.length != 9 ||
        value['version'] != 1 ||
        value['kind'] != 'persiantrend/helper-contact/v1' ||
        value['certificatePem'] is! String ||
        value['host'] is! String ||
        value['port'] is! int ||
        value['issuedAtMs'] is! int ||
        value['expiresAtMs'] is! int ||
        value['nonce'] is! String ||
        value['signature'] is! String) {
      throw const FormatException('Invalid helper contact.');
    }
    final issued = value['issuedAtMs'] as int;
    final expires = value['expiresAtMs'] as int;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (issued < 0 ||
        issued > 9007199254740991 ||
        expires > 9007199254740991 ||
        expires <= issued ||
        expires - issued > maxLifetimeMs ||
        issued > now + clockSkewMs ||
        expires <= now) {
      throw const FormatException(
        'Helper contact expired or clock is invalid.',
      );
    }
    final nonce = value['nonce'] as String;
    final decoded = base64Url.decode(nonce);
    if (decoded.length != 16 || base64UrlEncode(decoded) != nonce) {
      throw const FormatException('Invalid helper contact nonce.');
    }
    final host = InternetAddress.tryParse(value['host'] as String);
    if (host == null ||
        (value['host'] as String).contains('%') ||
        host.address != value['host'] ||
        !(isPublicAddress(host) ||
            allowLoopbackForTesting && host.isLoopback)) {
      throw const FormatException(
        'Helper contact requires a public numeric address.',
      );
    }
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'persiantrend/helper-contact/v1',
      'certificatePem': value['certificatePem'],
      'host': value['host'],
      'port': value['port'],
      'issuedAtMs': issued,
      'expiresAtMs': expires,
      'nonce': nonce,
    };
    final certificate = value['certificatePem'] as String;
    if (!Identity.verify(
      certificate,
      Uint8List.fromList(utf8.encode(jsonEncode(body))),
      value['signature'] as String,
    )) {
      throw const FormatException('Invalid helper contact signature.');
    }
    final peer = PeerCard(
      name: 'Peer ${Identity.certificateId(certificate).substring(0, 8)}',
      host: host.address,
      port: value['port'] as int,
      certificatePem: certificate,
      tcpEnrollment: true,
    );
    return PeerContact._(
      Map.unmodifiable({...body, 'signature': value['signature']}),
      peer,
      issued,
      expires,
    );
  }

  Map<String, dynamic> toJson() => Map.of(_value);

  /// Exclude local, documentation, benchmarking and special-use destinations.
  /// Remote referrals must not turn phones into local-network scanners/proxies.
  static bool isPublicAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final a = bytes[0], b = bytes[1], c = bytes[2];
      return !(a == 0 ||
          a == 10 ||
          a == 127 ||
          a >= 224 ||
          a == 100 && b >= 64 && b <= 127 ||
          a == 169 && b == 254 ||
          a == 172 && b >= 16 && b <= 31 ||
          a == 192 && (b == 168 || b == 0 || b == 2 || b == 88 && c == 99) ||
          a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) ||
          a == 203 && b == 0 && c == 113);
    }
    // Use ordinary global-unicast IPv6 only, excluding protocol assignments,
    // documentation and 6to4 (whose embedded IPv4 may be a local destination).
    return (bytes[0] & 0xe0) == 0x20 &&
        !(bytes[0] == 0x20 && bytes[1] == 1 && bytes[2] <= 1) &&
        !(bytes[0] == 0x20 &&
            bytes[1] == 1 &&
            bytes[2] == 0x0d &&
            bytes[3] == 0xb8) &&
        !(bytes[0] == 0x20 && bytes[1] == 2) &&
        !(bytes[0] == 0x3f && bytes[1] == 0xff);
  }
}
