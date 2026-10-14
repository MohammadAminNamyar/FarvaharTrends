import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'peer_contact.dart';

const int maxBootstrapConfigBytes = 128 * 1024;
const int maxBootstrapPeers = 16;
const int maxDhtBootstrapEntries = 16;
const _peerFields = {
  'version',
  'id',
  'name',
  'host',
  'port',
  'certificatePem',
  'tcpEnrollment',
};
const _documentFields = {'version', 'peers', 'dhtBootstrap'};

/// Parsed starting-peer configuration: pinned dialing hints plus optional
/// operator DHT bootstrap nodes. Neither list proves reachability, and no entry
/// can sign news or widen what this device shares.
class BootstrapConfig {
  const BootstrapConfig({
    this.peers = const <PeerCard>[],
    this.dhtBootstrap = const <String>[],
  });

  static const empty = BootstrapConfig();

  final List<PeerCard> peers;

  /// Canonical public IPv4 `host:port` entries supported by the DHT runtime.
  final List<String> dhtBootstrap;

  bool get isEmpty => peers.isEmpty && dhtBootstrap.isEmpty;

  Map<String, dynamic> toJson() => {
    'version': 2,
    'peers': peers.map((card) => card.toJson()).toList(),
    'dhtBootstrap': List<String>.of(dhtBootstrap),
  };
}

/// Public, certificate-pinned dialing hints. Parsing does not prove reachability.
/// Private identity fields and unexpected fields are never accepted or retained.
/// Version 1 documents carry peers only; version 2 adds `dhtBootstrap`.
BootstrapConfig parseBootstrapConfig(String source) {
  if (source.length > maxBootstrapConfigBytes ||
      utf8.encode(source).length > maxBootstrapConfigBytes) {
    throw const FormatException('Starting-peer configuration is too large.');
  }
  final data = jsonDecode(source);
  if (data is! Map<String, dynamic> ||
      data['version'] is! int ||
      data['peers'] is! List) {
    throw const FormatException('Invalid starting-peer configuration.');
  }
  final version = data['version'] as int;
  final valid = switch (version) {
    1 => data.length == 2,
    2 =>
      data.keys.every(_documentFields.contains) &&
          (!data.containsKey('dhtBootstrap') || data['dhtBootstrap'] is List),
    _ => false,
  };
  if (!valid) {
    throw const FormatException('Invalid starting-peer configuration.');
  }
  final entries = data['peers'] as List;
  if (entries.length > maxBootstrapPeers) {
    throw const FormatException('Too many configured starting peers.');
  }
  final cards = <PeerCard>[];
  for (final entry in entries) {
    cards.add(parseBootstrapPeer(entry));
  }
  final nodes = version == 2 && data['dhtBootstrap'] is List
      ? parseDhtBootstrapEntries(data['dhtBootstrap'] as List)
      : const <String>[];
  return BootstrapConfig(
    peers: mergeBootstrapPeers(cards),
    dhtBootstrap: nodes,
  );
}

/// Accept what a person pastes or scans: a pairing token, one peer card as
/// JSON, or a starting-peer document (version 1 or 2). A lone card may have no
/// dialing address; it is then trust-only exactly like the manual import.
BootstrapConfig parseBootstrapInput(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Paste a peer card or a starting-peer list.');
  }
  if (!trimmed.startsWith('{')) {
    return BootstrapConfig(
      peers: List<PeerCard>.unmodifiable([PeerCard.fromText(trimmed)]),
    );
  }
  if (trimmed.length > maxBootstrapConfigBytes ||
      utf8.encode(trimmed).length > maxBootstrapConfigBytes) {
    throw const FormatException('Starting-peer configuration is too large.');
  }
  final data = jsonDecode(trimmed);
  if (data is! Map<String, dynamic>) {
    throw const FormatException('Invalid peer card or starting-peer list.');
  }
  if (data.containsKey('peers')) return parseBootstrapConfig(trimmed);
  if (data.keys.any((key) => !_peerFields.contains(key))) {
    throw const FormatException('Invalid peer card.');
  }
  return BootstrapConfig(
    peers: List<PeerCard>.unmodifiable([PeerCard.fromJson(data)]),
  );
}

