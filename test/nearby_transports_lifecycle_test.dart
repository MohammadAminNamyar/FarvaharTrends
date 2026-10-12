import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/peer_discovery.dart';
import 'package:persian_trend/core/peer_engine.dart';
import 'package:persian_trend/nearby_transports.dart';

void main() {
  late Identity local, remote;
  late Directory directory;
  late PeerEngine engine;
  late _Radio radio;
  late NearbyTransports nearby;
  final states = <Map<String, dynamic>>[];
  setUpAll(() {
    local = Identity.generate();
    remote = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    directory = await parent.createTemp('nearby-lifecycle-');
    engine = PeerEngine(
      directory: directory,
      identity: local,
      listenPort: 0,
      enableLanDiscovery: false,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
    await engine.start(activeMode: false);
    radio = _Radio();
    states.clear();
    nearby = NearbyTransports(
      engine,
      platform: radio,
      onError: (_) {},
      onState: (_, state) => states.add(state),
    );
  });
  tearDown(() async {
    radio.startGate?.completeIfPending();
    radio.allowGate?.completeIfPending();
    radio.admitGate?.completeIfPending();
    await nearby.stop();
    await radio.controller.close();
    await engine.stop();
    await directory.delete(recursive: true);
  });

  test(
    'stop before queued startup does not start native radios later',
    () async {
      final starting = nearby.start();
      final stopping = nearby.stop();
      await Future.wait([starting, stopping]);
      expect(radio.starts, 0);
      expect(radio.active, false);
      await nearby.start();
      expect(radio.starts, 1);
      expect(radio.active, true);
    },
  );

  test(
    'pending native start is stopped before a replacement session starts',
    () async {
      radio.startGate = Completer<void>();
      final first = nearby.start();
      await until(() => radio.starts == 1);
      final stopped = nearby.stop();
      final replacement = nearby.start();
      radio.startGate!.complete();
      await Future.wait([first, stopped, replacement]);
      expect(radio.calls, ['start', 'stop', 'start']);
      expect(radio.active, true);
      await nearby.stop();
      expect(radio.active, false);
    },
  );

  test('repeated startup shares one native activation', () async {
    radio.startGate = Completer<void>();
    final starts = List.generate(10, (_) => nearby.start());
    await until(() => radio.starts == 1);
    radio.startGate!.complete();
    await Future.wait(starts);
    expect(radio.starts, 1);
  });

  test('stop invalidates refresh before later native commands', () async {
    await nearby.start();
    radio.allowGate = Completer<void>();
    final refreshed = nearby.refresh();
    await until(() => radio.allowCalls == 1);
    final stopping = nearby.stop();
    radio.allowGate!.complete();
    await Future.wait([refreshed, stopping]);
    expect(radio.beaconUpdates, 0);
    expect(radio.refreshCalls, 0);
    expect(radio.active, false);
  });

  test(
    'old queued radio events cannot mutate the replacement session',
    () async {
      await nearby.start();
      radio.admitGate = Completer<void>();
      radio.controller.add({
        'type': 'peerDiscovered',
        'transport': 'bluetooth',
        'routeId': 'old-route',
        'beaconBase64': base64Encode(PeerDiscovery.beacon(remote, 32123)),
      });
      await until(() => radio.admitCalls == 1);
      radio.controller.add({
        'type': 'status',
        'transport': 'bluetooth',
        'state': 'old-session-state',
      });
      final stopping = nearby.stop();
      final replacement = nearby.start();
      radio.admitGate!.complete();
      await Future.wait([stopping, replacement]);
      radio.controller.add({
        'type': 'status',
        'transport': 'bluetooth',
        'state': 'new-session-state',
      });
      await until(() => states.isNotEmpty);
      expect(states.map((value) => value['state']), ['new-session-state']);
    },
  );
}

class _Radio implements NearbyRadioPlatform {
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final calls = <String>[];
  Completer<void>? startGate, allowGate, admitGate;
  int starts = 0, allowCalls = 0, admitCalls = 0;
  int beaconUpdates = 0, refreshCalls = 0;
  bool active = false;
  @override
  bool get supported => true;
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<void> start({
    required String identityId,
    required Uint8List signedBeacon,
    required int tcpPort,
    required int bluetoothIngressPort,
  }) async {
    starts++;
    calls.add('start');
    await startGate?.future;
    active = true;
  }

  @override
  Future<void> allowWifiDirect(bool allowed) async {
    allowCalls++;
    await allowGate?.future;
  }

  @override
  Future<void> updateBeacon(Uint8List beacon) async => beaconUpdates++;
  @override
  Future<void> refresh() async => refreshCalls++;
  @override
  Future<void> stop() async {
    calls.add('stop');
    active = false;
  }

  @override
  Future<void> admitBluetooth(String routeId, bool accepted) async {
    admitCalls++;
    await admitGate?.future;
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}

Future<void> until(bool Function() condition) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 8)) {
      fail('Nearby transport condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
