import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_discovery.dart';

void main() {
  late Identity local;
  late Identity remote;
  setUpAll(() {
    local = Identity.generate();
    remote = Identity.generate();
  });

  test(
    'bind conflict recovers automatically and admits fresh signed UDP',
    () async {
      final blocker = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
        reusePort: false,
      );
      final port = blocker.port;
      final diagnostics = <String?>[];
      final received = <PeerCard>[];
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: port,
        multicast: false,
        maintenanceInterval: const Duration(milliseconds: 100),
        onPeer: received.add,
        onDiagnostic: diagnostics.add,
      );
      RawDatagramSocket? sender;
      try {
        await discovery.start();
        expect(discovery.localPort, isNull);
        expect(diagnostics.single, startsWith('discovery_bind_failed'));
        expect(diagnostics.single, isNot(contains('127.0.0.1')));
        // Repeated native group hints must not cause a tight failing bind loop.
        final elapsed = Stopwatch()..start();
        for (var i = 0; i < 20; i++) {
          discovery.probe(InternetAddress.loopbackIPv4);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // Under a busy full-suite run a 20 ms timer can resume after the
        // legitimate 100 ms maintenance retry. Bound attempts by elapsed time.
        expect(
          diagnostics.length,
          lessThanOrEqualTo(1 + elapsed.elapsedMilliseconds ~/ 100),
        );
        blocker.close();
        await until(() => discovery.localPort == port);
        sender = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        sender.send(
          PeerDiscovery.beacon(remote, 32123),
          InternetAddress.loopbackIPv4,
          port,
        );
        await until(() => received.isNotEmpty);
        expect(received.single.id, remote.id);
        expect(received.single.port, 32123);
        expect(diagnostics.last, isNull);
      } finally {
        blocker.close();
        sender?.close();
        await discovery.stop();
      }
    },
  );

  test('one signed beacon admits alternate source addresses but not same-route replay', () async {
    final received = <PeerCard>[];
    final discovery = PeerDiscovery(
      identity: local,
      listenPort: 45871,
      port: 0,
      multicast: false,
      onPeer: received.add,
      onDiagnostic: (_) {},
    );
    final first = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final alternate = await RawDatagramSocket.bind(
      InternetAddress('127.0.0.2'),
      0,
    );
    try {
      await discovery.start();
      final bytes = PeerDiscovery.beacon(remote, 32123);
      first.send(bytes, InternetAddress.loopbackIPv4, discovery.localPort!);
      await until(() => received.length == 1);
      first.send(bytes, InternetAddress.loopbackIPv4, discovery.localPort!);
      alternate.send(bytes, InternetAddress.loopbackIPv4, discovery.localPort!);
      await until(() => received.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received.map((peer) => peer.id).toSet(), {remote.id});
      expect(received.map((peer) => peer.host).toSet(), {
        '127.0.0.1',
        '127.0.0.2',
      });
      expect(received, hasLength(2));
    } finally {
      first.close();
      alternate.close();
      await discovery.stop();
    }
  });

  test(
    'stop during bind cannot resurrect a socket; a later session works',
    () async {
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: 0,
        multicast: false,
        maintenanceInterval: const Duration(milliseconds: 30),
        onPeer: (_) {},
        onDiagnostic: (_) {},
      );
      try {
        final starting = discovery.start();
        final stopping = discovery.stop();
        await Future.wait([starting, stopping]);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(discovery.localPort, isNull);
        await discovery.start();
        final nextPort = discovery.localPort;
        expect(nextPort, isNotNull);
        await Future.wait(List.generate(20, (_) => discovery.start()));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(discovery.localPort, nextPort);
      } finally {
        await discovery.stop();
      }
    },
  );

  test(
    'immediate stop and reopen preserves only the replacement session',
    () async {
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: 0,
        multicast: false,
        maintenanceInterval: const Duration(milliseconds: 30),
        onPeer: (_) {},
        onDiagnostic: (_) {},
      );
      try {
        final firstStart = discovery.start();
        final firstStop = discovery.stop();
        final secondStart = discovery.start();
        await Future.wait([firstStart, firstStop, secondStart]);
        final port = discovery.localPort;
        expect(port, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(discovery.localPort, port);
      } finally {
        await discovery.stop();
      }
      expect(discovery.localPort, isNull);
    },
  );

  test(
    'destination route errors preserve the bound listener and signed unicast',
    () async {
      final diagnostics = <String?>[];
      final received = <PeerCard>[];
      late _ErrorInjectingSocket bound;
      var binds = 0;
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: 0,
        multicast: false,
        maintenanceInterval: const Duration(milliseconds: 50),
        onPeer: received.add,
        onDiagnostic: diagnostics.add,
        socketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              binds++;
              bound = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  port,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              return bound;
            },
      );
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        await discovery.start();
        final port = discovery.localPort!;
        final networkCode = Platform.isWindows
            ? 10051
            : Platform.isMacOS || Platform.isIOS
            ? 51
            : 101;
        final hostCode = Platform.isWindows
            ? 10065
            : Platform.isMacOS || Platform.isIOS
            ? 65
            : 113;
        bound.injectStreamError(
          SocketException(
            'No network route',
            osError: OSError('', networkCode),
          ),
        );
        await until(
          () => diagnostics.contains(
            'discovery_route_unavailable_os_error_$networkCode',
          ),
        );
        bound.injectReceiveError(
          SocketException('No host route', osError: OSError('', hostCode)),
        );
        await until(
          () => diagnostics.contains(
            'discovery_route_unavailable_os_error_$hostCode',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(discovery.localPort, port);
        expect(binds, 1);
        expect(bound.closeCount, 0);
        sender.send(
          PeerDiscovery.beacon(remote, 32123),
          InternetAddress.loopbackIPv4,
          port,
        );
        await until(() => received.isNotEmpty);
        expect(received.single.id, remote.id);
        expect(received.single.port, 32123);
      } finally {
        sender.close();
        await discovery.stop();
      }
    },
  );

  test(
    'fatal socket errors still close and rebind on the retry schedule',
    () async {
      final diagnostics = <String?>[];
      final received = <PeerCard>[];
      final sockets = <_ErrorInjectingSocket>[];
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: 0,
        multicast: false,
        maintenanceInterval: const Duration(milliseconds: 100),
        onPeer: received.add,
        onDiagnostic: diagnostics.add,
        socketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              final socket = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  port,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              sockets.add(socket);
              return socket;
            },
      );
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        await discovery.start();
        final code = Platform.isWindows ? 10038 : 9;
        sockets.single.injectStreamError(
          SocketException('Invalid socket', osError: OSError('', code)),
        );
        await until(
          () => diagnostics.contains('discovery_socket_failed_os_error_$code'),
        );
        expect(discovery.localPort, isNull);
        expect(sockets.single.closeCount, 1);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(sockets, hasLength(1));
        await until(() => sockets.length == 2 && discovery.localPort != null);
        sender.send(
          PeerDiscovery.beacon(remote, 32123),
          InternetAddress.loopbackIPv4,
          discovery.localPort!,
        );
        await until(() => received.isNotEmpty);
        expect(received.single.id, remote.id);
      } finally {
        sender.close();
        await discovery.stop();
      }
    },
  );

  test(
    'outbound route failure and close never remove the fixed UDP listener',
    () async {
      final reservation = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final fixedPort = reservation.port;
      reservation.close();
      final diagnostics = <String?>[];
      final received = <PeerCard>[];
      final outgoing = <_ErrorInjectingSocket>[];
      final outboundRequestedPorts = <int>[];
      final outboundActualPorts = <int>[];
      late _ErrorInjectingSocket listener;
      var listenerBinds = 0;
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: fixedPort,
        multicast: false,
        seedAddresses: [InternetAddress.loopbackIPv4],
        maintenanceInterval: const Duration(milliseconds: 100),
        onPeer: received.add,
        onDiagnostic: diagnostics.add,
        socketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              listenerBinds++;
              listener = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  port,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              return listener;
            },
        outboundSocketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              outboundRequestedPorts.add(port);
              final socket = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  port,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              outgoing.add(socket);
              outboundActualPorts.add(socket.port);
              return socket;
            },
      );
      final remoteSender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      try {
        await discovery.start();
        expect(discovery.localPort, fixedPort);
        expect(outgoing, hasLength(1));
        expect(outgoing.single.sendCount, 1);
        final failedSender = outgoing.single;
        final code = Platform.isWindows
            ? 10051
            : Platform.isMacOS || Platform.isIOS
            ? 51
            : 101;
        failedSender.injectStreamErrorAndClose(
          SocketException('No network route', osError: OSError('', code)),
        );
        await until(
          () => diagnostics.contains(
            'discovery_unicast_sender_failed_os_error_$code',
          ),
        );
        expect(failedSender.closeCount, 1);
        expect(discovery.localPort, fixedPort);
        expect(listener.closeCount, 0);
        expect(listenerBinds, 1);

        // The sender can recover independently while the same receiver lives.
        await until(() => outgoing.length >= 2);
        remoteSender.send(
          PeerDiscovery.beacon(remote, 32123),
          InternetAddress.loopbackIPv4,
          fixedPort,
        );
        await until(() => received.isNotEmpty);
        expect(received.single.id, remote.id);
        expect(received.single.port, 32123);
        expect(discovery.localPort, fixedPort);
        expect(listenerBinds, 1);
        expect(listener.closeCount, 0);
        expect(listener.sendCount, 0);
        expect(outboundRequestedPorts, everyElement(0));
        expect(outboundActualPorts, isNot(contains(fixedPort)));
      } finally {
        remoteSender.close();
        await discovery.stop();
      }
      expect(listener.closeCount, 1);
    },
  );

  test(
    'seed and probe replies to an ephemeral source port are admitted',
    () async {
      final remoteSocket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final remotePackets = <Datagram>[];
      final remoteSubscription = remoteSocket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = remoteSocket.receive()) != null) {
          remotePackets.add(packet!);
        }
      });
      final received = <PeerCard>[];
      final outgoing = <_ErrorInjectingSocket>[];
      final outboundRequestedPorts = <int>[];
      late _ErrorInjectingSocket listener;
      final discovery = PeerDiscovery(
        identity: local,
        listenPort: 45871,
        port: remoteSocket.port,
        multicast: false,
        seedAddresses: [InternetAddress.loopbackIPv4],
        onPeer: received.add,
        onDiagnostic: (_) {},
        socketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              // Two logical hosts share loopback in this test. Keep the local
              // receiver separate from the remote's discovery destination.
              listener = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  0,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              return listener;
            },
        outboundSocketBinder:
            (address, port, {required reuseAddress, required reusePort}) async {
              outboundRequestedPorts.add(port);
              final socket = _ErrorInjectingSocket(
                await RawDatagramSocket.bind(
                  address,
                  port,
                  reuseAddress: reuseAddress,
                  reusePort: reusePort,
                ),
              );
              outgoing.add(socket);
              return socket;
            },
      );
      try {
        await discovery.start();
        await until(() => remotePackets.isNotEmpty);
        final seed = remotePackets.first;
        // Beacon v2 carries the rotating session token, never the certificate.
        expect(
          PeerDiscovery.parseSessionBeacon(seed.data, seed.address).session,
          discovery.session.token,
        );
        expect(String.fromCharCodes(seed.data), isNot(contains('CERTIFICATE')));
        expect(seed.port, outgoing.single.port);
        expect(seed.port, isNot(discovery.localPort));
        expect(seed.port, isNot(remoteSocket.port));
        remoteSocket.send(
          PeerDiscovery.beacon(remote, 32123),
          seed.address,
          seed.port,
        );
        await until(() => received.length == 1);
        // A bounded signed response is returned on the same independent sender.
        await until(() => remotePackets.length >= 2);
        final beforeProbe = remotePackets.length;
        discovery.probe(InternetAddress.loopbackIPv4);
        await until(() => remotePackets.length > beforeProbe);
        final probe = remotePackets.last;
        expect(
          PeerDiscovery.parseSessionBeacon(probe.data, probe.address).session,
          discovery.session.token,
        );
        expect(probe.port, seed.port);
        remoteSocket.send(
          PeerDiscovery.beacon(remote, 32124),
          probe.address,
          probe.port,
        );
        await until(() => received.length == 2);
        expect(received.map((peer) => peer.id), everyElement(remote.id));
        expect(received.map((peer) => peer.port), [32123, 32124]);
        expect(outgoing, hasLength(1));
        expect(outboundRequestedPorts, [0]);
        expect(listener.sendCount, 0);
        expect(listener.closeCount, 0);
      } finally {
        await discovery.stop();
        await remoteSubscription.cancel();
        remoteSocket.close();
      }
    },
  );
}

