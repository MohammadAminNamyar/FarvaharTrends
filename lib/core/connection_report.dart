/// A manually shared diagnostic report. Keep this allowlist independent of
/// the internal snapshot: snapshots also contain news, addresses and keys.
Map<String, dynamic> connectionReport({
  required Map<String, dynamic> snapshot,
  required Map<String, dynamic> device,
  required bool running,
  required bool activeMode,
  required String deliveryMode,
  String? connectionId,
}) {
  String? choice(Object? value, Set<String> allowed) =>
      value is String && allowed.contains(value) ? value : null;
  int? count(Object? value, int limit) =>
      value is int && value >= 0 ? value.clamp(0, limit) : null;
  final overlay = snapshot['overlay'] is Map
      ? snapshot['overlay'] as Map
      : const {};
  final transports = snapshot['activeTransportCounts'] is Map
      ? snapshot['activeTransportCounts'] as Map
      : const {};
  final version = device['appVersion'];
  final id = connectionId ?? snapshot['identityId'];
  final network = choice(device['network'], {
    'wifi',
    'cellular',
    'none',
    'other',
    'unknown',
  });
  final state = choice(overlay['state'], {
    'starting',
    'discovering',
    'connecting',
    'connected',
    'retrying',
    'disabled',
    'stopped',
    'error',
  });
  final stage = choice(overlay['discoveryStage'], {
    'bootstrapping',
    'connecting',
    'discovering',
  });
  final error = choice(overlay['error'], {
    'network_changed',
    'worklet_start_failed',
    'worklet_unresponsive',
    'discovery_stalled',
  });
  return {
    'reportVersion': 1,
    if (version is String &&
        RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}(?:\+\d{1,6})?$').hasMatch(version))
      'appVersion': version,
    if (id is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      'connectionId': id.substring(0, 12),
    'running': running,
    'activeMode': activeMode,
    if ({'allNetworks', 'nearbyOnly'}.contains(deliveryMode))
      'deliveryMode': deliveryMode,
    'network': ?network,
    for (final flag in [
      'internetValidated',
      'screenOn',
      'isLocked',
      'deviceIdle',
      'powerSave',
    ])
      if (device[flag] is bool) flag: device[flag],
    if (count(snapshot['connectedCount'], 8) case final int value)
      'connectedCount': value,
    'transports': {
      for (final transport in [
        'overlay',
        'ip',
        'lan',
        'wifiDirect',
        'bluetooth',
      ])
        if (count(transports[transport], 8) case final int value)
          transport: value,
    },
    'overlay': {
      'state': ?state,
      'discoveryStage': ?stage,
      'error': ?error,
      for (final flag in [
        'dhtOnline',
        'dhtFirewalled',
        'dhtRandomized',
        'reachableHelper',
      ])
        if (overlay[flag] is bool) flag: overlay[flag],
      for (final field in ['cachedRoutingCount', 'cachedPeerCount'])
        if (count(overlay[field], 256) case final int value) field: value,
      if (count(overlay['discoveryRefreshes'], 1000000) case final int value)
        'discoveryRefreshes': value,
      if (count(overlay['recoveryAttempts'], 3) case final int value)
        'recoveryAttempts': value,
    },
  };
}
