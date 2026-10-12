import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'channels.dart';
import 'delivery_mode.dart';
import 'identity.dart';
import 'local_wifi_transport.dart';
import 'models.dart';
import 'peer_discovery.dart';
import 'pilot_store.dart';

enum PeerTransport { ip, lan, wifiDirect, bluetooth }

class NativeAdmission {
  const NativeAdmission({
    required this.accepted,
    this.peerId,
    this.ingressPort,
  });
  final bool accepted;
  final String? peerId;
  final int? ingressPort;
}

/// Bounded signed gossip over pinned TLS. Numeric endpoints come from manual
/// pairing, explicit pinned seeds, cached contacts or signed UDP discovery.
class PeerEngine {
  PeerEngine({
    required this.directory,
    required this.identity,
    Identity? publisherIdentity,
    this.deliveryMode = DeliveryMode.allNetworks,
    this.localWifiTransport,
    required this.deviceState,
    required this.onStatus,
    this.listenPort = 45871,
    this.bootstrapPeers = const [],
    this.enableLanDiscovery = true,
    this.discoveryPort = 45872,
    this.readIdleTimeout = const Duration(seconds: 75),
    this.trafficWindow = const Duration(minutes: 1),
    this.cooldownDuration = const Duration(seconds: 30),
    this.egressBytesPerPeer = 512 * 1024,
    this.pendingBulletinLifetime = const Duration(seconds: 45),
    this.automaticContactIdleTime = const Duration(seconds: 60),
    this.outboundFrameTimeout = const Duration(seconds: 10),
    this.bluetoothFrameTimeout = const Duration(seconds: 30),
    this.nearbyDiscoveryInterval = const Duration(seconds: 10),
  }) : assert(trafficWindow > Duration.zero),
       assert(cooldownDuration > Duration.zero),
       assert(egressBytesPerPeer >= maxFrameBytes),
       assert(pendingBulletinLifetime > Duration.zero),
       assert(automaticContactIdleTime > Duration.zero),
       assert(outboundFrameTimeout > Duration.zero),
       assert(bluetoothFrameTimeout > Duration.zero),
       assert(nearbyDiscoveryInterval > Duration.zero),
       publisherIdentity = publisherIdentity ?? identity,
       _store = PilotStore(
         directory,
         localOwnerId: (publisherIdentity ?? identity).id,
       );

  final Directory directory;
  final Identity identity;
  final Identity publisherIdentity;
  final DeliveryMode deliveryMode;
  final LocalWifiTransport? localWifiTransport;
  bool get nearbyOnly => deliveryMode == DeliveryMode.nearbyOnly;
  final Future<Map<String, dynamic>> Function() deviceState;
  final void Function(Map<String, dynamic>) onStatus;
  final int listenPort;
  final List<PeerCard> bootstrapPeers;
  final bool enableLanDiscovery;
  final int discoveryPort;
  final Duration readIdleTimeout;
  final Duration trafficWindow;
  final Duration cooldownDuration;
  final int egressBytesPerPeer;
  final Duration pendingBulletinLifetime;
  final Duration automaticContactIdleTime;
  final Duration outboundFrameTimeout;
  final Duration bluetoothFrameTimeout;
  final Duration nearbyDiscoveryInterval;
  final PilotStore _store;
  static const maxPeers = 16;
  static const maxConnections = 8;
  static const maxAutomaticContacts = 8;
  static const automaticAdmissionsPerWindow = 16;
  static const maxFrameBytes = 32768;
  static const maxEndpointsPerPeer = 6;
  static const maxEndpoints = 64;
  static const ingressBytesPerPeer = 1024 * 1024;
  static const ingressBytesGlobal = 4 * 1024 * 1024;
  static const egressBytesGlobal = 4 * 1024 * 1024;
  static const framesPerPeer = 600;
  static const framesGlobal = 2400;
  static const requestItemsPerPeer = 512;
  static const requestItemsGlobal = 2048;
  static const responseRepeatMs = 10000;
  static const maxRecentResponses = 512;
  static const invalidPublisherObjectsPerWindow = 16;
  static const newChannelsPerPeer = 8;
  static const newChannelsGlobal = 32;
  static const incomingHandshakesPerAddress = 16;
  static const incomingHandshakesGlobal = 64;
  static const maxIncomingHandshakes = 4;
  static const _connectionLogKinds = {
    'connected',
    'connect_failed',
    'tls_rejected',
    'read_idle_timeout',
    'global_ingress_limit',
    'global_frame_limit',
  };
  final _TrafficWindow _globalTraffic = _TrafficWindow();
  final Map<String, _PeerTraffic> _peerTraffic = {};
  int _egressDeferred = 0;
  int _requestDeferred = 0;
  int _trafficLogSuppressed = 0;
  int _handshakesDeferred = 0;
  int _channelsDeferred = 0;
  int _incomingHandshakes = 0;
  int _handshakeWindowStart = 0;
  int _handshakeAttempts = 0;
  final Map<String, int> _handshakeAddresses = {};
  final Map<String, PeerCard> _peers = {};
  final Map<String, String> _origins = {};
  final Map<String, int> _automaticContactUsefulAt = {};
  int _automaticAdmissionWindowStart = 0;
  int _automaticAdmissions = 0;
  int _automaticAdmissionsDeferred = 0;
  int _backgroundGossip = 0;
  int _gossipDeferred = 0;
  final Map<String, SignedChannel> _channels = {};
  final Set<String> _blockedPeers = {};
  final Map<String, _PendingBulletin> _pendingBulletins = {};
  final Map<String, _Link> _links = {};
  final Set<String> _connecting = {};
  final Set<RawSocket> _handshakes = {};
  final List<RawServerSocket> _servers = [];
  final Map<String, List<_Endpoint>> _endpoints = {};
  final Map<String, _NativeRoute> _nativeRoutes = {};
  final Map<String, _DiscoveryHint> _discoveryHints = {};
  final Random _random = Random.secure();
  final Stopwatch _clock = Stopwatch()..start();
  final String _session = DateTime.now().microsecondsSinceEpoch.toString();
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _loading;
  SecurityContext? _serverContext;
  Timer? _retryTimer;
  Timer? _inventoryTimer;
  Timer? _statusTimer;
  Timer? _discoveryStatusTimer;
  Timer? _localBeaconTimer;
  Future<void>? _localSeedProbe;
  PeerDiscovery? _discovery;
  int? _searchStartedMs;
  String? _discoveryLastError;
  bool _running = false;
  bool _activeMode = false;
  int _port = 45871;
  int? _bluetoothIngressPort;
  int? _localWifiIngressPort;
  int? _wifiDirectIngressPort;
  int? get bluetoothIngressPort => _bluetoothIngressPort;
  bool _promotionInProgress = false;
  int _generation = 0;
  int _rejected = 0;
  int _duplicateCount = 0;
  String? _lastError;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _lifecycle.then((_) => action());
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _load() => _loading ??= () async {
    await _store.load();
    for (final raw in _store.channels.values) {
      final channel = SignedChannel.fromJson(raw);
      _channels[channel.id] = channel;
    }
    for (final value in _store.peers.values) {
      final peer = PeerCard.fromJson(value);
      if (peer.id != identity.id && _peers.length < maxPeers) {
        _peers[peer.id] = peer;
        _origins[peer.id] = switch (value['origin']) {
          'lan' || 'auto' || 'wifiDirect' || 'bluetooth' => 'lan',
          'bootstrap' => 'bootstrap',
          null || 'manual' => 'manual',
          _ => 'lan',
        };
        if (_origins[peer.id] == 'lan') {
          // A stored self-signed pin establishes no currently working route.
          _automaticContactUsefulAt[peer.id] =
              _clock.elapsedMilliseconds -
              automaticContactIdleTime.inMilliseconds;
        }
      }
    }
    // Protect already cached configured identities before selecting any auto
    // victim, regardless of ordering in the newly bundled bootstrap list.
    for (final peer in bootstrapPeers.take(maxPeers)) {
      if (peer.host.isNotEmpty &&
          _peers.containsKey(peer.id) &&
          _origins[peer.id] != 'manual') {
        _peers[peer.id] = peer;
        _origins[peer.id] = 'bootstrap';
        _automaticContactUsefulAt.remove(peer.id);
      }
    }
    for (final peer in bootstrapPeers.take(maxPeers)) {
      if (peer.id == identity.id || peer.host.isEmpty) continue;
      if (!_peers.containsKey(peer.id) && _peers.length >= maxPeers) {
        final stale = _oldestStaleAutomaticContact(_clock.elapsedMilliseconds);
        if (stale == null) continue;
        _forgetAutomaticContact(stale);
      }
      if (_origins[peer.id] != 'manual') {
        _peers[peer.id] = peer;
        _origins[peer.id] = 'bootstrap';
      }
    }
    for (final peer in _peers.values) {
      _setSavedEndpoint(peer);
    }
    await _savePeers();
  }();

  Future<void> _savePeers() => _store.setPeers(
    _peers.values
        .map(
          (peer) => {...peer.toJson(), 'origin': _origins[peer.id] ?? 'manual'},
        )
        .toList(),
  );

  void _syncChannels() {
    _channels.removeWhere((id, _) => !_store.channels.containsKey(id));
    for (final entry in _store.channels.entries) {
      _channels.putIfAbsent(
        entry.key,
        () => SignedChannel.fromJson(entry.value),
      );
    }
  }

  int get _bootstrapCount => nearbyOnly
      ? 0
      : bootstrapPeers
            .where((p) => p.host.isNotEmpty && p.id != identity.id)
            .map((p) => p.id)
            .toSet()
            .length;

  String get _discoveryState {
    if (_links.isNotEmpty) return 'connected';
    if (nearbyOnly && _running) return 'searching';
    if (!_running) return 'waitingForBootstrap';
    final initialSearch =
        _searchStartedMs != null &&
        _clock.elapsedMilliseconds - _searchStartedMs! < 12000;
    return initialSearch || _bootstrapCount > 0
        ? 'searching'
        : 'waitingForBootstrap';
  }