/// One starting-peer card: the ordinary card format with a numeric host.
PeerCard parseBootstrapPeer(Object? entry) {
  if (entry is! Map<String, dynamic> ||
      entry.keys.any((key) => !_peerFields.contains(key)) ||
      entry['host'] is! String ||
      (entry['host'] as String).trim().isEmpty) {
    throw const FormatException(
      'Expected a public peer card with a numeric host.',
    );
  }
  return PeerCard.fromJson(entry);
}

/// Operator DHT nodes are numeric only: a blocked or lying resolver must not be
/// able to redirect a cold start. Duplicates are rejected rather than merged.
List<String> parseDhtBootstrapEntries(List entries) {
  if (entries.length > maxDhtBootstrapEntries) {
    throw const FormatException('Too many DHT bootstrap entries.');
  }
  final result = <String>[];
  for (final entry in entries) {
    if (entry is! String) {
      throw const FormatException('DHT bootstrap entries must be strings.');
    }
    final normalized = normalizeDhtBootstrapEntry(entry);
    if (result.contains(normalized)) {
      throw const FormatException('Duplicate DHT bootstrap entry.');
    }
    result.add(normalized);
  }
  return List<String>.unmodifiable(result);
}

/// The pinned DHT runtime supports public IPv4 bootstrap addresses. Reject
/// unsupported addresses here, before a successful import can break discovery.
String normalizeDhtBootstrapEntry(String entry) {
  if (entry.length > 64 || entry.trim() != entry) {
    throw const FormatException('Invalid DHT bootstrap entry.');
  }
  final separator = entry.lastIndexOf(':');
  if (separator <= 0 || separator == entry.length - 1) {
    throw const FormatException('DHT bootstrap entries need host:port.');
  }
  var host = entry.substring(0, separator);
  final portText = entry.substring(separator + 1);
  final bracketed = host.startsWith('[') && host.endsWith(']');
  if (bracketed) host = host.substring(1, host.length - 1);
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535 || portText != port.toString()) {
    throw const FormatException('DHT bootstrap port must be 1–65535.');
  }
  // Non-canonical spellings are normalized so duplicates cannot hide behind
  // zero padding; the dialed address is always the canonical one.
  final parsed = InternetAddress.tryParse(host);
  if (parsed == null || host.contains('%')) {
    throw const FormatException(
      'DHT bootstrap hosts must be numeric IP addresses, not names.',
    );
  }
  final address = InternetAddress.fromRawAddress(parsed.rawAddress);
  final isV6 = address.type == InternetAddressType.IPv6;
  if (isV6 != bracketed) {
    throw const FormatException('IPv6 DHT bootstrap hosts need brackets.');
  }
  if (isV6 || !PeerContact.isPublicAddress(address)) {
    throw const FormatException(
      'DHT starting peers require a public IPv4 address. IPv6 and private addresses are not supported by this discovery transport.',
    );
  }
  return '${address.address}:$port';
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

/// Combine two already-valid configurations without failing: `preferred`
/// entries win over `fallback` duplicates (same identity and endpoint) and over
/// conflicting enrollment for the same endpoint. The result keeps the overall
/// caps by dropping the latest fallback entries first.
BootstrapConfig combineBootstrapConfigs(
  BootstrapConfig preferred,
  BootstrapConfig fallback,
) {
  final peers = <String, PeerCard>{};
  final enrollmentByEndpoint = <String, bool>{};
  for (final card in preferred.peers.followedBy(fallback.peers)) {
    if (peers.length >= maxBootstrapPeers) break;
    final endpoint = '${card.host}|${card.port}';
    if (enrollmentByEndpoint.containsKey(endpoint) &&
        enrollmentByEndpoint[endpoint] != card.tcpEnrollment) {
      continue;
    }
    enrollmentByEndpoint[endpoint] = card.tcpEnrollment;
    peers.putIfAbsent('${card.id}|$endpoint', () => card);
  }
  final nodes = <String>{};
  for (final node in preferred.dhtBootstrap.followedBy(fallback.dhtBootstrap)) {
    if (nodes.length >= maxDhtBootstrapEntries) break;
    nodes.add(node);
  }
  return BootstrapConfig(
    peers: List<PeerCard>.unmodifiable(peers.values),
    dhtBootstrap: List<String>.unmodifiable(nodes),
  );
}
