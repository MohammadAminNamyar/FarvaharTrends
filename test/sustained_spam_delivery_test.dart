import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

// A loopback transport workload, not a phone, carrier or million-user benchmark.
// The optional soak uses production-duration traffic windows without changing
// quotas. All fixtures and connections are disposable and local to this test.
void main() {
  test('honest news survives repeated signed spam and transport identity churn', () async {
    final rounds = int.parse(Platform.environment['FT_SPAM_WINDOWS'] ?? '3');
    final seconds = int.parse(
      Platform.environment['FT_SPAM_WINDOW_SECONDS'] ?? '3',
    );
    expect(rounds, inInclusiveRange(3, 10));
    expect(seconds, inInclusiveRange(3, 60));
    final window = Duration(seconds: seconds);
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    final scratch = await parent.createTemp('sustained-spam-');
    final sockets = <_Client>[];
    final engines = <PeerEngine>[];
    addTearDown(() async {
      for (final client in sockets) {
        client.close();
      }
      for (final engine in engines.reversed) {
        await engine.stop();
      }
      await scratch.delete(recursive: true);
    });

    final receiver = Identity.generate();
    final writer = Identity.generate();
    final observer = Identity.generate();
    final spamWriters = List.generate(4, (_) => Identity.generate());
    final followed = SignedChannel.create(writer, name: 'خبرهای آزمایشی معتبر');
    final spamChannels = [
      for (var i = 0; i < spamWriters.length; i++)
        SignedChannel.create(spamWriters[i], name: 'Disposable flood $i'),
    ];
    final expected = <SignedBulletin>[];
    final measurements = <Map<String, Object>>[];
    final watch = Stopwatch()..start();

    PeerEngine makeEngine() {
      final engine = PeerEngine(
        directory: scratch,
        identity: receiver,
        listenPort: 0,
        discoveryPort: 0,
        enableLanDiscovery: false,
        trafficWindow: window,
        protectedChannelIds: {followed.id},
        onStatus: (_) {},
        deviceState: () async => {'network': 'wifi'},
      );
      engines.add(engine);
      return engine;
    }

    Future<_Client> connect(PeerEngine engine, Identity identity) async {
      await engine.addPeer(
        PeerCard(
          name: 'Disposable workload participant',
          certificatePem: identity.certPem,
        ),
      );
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        (await engine.snapshot())['listenPort'] as int,
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(identity.certPem))
          ..usePrivateKeyBytes(utf8.encode(identity.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(receiver.certPem)),
        onBadCertificate: (certificate) =>
            Identity.certificateId(certificate.pem) == receiver.id,
        timeout: const Duration(seconds: 5),
      );
      final client = _Client(socket, watch);
      sockets.add(client);
      await _until(
        () async => client.receivedInventory,
        'initial inventory on connection ${sockets.length}',
      );
      return client;
    }

    var engine = makeEngine();
    await engine.start(activeMode: false);
    var sender = await connect(engine, writer);
    var reader = await connect(engine, observer);
    await sender.send('channel', followed.toJson());
    await _until(
      () async => ((await engine.snapshot())['channels'] as List).any(
        (row) => (row as Map)['id'] == followed.id,
      ),
      'followed channel admission',
    );

    var seq = 0;
    var floodFrames = 0;
    var writtenFloodFrames = 0;
    for (var round = 0; round < rounds; round++) {
      // New authenticated connection keys each window exercise identity churn.
      // Signing sources stay fixed, so signature validity can be checked against
      // established channels while the public cache repeatedly turns over.
      final transports = List.generate(4, (_) => Identity.generate());
      final attackers = <_Client>[];
      for (var i = 0; i < transports.length; i++) {
        final client = await connect(engine, transports[i]);
        attackers.add(client);
        await client.send('channel', spamChannels[i].toJson());
      }
      await _until(
        () async => ((await engine.snapshot())['channels'] as List).length == 5,
        'flood channel admission in round $round',
      );

      // Prepare real valid signatures before timing delivery. Dummy/invalid
      // payloads would exercise the cheap rejection path instead of storage.
      final spam = [
        for (var i = 0; i < spamWriters.length; i++)
          [
            for (var n = 0; n < 120; n++)
              SignedBulletin.create(
                spamWriters[i],
                channelId: spamChannels[i].id,
                sequence: round * 120 + n + 1,
                runId: 'news',
                text: 'فقط پیام آزمایشی؛ خبر واقعی نیست. $round/$i/$n',
              ),
          ],
      ];
      final roundPosts = <SignedBulletin>[];
      final sendTimes = <String, int>{};
      final pacedBatchMs = <int>[];
      for (var batch = 0; batch < 12; batch++) {
        final batchClock = Stopwatch()..start();
        await Future.wait([
          for (var i = 0; i < attackers.length; i++)
            () async {
              for (final bulletin in spam[i].skip(batch * 10).take(10)) {
                if (attackers[i].closed) break;
                floodFrames++;
                if (await attackers[i].send('bulletin', bulletin.toJson())) {
                  writtenFloodFrames++;
                }
              }
            }(),
        ]);
        if (batch.isEven) {
          final post = SignedBulletin.create(
            writer,
            channelId: followed.id,
            sequence: ++seq,
            runId: 'news',
            text: 'آزمایش دریافت خبر هنگام ازدحام؛ مسئولیت‌پذیری $round/$batch',
          );
          roundPosts.add(post);
          expected.add(post);
          sendTimes[post.id] = watch.elapsedMilliseconds;
          expect(await sender.send('bulletin', post.toJson()), true);
        }
        if (batch < 4) {
          // First force accepted cache pressure. Merely flooding faster than
          // the parser can consume would only test disconnection, not storage.
          final markers = [for (final posts in spam) posts[batch * 10 + 9].id];
          try {
            await _until(
              () async {
                final ids = ((await engine.snapshot())['bulletins'] as List)
                    .map((row) => (row as Map)['id'])
                    .toSet();
                return markers.every(ids.contains);
              },
              'accepted flood markers in round $round batch $batch',
              timeout: const Duration(seconds: 60),
            );
            pacedBatchMs.add(batchClock.elapsedMilliseconds);
          } catch (_) {
            final state = await engine.snapshot();
            final report = jsonDecode(await engine.exportReport()) as Map;
            final news = (state['bulletins'] as List).cast<Map>();
            final sequences = [
              for (final channel in spamChannels)
                (news
                    .where((row) => row['channelId'] == channel.id)
                    .map((row) => row['sequence'] as int)
                    .toList()
                  ..sort()),
            ];
            stdout.writeln(
              'SIGNED_SPAM_FAILURE ${jsonEncode({'round': round, 'batch': batch, 'connected': state['connectedCount'], 'rejected': state['rejectedCount'], 'lastError': state['lastError'], 'cacheCount': state['bulletinCount'], 'trafficDeferred': state['trafficDeferred'], 'presentMarkers': markers.map((id) => news.any((row) => row['id'] == id)).toList(), 'sourceSequences': sequences, 'events': (report['events'] as List).cast<Map>().map((event) => event['kind']).toSet().toList()})}',
            );
            rethrow;
          }
        }
        // Then allow flooders to hit the pending-parse cap. Their
        // disconnection is an expected defense, not a delivery failure.
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      final floodEndedAtMs = watch.elapsedMilliseconds;
      await _until(() async {
        final ids = ((await engine.snapshot())['bulletins'] as List)
            .map((row) => (row as Map)['id'])
            .toSet();
        return expected.every((post) => ids.contains(post.id));
      }, 'retained honest news in round $round');
      // At least one honest post must reach the independent receiving socket
      // during every flood. Bounded egress may defer others to reconciliation.
      expect(
        roundPosts.any((post) {
          final arrivedAt = reader.arrivals[post.id];
          return arrivedAt != null && arrivedAt <= floodEndedAtMs;
        }),
        true,
        reason: 'An honest post must arrive before the flood ends.',
      );
      final state = await engine.snapshot();
      final peers = (state['peers'] as List).cast<Map>();
      for (final identity in [writer, observer]) {
        expect(
          peers.singleWhere((peer) => peer['id'] == identity.id)['connected'],
          true,
        );
      }
      expect(
        state['bulletinCount'],
        lessThanOrEqualTo(PilotStore.maxBulletins),
      );
      final report = jsonDecode(await engine.exportReport()) as Map;
      final violations = (report['events'] as List)
          .cast<Map>()
          .where(
            (event) => const {
              'peer_rate_limit',
              'peer_ingress_limit',
              'invalid_frame',
              'oversize_frame',
              'invalid_publisher_object',
            }.contains(event['kind']),
          )
          .toList();
      expect(
        violations.where(
          (event) =>
              event['kind'] == 'invalid_frame' ||
              event['kind'] == 'invalid_publisher_object',
        ),
        isEmpty,
      );
      expect(
        violations.where(
          (event) =>
              event['peerId'] == writer.id.substring(0, 12) ||
              event['peerId'] == observer.id.substring(0, 12),
        ),
        isEmpty,
      );
      measurements.add({
        'window': round + 1,
        'cacheCount': state['bulletinCount'] as int,
        'rejectedConnections': state['rejectedCount'] as int,
        'violationKinds': violations
            .map((event) => event['kind'])
            .toSet()
            .toList(),
        'honestVisibleAtRelay': expected.length,
        'pacedBatchMs': pacedBatchMs,
        'honestArrivedDuringFlood': roundPosts
            .where(
              (post) =>
                  reader.arrivals[post.id] != null &&
                  reader.arrivals[post.id]! <= floodEndedAtMs,
            )
            .length,
        'observedDeliveryMs': [
          for (final post in roundPosts)
            if (reader.arrivals[post.id] case final int at)
              at - sendTimes[post.id]!,
        ],
      });
      stdout.writeln('SIGNED_SPAM_WINDOW ${jsonEncode(measurements.last)}');

      for (var i = 0; i < attackers.length; i++) {
        attackers[i].close();
        await engine.removePeer(transports[i].id);
      }
      await _until(
        () async => (await engine.snapshot())['connectedCount'] == 2,
        'disconnecting flooders in round $round',
      );
      // Wait a whole budget period after the attack stops. Windows start on
      // traffic activity, not at the test round's clock boundary.
      await Future<void>.delayed(window + const Duration(milliseconds: 100));
      // Repeat requests reconcile any sends deferred by the shared egress cap.
      await reader.want(expected.map((post) => post.id).toList());
      await _until(
        () async =>
            expected.every((post) => reader.arrivals.containsKey(post.id)),
        'honest reconciliation in round $round',
      );
    }

    await engine.stop();
    sender.close();
    reader.close();
    final store = PilotStore(scratch, protectedChannelIds: {followed.id});
    await store.load();
    expect(store.bulletins.length, lessThanOrEqualTo(PilotStore.maxBulletins));
    expect(store.evictions['bulletins'], greaterThan(0));
    for (final post in expected) {
      expect(store.bulletins.containsKey(post.id), true);
    }
    final journalBytes = await File('${scratch.path}/pilot.jsonl').length();
    expect(journalBytes, lessThan(8 * 1024 * 1024));

    engine = makeEngine();
    await engine.start(activeMode: false);
    sender = await connect(engine, writer);
    reader = await connect(engine, observer);
    final afterRestart = SignedBulletin.create(
      writer,
      channelId: followed.id,
      sequence: ++seq,
      runId: 'news',
      text: 'پس از راه‌اندازی دوباره نیز دریافت ادامه دارد.',
    );
    expect(await sender.send('bulletin', afterRestart.toJson()), true);
    await _until(
      () async => reader.arrivals.containsKey(afterRestart.id),
      'delivery after restart',
    );
    // Public measurements only; no keys, addresses or user data are output.
    stdout.writeln(
      'SIGNED_SPAM_RESULT ${jsonEncode({'scope': 'host-loopback-TLS', 'rounds': rounds, 'trafficWindowSeconds': seconds, 'validFloodFramesAttempted': floodFrames, 'validFloodFramesWrittenToSocket': writtenFloodFrames, 'rotatingTransportIdentities': rounds * 4, 'honestPostsDelivered': expected.length, 'cacheEvictions': store.evictions['bulletins'], 'journalBytesAfterReopen': journalBytes, 'restartDelivery': true, 'measurements': measurements})}',
    );
  }, timeout: const Timeout(Duration(minutes: 40)));
}

