/// Monotonic, bounded recovery for an answering but isolated Internet worklet.
/// Only a live pinned application link counts as success, never a discovery
/// announcement or an unauthenticated transport connection.
class OverlayRecovery {
  OverlayRecovery({required this.nowMs});

  final int Function() nowMs;
  int? _isolatedSince;
  int? _healthySince;
  int _attempts = 0;

  int get attempts => _attempts;

  void networkChanged() {
    _isolatedSince = null;
    _healthySince = null;
    _attempts = 0;
  }

  bool shouldRestart({
    required bool connected,
    required bool offline,
    required bool rememberedPeers,
  }) {
    final now = nowMs();
    if (offline) {
      _isolatedSince = null;
      _healthySince = null;
      return false;
    }
    if (connected) {
      _isolatedSince = null;
      _healthySince ??= now;
      // Brief connections from a hostile/flapping peer cannot reset the
      // restart budget and turn an outage into a continuous restart loop.
      if (now - _healthySince! >= 90000) _attempts = 0;
      return false;
    }
    _healthySince = null;
    _isolatedSince ??= now;
    final seconds = [
      rememberedPeers ? 90 : 180,
      180,
      360,
      900,
    ][_attempts.clamp(0, 3)];
    if (now - _isolatedSince! < seconds * 1000) return false;
    _attempts = (_attempts + 1).clamp(0, 3);
    _isolatedSince = now;
    return true;
  }
}