  Future<void> _startDiscovery() async {
    _searchStartedMs = _clock.elapsedMilliseconds;
    _discoveryLastError = null;
    _discoveryStatusTimer = Timer(const Duration(seconds: 12), _notify);
    if (nearbyOnly) {
      final transport = localWifiTransport;
      if (transport == null) {
        _discoveryLastError = 'local_wifi_unavailable';
        return;
      }
      final generation = _generation;
      try {
        await transport.start(
          tcpPort: _port,
          ingressPort: _localWifiIngressPort!,
          wifiDirectIngressPort: _wifiDirectIngressPort!,
          discoveryPort: discoveryPort,
          signedBeacon: createDiscoveryBeacon(),
          onBeacon: (bytes, address) {
            if (!_running || _generation != generation) return;
            try {
              final peer = PeerDiscovery.parseBeacon(bytes, address);
              unawaited(
                _serial(() async {
                  if (_running && _generation == generation) {
                    await _admitDiscovered(peer);
                  }
                }).catchError((Object _) {}),
              );
            } on FormatException {
              // Untrusted datagrams never admit a TLS certificate.
            }
          },
          onState: (error) {
            if (!_running || _generation != generation) return;
            _discoveryLastError = error;
            _notify();
          },
        );
        _localBeaconTimer = Timer.periodic(nearbyDiscoveryInterval, (_) {
          if (!_running || _generation != generation) return;
          unawaited(
            transport.updateBeacon(createDiscoveryBeacon()).catchError((
              Object _,
            ) {
              if (_running && _generation == generation) {
                _discoveryLastError = 'local_wifi_unavailable';
                _notify();
              }
            }),
          );
          unawaited(_probeNearbyBootstrap(transport, generation));
        });
        unawaited(_probeNearbyBootstrap(transport, generation));
      } catch (_) {
        // BLE remains usable; never fall back to a default-network socket.
        _discoveryLastError = 'local_wifi_unavailable';
      }
      return;
    }
    // The listener also serves explicit Wi-Fi Direct probes when ordinary LAN
    // multicast is disabled. An address hint alone never admits a certificate.
    _discovery = PeerDiscovery(
      identity: identity,
      listenPort: _port,
      port: discoveryPort,
      multicast: enableLanDiscovery,
      seedAddresses: bootstrapPeers
          .where((p) => p.host.isNotEmpty)
          .map((p) => InternetAddress.tryParse(p.host))
          .whereType<InternetAddress>()
          .toList(),
      onPeer: (peer) {
        unawaited(
          _serial(() => _admitDiscovered(peer)).catchError((Object _) {
            _discoveryLastError = 'discovery_admission_failed';
            _notify();
          }),
        );
      },
      onDiagnostic: (error) {
        if (_discoveryLastError != error) {
          final category = error == null
              ? 'ready'
              : RegExp(r'^[a-z0-9_]{1,80}$').hasMatch(error)
              ? error
              : 'discovery_failed';
          unawaited(
            _event('discovery_state_changed', extra: {'reason': category}),
          );
        }
        _discoveryLastError = error;
        _notify();
      },
    );
    await _discovery!.start();
  }

  Future<void> _probeNearbyBootstrap(
    LocalWifiTransport transport,
    int generation,
  ) {
    if (!_running || _generation != generation) return Future<void>.value();
    final pending = _localSeedProbe;
    if (pending != null) return pending;
    late final Future<void> tracked;
    tracked =
        (() async {
          // Reprobe after Wi-Fi returns even when multicast cannot cross the local
          // network. A seed is only a hint: native code must admit its current link.
          for (final peer in bootstrapPeers.take(maxPeers)) {
            if (!_running || _generation != generation) return;
            if (peer.id == identity.id ||
                _blockedPeers.contains(peer.id) ||
                _links[peer.id]?.transport == PeerTransport.lan) {
              continue;
            }
            final address = InternetAddress.tryParse(peer.host);
            if (address == null) continue;
            try {
              await transport.probe(address);
            } catch (_) {
              // Off-link/unavailable seeds remain rejected; never use a raw socket.
            }
          }
        })().whenComplete(() {
          if (identical(_localSeedProbe, tracked)) _localSeedProbe = null;
        });
    _localSeedProbe = tracked;
    return tracked;
  }

  Future<void> _admitDiscovered(PeerCard peer) async {
    if (!_running ||
        _blockedPeers.contains(peer.id) ||
        peer.id == identity.id) {
      return;
    }
    if (!await _admitIdentity(peer)) return;
    if (nearbyOnly) {
      unawaited(
        localWifiTransport
                ?.probe(InternetAddress(peer.host))
                .catchError((Object _) {}) ??
            Future<void>.value(),
      );
    }
    var hint = _discoveryHints[peer.host];
    if (hint == null) {
      for (final candidate in _discoveryHints.values) {
        if (candidate.matches(InternetAddress(peer.host))) {
          hint = candidate;
          break;
        }
      }
    }
    final transport = hint?.transport ?? PeerTransport.lan;
    _putEndpoint(
      _Endpoint(
        peerId: peer.id,
        routeId: hint?.routeId ?? 'lan:${peer.host}:${peer.port}',
        transport: transport,
        host: InternetAddress(peer.host),
        port: peer.port,
        availableSinceMs: _clock.elapsedMilliseconds,
        expiresAtMs: _clock.elapsedMilliseconds + 45000,
      ),
    );
    unawaited(_dialDue());
    _notify();
  }

  Future<bool> _admitIdentity(PeerCard peer) async {
    if (_blockedPeers.contains(peer.id) ||
        peer.id == identity.id ||
        _cooling(peer.id)) {
      return false;
    }
    if (_peers.containsKey(peer.id)) return true;
    final now = _clock.elapsedMilliseconds;
    if (now - _automaticAdmissionWindowStart >= trafficWindow.inMilliseconds) {
      _automaticAdmissionWindowStart = now;
      _automaticAdmissions = 0;
    }
    if (_automaticAdmissions >= automaticAdmissionsPerWindow) {
      _automaticAdmissionsDeferred++;
      _discoveryLastError = 'discovery_admission_rate_limit';
      return false;
    }
    if (_peers.length >= maxPeers ||
        _origins.values.where((v) => v == 'lan').length >=
            maxAutomaticContacts) {
      final stale = _oldestStaleAutomaticContact(now);
      if (stale == null) {
        _discoveryLastError = 'discovery_contact_capacity';
        return false;
      }
      _forgetAutomaticContact(stale);
    }
    // Keep the pin, never a temporary native proxy or discovered dialing address.
    _peers[peer.id] = PeerCard(
      name: peer.name,
      host: '',
      port: peer.port,
      certificatePem: peer.certificatePem,
    );
    _origins[peer.id] = 'lan';
    _automaticContactUsefulAt[peer.id] = now;
    _automaticAdmissions++;
    _serverContext = _context(_peers.values);
    await _savePeers();
    await _event('unverified_contact_discovered', peerId: peer.id);
    return true;
  }

  void _forgetAutomaticContact(String id) {
    assert(_origins[id] == 'lan');
    _peers.remove(id);
    _origins.remove(id);
    _automaticContactUsefulAt.remove(id);
    _endpoints.remove(id);
    _peerTraffic.remove(id);
    _pendingBulletins.removeWhere((_, pending) => pending.peerId == id);
  }

  String? _oldestStaleAutomaticContact(int now) {
    // An inbound handshake has no authenticated peer ID yet. Keep its entire
    // context pinned until it finishes instead of revoking a possible signer.
    if (_incomingHandshakes > 0) return null;
    String? oldest;
    int? oldestTime;
    for (final entry in _automaticContactUsefulAt.entries) {
      final id = entry.key;
      if (_origins[id] != 'lan' ||
          _links.containsKey(id) ||
          _connecting.contains(id) ||
          _nativeRoutes.values.any((route) => route.peerId == id) ||
          now - entry.value < automaticContactIdleTime.inMilliseconds) {
        continue;
      }
      if (oldestTime == null || entry.value < oldestTime) {
        oldest = id;
        oldestTime = entry.value;
      }
    }
    return oldest;
  }

  Uint8List createDiscoveryBeacon() => PeerDiscovery.beacon(identity, _port);

  Future<NativeAdmission> admitNativePeer({
    required Uint8List signedBeacon,
    required String routeId,
    required PeerTransport transport,
  }) => _serial(() async {
    await _load();
    _validateNativeRoute(routeId, transport);
    if (nearbyOnly && transport == PeerTransport.wifiDirect) {
      return const NativeAdmission(accepted: false);
    }
    if (!_running) return const NativeAdmission(accepted: false);
    final peer = PeerDiscovery.parseBeacon(
      signedBeacon,
      InternetAddress.loopbackIPv4,
    );
    final previous = _nativeRoutes[routeId];
    if (previous != null &&
        (previous.peerId != peer.id || previous.transport != transport)) {
      throw const FormatException('A native route cannot change its identity.');
    }
    if (!_nativeRoutes.containsKey(routeId) && _nativeRoutes.length >= 16) {
      return const NativeAdmission(accepted: false);
    }
    if (!await _admitIdentity(peer)) {
      return const NativeAdmission(accepted: false);
    }
    _nativeRoutes[routeId] = _NativeRoute(peer.id, transport);
    _notify();
    return NativeAdmission(
      accepted: true,
      peerId: peer.id,
      ingressPort: transport == PeerTransport.bluetooth
          ? _bluetoothIngressPort
          : _port,
    );
  });

  Future<void> registerNativeEndpoint({
    required String peerId,
    required String routeId,
    required PeerTransport transport,
    required InternetAddress host,
    required int port,
  }) => _serial(() async {
    _validateNativeRoute(routeId, transport);
    if (nearbyOnly && transport == PeerTransport.wifiDirect) {
      throw StateError('Wi-Fi Direct is disabled in nearby-only mode.');
    }
    final route = _nativeRoutes[routeId];
    if (!_running ||
        route == null ||
        route.peerId != peerId ||
        route.transport != transport ||
        !_peers.containsKey(peerId) ||
        _blockedPeers.contains(peerId)) {
      throw StateError('Native route must be admitted before dialing.');
    }
    if (port < 1 ||
        port > 65535 ||
        host.isMulticast ||
        host.address == '0.0.0.0' ||
        host.address == '::' ||
        (transport == PeerTransport.bluetooth && !host.isLoopback)) {
      throw ArgumentError('Invalid native endpoint.');
    }
    _putEndpoint(
      _Endpoint(
        peerId: peerId,
        routeId: routeId,
        transport: transport,
        host: host,
        port: port,
        availableSinceMs: _clock.elapsedMilliseconds,
      ),
    );
    unawaited(_dialDue());
    _notify();
  });

  Future<void> removeNativeRoute(String routeId) => _serial(() async {
    _nativeRoutes.remove(routeId);
    _discoveryHints.removeWhere((_, value) => value.routeId == routeId);
    for (final candidates in _endpoints.values) {
      candidates.removeWhere((endpoint) => endpoint.routeId == routeId);
    }
    for (final link in _links.values.toList()) {
      if (link.routeId == routeId) _drop(link, 'native_route_lost');
    }
    unawaited(_dialDue());
    _notify();
  });

  Future<void> probeDiscoveryAddress(
    InternetAddress address, {
    required PeerTransport transport,
    required String routeId,
    List<Map<String, dynamic>> localAddresses = const [],
  }) => _serial(() async {
    _validateNativeRoute(routeId, transport);
    if (nearbyOnly) return;
    if (transport != PeerTransport.wifiDirect ||
        address.isMulticast ||
        address.address == '0.0.0.0' ||
        address.address == '::') {
      throw ArgumentError('Wi-Fi Direct requires a unicast address hint.');
    }
    if (!_running) return;
    if (_discoveryHints.length >= 16 &&
        !_discoveryHints.containsKey(address.address)) {
      throw StateError('Too many native address hints.');
    }
    if (localAddresses.length > 8) {
      throw ArgumentError('Too many local interface addresses.');
    }
    final networks = <(InternetAddress, int)>[];
    for (final entry in localAddresses) {
      final local = entry['address'] is String
          ? InternetAddress.tryParse(entry['address'] as String)
          : null;
      final prefix = entry['prefixLength'];
      if (local == null ||
          prefix is! int ||
          prefix < 1 ||
          prefix > local.rawAddress.length * 8) {
        throw ArgumentError('Invalid native interface prefix.');
      }
      networks.add((local, prefix));
    }
    _discoveryHints[address.address] = _DiscoveryHint(
      routeId,
      transport,
      networks,
    );
    if (nearbyOnly) {
      await localWifiTransport?.probe(address);
    } else {
      _discovery?.probe(address);
    }
  });