class _Client {
  _Client(this.socket, Stopwatch watch) {
    // Real engines exchange inventories every 30 seconds. A receiving fixture
    // must do the same rather than being disconnected as a silent socket.
    _inventoryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(
        _writeFrame({
          'type': 'inventory',
          'channels': <String>[],
          'bulletins': <String>[],
          'receipts': <String>[],
        }),
      );
    });
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final frame = jsonDecode(line) as Map;
            if (frame['type'] == 'inventory') receivedInventory = true;
            if (frame['type'] == 'bulletin') {
              arrivals.putIfAbsent(
                (frame['value'] as Map)['id'] as String,
                () => watch.elapsedMilliseconds,
              );
            }
          },
          onError: (Object _) {
            close();
          },
          onDone: () {
            close();
          },
        );
  }
  final SecureSocket socket;
  late final Timer _inventoryTimer;
  Future<bool> _writes = Future<bool>.value(true);
  final arrivals = <String, int>{};
  bool receivedInventory = false;
  bool closed = false;

  void close() {
    closed = true;
    _inventoryTimer.cancel();
    socket.destroy();
  }

  Future<bool> send(String type, Map<String, dynamic> value) =>
      _writeFrame({'type': type, 'value': value});

  Future<bool> _writeFrame(Map<String, dynamic> frame) =>
      _writes = _writes.then((_) => _sendFrame(frame));

  Future<bool> _sendFrame(Map<String, dynamic> frame) async {
    if (closed) return false;
    try {
      socket.write('${jsonEncode(frame)}\n');
      await socket.flush();
      return true;
    } on SocketException {
      close();
      return false;
    }
  }

  Future<void> want(List<String> ids) async {
    for (var i = 0; i < ids.length; i += 16) {
      expect(
        await _writeFrame({
          'type': 'want',
          'channels': <String>[],
          'bulletins': ids.skip(i).take(16).toList(),
          'receipts': <String>[],
        }),
        true,
      );
    }
  }
}

Future<void> _until(
  Future<bool> Function() condition,
  String description, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final clock = Stopwatch()..start();
  while (!await condition()) {
    if (clock.elapsed > timeout) {
      fail('Signed-spam workload timed out: $description');
    }
    // Rendering a full status snapshot on every 25 ms poll can itself slow
    // signature verification and journal flushes on a loaded host.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
