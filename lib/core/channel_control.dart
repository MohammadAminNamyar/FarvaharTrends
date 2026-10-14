import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'channels.dart';
import 'identity.dart';

/// Public, channel-scoped authority. Never contains a private signing key.
/// A manager certificate lets legacy channels gain independent recovery keys.
class ChannelControl {
  ChannelControl._(this._json, this.body, this.authority);
  final Map<String, dynamic> _json;
  final Map<String, dynamic> body;
  final ChannelControl? authority;
  static final fingerprint = RegExp(r'^[a-f0-9]{64}$');
  static const maxBytes = 24 * 1024;
  static const maxEditors = 8;
  static const maxRemovals = 24;
  String get id => _json['id'] as String;
  String get kind => body['kind'] as String;
  String get channelId => body['channelId'] as String;
  String get signerId => body['signerId'] as String;
  String get signerCertificate => _json['signerCertificatePem'] as String;
  int get revision => body['revision'] as int? ?? 0;
  List<String> get retained =>
      List<String>.from(body['retained'] as List? ?? []);
  bool get deleted => body['deleted'] == true;
  List<String> get activeGrants =>
      List<String>.from(body['activeGrants'] as List? ?? const []);
  List<Map<String, dynamic>> get removed =>
      (body['removed'] as List? ?? const [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  Map<String, int> get floors =>
      Map<String, int>.from(body['floors'] as Map? ?? const {});
  String get editorCertificate => body['editorCertificatePem'] as String;
  String get managerCertificate => body['managerCertificatePem'] as String;
  String get editorId => Identity.certificateId(editorCertificate);
  String get managerId => Identity.certificateId(managerCertificate);
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_json)) as Map<String, dynamic>;