/// Retains real UDP I/O while deterministically injecting OS error delivery.
class _ErrorInjectingSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  _ErrorInjectingSocket(this._socket) {
    _subscription = _socket.listen(
      _events.add,
      onError: _events.addError,
      onDone: _events.close,
    );
  }

  final RawDatagramSocket _socket;
  final _events = StreamController<RawSocketEvent>();
  late final StreamSubscription<RawSocketEvent> _subscription;
  SocketException? _receiveError;
  int closeCount = 0;
  int sendCount = 0;

  void injectStreamError(SocketException error) => _events.addError(error);

  void injectStreamErrorAndClose(SocketException error) {
    _events.addError(error);
    _events.add(RawSocketEvent.closed);
    _socket.close();
  }

  void injectReceiveError(SocketException error) {
    _receiveError = error;
    _events.add(RawSocketEvent.read);
  }

  @override
  int get port => _socket.port;

  @override
  Datagram? receive() {
    final error = _receiveError;
    _receiveError = null;
    if (error != null) throw error;
    return _socket.receive();
  }

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    sendCount++;
    return _socket.send(buffer, address, port);
  }

  @override
  void close() {
    if (closeCount > 0) return;
    closeCount++;
    _socket.close();
    unawaited(_subscription.cancel());
    unawaited(_events.close());
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _events.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 3)) {
      throw StateError('UDP recovery condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
