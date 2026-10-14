import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/loopback_preface.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';

/// Loopback proxies are reachable by any app on the device. These checks race
/// hostile local callers against the legitimate one on every preface reader.
void main() {
  final sockets = <Socket>[];
  tearDown(() {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
  });
  Future<Socket> dial(int port, List<int> bytes) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 2),
    );
    sockets.add(socket);
    if (bytes.isNotEmpty) {
      socket.add(bytes);
      await socket.flush();
    }
    return socket;
  }

  Uint8List flipped(Uint8List token) =>
      Uint8List.fromList(token.map((value) => value ^ 0x80).toList());

  /// Resolves when the listener has closed the caller's socket.
  Future<bool> droppedByListener(Socket socket) {
    final done = Completer<bool>();
    socket.listen(
      (_) {},
      onError: (Object _) {
        if (!done.isCompleted) done.complete(true);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(true);
      },
    );
    return done.future.timeout(const Duration(seconds: 4), onTimeout: () => false);
  }

  group('tokens', () {
    test('are 32 random bytes compared in constant time', () {
      final token = LoopbackPreface.newToken();
      expect(LoopbackPreface.valid(token), true);
      expect(LoopbackPreface.valid(Uint8List(31)), false);
      expect(LoopbackPreface.valid(Uint8List(33)), false);
      expect(LoopbackPreface.valid(token.toList()), false);
      expect(token, isNot(equals(LoopbackPreface.newToken())));
      expect(LoopbackPreface.matches(token, Uint8List.fromList(token)), true);
      expect(LoopbackPreface.matches(token, flipped(token)), false);
      expect(LoopbackPreface.matches(token, token.sublist(0, 31)), false);
    });
  });

  group('single-use flow (acceptOnce)', () {
    test(
      'wrong, partial and empty prefaces are dropped; the legitimate caller still succeeds',
      () async {
        final token = LoopbackPreface.newToken();
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final flow = LoopbackPreface.acceptOnce(
          server,
          token,
          deadline: const Duration(seconds: 6),
          readTimeout: const Duration(milliseconds: 400),
        );
        final wrong = await dial(server.port, flipped(token));
        expect(await droppedByListener(wrong), true);
        final partial = await dial(server.port, token.sublist(0, 10));
        expect(await droppedByListener(partial), true);
        final silent = await dial(server.port, const []);
        expect(await droppedByListener(silent), true);
        final legitimate = await dial(server.port, [...token, 0x16, 0x03, 0x01]);
        final accepted = await flow;
        expect(accepted.socket.remotePort, legitimate.port);
        final first = await accepted.data.first.timeout(const Duration(seconds: 2));
        expect(first, [0x16, 0x03, 0x01]);
        accepted.socket.destroy();
      },
    );

    test('a replayed preface after use is refused', () async {
      final token = LoopbackPreface.newToken();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      final flow = LoopbackPreface.acceptOnce(
        server,
        token,
        deadline: const Duration(seconds: 6),
      );
      await dial(port, token);
      final accepted = await flow;
      // The listener is closed on success, so the same token is worthless.
      var refused = false;
      try {
        final replay = await dial(port, token);
        refused = await droppedByListener(replay);
      } on SocketException {
        refused = true;
      }
      expect(refused, true);
      accepted.socket.destroy();
    });

    test(
      'a late legitimate caller past the flow deadline reaches nothing and queues stay bounded',
      () async {
        final token = LoopbackPreface.newToken();
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = server.port;
        final flow = LoopbackPreface.acceptOnce(
          server,
          token,
          deadline: const Duration(milliseconds: 300),
        );
        await expectLater(flow, throwsA(isA<TimeoutException>()));
        var refused = false;
        try {
          final late = await dial(port, token);
          refused = await droppedByListener(late);
        } on SocketException {
          refused = true;
        }
        expect(refused, true);
      },
    );

    test('failed attempts are bounded and abandon the flow', () async {
      final token = LoopbackPreface.newToken();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final flow = LoopbackPreface.acceptOnce(
        server,
        token,
        deadline: const Duration(seconds: 10),
        readTimeout: const Duration(milliseconds: 200),
      );
      for (var i = 0; i < LoopbackPreface.maxAttempts; i++) {
        final hostile = await dial(server.port, Uint8List(LoopbackPreface.length));
        expect(await droppedByListener(hostile), true);
      }
      await expectLater(flow, throwsA(isA<SocketException>()));
    });
  });

  group('engine loopback ingress (RawSocket reader)', () {
    late Identity local, remote;
    late Directory directory;
    late PeerEngine engine;
    setUpAll(() {
      local = Identity.generate();
      remote = Identity.generate();
    });
    setUp(() async {
      final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
      await parent.create(recursive: true);
      directory = await parent.createTemp('loopback-preface-');
      engine = PeerEngine(
        directory: directory,
        identity: local,
        listenPort: 0,
        discoveryPort: 0,
        enableLanDiscovery: false,
        enableUdpDiscovery: false,
        deviceState: () async => {},
        onStatus: (_) {},
      );
      await engine.start(activeMode: false);
      await engine.admitNativePeer(
        signedBeacon: PeerDiscovery.beacon(remote, 45871),
        routeId: 'ble-route',
        transport: PeerTransport.bluetooth,
      );
    });
    tearDown(() async {
      await engine.stop();
      await directory.delete(recursive: true);
    });
    Future<void> until(Future<bool> Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!await condition()) {
        if (DateTime.now().isAfter(deadline)) fail('Condition timed out.');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    Future<SecureSocket> tls(Socket socket) => SecureSocket.secure(
      socket,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(remote.certPem))
        ..usePrivateKeyBytes(utf8.encode(remote.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(local.certPem)),
      onBadCertificate: (certificate) =>
          Identity.certificateId(certificate.pem) == local.id,
    ).timeout(const Duration(seconds: 3));

    test(
      'wrong and partial prefaces are rejected before TLS; the native caller with the secret connects',
      () async {
        final port = engine.bluetoothIngressPort!;
        final secret = engine.bluetoothIngressPreface!;
        final wrong = await dial(port, flipped(secret));
        expect(await droppedByListener(wrong), true);
        final partial = await dial(port, secret.sublist(0, 5));
        await partial.close();
        expect(await droppedByListener(partial), true);
        await until(() async => (await engine.snapshot())['rejectedCount'] >= 2);
        expect((await engine.snapshot())['connectedCount'], 0);
        // A TLS client without the preface never reaches the handshake.
        await expectLater(
          dial(port, const []).then(tls),
          throwsA(anything),
        );
        final legitimate = await dial(port, secret);
        final secure = await tls(legitimate);
        sockets.add(secure);
        secure.listen((_) {}, onError: (Object _) {});
        await until(() async => (await engine.snapshot())['connectedCount'] == 1);
        expect(
          ((await engine.snapshot())['peers'] as List).single['transport'],
          'bluetooth',
        );
      },
    );

    test('an engine restart invalidates every ingress secret', () async {
      final previousPort = engine.bluetoothIngressPort!;
      final previous = engine.bluetoothIngressPreface!;
      await engine.stop();
      expect(engine.bluetoothIngressPreface, null);
      await engine.start(activeMode: false);
      expect(engine.bluetoothIngressPreface, isNot(equals(previous)));
      // Whether or not the OS reuses the port, the old secret opens nothing.
      if (engine.bluetoothIngressPort == previousPort) {
        final stale = await dial(previousPort, previous);
        expect(await droppedByListener(stale), true);
      }
    });

    test('secrets never appear in snapshots or events', () async {
      final secret = engine.bluetoothIngressPreface!;
      final snapshot = jsonEncode(await engine.snapshot());
      expect(snapshot, isNot(contains(base64Encode(secret))));
      expect(snapshot, isNot(contains(secret.join(','))));
    });
  });
}
