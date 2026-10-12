import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'identity.dart';
import 'models.dart';

typedef DiscoverySocketBinder = Future<RawDatagramSocket> Function(
  InternetAddress address,
  int port, {
  required bool reuseAddress,
  required bool reusePort,
});

/// Local multicast and explicit-seed unicast admission. No address scanning,
/// DNS, global discovery service, or claim about a certificate owner's identity.
class PeerDiscovery {
  PeerDiscovery({
    required this.identity,
    required this.listenPort,
    required this.onPeer,
    required this.onDiagnostic,
    this.port = 45872,
    this.multicast = true,
    this.seedAddresses = const [],
    this.maintenanceInterval = const Duration(seconds: 10),
    DiscoverySocketBinder? socketBinder,
    DiscoverySocketBinder? outboundSocketBinder,
  }) : assert(maintenanceInterval > Duration.zero),
       _bindSocket = socketBinder ?? RawDatagramSocket.bind,
       _bindOutboundSocket = outboundSocketBinder ?? RawDatagramSocket.bind;

  final Identity identity;
  final int listenPort;
  final int port;
  final bool multicast;
  final List<InternetAddress> seedAddresses;
  final Duration maintenanceInterval;
  final DiscoverySocketBinder _bindSocket;
  final DiscoverySocketBinder _bindOutboundSocket;
  final void Function(PeerCard) onPeer;
  final void Function(String?) onDiagnostic;
  static const maxBeaconBytes = 4096;
  static const maxMulticastInterfaces = 8;
  static final group = InternetAddress('239.255.71.71');
  int? get localPort => _socket?.port;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _timer;
  bool _desiredRunning = false;
  int _generation = 0;
  Future<void>? _maintenance;
  int? _maintenanceGeneration;
  int _nextBindAttemptMs = 0;
  final List<NetworkInterface> _interfaces = [];
  final Map<String, _DiscoverySender> _senders = {};
  final Map<String, Future<_DiscoverySender?>> _senderBindings = {};
  final Map<String, int> _senderRetryAtMs = {};
  final Map<String, int> _seen = {};
  final Map<String, int> _responseTimes = {};
  final Map<String, int> _probeTimes = {};
  final Stopwatch _clock = Stopwatch()..start();
  int _rateCount = 0;
  int _rateStartMs = 0;

  /// Public for protocol tests. A signature proves possession of this key only.
  static Uint8List beacon(Identity identity, int listenPort, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final random = Random.secure();
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'persiantrend/discovery/v1',
      'certificatePem': identity.certPem,
      'port': listenPort,
      'nonce': base64UrlEncode(
        List<int>.generate(16, (_) => random.nextInt(256)),
      ),
      'issuedAtMs': now,
      'expiresAtMs': now + 45000,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    return Uint8List.fromList(
      utf8.encode(jsonEncode({...body, 'signature': identity.sign(bytes)})),
    );
  }

  /// The endpoint always comes from the datagram, never from its payload.
  static PeerCard parseBeacon(Uint8List bytes, InternetAddress observedSource) {
    if (bytes.isEmpty ||
        bytes.length > maxBeaconBytes ||
        observedSource.isMulticast ||
        observedSource.address == '0.0.0.0' ||
        observedSource.address == '::') {
      throw const FormatException('Invalid discovery datagram.');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map<String, dynamic> ||
        raw.length != 8 ||
        !raw.keys.every(
          {
            'version',
            'kind',
            'certificatePem',
            'port',
            'nonce',
            'issuedAtMs',
            'expiresAtMs',
            'signature',
          }.contains,
        ) ||
        raw['version'] != 1 ||
        raw['kind'] != 'persiantrend/discovery/v1' ||
        raw['certificatePem'] is! String ||
        raw['port'] is! int ||
        raw['nonce'] is! String ||
        (raw['nonce'] as String).length != 24 ||
        raw['issuedAtMs'] is! int ||
        raw['expiresAtMs'] is! int ||
        raw['signature'] is! String) {
      throw const FormatException('Invalid discovery fields.');
    }
    final issued = raw['issuedAtMs'] as int;
    final expiry = raw['expiresAtMs'] as int;
    // Phones need not agree on wall time. Replay suppression uses local elapsed
    // time; the following TLS handshake must still prove possession of the key.
    if (expiry - issued != 45000 || issued < 0) {
      throw const FormatException('Invalid discovery lifetime.');
    }
    final body = <String, dynamic>{
      'version': raw['version'],
      'kind': raw['kind'],
      'certificatePem': raw['certificatePem'],
      'port': raw['port'],
      'nonce': raw['nonce'],
      'issuedAtMs': issued,
      'expiresAtMs': expiry,
    };
    final certificate = raw['certificatePem'] as String;
    if (!Identity.verify(
      certificate,
      Uint8List.fromList(utf8.encode(jsonEncode(body))),
      raw['signature'] as String,
    )) {
      throw const FormatException('Invalid discovery signature.');
    }
    final id = Identity.certificateId(certificate);
    return PeerCard(
      name: 'Peer ${id.substring(0, 8)}',
      host: observedSource.address,
      port: raw['port'] as int,
      certificatePem: certificate,
    );
  }

