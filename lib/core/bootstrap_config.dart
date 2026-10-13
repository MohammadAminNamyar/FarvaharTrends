import 'dart:convert';

import 'models.dart';

const int maxBootstrapConfigBytes = 128 * 1024;
const int maxBootstrapPeers = 16;
const _peerFields = {
  'version',
  'id',
  'name',
  'host',
  'port',
  'certificatePem',
  'tcpEnrollment',
};

/// Public, certificate-pinned dialing hints. Parsing does not prove reachability.
/// Private identity fields and unexpected fields are never accepted or retained.
List<PeerCard> parseBootstrapConfig(String source) {
  if (source.length > maxBootstrapConfigBytes ||
      utf8.encode(source).length > maxBootstrapConfigBytes) {
    throw const FormatException('Starting-peer configuration is too large.');
  }
  final data = jsonDecode(source);
  if (data is! Map<String, dynamic> ||
      data.length != 2 ||
      data['version'] is! int ||
      data['version'] != 1 ||
      data['peers'] is! List) {
    throw const FormatException('Invalid starting-peer configuration.');
  }
  final entries = data['peers'] as List;
  if (entries.length > maxBootstrapPeers) {
    throw const FormatException('Too many configured starting peers.');
  }
  final cards = <PeerCard>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic> ||
        entry.keys.any((key) => !_peerFields.contains(key)) ||
        entry['host'] is! String ||
        (entry['host'] as String).trim().isEmpty) {
      throw const FormatException(
        'Expected a public peer card with a numeric host.',
      );
    }
    cards.add(PeerCard.fromJson(entry));
  }
  return mergeBootstrapPeers(cards);
}

/// Keep address aliases for a pinned identity, but avoid ambiguous capabilities
/// for the same dialing endpoint. A combined build still has at most 16 hints.
List<PeerCard> mergeBootstrapPeers(Iterable<PeerCard> cards) {
  final unique = <String, PeerCard>{};
  final enrollmentByEndpoint = <String, bool>{};
  for (final card in cards) {
    final endpoint = '${card.host}|${card.port}';
    if (enrollmentByEndpoint.containsKey(endpoint) &&
        enrollmentByEndpoint[endpoint] != card.tcpEnrollment) {
      throw const FormatException(
        'Conflicting enrollment settings for a starting-peer endpoint.',
      );
    }
    enrollmentByEndpoint[endpoint] = card.tcpEnrollment;
    unique.putIfAbsent('${card.id}|$endpoint', () => card);
    if (unique.length > maxBootstrapPeers) {
      throw const FormatException('Too many configured starting peers.');
    }
  }
  return List<PeerCard>.unmodifiable(unique.values);
}