  void _validateNativeRoute(String routeId, PeerTransport transport) {
    if (routeId.isEmpty ||
        routeId.length > 128 ||
        (transport != PeerTransport.bluetooth &&
            transport != PeerTransport.wifiDirect)) {
      throw ArgumentError('Invalid native route.');
    }
  }

  void _setSavedEndpoint(PeerCard peer) {
    final candidates = _endpoints.putIfAbsent(peer.id, () => []);
    candidates.removeWhere(
      (endpoint) => endpoint.routeId == 'saved:${peer.id}',
    );
    if (peer.host.isEmpty) return;
    final automatic = _origins[peer.id] == 'lan';
    _putEndpoint(
      _Endpoint(
        peerId: peer.id,
        routeId: 'saved:${peer.id}',
        transport: nearbyOnly || automatic
            ? PeerTransport.lan
            : PeerTransport.ip,
        host: InternetAddress(peer.host),
        port: peer.port,
        availableSinceMs: _clock.elapsedMilliseconds,
        expiresAtMs: automatic ? _clock.elapsedMilliseconds + 45000 : null,
        durable: !automatic,
      ),
    );
  }

  void _putEndpoint(_Endpoint endpoint) {
    final candidates = _endpoints.putIfAbsent(endpoint.peerId, () => []);
    for (final existing in candidates) {
      if (existing.key == endpoint.key) {
        existing.expiresAtMs = endpoint.expiresAtMs;
        return;
      }
    }
    final count = _endpoints.values.fold<int>(
      0,
      (total, values) => total + values.length,
    );
    if (candidates.length >= maxEndpointsPerPeer || count >= maxEndpoints) {
      // Stable manual/seed endpoints and active paths are never evicted by hints.
      final removable =
          candidates
              .where(
                (value) =>
                    !value.durable &&
                    value.key != _links[endpoint.peerId]?.endpointKey,
              )
              .toList()
            ..sort((a, b) => a.availableSinceMs.compareTo(b.availableSinceMs));
      if (removable.isEmpty) throw StateError('Endpoint capacity reached.');
      candidates.remove(removable.first);
    }
    candidates.add(endpoint);
  }

