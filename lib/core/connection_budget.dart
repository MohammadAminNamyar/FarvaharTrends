import 'dart:math';

enum TrafficResource {
  ingressBytes,
  ingressFrames,
  egressBytes,
  requests,
  channels,
  policies,
  contacts,
}

/// Fixed aggregate limits with a protected share for each live connection.
/// Half of each allowance is shared; the rest is reserved across [capacity]
/// slots. Free slots retain their spending until the engine's window resets,
/// so replacing a connection or its identity cannot mint additional allowance.
/// This does not authenticate participants or guarantee admission to a full pool.
class ConnectionBudget {
  ConnectionBudget({
    required this.capacity,
    required Map<TrafficResource, int> limits,
  }) : limits = Map.unmodifiable(limits),
       _slots = List.generate(capacity, (_) => _BudgetSlot()) {
    if (capacity <= 0 || limits.values.any((limit) => limit < capacity * 2)) {
      throw ArgumentError('Each resource needs a nonzero reserved share.');
    }
  }

  final int capacity;
  final Map<TrafficResource, int> limits;
  final List<_BudgetSlot> _slots;
  final Map<TrafficResource, int> _sharedSpent = {};
  int _window = 0;

  /// Use the engine's existing monotonic window boundary, not a second clock.
  void refreshWindow(int window) {
    if (window <= _window) return;
    _window = window;
    _sharedSpent.clear();
    for (final slot in _slots) {
      slot.spent.clear();
    }
  }

  ConnectionAllowance? acquire() {
    _BudgetSlot? selected;
    var leastUsed = double.infinity;
    for (final slot in _slots) {
      if (slot.owner != null) continue;
      final used = limits.keys.fold<double>(
        0,
        (total, resource) =>
            total + (slot.spent[resource] ?? 0) / _reserve(resource),
      );
      if (used < leastUsed) {
        leastUsed = used;
        selected = slot;
      }
    }
    if (selected == null) return null;
    final allowance = ConnectionAllowance._(this, selected);
    selected.owner = allowance;
    return allowance;
  }

  void release(ConnectionAllowance allowance) {
    if (_owns(allowance)) allowance._slot.owner = null;
  }

  bool spend(
    ConnectionAllowance allowance,
    TrafficResource resource,
    int count,
  ) {
    if (count < 0 || !limits.containsKey(resource)) {
      throw ArgumentError('Unknown resource or negative work.');
    }
    if (!_owns(allowance)) return false;
    final reserve = _reserve(resource);
    final sharedLeft =
        limits[resource]! - reserve * capacity - (_sharedSpent[resource] ?? 0);
    final reservedSpent = allowance._slot.spent[resource] ?? 0;
    if (count > sharedLeft + reserve - reservedSpent) return false;
    final shared = min(count, sharedLeft);
    _sharedSpent[resource] = (_sharedSpent[resource] ?? 0) + shared;
    allowance._slot.spent[resource] = reservedSpent + count - shared;
    return true;
  }

  bool _owns(ConnectionAllowance allowance) =>
      identical(allowance._pool, this) &&
      identical(allowance._slot.owner, allowance);
  int _reserve(TrafficResource resource) => limits[resource]! ~/ (2 * capacity);
}

class ConnectionAllowance {
  ConnectionAllowance._(this._pool, this._slot);
  final ConnectionBudget _pool;
  final _BudgetSlot _slot;
}

class _BudgetSlot {
  ConnectionAllowance? owner;
  final Map<TrafficResource, int> spent = {};
}
