/// Local OS network handles distinguish address/interface changes even when
/// both networks are Wi-Fi. Null means sampling unavailable, not offline.
class NetworkEpoch {
  String? _last;
  bool observe(String? key) {
    if (key == null) return false;
    final changed = _last != null && key != _last;
    _last = key;
    return changed;
  }
}