  Future<void> start({required bool activeMode}) => _serial(() async {
    await _load();
    if (_running && _activeMode == activeMode) return;
    if (_running) await _stopImpl();
    _activeMode = activeMode;
    _lastError = null;
    _serverContext = _context(_peers.values);
    _running = true;
    final generation = ++_generation;
    try {
      if (nearbyOnly) {
        // Only native, interface-bound Wi-Fi sockets reach these loopback
        // ingresses. There is no wildcard or default-network IP listener.
        _port = listenPort == 0 ? 45871 : listenPort;
        final lan = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        _localWifiIngressPort = lan.port;
        _servers.add(lan);
        _listen(lan, generation, transport: PeerTransport.lan);
        final direct = await RawServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        _wifiDirectIngressPort = direct.port;
        _servers.add(direct);
        _listen(direct, generation, transport: PeerTransport.wifiDirect);
      } else {
        final ipv4 = await RawServerSocket.bind(
          InternetAddress.anyIPv4,
          listenPort,
          shared: false,
        );
        _port = ipv4.port;
        _servers.add(ipv4);
        _listen(ipv4, generation);
      }
      // A separate loopback listener attributes native Bluetooth ingress.
      // It still requires the same admitted client certificate and pinned TLS.
      final bluetooth = await RawServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      _bluetoothIngressPort = bluetooth.port;
      _servers.add(bluetooth);
      _listen(bluetooth, generation, transport: PeerTransport.bluetooth);
      if (!nearbyOnly) {
        try {
          final ipv6 = await RawServerSocket.bind(
            InternetAddress.anyIPv6,
            _port,
            v6Only: true,
            shared: false,
          );
          _servers.add(ipv6);
          _listen(ipv6, generation);
        } on SocketException {
          await _event('ipv6_listener_unavailable');
        }
      }
      _retryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_dialDue());
      });
      _inventoryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        for (final link in _links.values.toList()) {
          unawaited(_sendInventory(link));
        }
      });
      await _event('engine_started', extra: {'activeMode': activeMode});
      await _startDiscovery();
      unawaited(_dialDue());
      _notify();
    } catch (_) {
      _lastError = 'listen_failed';
      await _stopImpl();
      rethrow;
    }
  });

  Future<void> stop() => _serial(_stopImpl);

  Future<void> _stopImpl() async {
    _running = false;
    _generation++;
    _retryTimer?.cancel();
    _inventoryTimer?.cancel();
    _retryTimer = null;
    _inventoryTimer = null;
    _discoveryStatusTimer?.cancel();
    _discoveryStatusTimer = null;
    _localBeaconTimer?.cancel();
    _localBeaconTimer = null;
    _localSeedProbe = null;
    // Closing native flows comes before removing any TLS listeners.
    try {
      await localWifiTransport?.stop();
    } catch (_) {
      _lastError = 'local_wifi_stop_failed';
    }
    await _discovery?.stop();
    _discovery = null;
    _bluetoothIngressPort = null;
    _localWifiIngressPort = null;
    _wifiDirectIngressPort = null;
    _pendingBulletins.clear();
    for (final server in _servers.toList()) {
      await server.close();
    }
    _servers.clear();
    for (final socket in _handshakes.toList()) {
      await socket.close();
    }
    _handshakes.clear();
    final closingLinks = _links.values.toList();
    for (final link in closingLinks) {
      _drop(link, 'stopped');
    }
    await Future.wait(closingLinks.map((link) => link.processing));
    _connecting.clear();
    _nativeRoutes.clear();
    _discoveryHints.clear();
    _endpoints.clear();
    for (final peer in _peers.values) {
      _setSavedEndpoint(peer);
    }
    _promotionInProgress = false;
    await _store.flush();
    _notify();
  }

  Future<void> addPeer(PeerCard peer) => _serial(() async {
    await _load();
    if (peer.id == identity.id) throw ArgumentError('Cannot pair with self.');
    if (peer.host.isNotEmpty && InternetAddress.tryParse(peer.host) == null) {
      throw ArgumentError('Only numeric IP addresses are permitted.');
    }
    if (peer.port < 1 || peer.port > 65535) {
      throw ArgumentError('Invalid peer port.');
    }
    if (!_peers.containsKey(peer.id) && _peers.length >= maxPeers) {
      throw StateError('The pilot supports at most 16 paired participants.');
    }
    _peers[peer.id] = peer;
    _origins[peer.id] = 'manual';
    _automaticContactUsefulAt.remove(peer.id);
    _setSavedEndpoint(peer);
    _blockedPeers.remove(peer.id);
    await _savePeers();
    if (_running) {
      _serverContext = _context(_peers.values);
      unawaited(_dialDue());
    }
    _notify();
  });

  Future<void> removePeer(String id) => _serial(() async {
    await _load();
    _peers.remove(id);
    _origins.remove(id);
    _automaticContactUsefulAt.remove(id);
    _peerTraffic.remove(id);
    _endpoints.remove(id);
    _nativeRoutes.removeWhere((_, route) => route.peerId == id);
    _blockedPeers.add(id);
    await _savePeers();
    final link = _links[id];
    if (link != null) _drop(link, 'removed');
    if (_running) _serverContext = _context(_peers.values);
    // Old publication rosters deliberately retain the removed participant.
    _notify();
  });

  SecurityContext _context(Iterable<PeerCard> peers) {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identity.certPem))
      ..usePrivateKeyBytes(utf8.encode(identity.keyPem))
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
    for (final peer in peers) {
      context.setTrustedCertificatesBytes(utf8.encode(peer.certificatePem));
    }
    return context;
  }

  void _listen(
    RawServerSocket server,
    int generation, {
    PeerTransport? transport,
  }) {
    server.listen(
      (socket) {
        if (!_running ||
            generation != _generation ||
            _links.length + _handshakes.length + _connecting.length >=
                maxConnections) {
          unawaited(socket.close());
          return;
        }
        if (_incomingHandshakes >= maxIncomingHandshakes ||
            !_allowIncomingHandshake(socket.remoteAddress)) {
          _handshakesDeferred++;
          unawaited(socket.close());
          return;
        }
        _incomingHandshakes++;
        _handshakes.add(socket);
        unawaited(() async {
          RawSecureSocket? secure;
          var expired = false;
          try {
            final handshake = RawSecureSocket.secureServer(
              socket,
              _serverContext!,
              requestClientCertificate: true,
              requireClientCertificate: true,
            );
            // Future.timeout does not cancel a TLS handshake. Destroy late results.
            unawaited(
              handshake.then<void>((result) {
                if (expired) unawaited(result.close());
              }, onError: (Object _, StackTrace _) {}),
            );
            secure = await handshake.timeout(
              transport == PeerTransport.bluetooth
                  ? const Duration(seconds: 30)
                  : const Duration(seconds: 6),
            );
            final certificate = secure.peerCertificate;
            final id = certificate == null
                ? ''
                : sha256.convert(certificate.der).toString();
            if (!_running ||
                generation != _generation ||
                !_peers.containsKey(id)) {
              await secure.close();
              _rejected++;
              return;
            }
            final route = _incomingRoute(id, socket.remoteAddress, transport);
            if (transport == PeerTransport.bluetooth && route == null) {
              await secure.close();
              _rejected++;
              return;
            }
            _adopt(
              secure,
              _peers[id]!,
              true,
              transport: transport ?? route?.transport ?? PeerTransport.ip,
              routeId: route?.routeId ?? 'incoming:ip:$id',
            );
          } catch (error) {
            expired = true;
            await secure?.close();
            await socket.close();
            _rejected++;
            if (_running && generation == _generation) {
              await _event(
                'tls_rejected',
                extra: {'reason': _transportReason(error)},
              );
            }
          } finally {
            _incomingHandshakes--;
            _handshakes.remove(socket);
            _notify();
          }
        }());
      },
      onError: (Object _) {
        _lastError = 'listener_error';
        _notify();
      },
    );
  }

  bool _allowIncomingHandshake(InternetAddress address) {
    final now = _clock.elapsedMilliseconds;
    if (now - _handshakeWindowStart >= trafficWindow.inMilliseconds) {
      _handshakeWindowStart = now;
      _handshakeAttempts = 0;
      _handshakeAddresses.clear();
    }
    // Apply before TLS allocates/does cryptographic work. The global cap also
    // bounds this address table, without exporting or persisting IP addresses.
    final count = _handshakeAddresses[address.address] ?? 0;
    if (_handshakeAttempts >= incomingHandshakesGlobal ||
        count >=
            (nearbyOnly && address.isLoopback
                ? incomingHandshakesGlobal
                : incomingHandshakesPerAddress)) {
      return false;
    }
    _handshakeAttempts++;
    _handshakeAddresses[address.address] = count + 1;
    return true;
  }

  Future<void> _dialDue() async {
    if (!_running) return;
    _expirePendingBulletins();
    for (final link in _links.values.toList()) {
      if (_clock.elapsedMilliseconds - link.lastReceivedMs >
          readIdleTimeout.inMilliseconds) {
        unawaited(_event('read_idle_timeout', peerId: link.peerId));
        _drop(link, 'read_idle_timeout');
      }
    }
    final now = _clock.elapsedMilliseconds;
    for (final candidates in _endpoints.values) {
      candidates.removeWhere(
        (endpoint) =>
            endpoint.expiresAtMs != null &&
            endpoint.expiresAtMs! < now &&
            endpoint.key != _links[endpoint.peerId]?.endpointKey,
      );
    }
    for (final peer in _peers.values.toList()) {
      if (!_running ||
          _links.length + _handshakes.length + _connecting.length >=
              maxConnections) {
        break;
      }
      if (_connecting.contains(peer.id)) {
        continue;
      }
      if (_cooling(peer.id)) continue;
      final link = _links[peer.id];
      final available =
          (_endpoints[peer.id] ?? <_Endpoint>[])
              .where(
                (endpoint) =>
                    endpoint.nextAttemptMs <= now &&
                    (endpoint.expiresAtMs == null ||
                        endpoint.expiresAtMs! >= now),
              )
              .toList()
            ..sort((a, b) {
              final priority = a.transport.index.compareTo(b.transport.index);
              return priority != 0
                  ? priority
                  : a.failures.compareTo(b.failures);
            });
      if (available.isEmpty) continue;
      final endpoint = available.first;
      final promotion = link != null;
      if (promotion &&
          (_promotionInProgress ||
              endpoint.transport.index >= link.transport.index ||
              now - endpoint.availableSinceMs < 20000 ||
              now - link.connectedAtMs < 30000)) {
        continue;
      }
      _connecting.add(peer.id);
      if (promotion) _promotionInProgress = true;
      unawaited(_connect(peer, endpoint, _generation, promotion: promotion));
    }
  }

  Future<void> _connect(
    PeerCard peer,
    _Endpoint endpoint,
    int generation, {
    bool promotion = false,
  }) async {
    RawSocket? raw;
    RawSecureSocket? socket;
    try {
      final address = endpoint.host;
      final ({InternetAddress host, int port}) destination;
      if (nearbyOnly && endpoint.transport != PeerTransport.bluetooth) {
        final transport = localWifiTransport;
        if (transport == null) throw StateError('local_wifi_unavailable');
        destination = await transport.open(address, endpoint.port);
        if (!destination.host.isLoopback) {
          throw StateError('local_wifi_proxy_invalid');
        }
      } else {
        destination = (host: address, port: endpoint.port);
      }
      if (!_running || generation != _generation) return;
      raw = await RawSocket.connect(
        destination.host,
        destination.port,
        timeout: const Duration(seconds: 6),
      );
      if (!_running || generation != _generation) {
        await raw.close();
        return;
      }
      _handshakes.add(raw);
      var expired = false;
      final handshake = RawSecureSocket.secure(
        raw,
        host: address,
        context: _context([peer]),
        // Self-signed names do not match a numeric endpoint. Never accept any
        // certificate except the complete DER fingerprint paired by the user.
        onBadCertificate: (certificate) =>
            sha256.convert(certificate.der).toString() == peer.id,
      );
      unawaited(
        handshake.then<void>((result) {
          if (expired) unawaited(result.close());
        }, onError: (Object _, StackTrace _) {}),
      );
      try {
        socket = await handshake.timeout(
          endpoint.transport == PeerTransport.bluetooth
              ? const Duration(seconds: 30)
              : const Duration(seconds: 6),
        );
      } catch (_) {
        expired = true;
        await raw.close();
        rethrow;
      }
      final actual = socket.peerCertificate;
      if (!_running ||
          generation != _generation ||
          !_peers.containsKey(peer.id) ||
          !(_endpoints[peer.id]?.contains(endpoint) ?? false) ||
          actual == null ||
          sha256.convert(actual.der).toString() != peer.id) {
        await socket.close();
        return;
      }
      endpoint.failures = 0;
      endpoint.nextAttemptMs = 0;
      _adopt(
        socket,
        peer,
        false,
        transport: endpoint.transport,
        routeId: endpoint.routeId,
        endpointKey: endpoint.key,
      );
    } catch (error) {
      await socket?.close();
      await raw?.close();
      if (_running && generation == _generation) {
        final reason = _transportReason(error);
        _lastError = reason;
        final attempts = min(endpoint.failures + 1, 6);
        endpoint.failures = attempts;
        final delay = min(60, 1 << attempts) + _random.nextInt(3);
        endpoint.nextAttemptMs = _clock.elapsedMilliseconds + delay * 1000;
        await _event(
          'connect_failed',
          peerId: peer.id,
          extra: {'reason': reason, 'transport': endpoint.transport.name},
        );
      }
    } finally {
      _handshakes.remove(raw);
      if (generation == _generation) {
        _connecting.remove(peer.id);
        if (promotion) _promotionInProgress = false;
        unawaited(_dialDue());
      }
      _notify();
    }
  }

  String _transportReason(Object error) {
    if (error is HandshakeException) return 'tls_handshake_failed';
    if (error is TlsException) return 'tls_failed';
    if (error is TimeoutException) return 'connection_timeout';
    if (error is SocketException) {
      final code = error.osError?.errorCode;
      return code == null ? 'socket_failed' : 'socket_os_error_$code';
    }
    return 'connection_failed';
  }

  _IncomingRoute? _incomingRoute(
    String peerId,
    InternetAddress source,
    PeerTransport? forced,
  ) {
    if (forced == PeerTransport.bluetooth) {
      for (final entry in _nativeRoutes.entries) {
        if (entry.value.peerId == peerId && entry.value.transport == forced) {
          return _IncomingRoute(entry.key, forced!);
        }
      }
      return null;
    }
    final matches =
        (_endpoints[peerId] ?? <_Endpoint>[])
            .where((endpoint) => endpoint.host.address == source.address)
            .toList()
          ..sort((a, b) => a.transport.index.compareTo(b.transport.index));
    return matches.isEmpty
        ? null
        : _IncomingRoute(matches.first.routeId, matches.first.transport);
  }

  void _adopt(
    RawSecureSocket socket,
    PeerCard peer,
    bool incoming, {
    required PeerTransport transport,
    required String routeId,
    String? endpointKey,
  }) {
    if (_cooling(peer.id)) {
      unawaited(socket.close());
      return;
    }
    final existing = _links[peer.id];
    if (existing != null) {
      final preferredIncoming = identity.id.compareTo(peer.id) > 0;
      if (transport.index > existing.transport.index ||
          (transport == existing.transport &&
              (existing.incoming == preferredIncoming ||
                  incoming != preferredIncoming))) {
        unawaited(socket.close());
        return;
      }
      _drop(existing, 'duplicate_link');
    }
    final link = _Link(
      socket,
      peer.id,
      incoming,
      transport: transport,
      routeId: routeId,
      endpointKey: endpointKey,
      connectedAtMs: _clock.elapsedMilliseconds,
    );
    link.lastReceivedMs = _clock.elapsedMilliseconds;
    _links[peer.id] = link;
    if (_origins[peer.id] == 'lan') {
      // Only a successfully adopted pinned TLS link renews a cached contact.
      // Repeated signed discovery beacons alone cannot keep dead routes pinned.
      _automaticContactUsefulAt[peer.id] = _clock.elapsedMilliseconds;
    }
    link.subscription = socket.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          while (!link.closed) {
            final bytes = socket.read(maxFrameBytes);
            if (bytes == null) break;
            _read(link, bytes);
          }
        } else if (event == RawSocketEvent.write) {
          socket.writeEventsEnabled = false;
          final ready = link.writeReady;
          link.writeReady = null;
          if (ready != null && !ready.isCompleted) ready.complete();
        } else if (event == RawSocketEvent.readClosed ||
            event == RawSocketEvent.closed) {
          _drop(link, 'closed');
        }
      },
      onError: (Object _) => _drop(link, 'connection_error'),
      onDone: () => _drop(link, 'closed'),
      cancelOnError: true,
    );
    unawaited(
      _event(
        'connected',
        peerId: peer.id,
        extra: {'transport': transport.name},
      ),
    );
    unawaited(_sendInventory(link));
    _notify();
  }

  void _read(_Link link, Uint8List bytes) {
    if (!_running || !_peers.containsKey(link.peerId) || link.closed) return;
    final traffic = _traffic(link.peerId);
    if (traffic.window.ingressBytes + bytes.length > ingressBytesPerPeer) {
      _reject(link, 'peer_ingress_limit', protocolAbuse: true);
      return;
    }
    if (_globalTraffic.ingressBytes + bytes.length > ingressBytesGlobal) {
      _globalTraffic.exhausted = true;
      _reject(link, 'global_ingress_limit');
      return;
    }
    traffic.window.ingressBytes += bytes.length;
    _globalTraffic.ingressBytes += bytes.length;
    for (final byte in bytes) {
      if (byte == 10) {
        final line = Uint8List.fromList(link.buffer);
        link.buffer.clear();
        if (line.isEmpty) continue;
        final current = _traffic(link.peerId);
        if (++current.window.ingressFrames > framesPerPeer ||
            ++link.pendingFrames > 64) {
          _reject(link, 'peer_rate_limit', protocolAbuse: true);
          return;
        }
        if (++_globalTraffic.ingressFrames > framesGlobal) {
          _globalTraffic.exhausted = true;
          _reject(link, 'global_frame_limit');
          return;
        }
        link.processing = link.processing.then((_) async {
          if (link.closed || !_running || !_peers.containsKey(link.peerId)) {
            return;
          }
          String? frameType;
          try {
            final value = jsonDecode(utf8.decode(line));
            if (value is! Map<String, dynamic>) throw const FormatException();
            frameType = value['type'] is String
                ? value['type'] as String
                : null;
            await _handle(link, value);
            link.lastReceivedMs = _clock.elapsedMilliseconds;
          } catch (_) {
            // Relays may carry bad publisher objects without originating them.
            // Such content cannot establish transport misconduct by that relay.
            if (const {'channel', 'bulletin', 'receipt'}.contains(frameType)) {
              _discardPublisherObject(link, 'invalid_publisher_object');
            } else {
              _reject(link, 'invalid_frame', protocolAbuse: true);
            }
          } finally {
            link.pendingFrames--;
          }
        });
      } else {
        link.buffer.add(byte);
        if (link.buffer.length > maxFrameBytes) {
          _reject(link, 'oversize_frame', protocolAbuse: true);
          return;
        }
      }
    }
  }

  Future<void> _handle(_Link link, Map<String, dynamic> frame) async {
    if (const {'channel', 'bulletin', 'receipt'}.contains(frame['type']) &&
        _traffic(link.peerId).window.invalidObjects >=
            invalidPublisherObjectsPerWindow) {
      return;
    }
    switch (frame['type']) {
      case 'inventory':
        final bulletinIds = _ids(frame['bulletins'], 256);
        final receiptIds = _ids(frame['receipts'], 128);
        final channelIds = _ids(frame['channels'] ?? <String>[], 32);
        final missingChannels = channelIds
            .where((id) => !_store.channels.containsKey(id))
            .toList();
        final missingBulletins = bulletinIds
            .where((id) => !_store.bulletins.containsKey(id))
            .toList();
        final missingReceipts = receiptIds
            .where((id) => !_store.receipts.containsKey(id))
            .toList();
        for (
          var i = 0;
          i <
              max(
                max(missingBulletins.length, missingReceipts.length),
                missingChannels.length,
              );
          i += 16
        ) {
          await _send(link, {
            'type': 'want',
            'bulletins': missingBulletins.skip(i).take(16).toList(),
            'receipts': missingReceipts.skip(i).take(16).toList(),
            'channels': missingChannels.skip(i).take(16).toList(),
          });
        }
      case 'want':
        final channelIds = _ids(frame['channels'] ?? <String>[], 16);
        final bulletinIds = _ids(frame['bulletins'], 16);
        final receiptIds = _ids(frame['receipts'], 16);
        if (!_allowRequests(
          link,
          channelIds.length + bulletinIds.length + receiptIds.length,
        )) {
          return;
        }
        for (final id in channelIds) {
          final value = _store.channels[id];
          if (value != null) {
            await _sendResponse(link, 'channel:$id', {
              'type': 'channel',
              'value': value,
            });
          }
        }
        for (final id in bulletinIds) {
          final value = _store.bulletins[id];
          if (value != null) {
            final channelId = SignedBulletin.fromJson(value).channelId;
            final channel = _store.channels[channelId];
            if (channel != null) {
              await _send(link, {'type': 'channel', 'value': channel});
            }
            await _sendResponse(link, 'bulletin:$id', {
              'type': 'bulletin',
              'value': value,
            });
          }
        }
        for (final id in receiptIds) {
          final value = _store.receipts[id];
          if (value != null && _isDiagnosticReceipt(value)) {
            await _sendResponse(link, 'receipt:$id', {
              'type': 'receipt',
              'value': value['envelope'],
            });
          }
        }
      case 'channel':
        final value = Map<String, dynamic>.from(frame['value'] as Map);
        final knownId = value['id'];
        if (knownId is! String || !_store.channels.containsKey(knownId)) {
          final traffic = _traffic(link.peerId);
          if (traffic.window.newChannels >= newChannelsPerPeer ||
              _globalTraffic.newChannels >= newChannelsGlobal) {
            _channelsDeferred++;
            return;
          }
          // Count attempts before signature parsing, including invalid objects.
          traffic.window.newChannels++;
          _globalTraffic.newChannels++;
        }
        final channel = SignedChannel.fromJson(value);
        bool inserted;
        try {
          inserted = await _store.putChannel(channel.toJson());
        } on ChannelCapacityException catch (error) {
          _lastError = error.reason;
          await _event(
            'channel_cache_limited',
            peerId: link.peerId,
            extra: {'reason': error.reason},
          );
          _notify();
          return;
        }
        if (inserted) {
          _syncChannels();
          await _broadcast({
            'type': 'channel',
            'value': channel.toJson(),
          }, except: link.peerId);
          _notify();
        }
        _expirePendingBulletins();
        for (final pending in _pendingBulletins.values.toList()) {
          final bulletin = SignedBulletin.fromJson(pending.value);
          if (bulletin.channelId == channel.id) {
            _pendingBulletins.remove(bulletin.id);
            await _receiveBulletin(
              link,
              pending.value,
              receivedTransport: pending.transport,
              receivedAtWallMs: pending.receivedAtWallMs,
              receivedNetwork: pending.network,
              deferred: true,
            );
          }
        }
      case 'bulletin':
        final value = Map<String, dynamic>.from(frame['value'] as Map);
        await _receiveBulletin(link, value);
      case 'receipt':
        final value = Map<String, dynamic>.from(frame['value'] as Map);
        if (utf8.encode(jsonEncode(value)).length > 16384) {
          throw const FormatException('Oversize envelope');
        }
        final receipt = SignedReceipt.fromJson(value);
        // Ordinary public news has no per-reader measurement ACK. This also
        // excludes cached ACKs created by older versions of the app.
        if (!_isDiagnosticReceipt({'envelope': value})) return;
        if (receipt.receiverId != identity.id &&
            !_peers.containsKey(receipt.receiverId)) {
          // A relay may know recipients that this node has never enrolled. Such
          // ACKs cannot count as evidence here and must not tear down news paths.
          return;
        }
        if (!receipt.verifyAgainst(_peers, identity)) {
          _discardPublisherObject(link, 'bad_receipt_signature');
          return;
        }
        final rawBulletin = _store.bulletins[receipt.bulletinId];
        if (rawBulletin == null) return;
        final bulletin = SignedBulletin.fromJson(rawBulletin);
        if (bulletin.sourceId != receipt.sourceId ||
            bulletin.runId != receipt.runId ||
            _hasReceipt(receipt.bulletinId, receipt.receiverId)) {
          return;
        }
        final observation = await _observeReceipt(receipt);
        if (await _store.putReceipt(value, observation)) {
          await _broadcast({
            'type': 'receipt',
            'value': value,
          }, except: link.peerId);
          _notify();
        }
      default:
        throw const FormatException('Unknown protocol frame');
    }
  }

  Future<void> _receiveBulletin(
    _Link link,
    Map<String, dynamic> value, {
    PeerTransport? receivedTransport,
    int? receivedAtWallMs,
    String? receivedNetwork,
    bool deferred = false,
  }) async {
    final generation = _generation;
    if (!_running || link.closed) return;
    final transport = receivedTransport ?? link.transport;
    final arrivedAt = receivedAtWallMs ?? DateTime.now().millisecondsSinceEpoch;
    if (utf8.encode(jsonEncode(value)).length > maxEnvelopeBytes) {
      throw const FormatException('Oversize envelope');
    }
    final bulletin = SignedBulletin.fromJson(value);
    bool valid;
    if (bulletin.channelId != null) {
      final rawChannel = _store.channels[bulletin.channelId];
      if (rawChannel == null) {
        final network = receivedNetwork ?? await _receivedNetwork();
        if (!_running || generation != _generation || link.closed) return;
        if (_store.channels.containsKey(bulletin.channelId)) {
          // Another TLS link may have admitted metadata during state sampling.
          // Validate now instead of parking news after its replay already ran.
          await _receiveBulletin(
            link,
            value,
            receivedTransport: transport,
            receivedAtWallMs: arrivedAt,
            receivedNetwork: network,
            deferred: deferred,
          );
          return;
        }
        // Several TLS links may finish native state sampling concurrently.
        // Fairness and insertion must run together without another await.
        _expirePendingBulletins();
        final fromPeer = _pendingBulletins.entries
            .where((entry) => entry.value.peerId == link.peerId)
            .toList();
        if (!_pendingBulletins.containsKey(bulletin.id) &&
            fromPeer.length >= 4) {
          _pendingBulletins.remove(fromPeer.first.key);
        }
        if (!_pendingBulletins.containsKey(bulletin.id) &&
            _pendingBulletins.length >= 16) {
          // A newcomer may replace an excess slot, but never another peer's
          // sole slot. One sender cannot squat on all deferred validation work.
          final counts = <String, int>{};
          for (final pending in _pendingBulletins.values) {
            counts.update(
              pending.peerId,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          }
          final excess = _pendingBulletins.entries.where(
            (entry) => counts[entry.value.peerId]! > 1,
          );
          if (excess.isNotEmpty) _pendingBulletins.remove(excess.first.key);
        }
        if (_pendingBulletins.length < 16) {
          _pendingBulletins.putIfAbsent(
            bulletin.id,
            () => _PendingBulletin(
              value,
              transport,
              arrivedAt,
              network,
              link.peerId,
              _clock.elapsedMilliseconds,
            ),
          );
        }
        await _send(link, {
          'type': 'want',
          'channels': [bulletin.channelId],
          'bulletins': <String>[],
          'receipts': <String>[],
        });
        return;
      }
      // Store admission can become visible while the admitting link still
      // awaits its durable write, before the derived channel cache is synced.
      valid = bulletin.verifyForChannel(
        _channels[bulletin.channelId] ?? SignedChannel.fromJson(rawChannel),
      );
    } else {
      // Legacy pilot messages retain the explicit manual-pair trust boundary.
      final paired = Map<String, PeerCard>.fromEntries(
        _peers.entries.where((entry) => _origins[entry.key] == 'manual'),
      );
      valid = bulletin.verifyAgainst(paired, identity);
    }
    if (!valid) {
      if (deferred) {
        // A different peer may have supplied the pending bytes. Do not frame
        // the authenticated peer that subsequently supplied channel metadata.
        _rejected++;
        await _event('bad_bulletin_signature');
      } else {
        _discardPublisherObject(link, 'bad_bulletin_signature');
      }
      return;
    }
    final network = receivedNetwork ?? await _receivedNetwork();
    if (!_running || generation != _generation || link.closed) return;
    if (!await _store.putBulletin(
      value,
      observation: {
        'receivedVia': transport.name,
        'receivedAtWallMs': arrivedAt,
        'receivedNetwork': network,
      },
    )) {
      _duplicateCount++;
      if (_store.bulletins.containsKey(bulletin.id) &&
          _isDiagnosticBulletin(bulletin)) {
        await _makeReceipt(bulletin, await _state());
      }
      return;
    }
    // A commit accepted before stopping remains durable. A replaced link or
    // new engine session must reconcile it rather than forward from old work.
    if (!_running || generation != _generation || link.closed) return;
    await _event(
      'bulletin_verified',
      peerId: link.peerId,
      extra: {
        'bulletinId': bulletin.id,
        'sourceId': bulletin.sourceId,
        if (bulletin.channelId != null) 'channelId': bulletin.channelId,
        'receivedVia': transport.name,
      },
    );
    final receipt = _isDiagnosticBulletin(bulletin)
        ? await _createReceipt(bulletin, await _state())
        : null;
    if (!_running || generation != _generation || link.closed) return;
    if (bulletin.channelId != null) {
      final currentChannel = _store.channels[bulletin.channelId];
      if (currentChannel != null) {
        await _broadcast({
          'type': 'channel',
          'value': currentChannel,
        }, except: link.peerId);
      }
    }
    if (!_running || generation != _generation || link.closed) return;
    await _broadcast({'type': 'bulletin', 'value': value}, except: link.peerId);
    if (receipt != null &&
        _running &&
        generation == _generation &&
        !link.closed) {
      await _broadcast({'type': 'receipt', 'value': receipt.toJson()});
    }
    _notify();
  }

  void _expirePendingBulletins() {
    final now = _clock.elapsedMilliseconds;
    _pendingBulletins.removeWhere(
      (_, pending) =>
          now - pending.queuedAtMs >= pendingBulletinLifetime.inMilliseconds,
    );
  }

  List<String> _ids(dynamic raw, int limit) {
    if (raw is! List || raw.length > limit) throw const FormatException();
    return raw.map((value) {
      if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
        throw const FormatException();
      }
      return value;
    }).toList();
  }

  bool _hasReceipt(String bulletinId, String receiverId) {
    for (final saved in _store.receipts.values) {
      final receipt = SignedReceipt.fromJson(
        Map<String, dynamic>.from(saved['envelope'] as Map),
      );
      if (receipt.bulletinId == bulletinId &&
          receipt.receiverId == receiverId) {
        return true;
      }
    }
    return false;
  }

  bool _isDiagnosticBulletin(SignedBulletin bulletin) =>
      bulletin.channelId == null &&
      (bulletin.sourceId == identity.id ||
          _origins[bulletin.sourceId] == 'manual');

  bool _isDiagnosticReceipt(Map<String, dynamic> saved) {
    final receipt = SignedReceipt.fromJson(
      Map<String, dynamic>.from(saved['envelope'] as Map),
    );
    final rawBulletin = _store.bulletins[receipt.bulletinId];
    if (rawBulletin != null) {
      final bulletin = SignedBulletin.fromJson(rawBulletin);
      return _isDiagnosticBulletin(bulletin) &&
          bulletin.sourceId == receipt.sourceId &&
          bulletin.runId == receipt.runId;
    }
    // A local diagnostic publication can outlive the bounded relay cache.
    // Unattributed orphan receipts fail closed and never initiate a fetch.
    final publication = _store.publications[receipt.bulletinId];
    return publication != null &&
        publication['channelId'] == null &&
        receipt.sourceId == identity.id &&
        publication['runId'] == receipt.runId;
  }

  Iterable<Map<String, dynamic>> get _diagnosticReceipts =>
      _store.receipts.values.where(_isDiagnosticReceipt);

  Future<Map<String, dynamic>> _state() async {
    try {
      final raw = await deviceState();
      return {
        for (final key in [
          'elapsedRealtimeMs',
          'bootId',
          'wallTimeMs',
          'isLocked',
          'locked',
          'lockStateKnown',
          'screenOn',
          'powerSave',
          'deviceIdle',
          'platform',
          'batteryExempt',
          'lowPowerStandby',
          'batteryPercent',
          'charging',
          'network',
          'internetValidated',
          'manufacturer',
          'model',
          'osVersion',
          'sdk',
          'targetSdk',
          'appVersion',
        ])
          if (raw[key] is String || raw[key] is num || raw[key] is bool)
            key: raw[key],
      };
    } catch (_) {
      return {'stateUnavailable': true};
    }
  }

  Future<String> _receivedNetwork() async {
    try {
      // Public news stores only the network label, not a device-state sample.
      final value = (await deviceState())['network'];
      return value is String && value.length <= 64 ? value : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  String _clockToken(Map<String, dynamic> state) {
    final boot = state['bootId'];
    return boot is String && boot.isNotEmpty ? boot : 'session:$_session';
  }

  Future<void> _makeReceipt(
    SignedBulletin bulletin,
    Map<String, dynamic> state,
  ) async {
    final receipt = await _createReceipt(bulletin, state);
    if (receipt != null) {
      await _broadcast({'type': 'receipt', 'value': receipt.toJson()});
    }
  }

  Future<SignedReceipt?> _createReceipt(
    SignedBulletin bulletin,
    Map<String, dynamic> state,
  ) async {
    if (!_isDiagnosticBulletin(bulletin) ||
        bulletin.sourceId == identity.id ||
        _hasReceipt(bulletin.id, identity.id)) {
      return null;
    }
    final receipt = SignedReceipt.create(
      identity,
      bulletinId: bulletin.id,
      sourceId: bulletin.sourceId,
      runId: bulletin.runId,
      locked: state['isLocked'] == true || state['locked'] == true,
      lockStateKnown:
          (state['isLocked'] is bool || state['locked'] is bool) &&
          state['lockStateKnown'] != false,
      elapsedRealtimeMs: (state['elapsedRealtimeMs'] as num?)?.toInt(),
    );
    if (await _store.putReceipt(receipt.toJson(), {
      'observedAtWallMs': DateTime.now().millisecondsSinceEpoch,
      'localDeviceState': state,
    })) {
      // The bulletin and this receipt have both completed flushed writes.
      return receipt;
    }
    return null;
  }

  Future<Map<String, dynamic>> _observeReceipt(SignedReceipt receipt) async {
    final state = await _state();
    final publication = _store.publications[receipt.bulletinId];
    final observedElapsed = (state['elapsedRealtimeMs'] as num?)?.toInt();
    final publishedElapsed =
        (publication?['publishedElapsedRealtimeMs'] as num?)?.toInt();
    int? upperBound;
    if (receipt.sourceId == identity.id &&
        publication != null &&
        observedElapsed != null &&
        publishedElapsed != null &&
        publication['clockToken'] == _clockToken(state) &&
        observedElapsed >= publishedElapsed) {
      upperBound = observedElapsed - publishedElapsed;
    }
    return {
      'observedAtWallMs': DateTime.now().millisecondsSinceEpoch,
      'sourceUpperBoundMs': upperBound,
      'withinFiveMinutes': upperBound != null && upperBound <= 300000,
      'lockedWithinFiveMinutes':
          upperBound != null &&
          upperBound <= 300000 &&
          receipt.locked &&
          receipt.lockStateKnown,
      'localDeviceState': state,
    };
  }

  Future<void> publish({required String runId, required String text}) =>
      _serial(() async {
        await _load();
        if (!_running) throw StateError('Start a test mode before publishing.');
        await _publish(runId: runId, text: text);
      });

  Future<SignedChannel> createChannel({
    required String name,
    String description = '',
  }) => _serial(() async {
    await _load();
    final channel = SignedChannel.create(
      publisherIdentity,
      name: name,
      description: description,
    );
    await _store.putChannel(channel.toJson());
    _syncChannels();
    _queueGossip([
      {'type': 'channel', 'value': channel.toJson()},
    ]);
    _notify();
    return channel;
  });

  Future<void> publishToChannel({
    required String channelId,
    required String text,
    String runId = 'news',
  }) => _serial(() async {
    await _load();
    final raw = _store.channels[channelId];
    if (raw == null ||
        !(_channels[channelId] ?? SignedChannel.fromJson(raw)).ownedBy(
          publisherIdentity,
        )) {
      throw StateError('Only the channel owner can publish to this channel.');
    }
    // Offline posts are durably queued and reconciled on the next connection.
    await _publish(runId: runId, text: text, channelId: channelId);
  });

  Future<void> _publish({
    required String runId,
    required String text,
    String? channelId,
  }) async {
    final state = channelId == null ? await _state() : <String, dynamic>{};
    final bulletin = SignedBulletin.create(
      channelId == null ? identity : publisherIdentity,
      runId: runId,
      text: text,
      sequence: channelId == null
          ? await _store.nextSequence()
          : await _store.nextChannelSequence(channelId),
      channelId: channelId,
    );
    final recipients = channelId == null
        ? (_peers.keys.where((id) => _origins[id] == 'manual').toList()..sort())
        : <String>[];
    await _store.putPublication(bulletin.toJson(), {
      'id': bulletin.id,
      'runId': bulletin.runId,
      'createdAtMs': bulletin.createdAtMs,
      'recipients': recipients,
      if (channelId == null) ...{
        'publishedElapsedRealtimeMs': state['elapsedRealtimeMs'],
        'clockToken': _clockToken(state),
        'activeMode': _activeMode,
      },
      'channelId': ?channelId,
    });
    await _event(
      'published',
      extra: {'bulletinId': bulletin.id, 'recipientCount': recipients.length},
    );
    if (channelId != null) {
      final channel = _store.channels[channelId];
      _queueGossip([
        if (channel != null) {'type': 'channel', 'value': channel},
        {'type': 'bulletin', 'value': bulletin.toJson()},
      ]);
    } else {
      // Diagnostic tests retain their existing awaited send behavior.
      await _broadcast({'type': 'bulletin', 'value': bulletin.toJson()});
    }
    _notify();
  }

  void _queueGossip(List<Map<String, dynamic>> frames) {
    if (!_running || _links.isEmpty) return;
    if (_backgroundGossip >= 16) {
      // The durable cache and future inventories still contain this update.
      _gossipDeferred++;
      return;
    }
    final generation = _generation;
    _backgroundGossip++;
    unawaited(() async {
      try {
        for (final frame in frames) {
          if (!_running || generation != _generation) return;
          // Keep channel metadata before its bulletin in this bounded chain.
          await _broadcast(frame);
        }
      } catch (_) {
        _lastError = 'gossip_send_failed';
        _notify();
      } finally {
        _backgroundGossip--;
      }
    }());
  }

  Future<void> _sendInventory(_Link link) async {
    final ids = _diagnosticReceipts
        .map((saved) => (saved['envelope'] as Map)['id'] as String)
        .toList()
        .reversed
        .toList();
    final start = ids.isEmpty ? 0 : link.receiptOffset % ids.length;
    final page = <String>[
      for (var i = 0; i < min(128, ids.length); i++)
        ids[(start + i) % ids.length],
    ];
    link.receiptOffset = ids.isEmpty ? 0 : (start + page.length) % ids.length;
    final channelIds = _store.channels.keys.toList();
    final channelStart = channelIds.isEmpty
        ? 0
        : link.channelOffset % channelIds.length;
    final channelPage = <String>[
      for (var i = 0; i < min(32, channelIds.length); i++)
        channelIds[(channelStart + i) % channelIds.length],
    ];
    link.channelOffset = channelIds.isEmpty
        ? 0
        : (channelStart + channelPage.length) % channelIds.length;
    await _send(link, {
      'type': 'inventory',
      'bulletins': _store.bulletins.keys.toList().reversed.toList(),
      'receipts': page,
      'channels': channelPage,
    });
  }

  Future<void> _broadcast(Map<String, dynamic> frame, {String? except}) async {
    await Future.wait(
      _links.values
          .toList()
          .where((link) => link.peerId != except)
          .map((link) => _send(link, frame)),
    );
  }

  _PeerTraffic _traffic(String peerId) {
    final now = _clock.elapsedMilliseconds;
    final value = _peerTraffic.putIfAbsent(peerId, _PeerTraffic.new);
    value.window.refresh(now, trafficWindow.inMilliseconds);
    _globalTraffic.refresh(now, trafficWindow.inMilliseconds);
    return value;
  }

  bool _cooling(String peerId) =>
      (_peerTraffic[peerId]?.cooldownUntilMs ?? 0) > _clock.elapsedMilliseconds;

  void _discardPublisherObject(_Link link, String reason) {
    final traffic = _traffic(link.peerId);
    if (traffic.window.invalidObjects >= invalidPublisherObjectsPerWindow) {
      return;
    }
    traffic.window.invalidObjects++;
    _rejected++;
    // A bounded local discard, not a transport strike or a public accusation.
    unawaited(_event(reason));
  }

  bool _allowRequests(_Link link, int count) {
    final traffic = _traffic(link.peerId);
    if (traffic.window.requestItems + count > requestItemsPerPeer ||
        _globalTraffic.requestItems + count > requestItemsGlobal) {
      if (_globalTraffic.requestItems + count > requestItemsGlobal) {
        _globalTraffic.exhausted = true;
      }
      // Ignore excess work rather than accusing a relay carrying a large cache.
      // The regular inventory will ask again in a later budget window.
      _requestDeferred++;
      return false;
    }
    traffic.window.requestItems += count;
    _globalTraffic.requestItems += count;
    return true;
  }

  Future<void> _sendResponse(
    _Link link,
    String key,
    Map<String, dynamic> frame,
  ) async {
    final traffic = _traffic(link.peerId);
    final now = _clock.elapsedMilliseconds;
    traffic.responses.removeWhere(
      (_, sentAt) => now - sentAt >= responseRepeatMs,
    );
    if (traffic.responses.containsKey(key)) return;
    if (await _send(link, frame, requested: true)) {
      if (traffic.responses.length >= maxRecentResponses) {
        traffic.responses.remove(traffic.responses.keys.first);
      }
      traffic.responses[key] = _clock.elapsedMilliseconds;
    }
  }

  Future<bool> _send(
    _Link link,
    Map<String, dynamic> frame, {
    bool requested = false,
  }) async {
    if (link.closed || !_running) return false;
    String? channelId;
    if (frame['type'] == 'channel') {
      channelId = (frame['value'] as Map)['id'] as String;
      // Suppress automatic repeats, but honor bounded explicit requests: the
      // receiver may have deferred admission or rotated its public cache.
      if (!requested && link.announcedChannels.contains(channelId)) {
        return false;
      }
    }
    final bytes = utf8.encode('${jsonEncode(frame)}\n');
    if (bytes.length > maxFrameBytes || link.writer.pending >= 32) {
      _reject(link, 'write_queue_limit');
      return false;
    }
    final traffic = _traffic(link.peerId);
    if (traffic.window.egressBytes + bytes.length > egressBytesPerPeer ||
        _globalTraffic.egressBytes + bytes.length > egressBytesGlobal) {
      if (_globalTraffic.egressBytes + bytes.length > egressBytesGlobal) {
        _globalTraffic.exhausted = true;
      }
      // A skipped send remains in the durable cache. Never mark an unsent
      // channel as announced; anti-entropy must be able to catch it up later.
      _egressDeferred++;
      return false;
    }
    traffic.window.egressBytes += bytes.length;
    _globalTraffic.egressBytes += bytes.length;
    if (channelId != null) {
      if (link.announcedChannels.length >= PilotStore.maxChannels) {
        link.announcedChannels.remove(link.announcedChannels.first);
      }
      link.announcedChannels.add(channelId);
    }
    return link.writer.enqueue(
      deadline: link.transport == PeerTransport.bluetooth
          ? bluetoothFrameTimeout
          : outboundFrameTimeout,
      onFailure: () => _drop(link, 'write_failed'),
      operation: () async {
        if (link.closed || !_running) return;
        var offset = 0;
        while (offset < bytes.length && !link.closed && _running) {
          final written = link.socket.write(bytes, offset);
          if (written > 0) {
            offset += written;
          } else {
            final ready = Completer<void>();
            link.writeReady = ready;
            link.socket.writeEventsEnabled = true;
            await ready.future.timeout(const Duration(seconds: 6));
          }
        }
      },
    );
  }

  void _reject(_Link link, String reason, {bool protocolAbuse = false}) {
    if (link.closed) return;
    _rejected++;
    if (protocolAbuse) {
      final traffic = _traffic(link.peerId);
      final now = _clock.elapsedMilliseconds;
      if (now - traffic.strikeStartedAtMs >=
          const Duration(minutes: 5).inMilliseconds) {
        traffic.strikes = 0;
        traffic.strikeStartedAtMs = now;
      }
      if (++traffic.strikes >= 3) {
        traffic.strikes = 0;
        traffic.cooldownUntilMs = now + cooldownDuration.inMilliseconds;
        unawaited(_event('peer_cooldown_started', peerId: link.peerId));
      }
    }
    unawaited(_event(reason, peerId: link.peerId));
    _drop(link, reason);
  }

  void _drop(_Link link, String reason) {
    if (link.closed) return;
    link.closed = true;
    link.writer.close();
    unawaited(link.socket.close());
    final ready = link.writeReady;
    link.writeReady = null;
    if (ready != null && !ready.isCompleted) ready.complete();
    unawaited(link.subscription?.cancel());
    if (identical(_links[link.peerId], link)) _links.remove(link.peerId);
    if (_running && reason != 'duplicate_link') {
      for (final endpoint in _endpoints[link.peerId] ?? <_Endpoint>[]) {
        if (endpoint.key == link.endpointKey) {
          endpoint.nextAttemptMs =
              _clock.elapsedMilliseconds + (2 + _random.nextInt(3)) * 1000;
        }
      }
      unawaited(_dialDue());
    }
    _notify();
  }

  Future<void> _event(
    String kind, {
    String? peerId,
    Map<String, dynamic>? extra,
  }) async {
    _globalTraffic.refresh(
      _clock.elapsedMilliseconds,
      trafficWindow.inMilliseconds,
    );
    if (_globalTraffic.exhausted &&
        _connectionLogKinds.contains(kind) &&
        !_globalTraffic.loggedCategories.add(kind)) {
      // Common event gate covers rejection and connection churn caused by
      // close/retry paths. Counters still count every actual rejection.
      _trafficLogSuppressed++;
      return;
    }
    try {
      await _store.event({
        'atWallMs': DateTime.now().millisecondsSinceEpoch,
        'kind': kind,
        'peerId': ?peerId,
        ...?extra,
      });
    } catch (_) {
      _lastError = 'storage_log_failed';
    }
  }

  void _notify() {
    if (_statusTimer?.isActive ?? false) return;
    _statusTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(() async {
        try {
          onStatus(await snapshot());
        } catch (_) {
          // UI callbacks must not stop the transport.
        }
      }());
    });
  }

  List<Map<String, dynamic>> _publicationResults() {
    final index = <String, Map<String, Map<String, dynamic>>>{};
    for (final saved in _diagnosticReceipts) {
      final receipt = SignedReceipt.fromJson(
        Map<String, dynamic>.from(saved['envelope'] as Map),
      );
      (index[receipt.bulletinId] ??= {})[receipt.receiverId] = {
        'receiverId': receipt.receiverId,
        'locked': receipt.locked,
        'lockStateKnown': receipt.lockStateKnown,
        ...Map<String, dynamic>.from(saved['observation'] as Map),
      };
    }
    final results = <Map<String, dynamic>>[];
    for (final publication in _store.publications.values) {
      if (publication['channelId'] != null) continue;
      final id = publication['id'] as String;
      final recipients = List<String>.from(publication['recipients'] as List);
      final rows = recipients
          .map(
            (receiverId) =>
                index[id]?[receiverId] ??
                {
                  'receiverId': receiverId,
                  'withinFiveMinutes': false,
                  'lockedWithinFiveMinutes': false,
                  'status': 'missing',
                },
          )
          .toList();
      results.add({
        ...publication,
        'receipts': rows,
        'expected': recipients.length,
        'received': rows.where((r) => r['status'] != 'missing').length,
        'withinFiveMinutes': rows
            .where((r) => r['withinFiveMinutes'] == true)
            .length,
        'lockedWithinFiveMinutes': rows
            .where((r) => r['lockedWithinFiveMinutes'] == true)
            .length,
      });
    }
    return results;
  }

  List<Map<String, dynamic>> _trialResults() => _publicationResults().map((
    value,
  ) {
    final receipts = List<Map<String, dynamic>>.from(value['receipts'] as List);
    final confirmed = value['lockedWithinFiveMinutes'] as int;
    final timelyUnlocked = receipts
        .where(
          (r) =>
              r['withinFiveMinutes'] == true &&
              r['locked'] != true &&
              r['lockStateKnown'] == true,
        )
        .length;
    return {
      'bulletinId': value['id'],
      'runId': value['runId'],
      'enrolled': value['expected'],
      'confirmed': confirmed,
      'timelyUnlocked': timelyUnlocked,
      'unknown': (value['expected'] as int) - confirmed - timelyUnlocked,
      'createdAtMs': value['createdAtMs'],
      'receipts': receipts,
    };
  }).toList();

  Future<Map<String, dynamic>> snapshot() async {
    await _load();
    return {
      'running': _running,
      'activeMode': _activeMode,
      'listenPort': _port,
      'identityId': identity.id,
      'deliveryMode': deliveryMode.name,
      'peerCount': _peers.length,
      'connectedCount': _links.length,
      'bluetoothIngressPort': _bluetoothIngressPort,
      'activeTransportCounts': {
        for (final transport in PeerTransport.values)
          transport.name: _links.values
              .where((link) => link.transport == transport)
              .length,
      },
      'discoveryState': _discoveryState,
      'discoveryLastError': _discoveryLastError,
      'bootstrapConfiguredCount': _bootstrapCount,
      'discoveredCount': _origins.values
          .where((origin) => origin == 'lan')
          .length,
      'peers': _peers.values
          .map(
            (peer) => {
              ...peer.toJson(),
              'id': peer.id,
              'connected': _links.containsKey(peer.id),
              'transport': _links[peer.id]?.transport.name,
              'endpointCount': _endpoints[peer.id]?.length ?? 0,
              'origin': _origins[peer.id] ?? 'manual',
              'trust': switch (_origins[peer.id]) {
                'lan' => 'unverified',
                'bootstrap' => 'configured',
                _ => 'paired',
              },
            },
          )
          .toList(),
      'bulletinCount': _store.bulletins.length,
      'receiptCount': _diagnosticReceipts.length,
      'rejectedCount': _rejected,
      'duplicateCount': _duplicateCount,
      'trafficDeferred': {
        'egress': _egressDeferred,
        'requests': _requestDeferred,
        'channels': _channelsDeferred,
        'handshakes': _handshakesDeferred,
        'contacts': _automaticAdmissionsDeferred,
        'gossip': _gossipDeferred,
      },
      'incomingHandshakeCount': _incomingHandshakes,
      'pendingBulletinCount': _pendingBulletins.length,
      'coolingPeerCount': _peerTraffic.keys.where(_cooling).length,
      'trafficLogSuppressedCount': _trafficLogSuppressed,
      'lastError': _lastError,
      'bulletins': _store.bulletins.values.toList().reversed.map((raw) {
        final bulletin = SignedBulletin.fromJson(raw);
        return {
          'id': bulletin.id,
          'sourceId': bulletin.sourceId,
          'runId': bulletin.runId,
          'text': bulletin.text,
          'createdAtMs': bulletin.createdAtMs,
          'sequence': bulletin.sequence,
          'channelId': bulletin.channelId,
          'localPublication': _store.publications.containsKey(bulletin.id),
          'receivedVia': _store.publications.containsKey(bulletin.id)
              ? 'local'
              : _store.bulletinObservations[bulletin.id]?['receivedVia'] ??
                    'unknown',
          'receivedAtWallMs':
              _store.bulletinObservations[bulletin.id]?['receivedAtWallMs'],
          'receivedNetwork':
              _store.bulletinObservations[bulletin.id]?['receivedNetwork'] ??
              'unknown',
        };
      }).toList(),
      'channels': _channels.values.map((channel) {
        final bulletins = _store.bulletins.values
            .map(SignedBulletin.fromJson)
            .where((b) => b.channelId == channel.id)
            .toList();
        return {
          'id': channel.id,
          'name': channel.name,
          'description': channel.description,
          'ownerId': channel.ownerId,
          'createdAtMs': channel.createdAtMs,
          'owned': channel.ownedBy(publisherIdentity),
          'trust': channel.ownerId == publisherIdentity.id
              ? 'self'
              : _origins[channel.ownerId] == 'manual'
              ? 'paired'
              : 'unverified',
          'bulletinCount': bulletins.length,
          'lastSequence': bulletins.fold<int>(
            0,
            (value, b) => max(value, b.sequence),
          ),
        };
      }).toList(),
      'publications': _publicationResults(),
      'trials': _trialResults(),
      'events': _store.events.reversed.take(40).toList(),
      'evictions': Map<String, int>.from(_store.evictions),
    };
  }

  Map<String, dynamic> _exportState(Map<String, dynamic> state) {
    final result = Map<String, dynamic>.from(state)..remove('bootId');
    final boot = state['bootId'];
    if (boot is String && boot.isNotEmpty) {
      result['bootGenerationId'] = sha256
          .convert(utf8.encode('${identity.id}|$boot'))
          .toString()
          .substring(0, 12);
    }
    return result;
  }

  /// Export intentionally excludes message contents, PEMs, private keys, peer
  /// names and raw IP addresses. This is diagnostic data, not anonymous data.
  Future<String> exportReport() async {
    await _load();
    String short(String value) =>
        value.length > 12 ? value.substring(0, 12) : value;
    final publications = _publicationResults().map((raw) {
      final value = Map<String, dynamic>.from(raw)..remove('clockToken');
      value['id'] = short(value['id'] as String);
      value['recipients'] = (value['recipients'] as List)
          .map((id) => short(id as String))
          .toList();
      value['receipts'] = (value['receipts'] as List).map((row) {
        final result = Map<String, dynamic>.from(row as Map);
        result['receiverId'] = short(result['receiverId'] as String);
        final state = result['localDeviceState'];
        if (state is Map) {
          result['localDeviceState'] = _exportState(
            Map<String, dynamic>.from(state),
          );
        }
        return result;
      }).toList();
      return value;
    }).toList();
    final currentState = _exportState(await _state());
    final localReceipts = <Map<String, dynamic>>[];
    for (final saved in _diagnosticReceipts) {
      final receipt = SignedReceipt.fromJson(
        Map<String, dynamic>.from(saved['envelope'] as Map),
      );
      if (receipt.receiverId != identity.id) continue;
      final observation = Map<String, dynamic>.from(
        saved['observation'] as Map,
      );
      final state = observation['localDeviceState'];
      if (state is Map) {
        observation['localDeviceState'] = _exportState(
          Map<String, dynamic>.from(state),
        );
      }
      localReceipts.add({
        'receiptId': short(receipt.id),
        'bulletinId': short(receipt.bulletinId),
        'sourceId': short(receipt.sourceId),
        'receiverId': short(receipt.receiverId),
        'runId': receipt.runId,
        'verifiedAtWallMs': receipt.verifiedAtWallMs,
        'elapsedRealtimeMs': receipt.elapsedRealtimeMs,
        'locked': receipt.locked,
        'lockStateKnown': receipt.lockStateKnown,
        'observation': observation,
        // ACK metadata contains public IDs and a signature, never news text.
        // A partner can verify it using a separately shared peer card.
        'signedReceipt': receipt.toJson(),
      });
    }
    // Ordinary news must not turn a voluntary diagnostic export into a mapping
    // between a connection key and a publisher (or the reader's news cache).
    final receivedBulletins = _store.bulletins.values
        .map(SignedBulletin.fromJson)
        .where((bulletin) => bulletin.channelId == null)
        .map((bulletin) {
          return {
            'bulletinId': short(bulletin.id),
            'sourceId': short(bulletin.sourceId),
            'runId': bulletin.runId,
            'publishedAtWallMs': bulletin.createdAtMs,
            'isLocalSource':
                bulletin.sourceId == identity.id ||
                bulletin.sourceId == publisherIdentity.id,
            'receivedVia': _store.publications.containsKey(bulletin.id)
                ? 'local'
                : _store.bulletinObservations[bulletin.id]?['receivedVia'] ??
                      'unknown',
            'receivedNetwork':
                _store.bulletinObservations[bulletin.id]?['receivedNetwork'] ??
                'unknown',
          };
        })
        .toList();
    return const JsonEncoder.withIndent('  ').convert({
      'currentState': currentState,
      'receivedBulletins': receivedBulletins,
      'receipts': localReceipts,
      'format': 'persiantrend-pilot-report-v1',
      'exportedAtWallMs': DateTime.now().millisecondsSinceEpoch,
      'participantId': short(identity.id),
      'running': _running,
      'activeMode': _activeMode,
      'activeTransportCounts': {
        for (final transport in PeerTransport.values)
          transport.name: _links.values
              .where((link) => link.transport == transport)
              .length,
      },
      'pairedCount': _origins.values
          .where((origin) => origin == 'manual')
          .length,
      'discoveredCount': _origins.values
          .where((origin) => origin == 'lan')
          .length,
      'bootstrapConfiguredCount': _bootstrapCount,
      'discoveryState': _discoveryState,
      'discoveryLastError': _discoveryLastError,
      'connectedCount': _links.length,
      'deadlineMs': 300000,
      'proof':
          'Signed receipt returned to source within native monotonic '
          'deadline. Late or clock-unavailable receipts are unproven.',
      'limitations': [
        'Pinned TCP/TLS peers; signed local IPv4 multicast and configured seed UDP admission; no NAT traversal.',
        'Discovery pins identify keys, not verified people or newsrooms.',
        'Ordinary channel news does not emit per-reader measurement ACKs.',
        'App endpoint logs cannot prove physical domestic routing.',
        'Locked state is measured at receipt, not throughout the idle interval.',
        'All paired participants at publication remain in the denominator.',
        'Truncated local retention is disclosed by eviction counters.',
        'Signed ACK payloads include full public fingerprints and run labels.',
      ],
      'publications': publications,
      'evictions': _store.evictions,
      'events': _store.events
          .where(
            (event) =>
                !event.containsKey('bulletinId') &&
                !event.containsKey('sourceId') &&
                !event.containsKey('channelId'),
          )
          .map(
            (event) => {
              ...event,
              if (event['peerId'] is String)
                'peerId': short(event['peerId'] as String),
              if (event['bulletinId'] is String)
                'bulletinId': short(event['bulletinId'] as String),
              if (event['sourceId'] is String)
                'sourceId': short(event['sourceId'] as String),
            },
          )
          .toList(),
    });
  }
}

