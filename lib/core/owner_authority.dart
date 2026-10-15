import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'channel_control.dart';
import 'channels.dart';

/// Bounded recovery-signed evidence of the highest owner generation observed.
/// This is local knowledge, not consensus or a guarantee of global freshness.
/// Two distinct grants for one generation fail closed until a higher one arrives.
class OwnerAuthority {
  OwnerAuthority._(this.channelId, this.grants);

  final String channelId;
  final List<ChannelControl> grants;
  int get generation => grants.first.generation;
  bool get conflicted => grants.length == 2;
  String get id => sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  factory OwnerAuthority.fromGrant(
    ChannelControl grant,
    SignedChannel channel,
  ) => OwnerAuthority.parse({
    'version': 1,
    'kind': 'owner-authority',
    'channelId': channel.id,
    'grants': [grant.toJson()],
  }, channel);

  factory OwnerAuthority.parse(
    Map<String, dynamic> value,
    SignedChannel channel,
  ) {
    const fields = {'version', 'kind', 'channelId', 'grants'};
    final raw = value['grants'];
    if (!channel.recoverable ||
        value.length != fields.length ||
        !value.keys.every(fields.contains) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['kind'] != 'owner-authority' ||
        value['channelId'] != channel.id ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 2 ||
        utf8.encode(jsonEncode(value)).length > ChannelControl.maxBytes) {
      throw const FormatException('Invalid owner authority.');
    }
    final grants = raw.map((v) {
      if (v is! Map<String, dynamic>) {
        throw const FormatException('Invalid owner grant.');
      }
      final grant = ChannelControl.parse(v, channel);
      if (grant.kind != 'owner') {
        throw const FormatException('Expected recovery-signed owner grant.');
      }
      return grant;
    }).toList()..sort((a, b) => a.id.compareTo(b.id));
    if (grants.any((v) => v.generation != grants.first.generation) ||
        grants.map((v) => v.id).toSet().length != grants.length) {
      throw const FormatException('Invalid owner conflict evidence.');
    }
    return OwnerAuthority._(channel.id, List.unmodifiable(grants));
  }

  /// A higher recovery generation always wins over policy revision and deletion.
  /// Keep at most two proofs, sufficient to preserve a conflict across restarts.
  OwnerAuthority merge(OwnerAuthority next) {
    if (next.channelId != channelId) {
      throw const FormatException(
        'Owner authority belongs to another channel.',
      );
    }
    if (next.generation < generation) return this;
    if (next.generation > generation) return next;
    final combined = {
      for (final v in [...grants, ...next.grants]) v.id: v,
    };
    final ids = combined.keys.toList()..sort();
    return OwnerAuthority._(
      channelId,
      List.unmodifiable(ids.take(2).map((id) => combined[id]!)),
    );
  }

  bool allows(ChannelControl control) =>
      !conflicted &&
      control.channelId == channelId &&
      control.ownerGrant?.id == grants.first.id;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'kind': 'owner-authority',
    'channelId': channelId,
    'grants': grants.map((v) => v.toJson()).toList(),
  };
}
