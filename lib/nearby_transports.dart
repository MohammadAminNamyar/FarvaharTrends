import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pilot_platform/pilot_platform.dart';

import 'core/peer_engine.dart';

/// Native radios only carry bytes and route hints. The engine authenticates
/// every peer before a native stream can enter the existing TLS protocol.
class NearbyTransports {
  NearbyTransports(
    this.engine, {
    required this.onError,
    required this.onState,
    NearbyRadioPlatform? platform,
  }) : _platform = platform ?? const AndroidNearbyRadioPlatform();
  final PeerEngine engine;
  final NearbyRadioPlatform _platform;
  final void Function(String?) onError;
  final void Function(String, Map<String, dynamic>) onState;
  final Map<String, String> _admitted = {};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _timer;
  Future<void> _queue = Future.value();
  Future<void> _lifecycle = Future.value();
  Future<void>? _starting, _stopping, _refresh;
  int _generation = 0;
  int _queued = 0;
  bool _running = false;
  bool _ready = false;
  String? _wifiRoute;
  final _withoutIp = Stopwatch();

  bool _current(int generation) => _running && generation == _generation;

  Future<void> _serial(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> start() {
    if (!_platform.supported) return Future.value();
    if (_running) return _starting ?? Future.value();
    _running = true;
    final generation = ++_generation;
    late final Future<void> tracked;
    tracked = _serial(() => _startSession(generation)).whenComplete(() {
      if (identical(_starting, tracked)) _starting = null;
    });
    _starting = tracked;
    return tracked;
  }

  Future<void> _startSession(int generation) async {
    if (!_current(generation)) return;
    _withoutIp.reset();
    _withoutIp.start();
    _subscription = _platform.events.listen((event) {
      if (!_current(generation) || _queued >= 32) return;
      _queued++;
      _queue = _queue
          .then((_) async {
            if (_current(generation)) await _handle(event, generation);
          })
          .catchError((Object _) {
            if (_current(generation)) onError('nearby_event_rejected');
          })
          .whenComplete(() => _queued--);
    });
    try {
      final snapshot = await engine.snapshot();
      if (!_current(generation)) return;
      await _platform.start(
        identityId: engine.identity.id,
        signedBeacon: engine.createDiscoveryBeacon(),
        tcpPort: snapshot['listenPort'] as int,
        bluetoothIngressPort: engine.bluetoothIngressPort ?? 0,
      );
      if (!_current(generation)) return;
      _ready = true;
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(refresh());
      });
      onError(null);
    } catch (_) {
      if (_current(generation)) {
        onError('nearby_start_unavailable');
        _running = false;
        _ready = false;
        ++_generation;
        final subscription = _subscription;
        _subscription = null;
        await _stopResources(subscription, _queue, _refresh);
      }
    }
  }

  Future<void> refresh() {
    if (!_running || !_ready) return Future.value();
    final pending = _refresh;
    if (pending != null) return pending;
    late final Future<void> tracked;
    tracked = _refreshSession(_generation).whenComplete(() {
      if (identical(_refresh, tracked)) _refresh = null;
    });
    _refresh = tracked;
    return tracked;
  }

  Future<void> _refreshSession(int generation) async {
    try {
      final snapshot = await engine.snapshot();
      if (!_current(generation)) return;
      final counts = snapshot['activeTransportCounts'] as Map? ?? const {};
      if ((counts['ip'] as int? ?? 0) + (counts['lan'] as int? ?? 0) > 0) {
        _withoutIp.reset();
      }
      await _platform.allowWifiDirect(
        !engine.nearbyOnly && _withoutIp.elapsed >= const Duration(seconds: 20),
      );
      if (!_current(generation)) return;
      await _platform.updateBeacon(engine.createDiscoveryBeacon());
      if (!_current(generation)) return;
      await _platform.refresh();
    } catch (_) {
      if (_current(generation)) onError('nearby_refresh_unavailable');
    }
  }

  Future<void> _handle(Map<String, dynamic> event, int generation) async {
    final type = event['type'];
    final transport = event['transport'];
    if (transport != 'wifiDirect' && transport != 'bluetooth') return;
    // Wi-Fi Direct has no bindable Android Network on supported versions.
    // Nearby only keeps the stricter Bluetooth + actual LAN Wi-Fi boundary.
    if (engine.nearbyOnly && transport == 'wifiDirect') return;
    if (type == 'state' || type == 'status') {
      onState(transport, event);
    }
    final route = event['routeId'] as String?;
    if (event['transport'] == 'wifiDirect' && type == 'state') {
      if (event['appGroup'] != true || event['groupFormed'] != true) {
        if (_wifiRoute != null) await engine.removeNativeRoute(_wifiRoute!);
        _wifiRoute = null;
        return;
      }
      final host = InternetAddress.tryParse('${event['groupOwnerHost'] ?? ''}');
      if (host == null ||
          host.isLoopback ||
          host.isMulticast ||
          route == null ||
          route.length > 160) {
        return;
      }
      if (_wifiRoute != null && _wifiRoute != route) {
        await engine.removeNativeRoute(_wifiRoute!);
      }
      if (!_current(generation)) return;
      _wifiRoute = route;
      await engine.probeDiscoveryAddress(
        host,
        transport: PeerTransport.wifiDirect,
        routeId: route,
        localAddresses: event['localAddresses'] is List
            ? (event['localAddresses'] as List)
                  .whereType<Map>()
                  .take(8)
                  .map((value) => Map<String, dynamic>.from(value))
                  .toList()
            : const [],
      );
      return;
    }
    if (event['transport'] != 'bluetooth' ||
        route == null ||
        route.length > 160) {
      return;
    }
    if (type == 'peerDiscovered') {
      var accepted = false;
      try {
        final encoded = event['beaconBase64'];
        if (encoded is! String || encoded.length > 5500) {
          throw const FormatException('Invalid beacon');
        }
        final admission = await engine.admitNativePeer(
          signedBeacon: base64Decode(encoded),
          routeId: route,
          transport: PeerTransport.bluetooth,
        );
        accepted = admission.accepted && admission.peerId != null;
        if (accepted && !_current(generation)) {
          await engine.removeNativeRoute(route);
          accepted = false;
        }
        if (accepted) {
          // The native bridge has exactly one active BLE stream. A dropped
          // endpointLost event must not leave old route capabilities retained.
          for (final oldRoute in _admitted.keys.toList()) {
            if (oldRoute != route) {
              await engine.removeNativeRoute(oldRoute);
              _admitted.remove(oldRoute);
            }
          }
          if (_current(generation)) {
            _admitted[route] = admission.peerId!;
          } else {
            await engine.removeNativeRoute(route);
            accepted = false;
          }
        }
      } catch (_) {
        accepted = false;
        onError('nearby_identity_rejected');
      }
      await _platform.admitBluetooth(route, accepted && _current(generation));
    } else if (type == 'endpointReady') {
      final peerId = _admitted[route];
      final host = InternetAddress.tryParse('${event['host'] ?? ''}');
      final port = event['port'];
      if (peerId == null ||
          host == null ||
          !host.isLoopback ||
          port is! int ||
          port < 1 ||
          port > 65535) {
        await _platform.admitBluetooth(route, false);
        return;
      }
      await engine.registerNativeEndpoint(
        peerId: peerId,
        routeId: route,
        transport: PeerTransport.bluetooth,
        host: host,
        port: port,
      );
    } else if (type == 'endpointLost') {
      _admitted.remove(route);
      await engine.removeNativeRoute(route);
    }
  }

  Future<void> stop() {
    if (!_running && _stopping != null) return _stopping!;
    _running = false;
    _ready = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    final queue = _queue, refresh = _refresh;
    late final Future<void> tracked;
    tracked = _serial(() => _stopResources(subscription, queue, refresh))
        .whenComplete(() {
          if (identical(_stopping, tracked)) _stopping = null;
        });
    _stopping = tracked;
    return tracked;
  }

  Future<void> _stopResources(
    StreamSubscription<Map<String, dynamic>>? subscription,
    Future<void> queue,
    Future<void>? refresh,
  ) async {
    await subscription?.cancel();
    await queue;
    await refresh;
    try {
      if (_platform.supported) await _platform.stop();
    } catch (_) {
      onError('nearby_stop_unavailable');
    }
    for (final route in [..._admitted.keys, ?_wifiRoute]) {
      try {
        await engine.removeNativeRoute(route);
      } catch (_) {
        onError('nearby_route_cleanup_unavailable');
      }
    }
    _admitted.clear();
    _wifiRoute = null;
  }
}