class _TrafficWindow {
  int startedAtMs = 0;
  int ingressBytes = 0;
  int ingressFrames = 0;
  int egressBytes = 0;
  int requestItems = 0;
  int invalidObjects = 0;
  int newChannels = 0;
  bool exhausted = false;
  final Set<String> loggedCategories = {};

  void refresh(int now, int intervalMs) {
    if (now - startedAtMs < intervalMs) return;
    startedAtMs = now;
    ingressBytes = 0;
    ingressFrames = 0;
    egressBytes = 0;
    requestItems = 0;
    invalidObjects = 0;
    newChannels = 0;
    exhausted = false;
    loggedCategories.clear();
  }
}

class _PeerTraffic {
  final window = _TrafficWindow();
  final Map<String, int> responses = {};
  int strikes = 0;
  int strikeStartedAtMs = 0;
  int cooldownUntilMs = 0;
}

/// Serial frame writes with one absolute deadline per caller, including time
/// behind earlier frames. A slow reader cannot renew this deadline by making
/// tiny amounts of progress. The failure callback closes the underlying stream.
class PeerWriteQueue {
  Future<void> _tail = Future<void>.value();
  bool _closed = false;
  int _pending = 0;
  int get pending => _pending;
  bool get closed => _closed;

  void close() => _closed = true;

