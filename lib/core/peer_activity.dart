/// A local view of transport activity, independent of publisher identities.
const maxTemporaryPeerActivity = 200;
const peerActivityKinds = {'connected', 'disconnected', 'bulletin_verified'};
const _transports = {'ip', 'overlay', 'lan', 'wifiDirect', 'bluetooth'};

/// Allowlisted fields only: no addresses, content, channel keys or peer names.
/// Input is the app's local journal, in commit order (oldest first).
List<Map<String, dynamic>> temporaryPeerActivity(
  Iterable<Map<String, dynamic>> events,
) {
  final rows = <Map<String, dynamic>>[];
  for (final event in events) {
    final kind = event['kind'];
    final peerId = event['peerId'];
    final at = event['atWallMs'];
    if (!peerActivityKinds.contains(kind) ||
        peerId is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(peerId) ||
        at is! int ||
        at <= 0 ||
        at > 8640000000000000) {
      continue;
    }
    final transport = event['transport'] ?? event['receivedVia'];
    rows.add({
      'kind': kind,
      'peerId': peerId,
      'atWallMs': at,
      'transport': _transports.contains(transport) ? transport : 'unknown',
    });
    if (rows.length > maxTemporaryPeerActivity) rows.removeAt(0);
  }
  // Journal order also works if this phone's wall clock moves backwards.
  return rows.reversed.toList();
}