  static ChannelControl create(
    Identity signer,
    SignedChannel channel, {
    required String kind,
    required Map<String, dynamic> data,
    ChannelControl? authority,
  }) {
    final body = <String, dynamic>{
      'version': 1,
      'kind': kind,
      'domain': 'farvahartrends/channel-$kind/v1',
      'channelId': channel.id,
      'signerId': signer.id,
      ...data,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return parse({
      'id': sha256.convert(bytes).toString(),
      'payloadBase64': base64Encode(bytes),
      'signature': signer.sign(bytes),
      'signerCertificatePem': signer.certPem,
      if (authority != null) 'authority': authority.toJson(),
    }, channel);
  }

  static String randomNonce() =>
      base64UrlEncode(List.generate(16, (_) => Random.secure().nextInt(256)))
          .replaceAll('=', '');

  static ChannelControl parse(
    Map<String, dynamic> json,
    SignedChannel channel, {
    bool nested = false,
  }) {
    try {
      final allowed = {
        'id',
        'payloadBase64',
        'signature',
        'signerCertificatePem',
        if (json.containsKey('authority')) 'authority',
      };
      if (utf8.encode(jsonEncode(json)).length > maxBytes ||
          json.length != allowed.length ||
          !json.keys.every(allowed.contains)) {
        throw const FormatException();
      }
      final id = json['id'],
          payload = json['payloadBase64'],
          signature = json['signature'],
          certificate = json['signerCertificatePem'];
      if (id is! String ||
          !fingerprint.hasMatch(id) ||
          payload is! String ||
          payload.length > 22000 ||
          signature is! String ||
          certificate is! String) {
        throw const FormatException();
      }
      final bytes = base64Decode(payload);
      if (bytes.length > 16 * 1024 ||
          base64Encode(bytes) != payload ||
          sha256.convert(bytes).toString() != id) {
        throw const FormatException();
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) throw const FormatException();
      final kind = value['kind'];
      final extra = switch (kind) {
        'manager' => {'managerCertificatePem', 'nonce'},
        'editor' => {'editorCertificatePem', 'label', 'revision', 'nonce'},
        'policy' => {
          'revision',
          'activeGrants',
          'removed',
          'floors',
          if (value.containsKey('deleted')) 'deleted',
          if (value.containsKey('retained')) 'retained',
        },
        _ => throw const FormatException(),
      };
      final fields = {
        'version',
        'kind',
        'domain',
        'channelId',
        'signerId',
        ...extra,
      };
      if (value.length != fields.length ||
          !value.keys.every(fields.contains) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['domain'] != 'farvahartrends/channel-$kind/v1' ||
          value['channelId'] != channel.id ||
          value['signerId'] != Identity.certificateId(certificate) ||
          !Identity.verify(certificate, bytes, signature)) {
        throw const FormatException();
      }
      ChannelControl? authority;
      if (json.containsKey('authority')) {
        if (nested ||
            kind == 'manager' ||
            json['authority'] is! Map<String, dynamic>) {
          throw const FormatException();
        }
        authority = parse(
          json['authority'] as Map<String, dynamic>,
          channel,
          nested: true,
        );
        if (authority.kind != 'manager' ||
            authority.managerId != value['signerId']) {
          throw const FormatException();
        }
      } else if (value['signerId'] != channel.ownerId) {
        throw const FormatException();
      }
      if (kind == 'manager' || kind == 'editor') {
        final nonce = value['nonce'];
        if (nonce is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(nonce) ||
            base64UrlEncode(base64Url.decode('$nonce==')).replaceAll('=', '') !=
                nonce) {
          throw const FormatException();
        }
        final cert =
            value[kind == 'manager'
                ? 'managerCertificatePem'
                : 'editorCertificatePem'];
        if (cert is! String) throw const FormatException();
        Identity.publicKeyFromCertificate(cert);
      }
      if (kind == 'editor') {
        final label = value['label'];
        if (label is! String ||
            label.trim().isEmpty ||
            label.length > 80 ||
            utf8.encode(label).length > 256 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(label)) {
          throw const FormatException();
        }
      }
      if (kind != 'manager' && !_integer(value['revision'], 1)) {
        throw const FormatException();
      }
      if (kind == 'policy' &&
          value.containsKey('deleted') &&
          value['deleted'] is! bool) {
        throw const FormatException();
      }
      if (kind == 'policy' && value.containsKey('retained')) {
        final retained = value['retained'];
        if (retained is! List ||
            retained.length > 64 ||
            retained.any((v) => v is! String || !fingerprint.hasMatch(v)) ||
            retained.toSet().length != retained.length) {
          throw const FormatException();
        }
      }
      if (kind == 'policy') {
        final active = value['activeGrants'],
            removed = value['removed'],
            floors = value['floors'];
        if (active is! List ||
            active.length > maxEditors ||
            active.any((v) => v is! String || !fingerprint.hasMatch(v)) ||
            active.toSet().length != active.length ||
            removed is! List ||
            removed.length > maxRemovals ||
            floors is! Map ||
            floors.length > maxEditors + 2) {
          throw const FormatException();
        }
        for (final row in removed) {
          if (row is! Map ||
              row.length != 3 ||
              row['id'] is! String ||
              !fingerprint.hasMatch(row['id'] as String) ||
              row['authorId'] is! String ||
              !fingerprint.hasMatch(row['authorId'] as String) ||
              !_integer(row['sequence'], 1)) {
            throw const FormatException();
          }
        }
        for (final entry in floors.entries) {
          if (entry.key is! String ||
              !fingerprint.hasMatch(entry.key as String) ||
              !_integer(entry.value, 1)) {
            throw const FormatException();
          }
        }
      }
      return ChannelControl._(
        Map.unmodifiable(jsonDecode(jsonEncode(json)) as Map<String, dynamic>),
        Map.unmodifiable(value),
        authority,
      );
    } catch (_) {
      throw const FormatException(
        'Invalid channel authority or control signature.',
      );
    }
  }

  bool permits(String newsId, String authorId, int sequence) =>
      kind == 'policy' &&
      !deleted &&
      !removed.any((row) => row['id'] == newsId) &&
      (sequence >= (floors[authorId] ?? 1) || retained.contains(newsId));

  static bool _integer(dynamic value, int minimum) =>
      value is int && value >= minimum && value <= 9007199254740991;
}
