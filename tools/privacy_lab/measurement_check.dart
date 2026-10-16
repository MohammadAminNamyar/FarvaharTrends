// Checks that the measurement apparatus itself counts what it claims.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'measurement.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final peer = Completer<Socket>();
  final subscription = server.listen(peer.complete);
  final meter = await MeteredLink.start(server.port);
  final client = await Socket.connect(InternetAddress.loopbackIPv4, meter.port);
  final accepted = await peer.future;
  var atClient = 0;
  var atServer = 0;
  final receivedUp = Completer<void>();
  final receivedDown = Completer<void>();
  client.listen((bytes) {
    atClient += bytes.length;
    if (atClient == 1379) receivedDown.complete();
  });
  accepted.listen((bytes) {
    atServer += bytes.length;
    if (atServer == 3217) receivedUp.complete();
  });
  try {
    // Several writes can be merged or split by TCP; counting must be invariant.
    client.add(Uint8List(19));
    client.add(Uint8List(3198));
    accepted.add(Uint8List(1000));
    accepted.add(Uint8List(379));
    await Future.wait([receivedUp.future, receivedDown.future])
        .timeout(const Duration(seconds: 5));
    require(meter.upstreamBytes == 3217, 'Wrong upstream byte count');
    require(meter.downstreamBytes == 1379, 'Wrong downstream byte count');
    require(meter.acceptedConnections == 1, 'Wrong connection count');
    require(meter.errors.isEmpty, 'Proxy errored');
    final cpu = ProcessCpu();
    final before = cpu.readMs();
    final wall = Stopwatch()..start();
    var result = 0;
    while (wall.elapsedMilliseconds < 150) {
      for (var i = 0; i < 10000; i++) {
        result = (result + i) & 0x7fffffff;
      }
    }
    final consumed = cpu.readMs() - before;
    require(consumed > 0, 'CPU sampler did not observe busy work ($result)');
    stdout.writeln(
      'PASS: exact bidirectional TCP bytes, one connection, process CPU increases',
    );
  } finally {
    await meter.close();
    client.destroy();
    accepted.destroy();
    await subscription.cancel();
    await server.close();
  }
}
