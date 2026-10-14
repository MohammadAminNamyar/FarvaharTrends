import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  late Identity receiver, publisher, honest;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <Socket>[];
  setUpAll(() {
    receiver = Identity.generate();
    publisher = Identity.generate();
    honest = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('engine-hardening-');
  });
  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    await scratch.delete(recursive: true);
  });
  PeerEngine create(
    Identity identity,
    String name, {
    Duration window = const Duration(minutes: 1),
    Duration pending = const Duration(seconds: 45),
  }) {
    final engine = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: identity,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      trafficWindow: window,
      pendingBulletinLifetime: pending,
      deviceState: () async => {'network': 'wifi'},
      onStatus: (_) {},
    );
    engines.add(engine);
    return engine;
  }

  Future<SecureSocket> connect(
    PeerEngine target,
    Identity local,
    Identity remote, {
    void Function(Map<String, dynamic>)? onFrame,
  }) async {
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      (await target.snapshot())['listenPort'] as int,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(local.certPem))
        ..usePrivateKeyBytes(utf8.encode(local.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(remote.certPem)),
      onBadCertificate: (cert) => Identity.certificateId(cert.pem) == remote.id,
      timeout: const Duration(seconds: 3),
    );
    sockets.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          onFrame?.call(jsonDecode(line) as Map<String, dynamic>);
        }, onError: (Object _) {});
    return socket;
  }

  Future<void> send(
    Socket socket,
    String type,
    Map<String, dynamic> value,
  ) async {
    socket.write('${jsonEncode({'type': type, 'value': value})}\n');
    await socket.flush();
  }

  Future<void> pair(PeerEngine target, Identity peer, {int? port}) =>
      target.addPeer(
        PeerCard(
          name: 'Test peer',
          certificatePem: peer.certPem,
          host: port == null ? '' : '127.0.0.1',
          port: port ?? 45871,
        ),
      );

  test('explicit request repairs metadata deferred after an automatic announcement', () async {
    final target = create(receiver, 'metadata-repair');
    await pair(target, publisher);
    await target.start(activeMode: false);
    final frames = <Map<String, dynamic>>[];
    final client = await connect(
      target,
      publisher,
      receiver,
      onFrame: frames.add,
    );
    await until(() async => (await target.snapshot())['connectedCount'] == 1);
    final channel = await target.createChannel(
      name: 'Metadata can be requested again',
    );
    await until(
      () async => frames.where((f) => f['type'] == 'channel').length == 1,
    );
    // Simulate a receiver that deferred the announcement due to its admission
    // budget, then requests it over the same still-healthy TLS connection.
    client.write(
      '${jsonEncode({
        'type': 'want',
        'channels': [channel.id],
        'bulletins': <String>[],
        'receipts': <String>[],
      })}\n',
    );
    await client.flush();
    await until(
      () async => frames.where((f) => f['type'] == 'channel').length == 2,
    );
    expect((await target.snapshot())['connectedCount'], 1);
  });

  test(
    'incomplete TLS clients cannot consume all outgoing connection capacity',
    () async {
      final left = create(receiver, 'left');
      final right = create(honest, 'right');
      await left.start(activeMode: false);
      await right.start(activeMode: false);
      await pair(right, receiver);
      final port = (await left.snapshot())['listenPort'] as int;
      for (var i = 0; i < PeerEngine.maxIncomingHandshakes + 2; i++) {
        final raw = await Socket.connect(InternetAddress.loopbackIPv4, port);
        raw.listen((_) {}, onError: (Object _) {});
        sockets.add(raw);
      }
      await until(
        () async =>
            ((await left.snapshot())['trafficDeferred'] as Map)['handshakes'] >=
            2,
      );
      expect(
        (await left.snapshot())['incomingHandshakeCount'],
        PeerEngine.maxIncomingHandshakes,
      );
      await pair(
        left,
        honest,
        port: (await right.snapshot())['listenPort'] as int,
      );
      await until(
        () async =>
            (await left.snapshot())['connectedCount'] == 1 &&
            (await right.snapshot())['connectedCount'] == 1,
      );
      final channel = await right.createChannel(
        name: 'Valid news during slow TLS flood',
      );
      await right.publishToChannel(
        channelId: channel.id,
        text: 'Authentic delivery survives reserved inbound saturation',
      );
      await until(() async => (await left.snapshot())['bulletinCount'] == 1);
    },
  );

  test(
    'incoming handshake churn is bounded before TLS and later recovers',
    () async {
      final target = create(
        receiver,
        'churn',
        // The complete TLS churn must fit inside one rate window, even while
        // the full suite and Android emulators compete for CPU on Windows.
        window: const Duration(seconds: 10),
      );
      await pair(target, publisher);
      await target.start(activeMode: false);
      for (var i = 0; i < PeerEngine.incomingHandshakesPerAddress; i++) {
        final socket = await connect(target, publisher, receiver);
        await until(
          () async => (await target.snapshot())['connectedCount'] == 1,
        );
        socket.destroy();
        await until(
          () async =>
              (await target.snapshot())['connectedCount'] == 0 &&
              (await target.snapshot())['incomingHandshakeCount'] == 0,
        );
      }
      final raw = await Socket.connect(
        InternetAddress.loopbackIPv4,
        (await target.snapshot())['listenPort'] as int,
      );
      sockets.add(raw);
      final closed = Completer<void>();
      raw.listen(
        (_) {},
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      await closed.future.timeout(const Duration(seconds: 5));
      expect(
        ((await target.snapshot())['trafficDeferred'] as Map)['handshakes'],
        greaterThan(0),
      );
      await Future<void>.delayed(const Duration(seconds: 10));
      await connect(target, publisher, receiver);
      await until(() async => (await target.snapshot())['connectedCount'] == 1);
    },
  );

  test('missing-channel spam has per-peer slots, expires and cannot block another publisher', () async {
    final target = create(
      receiver,
      'pending',
      pending: const Duration(seconds: 2),
    );
    await pair(target, publisher);
    await pair(target, honest);
    await target.start(activeMode: false);
    final attacker = await connect(target, publisher, receiver);
    for (var i = 0; i < 20; i++) {
      await send(
        attacker,
        'bulletin',
        SignedBulletin.create(
          publisher,
          runId: 'spam',
          text: 'Unresolvable',
          sequence: i + 1,
          channelId: i.toRadixString(16).padLeft(64, '0'),
        ).toJson(),
      );
    }
    await until(
      () async => (await target.snapshot())['pendingBulletinCount'] == 4,
    );
    final client = await connect(target, honest, receiver);
    final channel = SignedChannel.create(
      honest,
      name: 'Honest metadata arrives second',
    );
    final bulletin = SignedBulletin.create(
      honest,
      runId: 'news',
      text: 'Real pending news',
      sequence: 1,
      channelId: channel.id,
    );
    await send(client, 'bulletin', bulletin.toJson());
    await until(
      () async => (await target.snapshot())['pendingBulletinCount'] == 5,
    );
    await send(client, 'channel', channel.toJson());
    await until(() async => (await target.snapshot())['bulletinCount'] == 1);
    expect((await target.snapshot())['bulletins'].single['id'], bulletin.id);
    await until(
      () async => (await target.snapshot())['pendingBulletinCount'] == 0,
    );
  });

  test(
    'new channel admission is budgeted without striking a relay, then resumes',
    () async {
      // Prepare the signed frames before starting the admission window. The
      // budget checks receiver behavior rather than parallel RSA signing speed.
      final channels = List.generate(
        9,
        (i) => SignedChannel.create(honest, name: 'Public channel $i'),
      );
      final target = create(
        receiver,
        'channels',
        window: const Duration(seconds: 20),
      );
      await pair(target, publisher);
      await target.start(activeMode: false);
      final client = await connect(target, publisher, receiver);
      for (final channel in channels) {
        client.write(
          '${jsonEncode({'type': 'channel', 'value': channel.toJson()})}\n',
        );
      }
      await client.flush();
      await until(
        () async =>
            ((await target.snapshot())['trafficDeferred'] as Map)['channels'] >
            0,
      );
      expect((await target.snapshot())['channels'], hasLength(8));
      expect((await target.snapshot())['coolingPeerCount'], 0);
      await Future<void>.delayed(const Duration(seconds: 20));
      await send(client, 'channel', channels.last.toJson());
      await until(
        () async => ((await target.snapshot())['channels'] as List).length == 9,
      );
    },
  );
}

Future<void> until(Future<bool> Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > const Duration(seconds: 12)) {
      fail('Engine hardening condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
