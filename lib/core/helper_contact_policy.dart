import 'dart:io';

import 'peer_contact.dart';

/// Local admission only: a signature is an address claim, not reachability.
/// Bounds do not make an account-free network Sybil-proof.
class HelperContactPolicy {
  static const maxPending = 4;
  static const maxPerSource = 4;
  static const maxPerPrefix = 4;
  static const pendingLifetimeMs = 60000;
  final Map<String, _Claim> _claims = {};

  bool canAccept(PeerContact contact, String source) {
    final old = _claims[contact.id];
    if (old != null && old.contact.issuedAtMs >= contact.issuedAtMs) {
      return false;
    }
    final others = _claims.values.where((c) => c.contact.id != contact.id);
    final pending = others.where((c) => !c.verified && !c.cached).length;
    final sameEndpoint = old != null && _sameEndpoint(old.contact, contact);
    return ((sameEndpoint && (old.verified || old.cached)) ||
            pending < maxPending) &&
        others.where((c) => c.source == (old?.source ?? source)).length <
            maxPerSource &&
        others.where((c) => _prefix(c.contact) == _prefix(contact)).length <
            maxPerPrefix;
  }

  void record(PeerContact contact, String source, int nowMs) {
    final old = _claims[contact.id];
    _claims[contact.id] = _Claim(
      contact,
      old?.source ?? source,
      // Repeating a signed hint must not keep an unreachable slot alive.
      old == null ||
              ((old.verified || old.cached) &&
                  !_sameEndpoint(old.contact, contact))
          ? nowMs
          : old.firstSeenMs,
      old != null && old.verified && _sameEndpoint(old.contact, contact),
      old != null && old.cached && _sameEndpoint(old.contact, contact),
    );
  }

  void restore(PeerContact contact, int nowMs) {
    _claims[contact.id] = _Claim(contact, contact.id, nowMs, false, true);
  }

  bool confirm(String id, String host, int port) {
    final claim = _claims[id];
    if (claim == null ||
        claim.verified ||
        claim.contact.peer.host != host ||
        claim.contact.peer.port != port) {
      return false;
    }
    claim.verified = true;
    return true;
  }

  bool isVerified(String id) => _claims[id]?.verified ?? false;
  bool isDurable(String id) => isVerified(id) || (_claims[id]?.cached ?? false);
  void remove(String id) => _claims.remove(id);
  void clear() => _claims.clear();

  List<String> expirePending(int nowMs) {
    final stale = _claims.entries
        .where(
          (e) =>
              !e.value.verified &&
              !e.value.cached &&
              nowMs - e.value.firstSeenMs >= pendingLifetimeMs,
        )
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      _claims.remove(id);
    }
    return stale;
  }

  static bool _sameEndpoint(PeerContact a, PeerContact b) =>
      a.peer.host == b.peer.host && a.peer.port == b.peer.port;

  // IPv4 /24 and IPv6 /48: repeated identities on one range share a budget.
  static String _prefix(PeerContact contact) {
    final bytes = InternetAddress(contact.peer.host).rawAddress;
    return '${bytes.length}:${bytes.take(bytes.length == 4 ? 3 : 6).join('.')}';
  }
}

class _Claim {
  _Claim(
    this.contact,
    this.source,
    this.firstSeenMs,
    this.verified,
    this.cached,
  );
  final PeerContact contact;
  final String source;
  final int firstSeenMs;
  bool verified;
  final bool cached;
}
