import 'dart:async';

import 'package:flutter/services.dart';

class PilotPlatform {
  static const _channel = MethodChannel('farvahartrends/device');
  static final _transportEvents =
      StreamController<Map<String, dynamic>>.broadcast();
  static bool _listening = false;
  // One native lease per Flutter engine. Reader updates and publisher-key
  // operations can overlap within that engine, so serialize them here before
  // entering the process-wide native queue shared with the other engine.
  static Future<void> _identityTail = Future<void>.value();
  static int _identityRequests = 0;
  static String? _identityToken;
  static Completer<void>? _identityReleased;
  static Future<String> acquireIdentityLease() async {
    if (_identityRequests >= 16) {
      throw StateError('Identity storage request queue is full.');
    }
    _identityRequests++;
    final previous = _identityTail;
    final released = Completer<void>();
    _identityTail = released.future;
    await previous;
    try {
      final token = await _channel.invokeMethod<String>('acquireIdentityLease');
      if (token == null || token.isEmpty) {
        throw StateError('Identity storage could not be locked.');
      }
      _identityToken = token;
      _identityReleased = released;
      return token;
    } catch (_) {
      _identityRequests--;
      released.complete();
      rethrow;
    }
  }

  static Future<void> releaseIdentityLease(String token) async {
    if (_identityToken != token || _identityReleased == null) {
      throw StateError('Identity storage lease is not owned.');
    }
    final released = _identityReleased!;
    _identityToken = null;
    _identityReleased = null;
    try {
      await _channel.invokeMethod('releaseIdentityLease', {'token': token});
    } finally {
      _identityRequests--;
      released.complete();
    }
  }

  /// A short-lived lease on the active Wi-Fi gateway, when supported.
  static Future<Map<String, dynamic>> refreshPhoneHelper(int port) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('refreshPhoneHelper', {
              'port': port,
            }) ??
            const {},
      );
  static Future<void> releasePhoneHelper() =>
      _channel.invokeMethod('releasePhoneHelper');

  /// Nearby-only IP transport. Native code pins each socket to a real local
  /// Wi-Fi link; these APIs never fall back to the device's default network.
  /// The ingress prefaces are engine-issued loopback secrets: they cross only
  /// this private channel and are never logged, reported or sent on the air.
  static Future<void> startLocalWifi({
    required int tcpPort,
    required int ingressPort,
    required int wifiDirectIngressPort,
    required Uint8List signedBeacon,
    required Uint8List ingressPreface,
    required Uint8List wifiDirectIngressPreface,
    int discoveryPort = 45872,
  }) => _channel.invokeMethod('startLocalWifi', {
    'tcpPort': tcpPort,
    'ingressPort': ingressPort,
    'wifiDirectIngressPort': wifiDirectIngressPort,
    'signedBeacon': signedBeacon,
    'ingressPreface': ingressPreface,
    'wifiDirectIngressPreface': wifiDirectIngressPreface,
    'discoveryPort': discoveryPort,
  });
  static Future<void> updateLocalWifiBeacon(Uint8List signedBeacon) => _channel
      .invokeMethod('updateLocalWifiBeacon', {'signedBeacon': signedBeacon});
  static Future<void> probeLocalWifi(String host, {int port = 45872}) =>
      _channel.invokeMethod('probeLocalWifi', {'host': host, 'port': port});
  static Future<Map<String, dynamic>> openLocalWifiPeer({
    required String host,
    required int port,
  }) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>('openLocalWifiPeer', {
          'host': host,
          'port': port,
        }) ??
        (throw StateError('Local Wi-Fi peer is unavailable.')),
  );
  static Future<void> stopLocalWifi() => _channel.invokeMethod('stopLocalWifi');

  static Stream<Map<String, dynamic>> get transportEvents {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'transportEvent' && call.arguments is Map) {
          _transportEvents.add(
            Map<String, dynamic>.from(call.arguments as Map),
          );
        }
      });
    }
    return _transportEvents.stream;
  }

  static Future<bool> saveChannelDocument(String contents, String name) async =>
      await _channel.invokeMethod<bool>('saveChannelDocument', {
        'contents': contents,
        'name': name,
      }) ??
      false;
  static Future<String?> openChannelDocument() =>
      _channel.invokeMethod<String>('openChannelDocument');
  static Future<Uint8List?> pickNewsImage() =>
      _channel.invokeMethod<Uint8List>('pickNewsImage');
  static Future<void> postNewsNotification(
    int count,
    String language, {
    bool alert = false,
  }) => _channel.invokeMethod('postNewsNotification', {
    'count': count,
    'language': language,
    'alert': alert,
  });
  static Future<void> requestNearbyPermissions() =>
      _channel.invokeMethod('requestNearbyPermissions');
  static Future<void> enableBluetooth() =>
      _channel.invokeMethod('enableBluetooth');
  static Future<void> startNearby({
    required String identityId,
    required Uint8List signedBeacon,
    required int tcpPort,
    required int bluetoothIngressPort,
    Uint8List? bluetoothIngressPreface,
  }) => _channel.invokeMethod('startNearby', {
    'identityId': identityId,
    'signedBeacon': signedBeacon,
    'tcpPort': tcpPort,
    'bluetoothIngressPort': bluetoothIngressPort,
    'bluetoothIngressPreface': bluetoothIngressPreface,
  });
  static Future<void> updateNearbyBeacon(Uint8List beacon) =>
      _channel.invokeMethod('updateNearbyBeacon', {'signedBeacon': beacon});
  static Future<void> refreshNearby() => _channel.invokeMethod('refreshNearby');
  static Future<void> allowWifiDirect(bool allowed) =>
      _channel.invokeMethod('allowWifiDirect', {'allowed': allowed});
  static Future<void> stopNearby() => _channel.invokeMethod('stopNearby');
  static Future<void> admitBluetooth(String routeId, bool accepted) =>
      _channel.invokeMethod('admitBluetooth', {
        'routeId': routeId,
        'accepted': accepted,
      });
  static Future<Map<String, dynamic>> state() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('state') ?? {},
      );
  static Future<void> requestNotifications() =>
      _channel.invokeMethod('requestNotifications');
  static Future<void> batterySettings() =>
      _channel.invokeMethod('batterySettings');
  static Future<void> setDiscoveryActive(bool active) =>
      _channel.invokeMethod('setDiscoveryActive', {'active': active});
  static Future<bool> exportReport(String report) async =>
      await _channel.invokeMethod<bool>('exportReport', {'report': report}) ??
      false;
}
