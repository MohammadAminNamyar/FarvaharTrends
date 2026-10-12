import 'dart:io';
import 'dart:typed_data';

/// An OS-enforced, on-link Wi-Fi transport. Never resolves names or uses the
/// default network. A missing implementation means no Wi-Fi in nearby mode.
abstract interface class LocalWifiTransport {
  Future<void> start({
    required int tcpPort,
    required int ingressPort,
    required int wifiDirectIngressPort,
    required int discoveryPort,
    required Uint8List signedBeacon,
    required void Function(Uint8List beacon, InternetAddress source) onBeacon,
    required void Function(String? error) onState,
  });
  Future<void> updateBeacon(Uint8List signedBeacon);
  Future<void> probe(InternetAddress address);

  /// Returns a loopback proxy for one OS-bound socket. The caller must still
  /// authenticate the peer with pinned TLS; the proxy never terminates TLS.
  Future<({InternetAddress host, int port})> open(
    InternetAddress host,
    int port,
  );
  Future<void> stop();
}