  Future<bool> enqueue({
    required Duration deadline,
    required Future<void> Function() operation,
    required void Function() onFailure,
  }) async {
    if (_closed) return false;
    _pending++;
    void fail() {
      if (_closed) return;
      _closed = true;
      onFailure();
    }

    final write = _tail.then<void>((_) async {
      if (!_closed) await operation();
    });
    final bounded = write.timeout(deadline);
    _tail = bounded.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) => fail(),
    );
    try {
      await bounded;
      return !_closed;
    } catch (_) {
      fail();
      return false;
    } finally {
      _pending--;
    }
  }
}

class _Link {
  _Link(
    this.socket,
    this.peerId,
    this.incoming, {
    required this.transport,
    required this.routeId,
    required this.connectedAtMs,
    this.endpointKey,
  });
  final RawSecureSocket socket;
  final String peerId;
  final bool incoming;
  final PeerTransport transport;
  final String routeId;
  final String? endpointKey;
  final int connectedAtMs;
  StreamSubscription<RawSocketEvent>? subscription;
  Completer<void>? writeReady;
  final List<int> buffer = [];
  final Set<String> announcedChannels = {};
  Future<void> processing = Future<void>.value();
  final PeerWriteQueue writer = PeerWriteQueue();
  int receiptOffset = 0;
  int channelOffset = 0;
  int lastReceivedMs = 0;
  int pendingFrames = 0;
  bool closed = false;
}

