import 'dart:io';
import 'dart:typed_data';

/// An OS-enforced, on-link Wi-Fi transport. Never resolves names or uses the
/// default network. A missing implementation means no Wi-Fi in nearby mode.
abstract interface class LocalWifiTransport {
  /// [ingressPreface] and [wifiDirectIngressPreface] are the engine's loopback
  /// ingress secrets (see LoopbackPreface). The implementation writes them
  /// before TLS on every inbound flow it hands to those ports and must never
  /// log, report or transmit them.
  Future<void> start({
    required int tcpPort,
    required int ingressPort,
    required int wifiDirectIngressPort,
    required int discoveryPort,
    required Uint8List signedBeacon,
    required Uint8List ingressPreface,
    required Uint8List wifiDirectIngressPreface,
    required void Function(Uint8List beacon, InternetAddress source) onBeacon,
    required void Function(String? error) onState,
  });
  Future<void> updateBeacon(Uint8List signedBeacon);
  Future<void> probe(InternetAddress address);

  /// Returns a loopback proxy for one OS-bound socket together with the
  /// single-use preface the caller writes before TLS. The caller must still
  /// authenticate the peer with pinned TLS; the proxy never terminates TLS.
  Future<({InternetAddress host, int port, Uint8List preface})> open(
    InternetAddress host,
    int port,
  );
  Future<void> stop();
}
