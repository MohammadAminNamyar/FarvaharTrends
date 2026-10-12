import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pilot_platform/pilot_platform.dart';

import 'core/local_wifi_transport.dart';

/// Android transports opaque TLS bytes over native sockets bound to a real
/// on-link Wi-Fi network. Dart never opens a remote socket in nearby mode.
class AndroidLocalWifiTransport implements LocalWifiTransport {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  int _generation = 0;
  int _discoveryPort = 45872;

  @override
  Future<void> start({
    required int tcpPort,
    required int ingressPort,
    required int wifiDirectIngressPort,
    required int discoveryPort,
    required Uint8List signedBeacon,
    required void Function(Uint8List, InternetAddress) onBeacon,
    required void Function(String?) onState,
  }) async {
    await stop();
    final generation = ++_generation;
    _discoveryPort = discoveryPort;
    _subscription = PilotPlatform.transportEvents.listen((event) {
      if (generation != _generation) return;
      if (event['type'] == 'localWifiBeacon') {
        final bytes = event['signedBeacon'];
        final address = InternetAddress.tryParse(
          event['host'] as String? ?? '',
        );
        if (bytes is Uint8List && bytes.length <= 4096 && address != null) {
          onBeacon(bytes, address);
        }
      } else if (event['type'] == 'localWifiState') {
        onState(
          event['wifiAvailable'] == true || event['wifiDirectAvailable'] == true
              ? null
              : 'local_wifi_unavailable',
        );
      }
    });
    try {
      await PilotPlatform.startLocalWifi(
        tcpPort: tcpPort,
        ingressPort: ingressPort,
        wifiDirectIngressPort: wifiDirectIngressPort,
        discoveryPort: discoveryPort,
        signedBeacon: signedBeacon,
      );
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> updateBeacon(Uint8List signedBeacon) =>
      PilotPlatform.updateLocalWifiBeacon(signedBeacon);

  @override
  Future<void> probe(InternetAddress address) =>
      PilotPlatform.probeLocalWifi(address.address, port: _discoveryPort);

  @override
  Future<({InternetAddress host, int port})> open(
    InternetAddress host,
    int port,
  ) async {
    final result = await PilotPlatform.openLocalWifiPeer(
      host: host.address,
      port: port,
    );
    final proxy = InternetAddress.tryParse(result['host'] as String? ?? '');
    final proxyPort = result['port'];
    if (proxy == null ||
        !proxy.isLoopback ||
        proxyPort is! int ||
        proxyPort < 1 ||
        proxyPort > 65535) {
      throw StateError('Invalid local Wi-Fi proxy.');
    }
    return (host: proxy, port: proxyPort);
  }

  @override
  Future<void> stop() async {
    ++_generation;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await PilotPlatform.stopLocalWifi();
  }
}