/// Injectable platform boundary for host lifecycle tests; never authenticates
/// peers. Production uses only the Android MethodChannel implementation.
abstract interface class NearbyRadioPlatform {
  bool get supported;
  Stream<Map<String, dynamic>> get events;
  Future<void> start({
    required String identityId,
    required Uint8List signedBeacon,
    required int tcpPort,
    required int bluetoothIngressPort,
  });
  Future<void> updateBeacon(Uint8List beacon);
  Future<void> allowWifiDirect(bool allowed);
  Future<void> refresh();
  Future<void> stop();
  Future<void> admitBluetooth(String routeId, bool accepted);
}

class AndroidNearbyRadioPlatform implements NearbyRadioPlatform {
  const AndroidNearbyRadioPlatform();
  @override
  bool get supported => Platform.isAndroid;
  @override
  Stream<Map<String, dynamic>> get events => PilotPlatform.transportEvents;
  @override
  Future<void> start({
    required String identityId,
    required Uint8List signedBeacon,
    required int tcpPort,
    required int bluetoothIngressPort,
  }) => PilotPlatform.startNearby(
    identityId: identityId,
    signedBeacon: signedBeacon,
    tcpPort: tcpPort,
    bluetoothIngressPort: bluetoothIngressPort,
  );
  @override
  Future<void> updateBeacon(Uint8List beacon) =>
      PilotPlatform.updateNearbyBeacon(beacon);
  @override
  Future<void> allowWifiDirect(bool allowed) =>
      PilotPlatform.allowWifiDirect(allowed);
  @override
  Future<void> refresh() => PilotPlatform.refreshNearby();
  @override
  Future<void> stop() => PilotPlatform.stopNearby();
  @override
  Future<void> admitBluetooth(String routeId, bool accepted) =>
      PilotPlatform.admitBluetooth(routeId, accepted);
}