  Future<void> start() async {
    if (_desiredRunning) {
      await _maintain(_generation);
      return;
    }
    _desiredRunning = true;
    final generation = ++_generation;
    await _maintain(generation);
  }

  bool _current(int generation) => _desiredRunning && generation == _generation;

  Future<void> _maintain(int generation) {
    if (!_current(generation)) return Future<void>.value();
    final pending = _maintenance;
    if (pending != null) {
      if (_maintenanceGeneration == generation) return pending;
      // A replacement session waits for an old bind/interface lookup to finish.
      return pending.then((_) => _maintain(generation));
    }
    _maintenanceGeneration = generation;
    late final Future<void> tracked;
    tracked = _runMaintenance(generation).whenComplete(() {
      if (identical(_maintenance, tracked)) {
        _maintenance = null;
        _maintenanceGeneration = null;
      }
      _scheduleMaintenance(generation);
    });
    _maintenance = tracked;
    return tracked;
  }

  void _scheduleMaintenance(int generation) {
    if (!_current(generation) || (_timer?.isActive ?? false)) return;
    // Schedule after the attempt completes. A periodic timer started before a
    // slow bind could fire just before the retry deadline and add another 10s.
    final remainingMs = _nextBindAttemptMs - _clock.elapsedMilliseconds;
    final delay = _socket == null && remainingMs > 0
        ? Duration(milliseconds: remainingMs)
        : maintenanceInterval;
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(_maintain(generation));
    });
  }

  Future<void> _runMaintenance(int generation) async {
    if (!_current(generation)) return;
    if (_socket == null) {
      if (_clock.elapsedMilliseconds < _nextBindAttemptMs) return;
      await _bind(generation);
    }
    final socket = _socket;
    if (socket == null || !_current(generation)) return;
    if (multicast) {
      await _refreshInterfaces();
    } else {
      onDiagnostic(null);
    }
    if (_current(generation) && identical(_socket, socket)) {
      await _announce(generation);
    }
  }

  Future<void> _bind(int generation) async {
    RawDatagramSocket? candidate;
    try {
      final socket = await _bindSocket(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      candidate = socket;
      if (!_current(generation)) {
        socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.listen(
        (event) {
          if (!_current(generation) || !identical(_socket, socket)) return;
          if (event == RawSocketEvent.closed) {
            _socketFailed(generation, socket, 'discovery_socket_closed');
            return;
          }
          if (event != RawSocketEvent.read) return;
          try {
            Datagram? datagram;
            while ((datagram = socket.receive()) != null) {
              _receive(datagram!);
            }
          } on SocketException catch (error) {
            _socketError(generation, socket, error);
          }
        },
        onError: (Object error) {
          _socketError(generation, socket, error);
        },
        onDone: () {
          _socketFailed(generation, socket, 'discovery_socket_closed');
        },
      );
      _nextBindAttemptMs = 0;
    } catch (error) {
      if (candidate != null && identical(_socket, candidate)) {
        _socket = null;
        final subscription = _subscription;
        _subscription = null;
        if (subscription != null) unawaited(subscription.cancel());
        _interfaces.clear();
      }
      candidate?.close();
      if (_current(generation)) {
        _nextBindAttemptMs =
            _clock.elapsedMilliseconds + maintenanceInterval.inMilliseconds;
        onDiagnostic(_diagnostic('discovery_bind_failed', error));
      }
    }
  }

  String _diagnostic(String category, Object error) {
    final code = error is SocketException ? error.osError?.errorCode : null;
    return code == null ? category : '${category}_os_error_$code';
  }

  void _socketError(int generation, RawDatagramSocket socket, Object error) {
    if (!_current(generation) || !identical(_socket, socket)) return;
    final code = error is SocketException ? error.osError?.errorCode : null;
    // A connectionless UDP send can report a destination route failure later
    // on the socket stream/receive call. The bound listener is still usable on
    // other interfaces, including a Wi-Fi Direct group. Errnos are platform
    // specific: ENETUNREACH/EHOSTUNREACH, or their Winsock equivalents.
    final routeUnavailable = switch (Platform.operatingSystem) {
      'android' || 'linux' => code == 101 || code == 113,
      'ios' || 'macos' => code == 51 || code == 65,
      'windows' => code == 10051 || code == 10065,
      _ => false,
    };
    if (routeUnavailable) {
      onDiagnostic(_diagnostic('discovery_route_unavailable', error));
      return;
    }
    _socketFailed(
      generation,
      socket,
      _diagnostic('discovery_socket_failed', error),
    );
  }

  void _socketFailed(int generation, RawDatagramSocket socket, String reason) {
    if (!_current(generation) || !identical(_socket, socket)) return;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    _interfaces.clear();
    socket.close();
    if (subscription != null) unawaited(subscription.cancel());
    _nextBindAttemptMs =
        _clock.elapsedMilliseconds + maintenanceInterval.inMilliseconds;
    onDiagnostic(reason);
  }

  void _receive(Datagram datagram) {
    if (datagram.data.length > maxBeaconBytes) return;
    final nowMs = _clock.elapsedMilliseconds;
    if (nowMs - _rateStartMs >= 10000) {
      _rateStartMs = nowMs;
      _rateCount = 0;
    }
    if (++_rateCount > 32) return;
    try {
      final raw = jsonDecode(utf8.decode(datagram.data));
      if (raw is! Map<String, dynamic>) return;
      // One signed announcement can arrive from several legitimate interfaces.
      // Suppress replay on the same observed route without discarding another
      // source address that the TLS engine may need as a fallback endpoint.
      final token =
          '${datagram.address.address}:${raw['nonce']}:${raw['signature']}';
      _seen.removeWhere((_, expiry) => expiry < nowMs);
      if (_seen.containsKey(token)) return;
      final peer = parseBeacon(datagram.data, datagram.address);
      if (peer.id == identity.id) return;
      if (_seen.length >= 64) _seen.remove(_seen.keys.first);
      _seen[token] = nowMs + 45000;
      onPeer(peer);
      // Reply only after signature validation, at most once per identity/source
      // each 10 seconds. Repeated replies cannot create a beacon ping-pong.
      final responseKey = '${peer.id}:${datagram.address.address}';
      _responseTimes.removeWhere((_, time) => nowMs - time > 60000);
      if (!_responseTimes.containsKey(responseKey) ||
          nowMs - _responseTimes[responseKey]! >= 10000) {
        if (_responseTimes.length >= 64) {
          _responseTimes.remove(_responseTimes.keys.first);
        }
        _responseTimes[responseKey] = nowMs;
        unawaited(
          _sendUnicast(
            _generation,
            beacon(identity, listenPort),
            datagram.address,
            datagram.port,
          ),
        );
      }
    } catch (_) {
      // Malformed, repeated and unauthenticated packets have no state effect.
    }
  }

  /// A native group-owner address is only a discovery hint, never a trust pin.
  /// The bounded signed response is handled through the normal admission path.
  void probe(InternetAddress address) {
    if (address.isMulticast ||
        address.address == '0.0.0.0' ||
        address.address == '::' ||
        port == 0) {
      throw ArgumentError('A unicast address and discovery port are required.');
    }
    final socket = _socket;
    if (socket == null) {
      // Keep the bounded retry schedule alive rather than silently abandoning
      // a formed native group. Calls before the retry deadline do not rebind.
      if (_desiredRunning) unawaited(_maintain(_generation));
      return;
    }
    final now = _clock.elapsedMilliseconds;
    if (now - (_probeTimes[address.address] ?? -10000) < 10000) return;
    if (_probeTimes.length >= 16 && !_probeTimes.containsKey(address.address)) {
      _probeTimes.remove(_probeTimes.keys.first);
    }
    _probeTimes[address.address] = now;
    unawaited(
      _sendUnicast(_generation, beacon(identity, listenPort), address, port),
    );
  }

  String _interfaceKey(NetworkInterface interface) =>
      '${interface.index}:${interface.addresses.map((a) => a.address).join(',')}';

  Future<void> _refreshInterfaces() async {
    final socket = _socket;
    if (socket == null) return;
    try {
      final available = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (!identical(_socket, socket)) return;
      final current = available.take(maxMulticastInterfaces).toList();
      final keys = current.map(_interfaceKey).toSet();
      for (final previous in _interfaces.toList()) {
        if (keys.contains(_interfaceKey(previous))) continue;
        try {
          socket.leaveMulticast(group, previous);
        } on SocketException {
          /* Adapter disappeared. */
        }
        _interfaces.remove(previous);
      }
      for (final interface in current) {
        if (_interfaces.any(
          (i) => _interfaceKey(i) == _interfaceKey(interface),
        )) {
          continue;
        }
        try {
          socket.joinMulticast(group, interface);
          _interfaces.add(interface);
        } on SocketException {
          /* Continue with other local adapters. */
        }
      }
      final senderKeys = _interfaces
          .map((interface) => 'multicast:${_interfaceKey(interface)}')
          .toSet();
      for (final key in _senders.keys.toList()) {
        if (key != 'unicast' && !senderKeys.contains(key)) {
          _closeSender(key, _senders[key]!);
        }
      }
      _senderRetryAtMs.removeWhere(
        (key, _) => key != 'unicast' && !senderKeys.contains(key),
      );
      onDiagnostic(_interfaces.isEmpty ? 'lan_multicast_unavailable' : null);
    } catch (_) {
      if (identical(_socket, socket)) {
        onDiagnostic('lan_interface_lookup_failed');
      }
    }
  }

  Future<void> _announce(int generation) async {
    final socket = _socket;
    if (socket == null) return;
    final bytes = beacon(identity, listenPort);
    for (final interface in _interfaces.toList()) {
      if (!_current(generation)) return;
      final key = 'multicast:${_interfaceKey(interface)}';
      final sender = await _sender(generation, key, interface: interface);
      if (sender != null) {
        _sendDatagram(generation, key, sender, bytes, group, port);
      }
    }
    for (final address in seedAddresses) {
      if (!_current(generation)) return;
      if (address.type != InternetAddressType.IPv4) continue;
      await _sendUnicast(generation, bytes, address, port);
    }
  }

  Future<void> _sendUnicast(
    int generation,
    Uint8List bytes,
    InternetAddress address,
    int destinationPort,
  ) async {
    final sender = await _sender(generation, 'unicast');
    if (sender != null) {
      _sendDatagram(
        generation,
        'unicast',
        sender,
        bytes,
        address,
        destinationPort,
      );
    }
  }

  void _sendDatagram(
    int generation,
    String key,
    _DiscoverySender sender,
    Uint8List bytes,
    InternetAddress address,
    int destinationPort,
  ) {
    if (!_current(generation) || !identical(_senders[key], sender)) return;
    try {
      sender.socket.send(bytes, address, destinationPort);
    } on SocketException catch (error) {
      _senderFailed(generation, key, sender, error);
    }
  }

  Future<_DiscoverySender?> _sender(
    int generation,
    String key, {
    NetworkInterface? interface,
  }) {
    if (!_current(generation)) return Future.value(null);
    final existing = _senders[key];
    if (existing != null) return Future.value(existing);
    final pending = _senderBindings[key];
    if (pending != null) {
      return pending.then(
        (_) => _sender(generation, key, interface: interface),
      );
    }
    if (_clock.elapsedMilliseconds < (_senderRetryAtMs[key] ?? 0)) {
      return Future.value(null);
    }
    late final Future<_DiscoverySender?> tracked;
    tracked = _bindSender(generation, key, interface).whenComplete(() {
      if (identical(_senderBindings[key], tracked)) _senderBindings.remove(key);
    });
    _senderBindings[key] = tracked;
    return tracked;
  }

  Future<_DiscoverySender?> _bindSender(
    int generation,
    String key,
    NetworkInterface? interface,
  ) async {
    RawDatagramSocket? candidate;
    try {
      // The fixed discovery socket never sends. Some runtimes close an entire
      // UDP socket after an asynchronous per-destination send error, so isolate
      // unicast and each multicast interface on bounded ephemeral sockets.
      final socket = await _bindOutboundSocket(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: false,
        reusePort: false,
      );
      candidate = socket;
      if (!_current(generation)) {
        socket.close();
        return null;
      }
      if (interface != null) {
        socket.multicastHops = 1;
        socket.multicastLoopback = false;
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            interface.addresses.first.rawAddress,
          ),
        );
      }
      final sender = _DiscoverySender(socket);
      _senders[key] = sender;
      sender.subscription = socket.listen(
        (event) {
          if (!_current(generation) || !identical(_senders[key], sender)) {
            return;
          }
          if (event == RawSocketEvent.closed) {
            _senderFailed(generation, key, sender, null);
          } else if (event == RawSocketEvent.read) {
            try {
              Datagram? datagram;
              while ((datagram = socket.receive()) != null) {
                _receive(datagram!);
              }
            } on SocketException catch (error) {
              _senderFailed(generation, key, sender, error);
            }
          }
        },
        onError: (Object error) =>
            _senderFailed(generation, key, sender, error),
        onDone: () => _senderFailed(generation, key, sender, null),
      );
      _senderRetryAtMs.remove(key);
      return sender;
    } catch (error) {
      final sender = _senders[key];
      if (sender != null && identical(sender.socket, candidate)) {
        _closeSender(key, sender);
      } else {
        candidate?.close();
      }
      if (_current(generation)) {
        _senderRetryAtMs[key] =
            _clock.elapsedMilliseconds + maintenanceInterval.inMilliseconds;
        final category = key == 'unicast' ? 'unicast' : 'multicast';
        onDiagnostic(_diagnostic('discovery_${category}_sender_failed', error));
      }
      return null;
    }
  }

  void _senderFailed(
    int generation,
    String key,
    _DiscoverySender sender,
    Object? error,
  ) {
    if (!_current(generation) || !identical(_senders[key], sender)) return;
    _closeSender(key, sender);
    _senderRetryAtMs[key] =
        _clock.elapsedMilliseconds + maintenanceInterval.inMilliseconds;
    final category = key == 'unicast' ? 'unicast' : 'multicast';
    onDiagnostic(
      error == null
          ? 'discovery_${category}_sender_closed'
          : _diagnostic('discovery_${category}_sender_failed', error),
    );
  }

  void _closeSender(String key, _DiscoverySender sender) {
    if (identical(_senders[key], sender)) _senders.remove(key);
    sender.socket.close();
    final subscription = sender.subscription;
    sender.subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  Future<void> stop() async {
    _desiredRunning = false;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final pending = _maintenance;
    final bindings = _senderBindings.values.toList();
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    _interfaces.clear();
    for (final entry in _senders.entries.toList()) {
      _closeSender(entry.key, entry.value);
    }
    _senderRetryAtMs.clear();
    _seen.clear();
    _responseTimes.clear();
    _probeTimes.clear();
    _rateCount = 0;
    _rateStartMs = 0;
    _nextBindAttemptMs = 0;
    socket?.close();
    await subscription?.cancel();
    await pending;
    await Future.wait(bindings);
  }
}

class _DiscoverySender {
  _DiscoverySender(this.socket);
  final RawDatagramSocket socket;
  StreamSubscription<RawSocketEvent>? subscription;
}
