import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';

import 'core/overlay_frames.dart';
import 'core/peer_engine.dart';
import 'core/network_epoch.dart';

/// Hyperswarm discovers connection identities, then carries the existing TLS
/// protocol. A discovered peer gains no publisher trust or subscriptions.
class InternetOverlay {
  InternetOverlay(this.engine, {required this.onState, this.networkKey});
  final PeerEngine engine;
  final void Function(Map<String, dynamic>) onState;
  final Future<String?> Function()? networkKey;
  final NetworkEpoch _networkEpoch = NetworkEpoch();
  Future<void>? _stopping;
  static const namespace = String.fromEnvironment(
    'PERSIANTREND_DISCOVERY_NAMESPACE',
    defaultValue: 'persiantrend/public-news/overlay/v1',
  );
  final Map<String, _OverlayRoute> _routes = {};
  Pear? _pear;
  PearSwarm? _swarm;
  PearKey? _topic;
  StreamSubscription<PearConnection>? _connections;
  StreamSubscription<PearSwarmStatus>? _states;
  Timer? _timer;
  bool _wanted = false;
  Timer? _restartTimer;
  int _restartAttempts = 0, _refreshFailures = 0;
  bool _running = false;
  bool _refreshing = false;
  int _generation = 0;
  int _routeCounter = 0;

