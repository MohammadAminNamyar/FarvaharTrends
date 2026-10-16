import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

// Real loopback TLS and reader reconciliation, with no recovery pauses in the
// offered workload. This does not model hostile automatic admission or carriers.
void main() {
  test('honest news progresses during continuous signed spam and key rotation', () async {
    // Allow a third production traffic window for cache saturation on hosts
    // where TLS, verification and journal flushes reduce the offered rate.
    // The full-cache, continuous-progress and no-starvation checks stay intact.
    final seconds = int.parse(
      Platform.environment['FT_CONTINUOUS_SPAM_SECONDS'] ?? '180',
    );
    expect(seconds, inInclusiveRange(120, 900));
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    final scratch = await parent.createTemp('continuous-spam-');
    final engines = <PeerEngine>[];
    final clients = <_Client>[];
    var running = true;
    final workers = <Future<void>>[];
    addTearDown(() async {
      running = false;
      for (final client in clients) {
        client.close();
      }
      // Workers finish before any owned directory is deleted.
      for (final worker in workers) {
        try {
          await worker;
        } catch (_) {
          // The primary assertion/worker failure is reported by the test.
        }
      }
      for (final engine in engines.reversed) {
        await engine.stop();
      }
      final expectedParent = parent.absolute.path;
      if (!scratch.absolute.path.startsWith(
        '$expectedParent${Platform.pathSeparator}',
      )) {
        throw StateError('Invalid test cleanup path.');
      }
      await scratch.delete(recursive: true);
    });

    final relayIdentity = Identity.generate();
    final readerIdentity = Identity.generate();
    final honestIdentity = Identity.generate();
    final followed = SignedChannel.create(
      honestIdentity,
      name: 'خبرهای معتبر آزمایشی',
    );
    final spamPublishers = List.generate(4, (_) => Identity.generate());
    final spamChannels = [
      for (final identity in spamPublishers)
        SignedChannel.create(identity, name: 'فقط آزمون ازدحام'),
    ];
    // Precompute signatures and transport keys before timing the workload.
    // RSA generation in the measured event loop would distort delivery times.
    final transportKeys = [
      for (var i = 0; i < 4; i++)
        List.generate((seconds / 30).ceil() + 3, (_) => Identity.generate()),
    ];
    final spam = [
      for (var i = 0; i < 4; i++)
        [
          for (var sequence = 1; sequence <= seconds + 4; sequence++)
            SignedBulletin.create(
              spamPublishers[i],
              channelId: spamChannels[i].id,
              runId: 'news',
              sequence: sequence,
              text: 'این خبر واقعی نیست؛ فقط آزمایش ازدحام پیوسته $i/$sequence',
            ),
        ],
    ];
    final honest = [
      for (var i = 0; i < (seconds / 15).ceil(); i++)
        SignedBulletin.create(
          honestIdentity,
          channelId: followed.id,
          runId: 'news',
          sequence: i + 1,
          text:
              'خبر آزمایشی هنگام ازدحام؛ مسئولیت‌پذیری و دسترس‌پذیری ${i + 1}',
        ),
    ];

    PeerEngine makeEngine(String name, Identity identity) {
      final value = PeerEngine(
        directory: Directory('${scratch.path}/$name'),
        identity: identity,
        listenPort: 0,
        discoveryPort: 0,
        enableLanDiscovery: false,
        enableUdpDiscovery: false,
        protectedChannelIds: {followed.id},
        onStatus: (_) {},
        deviceState: () async => {'network': 'wifi'},
      );
      engines.add(value);
      return value;
    }

    final relay = makeEngine('relay', relayIdentity);
    final reader = makeEngine('reader', readerIdentity);
    await relay.start(activeMode: false);
    await reader.start(activeMode: false);
    PeerCard card(PeerEngine engine) => PeerCard(
      name: 'Disposable loopback participant',
      host: '127.0.0.1',
      port: engine.boundPort,
      certificatePem: engine.identity.certPem,
    );
    await relay.addPeer(card(reader));
    await reader.addPeer(card(relay));
    await relay.addPeer(card(reader));
    await _until(
      () async => (await reader.snapshot())['connectedCount'] == 1,
      'reader connection',
    );

    Future<_Client> connect(Identity identity) async {
      await relay.addPeer(
        PeerCard(name: 'Disposable sender', certificatePem: identity.certPem),
      );
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        relay.boundPort,
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(identity.certPem))
          ..usePrivateKeyBytes(utf8.encode(identity.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(relayIdentity.certPem)),
        onBadCertificate: (cert) =>
            Identity.certificateId(cert.pem) == relayIdentity.id,
        timeout: const Duration(seconds: 5),
      );
      final client = _Client(socket);
      clients.add(client);
      await _until(
        () async => client.inventory || client.closed,
        'sender inventory',
      );
      if (client.closed) throw StateError('Sender rejected before inventory.');
      return client;
    }

    final writer = await connect(honestIdentity);
    expect(await writer.send('channel', followed.toJson()), isTrue);
    await _until(
      () async => ((await reader.snapshot())['channels'] as List).any(
        (raw) => (raw as Map)['id'] == followed.id,
      ),
      'honest metadata at reader',
    );
    final initialFlooders = <_Client>[];
    for (var i = 0; i < 4; i++) {
      final client = await connect(transportKeys[i].first);
      initialFlooders.add(client);
      expect(await client.send('channel', spamChannels[i].toJson()), isTrue);
    }
    await _until(
      () async => ((await relay.snapshot())['channels'] as List).length == 5,
      'spam metadata admission',
    );

    final clock = Stopwatch()..start();
    final sentAt = <String, int>{};
    final observedAt = <String, int>{};
    final writtenBySource = List.filled(4, 0);
    final rotationsBySource = List.filled(4, 0);
    final lastWriteBySource = List<int?>.filled(4, null);
    final maxGapBySource = List.filled(4, 0);
    final workerErrors = <Object>[];
    var maxCache = 0;
    var maxJournal = 0;
    var lastSample = -30;

    Future<void> flood(int source) async {
      var index = 0;
      var keyIndex = 0;
      var client = initialFlooders[source];
      var rotateAfter = 45 + source * 10;
      while (running && clock.elapsed.inSeconds < seconds) {
        final cycle = Stopwatch()..start();
        if (client.closed || clock.elapsed.inSeconds >= rotateAfter) {
          client.close();
          await relay.removePeer(transportKeys[source][keyIndex].id);
          keyIndex++;
          if (keyIndex >= transportKeys[source].length) {
            throw StateError(
              'Transport key bank exhausted during continuous load.',
            );
          }
          client = await connect(transportKeys[source][keyIndex]);
          rotationsBySource[source]++;
          expect(
            await client.send('channel', spamChannels[source].toJson()),
            isTrue,
          );
          rotateAfter = clock.elapsed.inSeconds + 60;
        }
        if (await client.send('bulletin', spam[source][index++].toJson())) {
          writtenBySource[source]++;
          final previous = lastWriteBySource[source];
          final now = clock.elapsedMilliseconds;
          if (previous != null && now - previous > maxGapBySource[source]) {
            maxGapBySource[source] = now - previous;
          }
          lastWriteBySource[source] = now;
        }
        final delay = 1000 - cycle.elapsedMilliseconds;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
      }
      client.close();
      await relay.removePeer(transportKeys[source][keyIndex].id);
    }

    Future<void> sendHonest() async {
      for (var i = 0; i < honest.length && running; i++) {
        final due = i * 15000;
        final wait = due - clock.elapsedMilliseconds;
        if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
        if (!running) break;
        expect(
          writer.closed,
          isFalse,
          reason: 'Honest writer must stay connected.',
        );
        sentAt[honest[i].id] = clock.elapsedMilliseconds;
        expect(await writer.send('bulletin', honest[i].toJson()), isTrue);
      }
    }

    Future<void> observe() async {
      final state = await reader.snapshot();
      for (final row in (state['bulletins'] as List).cast<Map>()) {
        final id = row['id'] as String;
        if (sentAt.containsKey(id)) {
          observedAt.putIfAbsent(id, () => clock.elapsedMilliseconds);
        }
      }
      final relayState = await relay.snapshot();
      for (final value in [state, relayState]) {
        final count = value['bulletinCount'] as int;
        if (count > maxCache) maxCache = count;
        expect(count, lessThanOrEqualTo(PilotStore.maxBulletins));
        expect(value['peerCount'], lessThanOrEqualTo(PeerEngine.maxPeers));
        expect(
          value['connectedCount'],
          lessThanOrEqualTo(PeerEngine.maxConnections),
        );
      }
      for (final role in ['relay', 'reader']) {
        final bytes = await File('${scratch.path}/$role/pilot.jsonl').length();
        if (bytes > maxJournal) maxJournal = bytes;
        expect(bytes, lessThan(8 * 1024 * 1024));
      }
      for (final entry in sentAt.entries) {
        final age =
            (observedAt[entry.key] ?? clock.elapsedMilliseconds) - entry.value;
        expect(
          age,
          lessThan(120000),
          reason: 'Honest news starved under continuous load.',
        );
      }
      if (clock.elapsed.inSeconds - lastSample >= 30) {
        lastSample = clock.elapsed.inSeconds;
        stdout.writeln(
          'CONTINUOUS_SPAM_SAMPLE ${jsonEncode({'elapsedSeconds': lastSample, 'writtenBySource': writtenBySource, 'rotationsBySource': rotationsBySource, 'honestSent': sentAt.length, 'honestObserved': observedAt.length, 'maxCache': maxCache, 'maxJournalBytes': maxJournal, 'relayDeferred': relayState['trafficDeferred'], 'relayRejections': relayState['rejectedCount']})}',
        );
      }
    }

    // Capture task failures immediately, and stop all workers before teardown.
    for (final work in [for (var i = 0; i < 4; i++) flood(i), sendHonest()]) {
      workers.add(
        work.catchError((Object error) {
          workerErrors.add(error);
          running = false;
        }),
      );
    }
    while (running && clock.elapsed.inSeconds < seconds) {
      await observe();
      expect(workerErrors, isEmpty);
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    running = false;
    await Future.wait(workers);
    expect(workerErrors, isEmpty);
    final floodEndedAt = clock.elapsedMilliseconds;
    await observe();
    // Require progress in each complete minute of offered load, not just after
    // the adversarial senders stop. Normal reader inventory/want handles repair.
    for (var minute = 0; minute < seconds ~/ 60; minute++) {
      expect(
        observedAt.values.any(
          (at) => at >= minute * 60000 && at < (minute + 1) * 60000,
        ),
        isTrue,
        reason: 'No honest delivery during attack minute $minute.',
      );
    }
    await _until(
      () async {
        await observe();
        return observedAt.length == honest.length;
      },
      'reader catch-up after continuous load',
      timeout: const Duration(seconds: 120),
    );
    expect(
      maxCache,
      PilotStore.maxBulletins,
      reason: 'The workload must fill the cache.',
    );
    expect(rotationsBySource.every((count) => count > 0), isTrue);
    expect(
      writtenBySource.every((count) => count >= seconds ~/ 2),
      isTrue,
      reason: 'Continuous load must not silently degrade into sparse attempts.',
    );
    expect(
      maxGapBySource.every((gap) => gap < 15000),
      isTrue,
      reason: 'Long quiet gaps would invalidate the continuous-load claim.',
    );

    for (final engine in engines.reversed) {
      await engine.stop();
    }
    for (final role in ['relay', 'reader']) {
      final store = PilotStore(
        Directory('${scratch.path}/$role'),
        protectedChannelIds: {followed.id},
      );
      await store.load();
      expect(store.evictions['bulletins'], greaterThan(0));
      for (final post in honest) {
        expect(
          store.bulletins.containsKey(post.id),
          isTrue,
          reason: 'Acknowledged honest news must remain durable at $role.',
        );
      }
    }
    stdout.writeln(
      'CONTINUOUS_SPAM_RESULT ${jsonEncode({'scope': 'host-loopback-TLS-text-only', 'requestedSeconds': seconds, 'actualFloodMilliseconds': floodEndedAt, 'productionTrafficWindowSeconds': 60, 'writtenBySource': writtenBySource, 'rotationsBySource': rotationsBySource, 'maxWriteGapMsBySource': maxGapBySource, 'honestPostsDelivered': observedAt.length, 'maxObservedDeliveryMs': observedAt.entries.map((entry) => entry.value - sentAt[entry.key]!).reduce((a, b) => a > b ? a : b), 'maxCache': maxCache, 'maxJournalBytes': maxJournal, 'durableAfterRestart': true})}',
    );
  }, timeout: const Timeout(Duration(minutes: 40)));
}

class _Client {
  _Client(this.socket) {
    _keepalive = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(
        _frame({
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
            if (frame['type'] == 'inventory') inventory = true;
          },
          onDone: close,
          onError: (Object _) => close(),
        );
  }
  final SecureSocket socket;
  late final Timer _keepalive;
  bool closed = false;
  bool inventory = false;
  Future<bool> _writes = Future.value(true);

  Future<bool> send(String type, Map<String, dynamic> value) =>
      _frame({'type': type, 'value': value});
  Future<bool> _frame(Map<String, dynamic> value) =>
      _writes = _writes.then((_) async {
        if (closed) return false;
        try {
          socket.write('${jsonEncode(value)}\n');
          await socket.flush();
          return true;
        } on SocketException {
          close();
          return false;
        }
      });
  void close() {
    if (closed) return;
    closed = true;
    _keepalive.cancel();
    socket.destroy();
  }
}

Future<void> _until(
  Future<bool> Function() predicate,
  String stage, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > timeout) {
      fail('Continuous-spam workload timed out: $stage');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
