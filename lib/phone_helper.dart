import 'dart:async';

import 'package:pilot_platform/pilot_platform.dart';

import 'core/peer_engine.dart';

/// Optional phone-to-phone TCP fallback. Unsupported routers stay unchanged.
/// Active only in All networks; leases expire within two minutes after a crash.
class PhoneHelper {
  PhoneHelper(this.engine);
  final PeerEngine engine;
  Timer? _timer;
  Future<void>? _pending;
  bool _running = false;
  int _generation = 0;
  String? _leaseId;

  Future<void> start() async {
    if (_running || engine.nearbyOnly) return;
    _running = true;
    ++_generation;
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    refresh();
  }

  void refresh() {
    if (!_running || _pending != null) return;
    final generation = _generation;
    late final Future<void> pending;
    pending = _refresh(generation).whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    });
    _pending = pending;
  }

  Future<void> _refresh(int generation) async {
    try {
      final lease = await PilotPlatform.refreshPhoneHelper(engine.boundPort);
      if (!_running || _generation != generation) return;
      if (lease['state'] != 'leased') {
        if (_leaseId != null) {
          await engine.withdrawHelperEndpoint();
          _leaseId = null;
        }
        return;
      }
      if (lease['leaseId'] == _leaseId) return;
      final host = lease['host'],
          port = lease['port'],
          remaining = lease['remainingMs'];
      if (host is! String ||
          port is! int ||
          remaining is! int ||
          remaining < 1000 ||
          remaining > 120000) {
        return;
      }
      await engine.publishHelperEndpoint(
        host: host,
        port: port,
        lifetimeMs: remaining,
      );
      if (_running && generation == _generation) {
        _leaseId = lease['leaseId'] as String;
      }
    } catch (_) {
      if (_leaseId != null) {
        try {
          await engine.withdrawHelperEndpoint();
        } catch (_) {}
        _leaseId = null;
      }
    }
  }

  Future<void> stop() async {
    _running = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    await _pending;
    try {
      await engine.withdrawHelperEndpoint();
    } finally {
      await PilotPlatform.releasePhoneHelper();
      _leaseId = null;
    }
  }
}