  Future<void> start() async {
    if (engine.nearbyOnly) return;
    _wanted = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _stopping;
    if (!_wanted || engine.nearbyOnly || _running) return;
    _running = true;
    final generation = ++_generation;
    try {
      final key = await networkKey?.call();
      if (!_current(generation)) return;
      _networkEpoch.observe(key);
      final pear = await Pear.start();
      if (!_current(generation)) {
        await pear.dispose();
        return;
      }
      _pear = pear;
      // The Android receiving foreground service owns this lifecycle.
      pear.lifecycle.policy = PearLifecyclePolicy.manual;
      final topic = PearCrypto.hash(Uint8List.fromList(utf8.encode(namespace)));
      _topic = topic;
      final swarm = await pear.join(topic, acceptUnannounced: true);
      if (!_current(generation)) {
        await pear.dispose();
        return;
      }
      _swarm = swarm;
      _connections = swarm.connections.listen((connection) {
        if (!_current(generation) ||
            _routes.length >= PeerEngine.maxConnections) {
          unawaited(
            pear.disconnect(connection.remotePublicKey, cooldown: true),
          );
          return;
        }
        final id = connection.remotePublicKey.hex;
        final old = _routes[id];
        // Disconnect RPCs are keyed by peer, so retiring the old route must not
        // close the replacement connection for the same peer.
        if (old != null) unawaited(old.close(disconnect: false));
        final route = _OverlayRoute(this, connection, generation);
        _routes[id] = route;
        unawaited(route.start());
      });
      _states = swarm.state.listen((value) {
        if (_current(generation)) {
          onState({
            'state': value.state.name,
            if (value.error != null) 'error': value.error!.code,
          });
        }
      });
      _timer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(refresh()),
      );
      _restartAttempts = 0;
      _refreshFailures = 0;
      onState({'state': 'discovering'});
    } catch (_) {
      if (!_current(generation)) return;
      onState({'state': 'retrying', 'error': 'worklet_start_failed'});
      await _stopResources();
      _scheduleRestart();
    }
  }

  void _scheduleRestart({Duration? after}) {
    if (!_wanted || engine.nearbyOnly || _restartTimer != null) return;
    final delay = [10, 20, 40, 80, 120][_restartAttempts.clamp(0, 4)];
    _restartAttempts++;
    _restartTimer = Timer(after ?? Duration(seconds: delay), () {
      _restartTimer = null;
      if (_wanted) unawaited(start());
    });
  }

  bool _current(int generation) => _running && _generation == generation;

  Future<void> refresh() async {
    if (!_running || _refreshing) return;
    final generation = _generation;
    _refreshing = true;
    try {
      final key = await networkKey?.call();
      if (!_current(generation)) return;
      if (_networkEpoch.observe(key)) {
        onState({'state': 'retrying', 'error': 'network_changed'});
        // The old UDP sockets can remain bound to a vanished interface. Reopen
        // the worklet after a short debounce; keys/cache/news remain intact.
        await _stopResources();
        _scheduleRestart(after: const Duration(seconds: 2));
        return;
      }
      for (final route in _routes.values.toList()) {
        final linked =
            route.peerId != null &&
            engine.hasPinnedRoute(
              route.peerId!,
              route.routeId,
              PeerTransport.overlay,
            );
        if (linked && !route.remembered && _pear != null && _topic != null) {
          await _pear!.rememberConnection(
            route.connection.remotePublicKey,
            _topic!,
            node: route.helperNode,
          );
          if (!_current(generation)) return;
          route.remembered = true;
          route.deadline?.cancel();
        }
      }
      final network = await _pear?.networkState();
      if (!_current(generation)) return;
      _refreshFailures = 0;
      if (_running && network != null) {
        onState({
          'state': _routes.values.any((route) => route.remembered)
              ? 'connected'
              : 'discovering',
          'discoveryStage': network['discoveryStage'],
          'discoveryRefreshes': network['discoveryRefreshes'],
          'cachedRoutingCount': network['cachedRoutingCount'],
          'cachedPeerCount': network['cachedPeerCount'],
          'reachableHelper': network['reachableHelper'],
        });
      }
    } catch (_) {
      if (_current(generation)) {
        onState({'state': 'retrying', 'error': 'worklet_unresponsive'});
        if (++_refreshFailures >= 3) {
          await _stopResources();
          _scheduleRestart();
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> stop() async {
    _wanted = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    await _stopResources();
  }

  Future<void> _stopResources() {
    return _stopping ??= _disposeResources().whenComplete(
      () => _stopping = null,
    );
  }

  Future<void> _disposeResources() async {
    _running = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    await _connections?.cancel();
    await _states?.cancel();
    _connections = null;
    _states = null;
    for (final route in _routes.values.toList()) {
      await route.close(disconnect: false);
    }
    _routes.clear();
    final pear = _pear;
    final swarm = _swarm;
    _pear = null;
    _swarm = null;
    try {
      await swarm?.leave().timeout(const Duration(seconds: 3));
    } catch (_) {}
    // Native termination is required even if public DHT unannouncing times out.
    try {
      await pear?.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {
      await pear?.worklet.terminate();
    }
  }
}

class _OverlayRoute {
  _OverlayRoute(this.owner, this.connection, this.generation)
    : routeId =
          'overlay:${connection.remotePublicKey.hex}:${owner._routeCounter++}';
  final InternetOverlay owner;
  final PearConnection connection;
  final int generation;
  final decoder = OverlayFrameDecoder();
  final helloWritten = Completer<void>();
  final String routeId;
  String? peerId;
  Map<String, dynamic>? helperNode;
  bool remembered = false;
  bool closed = false;
  bool helloReceived = false;
  bool remoteReady = false;
  bool bridgeStarted = false;
  int? ingress;
  int queuedBytes = 0;
  final pendingData = <Uint8List>[];
  int pendingBytes = 0;
  Future<void> processing = Future.value();
  StreamSubscription<Uint8List>? subscription;
  StreamSubscription<Uint8List>? socketSubscription;
  ServerSocket? server;
  Socket? socket;
  Timer? deadline;
  bool get current => !closed && owner._current(generation);

  Future<void> start() async {
    subscription = connection.data.listen(
      (bytes) {
        if (!current) return;
        queuedBytes += bytes.length;
        if (queuedBytes > 256 * 1024) {
          unawaited(close(cooldown: true));
          return;
        }
        processing = processing
            .then((_) async {
              if (!current) return;
              for (final frame in decoder.add(bytes)) {
                await handle(frame);
              }
            })
            .catchError((Object _) {
              unawaited(close(cooldown: true));
            })
            .whenComplete(() {
              queuedBytes -= bytes.length;
            });
      },
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
    );
    deadline = Timer(const Duration(seconds: 30), () {
      if (!remembered) unawaited(close(cooldown: true));
    });
    try {
      final network = await owner._pear!.networkState();
      if (!current) return;
      await send(
        OverlayFrame.hello,
        utf8.encode(
          jsonEncode({
            'version': 1,
            'beacon': base64Encode(owner.engine.createDiscoveryBeacon()),
            if (network['ownContact'] is Map)
              'helperNode': network['ownContact'],
          }),
        ),
      );
      if (!helloWritten.isCompleted) helloWritten.complete();
    } catch (_) {
      await close();
    }
  }

  Future<void> send(int type, List<int> bytes) =>
      connection.write(OverlayFrame.encode(type, bytes));

  Future<void> handle(OverlayFrame frame) async {
    if (!current) return;
    if (frame.type == OverlayFrame.hello) {
      if (helloReceived) {
        throw const FormatException('Repeated overlay introduction.');
      }
      helloReceived = true;
      final value = jsonDecode(utf8.decode(frame.bytes));
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['beacon'] is! String ||
          (value['beacon'] as String).length > 5500 ||
          value.keys.any(
            (key) => !{'version', 'beacon', 'helperNode'}.contains(key),
          )) {
        throw const FormatException('Invalid overlay introduction.');
      }
      final admission = await owner.engine.admitNativePeer(
        signedBeacon: base64Decode(value['beacon'] as String),
        routeId: routeId,
        transport: PeerTransport.overlay,
      );
      if (!current ||
          !admission.accepted ||
          admission.peerId == null ||
          admission.ingressPort == null) {
        await close();
        return;
      }
      peerId = admission.peerId;
      ingress = admission.ingressPort;
      if (value['helperNode'] is Map<String, dynamic>) {
        helperNode = value['helperNode'] as Map<String, dynamic>;
      }
      await helloWritten.future;
      if (!current) return;
      await send(OverlayFrame.ready, const []);
      await maybeStartBridge();
    } else if (frame.type == OverlayFrame.ready) {
      if (!helloReceived || remoteReady) {
        throw const FormatException('Invalid overlay readiness.');
      }
      remoteReady = true;
      await maybeStartBridge();
    } else {
      if (!helloReceived || !remoteReady || ingress == null) {
        throw const FormatException('Premature overlay data.');
      }
      final target = socket;
      if (target == null) {
        pendingBytes += frame.bytes.length;
        if (pendingBytes > 64 * 1024) {
          throw const FormatException('Overlay startup buffer exceeded.');
        }
        pendingData.add(frame.bytes);
      } else {
        target.add(frame.bytes);
        await target.flush();
      }
    }
  }

  Future<void> maybeStartBridge() async {
    if (!current ||
        bridgeStarted ||
        !remoteReady ||
        peerId == null ||
        ingress == null) {
      return;
    }
    bridgeStarted = true;
    if (owner.engine.identity.id.compareTo(peerId!) < 0) {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server = listener;
      if (!current) {
        await listener.close();
        return;
      }
      listener.listen((accepted) {
        if (!current || socket != null) {
          accepted.destroy();
          return;
        }
        attach(accepted);
      }, onError: (Object _) => unawaited(close()));
      await owner.engine.registerNativeEndpoint(
        peerId: peerId!,
        routeId: routeId,
        transport: PeerTransport.overlay,
        host: InternetAddress.loopbackIPv4,
        port: listener.port,
      );
    } else {
      final connected = await Socket.connect(
        InternetAddress.loopbackIPv4,
        ingress!,
        timeout: const Duration(seconds: 5),
      );
      if (!current) {
        connected.destroy();
        return;
      }
      attach(connected);
    }
  }

  void attach(Socket connected) {
    socket = connected;
    connected.setOption(SocketOption.tcpNoDelay, true);
    for (final bytes in pendingData) {
      connected.add(bytes);
    }
    pendingData.clear();
    pendingBytes = 0;
    late final StreamSubscription<Uint8List> outgoing;
    outgoing = connected.listen(
      (bytes) {
        outgoing.pause();
        unawaited(() async {
          try {
            for (var offset = 0; offset < bytes.length; offset += 16384) {
              if (!current) return;
              final end = offset + 16384 < bytes.length
                  ? offset + 16384
                  : bytes.length;
              await send(
                OverlayFrame.data,
                Uint8List.sublistView(bytes, offset, end),
              );
            }
            if (current) outgoing.resume();
          } catch (_) {
            await close();
          }
        }());
      },
      onError: (Object _) => unawaited(close()),
      onDone: () => unawaited(close()),
    );
    socketSubscription = outgoing;
  }

  Future<void> close({bool disconnect = true, bool cooldown = false}) async {
    if (closed) return;
    final pear = owner._pear;
    closed = true;
    if (!helloWritten.isCompleted) helloWritten.complete();
    deadline?.cancel();
    await subscription?.cancel();
    await socketSubscription?.cancel();
    socket?.destroy();
    await server?.close();
    await owner.engine.removeNativeRoute(routeId);
    final ownsPeer = identical(
      owner._routes[connection.remotePublicKey.hex],
      this,
    );
    if (ownsPeer) {
      owner._routes.remove(connection.remotePublicKey.hex);
    }
    if (disconnect &&
        ownsPeer &&
        owner._current(generation) &&
        pear != null &&
        identical(owner._pear, pear)) {
      try {
        await pear.disconnect(connection.remotePublicKey, cooldown: cooldown);
      } catch (_) {}
    }
  }
}