class _Endpoint {
  _Endpoint({
    required this.peerId,
    required this.routeId,
    required this.transport,
    required this.host,
    required this.port,
    required this.availableSinceMs,
    this.expiresAtMs,
    this.durable = false,
  });
  final String peerId, routeId;
  final PeerTransport transport;
  final InternetAddress host;
  final int port, availableSinceMs;
  final bool durable;
  int? expiresAtMs;
  int failures = 0;
  int nextAttemptMs = 0;
  String get key => '${transport.name}|$routeId|${host.address}|$port';
}

class _NativeRoute {
  const _NativeRoute(this.peerId, this.transport);
  final String peerId;
  final PeerTransport transport;
}

class _DiscoveryHint {
  const _DiscoveryHint(this.routeId, this.transport, this.networks);
  final String routeId;
  final PeerTransport transport;
  final List<(InternetAddress, int)> networks;
  bool matches(InternetAddress source) {
    for (final (address, prefix) in networks) {
      final a = address.rawAddress, b = source.rawAddress;
      if (a.length != b.length) continue;
      var match = true;
      for (var bit = 0; bit < prefix; bit++) {
        final mask = 1 << (7 - bit % 8);
        if (a[bit ~/ 8] & mask != b[bit ~/ 8] & mask) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }
}

class _IncomingRoute {
  const _IncomingRoute(this.routeId, this.transport);
  final String routeId;
  final PeerTransport transport;
}

class _PendingBulletin {
  const _PendingBulletin(
    this.value,
    this.transport,
    this.receivedAtWallMs,
    this.network,
    this.peerId,
    this.queuedAtMs,
  );
  final Map<String, dynamic> value;
  final PeerTransport transport;
  final int receivedAtWallMs;
  final String network;
  final String peerId;
  final int queuedAtMs;
}
