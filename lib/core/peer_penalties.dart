import 'dart:io';

/// In-memory abuse history, independent of the bounded contact cache.
/// Fingerprints and network prefixes never leave this process.
class PeerPenalties {
  PeerPenalties({required this.nowMs, required this.cooldownMs});
  final int Function() nowMs;
  final int cooldownMs;
  static const maxEntries = 64;
  static const strikeLifetimeMs = 5 * 60 * 1000;
  final Map<String, _Penalty> _entries = {};

  void _expire() {
    final now = nowMs();
    _entries.removeWhere(
      (_, p) => now >= p.startedMs + strikeLifetimeMs && now >= p.untilMs,
    );
  }

  bool cooling(String id) {
    _expire();
    return (_entries[id]?.untilMs ?? 0) > nowMs();
  }

  int get coolingCount {
    _expire();
    final now = nowMs();
    return _entries.values.where((p) => p.untilMs > now).length;
  }

  /// Returns true only when this strike starts a cooldown.
  bool strike(String id) {
    _expire();
    final now = nowMs();
    var penalty = _entries[id];
    if (penalty == null) {
      // Do not let identity churn displace an unexpired penalty. At saturation
      // the global handshake/traffic budgets still protect the receiver.
      if (_entries.length >= maxEntries) return false;
      penalty = _entries[id] = _Penalty(now);
    }
    if (now >= penalty.startedMs + strikeLifetimeMs) {
      penalty.strikes = 0;
      penalty.startedMs = now;
    }
    if (++penalty.strikes < 3) return false;
    penalty.strikes = 0;
    penalty.untilMs = now + cooldownMs;
    return true;
  }

  int get length {
    _expire();
    return _entries.length;
  }

  /// IPv6 privacy addresses within one /64 share the pre-TLS work budget.
  static String addressBucket(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type != InternetAddressType.IPv6) return address.address;
    // Normalize IPv4-mapped IPv6 as IPv4 too.
    if (bytes.take(10).every((b) => b == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return bytes.skip(12).join('.');
    }
    return '${bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}/64';
  }
}

class _Penalty {
  _Penalty(this.startedMs);
  int startedMs, strikes = 0, untilMs = 0;
}
