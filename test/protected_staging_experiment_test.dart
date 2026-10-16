import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/envelope_crypto_worker.dart';

import '../tools/privacy_lab/measurement.dart' show ProcessCpu;

// Section 9.2 of docs/PUBLISHER-DESIGN-REVIEW.md: isolated staging experiment
// with a known-leaking positive control. Explicitly opt in to this long lab run;
// it must not compete with timing-sensitive unit tests in the ordinary suite.
// HPKE or a matched-size/IPC stub; lab-pinned keys, no carrier/shutdown claim.

int _env(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;
bool _flag(String name, bool fallback) => switch (Platform.environment[name]) {
  '1' || 'true' => true,
  '0' || 'false' => false,
  _ => fallback,
};

void main() {
  test(
    'section 9.2 staging experiment with positive control',
    () async {
      final sessions = _env('FT_STAGING_SESSIONS', 1);
      final publications = _env('FT_STAGING_PUBLICATIONS', 6);
      final retries = _flag('FT_STAGING_RETRY', true);
      final restarts = _flag('FT_STAGING_RESTART', false);
      final ackMs = _env('FT_STAGING_ACK_MS', 10000);
      final echoMs = _env('FT_STAGING_ECHO_MS', 30000);
      final zMs = _env('FT_STAGING_Z_MS', 8000);
      final imageEvery = _env('FT_STAGING_IMAGE_EVERY', 5);
      final results = <Map<String, dynamic>>[];
      final fixture = await File('test/fixtures/news-small.jpg').readAsBytes();
      final image = _padImage(
        fixture,
        _env('FT_STAGING_IMAGE_BYTES', fixture.length),
      );
      // Every publication carries a distinct image hash, so a fetch in one phase
      // cannot satisfy a request in another and confound the own-image check.
      var imageIndex = 0;
      Uint8List nextImage() => _imageVariant(image, imageIndex++);
      for (var i = 0; i < sessions; i++) {
        final session = _Session(
          index: i,
          publications: publications,
          retries: retries,
          restarts: restarts,
          ackDeadline: Duration(milliseconds: ackMs),
          echoDeadline: Duration(milliseconds: echoMs),
          image: nextImage,
          zInterval: Duration(milliseconds: zMs),
          imageEvery: imageEvery,
        );
        results.add(await session.run());
        stdout.writeln('STAGING_9_2_SESSION ${jsonEncode(results.last)}');
      }
      final summary = _summarize(results);
      final out = File(
        'artifacts/privacy-lab/staging-9-2-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json',
      );
      await out.parent.create(recursive: true);
      await out.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'summary': summary, 'sessions': results}),
      );
      stdout.writeln('STAGING_9_2_RESULT ${jsonEncode(summary)}');
      // Hard requirements: the positive control must detect the known leaks and
      // staging must never expose pending data before release. Everything else
      // is reported, not asserted.
      expect(summary['positiveControl']['detectsLeaks'], isTrue);
      expect(summary['staging']['preReleaseViolations'], 0);
    },
    skip: !_flag('FT_STAGING_RUN', false),
    timeout: const Timeout(Duration(minutes: 90)),
  );
}

class _Session {
  _Session({
    required this.index,
    required this.publications,
    required this.retries,
    required this.restarts,
    required this.ackDeadline,
    required this.echoDeadline,
    required this.image,
    required this.zInterval,
    required this.imageEvery,
  });
  final Duration zInterval;
  final int imageEvery;
  final int index, publications;
  final bool retries, restarts;
  final Duration ackDeadline, echoDeadline;
  final Uint8List Function() image;
  final clock = Stopwatch()..start();
  final engines = <String, PeerEngine>{};
  final directories = <String, Directory>{};
  final identities = <String, Identity>{};
  final publisherIdentities = <String, Identity>{};
  final observers = <_Observer>[];
  final log = <_Frame>[];
  final fullObjects = <String, Map<String, dynamic>>{};
  final admittedAt = <String, Map<String, int>>{};
  late final bool publisherIsA;
  late final Directory scratch;
  _Observer? zA, zB;
  Timer? zTimer;
  ProcessCpu? cpu;

  String get pub => publisherIsA ? 'A' : 'B';
  String get ctl => publisherIsA ? 'B' : 'A';

  Future<Map<String, dynamic>> run() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('staging-9-2-');
    try {
      cpu = ProcessCpu();
    } catch (_) {
      cpu = null;
    }
    try {
      return await _runInner();
    } finally {
      zTimer?.cancel();
      for (final observer in observers) {
        observer.close();
      }
      for (final engine in engines.values) {
        try {
          await engine.stop();
        } catch (_) {}
      }
      final expected = parent.absolute.path;
      if (scratch.absolute.path.startsWith(
        '$expected${Platform.pathSeparator}',
      )) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<Map<String, dynamic>> _runInner() async {
    publisherIsA = Random.secure().nextBool();
    for (final name in ['A', 'B', 'E', 'R1', 'R2', 'R3', 'P', 'Z']) {
      identities[name] = Identity.generate();
    }
    for (final name in ['A', 'B']) {
      publisherIdentities[name] = Identity.generate();
    }
    final zPublisher = Identity.generate();
    final startedAt = clock.elapsedMilliseconds;
    final exits = ['R1', 'R2', 'R3'].map((n) => identities[n]!.id).toList();
    EnvelopeExperiment experiment({bool publisherRole = false}) =>
        EnvelopeExperiment(
          guardPeerId: identities['E']!.id,
          exitPeerIds: exits,
          ackDeadline: ackDeadline,
          echoDeadline: echoDeadline,
          cryptoMode: Platform.environment['FT_STAGING_CRYPTO'] == 'stub'
              ? EnvelopeCryptoMode.stub
              : EnvelopeCryptoMode.hpke,
        );
    for (final name in ['A', 'B', 'E', 'R1', 'R2', 'R3']) {
      await _makeEngine(name, experiment());
    }
    for (final name in ['A', 'B', 'E', 'R1', 'R2', 'R3']) {
      await engines[name]!.start(activeMode: false);
    }
    for (final recipient in engines.values) {
      final key = await recipient.envelopePublicKey();
      for (final engine in engines.values) {
        engine.envelopeExperiment!.recipientKeys[recipient.identity.id] = key;
      }
    }
    // Identical link sets for A and B: guard, three exits, P and Z.
    for (final node in ['A', 'B']) {
      for (final other in ['E', 'R1', 'R2', 'R3']) {
        await _peer(node, other);
      }
    }
    for (final exit in ['R1', 'R2', 'R3']) {
      await _peer('E', exit);
    }
    for (final name in ['A', 'B', 'E', 'R1', 'R2', 'R3']) {
      observers.add(await _Observer.connect(this, 'P', name));
    }
    zA = await _Observer.connect(this, 'Z', 'A');
    zB = await _Observer.connect(this, 'Z', 'B');
    await _until(() async {
      for (final name in ['A', 'B']) {
        if ((await engines[name]!.snapshot())['connectedCount'] != 6) {
          return false;
        }
      }
      return (await engines['E']!.snapshot())['connectedCount'] == 6;
    }, 'session links');
    final startupMs = clock.elapsedMilliseconds - startedAt;

    // Unrelated public traffic, identical to A and B: Z's channel and posts.
    final zChannel = SignedChannel.create(zPublisher, name: 'Unrelated Z');
    var zSequence = 0;
    final zPosts = <SignedBulletin>[];
    await zA!.push('channel', zChannel.toJson());
    await zB!.push('channel', zChannel.toJson());
    zTimer = Timer.periodic(zInterval, (_) {
      final post = SignedBulletin.create(
        zPublisher,
        channelId: zChannel.id,
        runId: 'news',
        sequence: ++zSequence,
        text: 'خبر نامربوط آزمایشی $zSequence',
      );
      zPosts.add(post);
      unawaited(zA!.push('bulletin', post.toJson()));
      unawaited(zB!.push('bulletin', post.toJson()));
    });
    await Future<void>.delayed(const Duration(seconds: 3));

    final records = <Map<String, dynamic>>[];
    final cpuPhase = <String, double>{};
    final phaseWall = <String, int>{};
    final publisher = engines[pub]!;
    late String stagedChannel;
    // Counterbalance phase order across independent sessions. Matched payload
    // lengths and a common reader endpoint are used for paired latency deltas.
    final phaseOrder = index.isEven ? ['M0', 'staging'] : ['staging', 'M0'];
    for (final phase in phaseOrder) {
      final direct = phase == 'M0';
      final wallStart = clock.elapsedMilliseconds, cpuStart = cpu?.readMs();
      final channel = await _timed(phase, 'channel', () async {
        return (direct
                ? await publisher.createChannel(name: 'Channel $index')
                : await publisher.createProtectedChannel(
                    name: 'Channel $index',
                  ))
            .id;
      }, records);
      if (!direct) {
        stagedChannel = channel;
        await _until(
          () async => ((await publisher.snapshot())['channels'] as List).any(
            (c) => (c as Map)['id'] == channel,
          ),
          'staged channel echo',
        );
      }
      for (var i = 0; i < publications; i++) {
        final withImage = i % imageEvery == imageEvery - 1;
        await _timed(phase, withImage ? 'image' : 'text', () async {
          final marker = 'news-$index-$i';
          final body = 'خبر آزمایشی $marker';
          final photo = withImage ? image() : null;
          if (!direct) {
            return publisher.publishProtected(
              channelId: channel,
              text: body,
              imageBytes: photo,
            );
          }
          await publisher.publishToChannel(
            channelId: channel,
            text: body,
            imageBytes: photo,
          );
          final rows = (await publisher.snapshot())['bulletins'] as List;
          return rows.cast<Map>().firstWhere(
                (r) => r['channelId'] == channel && r['text'] == body,
              )['id']
              as String;
        }, records);
      }
      if (cpuStart != null) cpuPhase[phase] = cpu!.readMs() - cpuStart;
      phaseWall[phase] = clock.elapsedMilliseconds - wallStart;
    }
    Future<void> scenario(
      String kind,
      Future<String> Function() body,
      Duration settle,
      void Function() reset,
    ) async {
      stderr.writeln('STAGING_9_2_PROGRESS session=$index scenario=$kind');
      try {
        await _timed('staging', kind, body, records, settle: settle);
      } catch (error) {
        records.add({
          'phase': 'staging',
          'kind': kind,
          'error': error.toString(),
          'verdict': 'inconclusive: scenario did not complete',
        });
      } finally {
        reset();
      }
    }

    if (retries) {
      final guard = engines['E']!.envelopeExperiment!;
      final exit = engines['R1']!.envelopeExperiment!;
      await scenario(
        'retryEntry',
        () async {
          guard.dropAtEntry = true;
          final id = await publisher.publishProtected(
            channelId: stagedChannel,
            text: 'آزمایش ارسال مجدد ورودی $index',
          );
          await _until(() async => _state(publisher, id) == 'acked', 'ack');
          guard.dropAtEntry = false;
          return id;
        },
        echoDeadline + const Duration(seconds: 15),
        () {
          guard.dropAtEntry = false;
        },
      );
      await scenario(
        'retryExit',
        () async {
          exit.dropAtExit = true;
          publisher.envelopeExperiment!.nextExitIndex = 0;
          final id = await publisher.publishProtected(
            channelId: stagedChannel,
            text: 'آزمایش ارسال مجدد خروجی $index',
          );
          await _until(() async => _state(publisher, id) == 'acked', 'ack');
          return id;
        },
        echoDeadline + const Duration(seconds: 15),
        () {
          exit.dropAtExit = false;
        },
      );
    }

    if (restarts) {
      final guard = engines['E']!.envelopeExperiment!;
      // (a) Publisher restart between sealed and acked.
      await scenario(
        'restartSealed',
        () async {
          guard.silentAtEntry = true;
          final id = await engines[pub]!.publishProtected(
            channelId: stagedChannel,
            text: 'بازیابی پس از راه‌اندازی مجدد، مهر نشده $index',
          );
          await Future<void>.delayed(const Duration(seconds: 1));
          guard.silentAtEntry = false;
          await _restartPublisher();
          return id;
        },
        const Duration(seconds: 25),
        () {
          guard.silentAtEntry = false;
        },
      );
      // (b) Publisher restart between acked and echoed.
      await scenario(
        'restartAcked',
        () async {
          guard.dropAtEntry = true;
          final id = await engines[pub]!.publishProtected(
            channelId: stagedChannel,
            text: 'بازیابی پس از راه‌اندازی مجدد، تأیید شده $index',
          );
          await _until(() async => _state(engines[pub]!, id) == 'acked', 'ack');
          guard.dropAtEntry = false;
          await _restartPublisher();
          return id;
        },
        echoDeadline + const Duration(seconds: 20),
        () {
          guard.dropAtEntry = false;
        },
      );
      // (c) Exit restart with a complete held object.
      await scenario(
        'restartExit',
        () async {
          engines['R1']!.envelopeExperiment!.holdAtExit = true;
          engines[pub]!.envelopeExperiment!.nextExitIndex = 0;
          final id = await engines[pub]!.publishProtected(
            channelId: stagedChannel,
            text: 'بازیابی خروجی پس از راه‌اندازی مجدد $index',
            imageBytes: image(),
          );
          await _until(
            () async => _pending(engines[pub]!, id)?['exitAckedMs'] != null,
            'exit ack',
          );
          await _restartExit('R1');
          await engines['R1']!.releaseHeldRelayedObjects(identities['E']!.id);
          return id;
        },
        const Duration(seconds: 20),
        () {
          engines['R1']!.envelopeExperiment!.holdAtExit = false;
        },
      );
    }

    await Future<void>.delayed(const Duration(seconds: 2));
    zTimer?.cancel();
    final snapshots = <String, dynamic>{};
    final deferred = <String, dynamic>{};
    for (final name in engines.keys) {
      final snapshot = await engines[name]!.snapshot();
      snapshots[name] = snapshot['envelopeExperiment'];
      deferred[name] = snapshot['trafficDeferred'];
    }
    Future<int> size(String path) async {
      final file = File(path);
      if (await file.exists()) return file.length();
      final dir = Directory(path);
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    }

    final storage = {
      'publisherPendingJournalBytes': await size(
        '${directories[pub]!.path}/pending-publications-x2.jsonl',
      ),
      'publisherPendingImagesBytes': await size(
        '${directories[pub]!.path}/pending-images-x2',
      ),
      'entryJournalBytes': await size(
        '${directories['E']!.path}/envelope-entry-x2.jsonl',
      ),
      'exitJournalBytes': {
        for (final r in ['R1', 'R2', 'R3'])
          r: await size('${directories[r]!.path}/envelope-exit-x2.jsonl'),
      },
    };
    final bytesByLink = <String, int>{};
    for (final frame in log) {
      bytesByLink.update(
        frame.link,
        (v) => v + frame.bytes,
        ifAbsent: () => frame.bytes,
      );
    }
    return {
      'session': index,
      'publisherRole': pub,
      'startupMs': startupMs,
      'publications': publications,
      'zPosts': zPosts.length,
      'records': records,
      'cpuMsByPhase': cpuPhase,
      'cpuScope': cpu == null ? 'unavailable' : 'whole test process (all engines, crypto workers, observers, harness)',
      'cryptoMode': engines[pub]!.envelopeExperiment!.cryptoMode.name,
      'zIntervalMs': zInterval.inMilliseconds,
      'imageEvery': imageEvery,
      'phaseWallMs': phaseWall,
      'phaseOrder': phaseOrder,
      'engineStats': snapshots,
      'trafficDeferred': deferred,
      'labEgressBytesPerPeer': _env('FT_STAGING_EGRESS', 512 * 1024),
      'storageBytes': storage,
      'observerBytesByLink': bytesByLink,
    };
  }

  String? _state(PeerEngine engine, String id) =>
      _pending(engine, id)?['state'] as String?;
  Map<String, dynamic>? _pending(PeerEngine engine, String id) {
    for (final row in engine.pendingPublicationSummaries) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  Future<void> _makeEngine(String name, EnvelopeExperiment experiment) async {
    experiment.onPublicAdmission = (id) {
      admittedAt
          .putIfAbsent(name, () => {})
          .putIfAbsent(id, () => clock.elapsedMilliseconds);
    };
    final directory = Directory('${scratch.path}/$name');
    directories[name] = directory;
    engines[name] = PeerEngine(
      directory: directory,
      identity: identities[name]!,
      publisherIdentity: publisherIdentities[name],
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      imageMode: 'any',
      // Production default. Any override is explicit and recorded in results.
      egressBytesPerPeer: _env('FT_STAGING_EGRESS', 512 * 1024),
      envelopeExperiment: experiment,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
  }

  PeerCard _card(String name, {bool withAddress = true}) => PeerCard(
    name: 'Disposable $name',
    host: withAddress ? '127.0.0.1' : '',
    port: withAddress ? engines[name]!.boundPort : 0,
    certificatePem: identities[name]!.certPem,
  );

  Future<void> _peer(String a, String b) async {
    await engines[a]!.addPeer(_card(b));
    await engines[b]!.addPeer(_card(a));
  }

  Future<void> _restartPublisher() async {
    final name = pub;
    final old = engines[name]!;
    final experiment = old.envelopeExperiment!;
    await old.stop();
    for (final observer in observers.where((o) => o.target == name)) {
      observer.close();
    }
    observers.removeWhere((o) => o.target == name);
    if (name == 'A') {
      zA!.close();
    } else {
      zB!.close();
    }
    await _makeEngine(name, experiment);
    await engines[name]!.start(activeMode: false);
    for (final other in ['E', 'R1', 'R2', 'R3']) {
      await _peer(name, other);
    }
    observers.add(await _Observer.connect(this, 'P', name));
    final z = await _Observer.connect(this, 'Z', name);
    if (name == 'A') {
      zA = z;
    } else {
      zB = z;
    }
    await _until(
      () async => (await engines[name]!.snapshot())['connectedCount'] == 6,
      'publisher restart links',
      timeout: const Duration(seconds: 60),
    );
  }

  Future<void> _restartExit(String name) async {
    final old = engines[name]!;
    final experiment = old.envelopeExperiment!;
    await old.stop();
    for (final observer in observers.where((o) => o.target == name)) {
      observer.close();
    }
    observers.removeWhere((o) => o.target == name);
    experiment.holdAtExit = false;
    await _makeEngine(name, experiment);
    await engines[name]!.start(activeMode: false);
    for (final other in ['A', 'B', 'E']) {
      await _peer(name, other);
    }
    observers.add(await _Observer.connect(this, 'P', name));
    await _until(
      () async => (await engines[name]!.snapshot())['connectedCount'] == 4,
      'exit restart links',
    );
  }

  /// Publish through [action], then run the probes and collect one record.
  Future<String> _timed(
    String phase,
    String kind,
    Future<String> Function() action,
    List<Map<String, dynamic>> records, {
    Duration settle = const Duration(seconds: 8),
  }) async {
    final logStart = log.length;
    final tPublish = clock.elapsedMilliseconds;
    // Public, unrelated ids: this probe requires no unpublished object id. It
    // overlaps sealing instead of only hitting the duplicate fast path later.
    final concurrentProbeRows = <Map<String, dynamic>>[];
    final concurrentProbes = <Future<void>>[];
    for (final offset in [0, 50, 100, 200]) {
      concurrentProbes.add(
        Future<void>.delayed(Duration(milliseconds: offset), () async {
          final probe = List.generate(
            32,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          final row = <String, dynamic>{
            'id': probe,
            'sentAt': clock.elapsedMilliseconds,
          };
          concurrentProbeRows.add(row);
          try {
            await Future.wait([
              _obs(pub).inventory({
                'bulletins': [probe],
              }),
              _obs(ctl).inventory({
                'bulletins': [probe],
              }),
            ]);
          } catch (_) {
            row['sendFailed'] = true;
          }
        }),
      );
    }
    final id = await action();
    final tReturned = clock.elapsedMilliseconds;
    final releasedBeforeInspection = [
      'E',
      'R1',
      'R2',
      'R3',
    ].any((n) => admittedAt[n]?.containsKey(id) == true);
    final privateInspection = phase == 'staging' && !releasedBeforeInspection
        ? engines[pub]!.inspectProtectedObject(id)
        : null;
    if (privateInspection != null) {
      expect(
        privateInspection.values.any((v) => v),
        isFalse,
        reason: 'Unreleased object in public publisher state',
      );
    }
    stderr.writeln(
      'STAGING_9_2_PROGRESS session=$index phase=$phase kind=$kind n=${records.length}',
    );
    // White-box want probe: the harness knows the id; a neighbour would not.
    final pubObs = _obs(pub), ctlObs = _obs(ctl);
    final probeAt = clock.elapsedMilliseconds;
    final listKey = kind == 'channel' ? 'channels' : 'bulletins';
    await Future.wait([
      pubObs.inventory({
        listKey: [id],
      }),
      ctlObs.inventory({
        listKey: [id],
      }),
    ]);
    // Timing probe once the object is first seen anywhere at P.
    final probeId = List.generate(
      64,
      (_) => '0123456789abcdef'[Random().nextInt(16)],
    ).join();
    int? tFirstSeen;
    String? firstLink;
    int? timingSentAt;
    final deadline = clock.elapsedMilliseconds + settle.inMilliseconds;
    while (clock.elapsedMilliseconds < deadline) {
      if (tFirstSeen == null) {
        final seen = _firstSighting(id, logStart);
        if (seen != null) {
          tFirstSeen = seen.t;
          firstLink = seen.link;
          final value = fullObjects[id];
          if (value != null) {
            final type = kind == 'channel' ? 'channel' : 'bulletin';
            timingSentAt = clock.elapsedMilliseconds;
            await Future.wait([
              pubObs
                  .push(type, value)
                  .then(
                    (_) => pubObs.inventory({
                      'bulletins': [probeId],
                    }),
                  ),
              ctlObs
                  .push(type, value)
                  .then(
                    (_) => ctlObs.inventory({
                      'bulletins': [probeId],
                    }),
                  ),
            ]);
          }
        }
      }
      // Both arms use the complete observation window, irrespective of probe
      // success. Otherwise CPU percentages have different denominators.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await Future.wait(concurrentProbes);
    final relayLinks = {'E', 'R1', 'R2', 'R3'};
    // Exact local white-box release boundary; a later observer sighting can
    // wrongly classify an ordinary publisher forward as a pre-release leak.
    final releaseTimes =
        relayLinks.map((n) => admittedAt[n]?[id]).whereType<int>().toList()
          ..sort();
    final int? tRelease = releaseTimes.firstOrNull;
    final imageHash = fullObjects[id]?['image'] is Map
        ? ((fullObjects[id]!['image'] as Map)['hash'] as String?)
        : _imageHashOf(id);
    final releaseRef = tRelease ?? tFirstSeen;
    var preRelease = 0;
    final preReleaseKinds = <String>{};
    for (final frame in log.skip(logStart)) {
      if (frame.link != pub) continue;
      if (releaseRef != null && frame.t >= releaseRef) break;
      // A request for an id the prober itself advertised is ordinary reader
      // behaviour, not an offer of pending data; offers and listings count.
      if (frame.type == 'want') continue;
      if (frame.mentions(id) ||
          (imageHash != null && frame.mentions(imageHash))) {
        preRelease++;
        preReleaseKinds.add(frame.type);
      }
    }
    final pubState = _pending(engines[pub]!, id);
    final publicValue = fullObjects[id];
    final publicSigner = publicValue == null
        ? null
        : kind == 'channel'
        ? SignedChannel.fromJson(publicValue).ownerId
        : SignedBulletin.fromJson(publicValue).sourceId;
    if (phase == 'staging' && publicSigner != null) {
      expect(
        publicSigner,
        isNot(identities[pub]!.id),
        reason: 'Signing identity must not equal transport identity',
      );
    }
    final pubFetched =
        (await engines[pub]!.snapshot())['envelopeExperiment']['fetchedImages']
            as List;
    final ctlFetched =
        (await engines[ctl]!.snapshot())['envelopeExperiment']['fetchedImages']
            as List;
    final record = <String, dynamic>{
      'phase': phase,
      'preReleaseInspection': privateInspection,
      'kind': kind,
      'id': id,
      'tPublish': tPublish,
      'callMs': tReturned - tPublish,
      'tFirstSeen': tFirstSeen,
      'firstLink': firstLink,
      'firstLinkIsPublisher': firstLink == pub,
      'tRelease': tRelease,
      'releaseDelayMs': tRelease == null ? null : tRelease - tPublish,
      'directDelayMs': phase == 'M0' && tFirstSeen != null
          ? tFirstSeen - tPublish
          : null,
      'readerReadyDelayMs': admittedAt[ctl]?[id] == null
          ? null
          : admittedAt[ctl]![id]! - tPublish,
      'readerReadyEndpoint':
          'same matched control engine, durable public admission',
      'preReleaseFramesFromPublisher': preRelease,
      'preReleaseKinds': preReleaseKinds.toList(),
      'wantProbe': {
        'publisher': _wantAt(id, pub, logStart, after: probeAt) != null,
        'control': _wantAt(id, ctl, logStart, after: probeAt) != null,
      },
      'timingProbeMs': timingSentAt == null
          ? null
          : {
              'publisher': _delta(
                _wantAt(probeId, pub, logStart),
                timingSentAt,
              ),
              'control': _delta(_wantAt(probeId, ctl, logStart), timingSentAt),
            },
      'concurrentPublicProbeMs': concurrentProbeRows
          .map(
            (row) => {
              'offsetMs': (row['sentAt'] as int) - tPublish,
              'publisher': _delta(
                _wantAt(row['id'] as String, pub, logStart),
                row['sentAt'] as int,
              ),
              'control': _delta(
                _wantAt(row['id'] as String, ctl, logStart),
                row['sentAt'] as int,
              ),
              'sendFailed': row['sendFailed'] ?? false,
            },
          )
          .toList(),
      'offerAfterReleaseMs': releaseRef == null
          ? null
          : {
              'publisher': _delta(
                _offer(id, pub, logStart, after: releaseRef),
                releaseRef,
              ),
              'control': _delta(
                _offer(id, ctl, logStart, after: releaseRef),
                releaseRef,
              ),
            },
      'publisherOfferedFirst': () {
        final a = _offer(id, pub, logStart), b = _offer(id, ctl, logStart);
        if (a == null || b == null) return null;
        return a < b;
      }(),
      'imageHash': imageHash,
      'imageFetched': imageHash == null
          ? null
          : {
              'publisher': pubFetched.contains(imageHash),
              'control': ctlFetched.contains(imageHash),
            },
      'pending': pubState,
      'signerMatchesPublisherTransport': publicSigner == identities[pub]!.id,
      'publisherImageCounters': _imageCounters(
        (await engines[pub]!.snapshot())['envelopeExperiment'] as Map,
      ),
      'controlImageCounters': _imageCounters(
        (await engines[ctl]!.snapshot())['envelopeExperiment'] as Map,
      ),
    };
    records.add(record);
    return id;
  }

  Map<String, dynamic> _imageCounters(Map stats) => {
    for (final key in stats.keys)
      if (key is String && key.startsWith('image')) key: stats[key],
  };

  String? _imageHashOf(String id) {
    for (final frame in log) {
      if (frame.ids.contains(id) && frame.imageHash != null) {
        return frame.imageHash;
      }
    }
    return null;
  }

  _Observer _obs(String target) =>
      observers.firstWhere((o) => o.target == target && o.name == 'P');

  _Frame? _firstSighting(String id, int from) {
    for (final frame in log.skip(from)) {
      if ((frame.type == 'bulletin' || frame.type == 'channel') &&
          frame.ids.contains(id)) {
        return frame;
      }
    }
    return null;
  }

  int? _offer(String id, String link, int from, {int? after}) {
    for (final frame in log.skip(from)) {
      if (frame.link == link &&
          (frame.type == 'bulletin' || frame.type == 'channel') &&
          frame.ids.contains(id) &&
          (after == null || frame.t >= after)) {
        return frame.t;
      }
    }
    return null;
  }

  int? _wantAt(String id, String link, int from, {int? after}) {
    for (final frame in log.skip(from)) {
      if (frame.link == link &&
          frame.type == 'want' &&
          frame.ids.contains(id) &&
          (after == null || frame.t >= after)) {
        return frame.t;
      }
    }
    return null;
  }

  int? _delta(int? t, int? base) => t == null || base == null ? null : t - base;

  Future<void> _until(
    Future<bool> Function() predicate,
    String stage, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final started = clock.elapsedMilliseconds;
    while (!await predicate()) {
      if (clock.elapsedMilliseconds - started > timeout.inMilliseconds) {
        fail('Staging experiment timed out: $stage');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class _Frame {
  _Frame(this.t, this.link, this.type, this.ids, this.imageHash, this.bytes);
  final int t;
  final String link, type;
  final Set<String> ids;
  final String? imageHash;
  final int bytes;
  bool mentions(String id) => ids.contains(id) || imageHash == id;
}

/// A raw pinned-TLS peer that logs every frame on one link. Never answers
/// requests, so it cannot short-circuit a release path.
class _Observer {
  _Observer(this.session, this.name, this.target, this.socket) {
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: close, onError: (Object _) => close());
    _keepalive = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(inventory(const {}));
    });
  }
  final _Session session;
  final String name, target;
  final SecureSocket socket;
  late final Timer _keepalive;
  bool closed = false;
  Future<void> _writes = Future.value();

  static Future<_Observer> connect(
    _Session session,
    String name,
    String target,
  ) async {
    final identity = session.identities[name]!;
    final engine = session.engines[target]!;
    await engine.addPeer(
      PeerCard(name: 'Disposable $name', certificatePem: identity.certPem),
    );
    final targetIdentity = session.identities[target]!;
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      engine.boundPort,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(identity.certPem))
        ..usePrivateKeyBytes(utf8.encode(identity.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(targetIdentity.certPem)),
      onBadCertificate: (cert) =>
          Identity.certificateId(cert.pem) == targetIdentity.id,
      timeout: const Duration(seconds: 5),
    );
    final observer = _Observer(session, name, target, socket);
    await observer.inventory(const {});
    return observer;
  }

  void _onLine(String line) {
    if (name != 'P') return;
    final t = session.clock.elapsedMilliseconds;
    Map<String, dynamic> frame;
    try {
      frame = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = frame['type'] is String ? frame['type'] as String : '?';
    final ids = <String>{};
    String? imageHash;
    void addAll(dynamic list) {
      if (list is List) {
        for (final v in list) {
          if (v is String) ids.add(v);
        }
      }
    }

    switch (type) {
      case 'bulletin' || 'channel' || 'channelPolicy' || 'ownerAuthority':
        final value = frame['value'];
        if (value is Map && value['id'] is String) {
          ids.add(value['id'] as String);
          session.fullObjects.putIfAbsent(
            value['id'] as String,
            () => Map<String, dynamic>.from(value),
          );
          if (type == 'bulletin') {
            try {
              imageHash = SignedBulletin.fromJson(
                Map<String, dynamic>.from(value),
              ).image?.hash;
            } catch (_) {}
          }
        }
      case 'inventory':
        addAll(frame['bulletins']);
        addAll(frame['channels']);
        addAll(frame['policies']);
        addAll(frame['media']);
      case 'want':
        addAll(frame['bulletins']);
        addAll(frame['channels']);
        addAll(frame['policies']);
      case 'mediaWant':
        if (frame['hash'] is String) ids.add(frame['hash'] as String);
    }
    session.log.add(_Frame(t, target, type, ids, imageHash, line.length + 1));
  }

  Future<void> inventory(Map<String, List<String>> lists) => _frame({
    'type': 'inventory',
    'features': ['channel-v2', 'owner-recovery-v1'],
    'bulletins': lists['bulletins'] ?? const <String>[],
    'receipts': const <String>[],
    'channels': lists['channels'] ?? const <String>[],
    'policies': const <String>[],
    'media': lists['media'] ?? const <String>[],
  });

  Future<void> push(String type, Map<String, dynamic> value) =>
      _frame({'type': type, 'value': value});

  Future<void> _frame(Map<String, dynamic> value) =>
      _writes = _writes.then((_) async {
        if (closed) return;
        try {
          socket.write('${jsonEncode(value)}\n');
          await socket.flush();
        } on SocketException {
          close();
        }
      });

  void close() {
    if (closed) return;
    closed = true;
    _keepalive.cancel();
    socket.destroy();
  }
}

Map<String, dynamic> _summarize(List<Map<String, dynamic>> sessions) {
  final n = sessions.length;
  List<Map<String, dynamic>> recs(Map<String, dynamic> s, String phase) =>
      (s['records'] as List)
          .cast<Map<String, dynamic>>()
          .where((r) => r['phase'] == phase)
          .toList();
  // Per-session indicators, then intervals across sessions.
  final m0FirstFromPub = <double>[];
  final m0WantGap = <double>[];
  final m0ImageGap = <double>[];
  final m0Timing = <double>[];
  final stPreRelease = <int>[];
  final stFirstFromRelay = <double>[];
  final stWantAgree = <double>[];
  final stImageBoth = <double>[];
  final stPubFirstRate = <double>[];
  final stOfferDelta = <double>[];
  final stTiming = <double>[];
  final stReleaseDelays = <int>[];
  final m0Delays = <int>[];
  final pairedReaderDeltas = <int>[];
  final sessionMedianReaderDeltas = <double>[];
  final byKind = <String, Map<String, int>>{};
  for (final s in sessions) {
    final m0 = recs(s, 'M0');
    final st = recs(s, 'staging');
    double rate(List<Map<String, dynamic>> rs, bool Function(Map) f) =>
        rs.isEmpty ? double.nan : rs.where(f).length / rs.length;
    m0.removeWhere((r) => r.containsKey('error'));
    st.removeWhere((r) => r.containsKey('error'));
    final ordinary = st
        .where((r) => {'channel', 'text', 'image'}.contains(r['kind']))
        .toList();
    final pairs = <int>[];
    for (var i = 0; i < min(m0.length, ordinary.length); i++) {
      final direct = m0[i]['readerReadyDelayMs'],
          staged = ordinary[i]['readerReadyDelayMs'];
      if (direct is int &&
          staged is int &&
          m0[i]['kind'] == ordinary[i]['kind']) {
        pairs.add(staged - direct);
      }
    }
    pairedReaderDeltas.addAll(pairs);
    if (pairs.isNotEmpty) {
      pairs.sort();
      sessionMedianReaderDeltas.add(pairs[pairs.length ~/ 2].toDouble());
    }
    m0FirstFromPub.add(rate(m0, (r) => r['firstLinkIsPublisher'] == true));
    m0WantGap.add(
      rate(
        m0,
        (r) =>
            r['wantProbe']['control'] == true &&
            r['wantProbe']['publisher'] == false,
      ),
    );
    final m0Images = m0.where((r) => r['imageFetched'] != null).toList();
    m0ImageGap.add(
      rate(
        m0Images,
        (r) =>
            r['imageFetched']['control'] == true &&
            r['imageFetched']['publisher'] == false,
      ),
    );
    m0Timing.add(_medianDelta(m0, 'timingProbeMs'));
    m0Delays.addAll(m0.map((r) => r['directDelayMs']).whereType<int>());
    stPreRelease.add(
      st.fold<int>(
        0,
        (v, r) => v + (r['preReleaseFramesFromPublisher'] as int),
      ),
    );
    stFirstFromRelay.add(
      rate(
        st,
        (r) => r['firstLink'] != null && r['firstLinkIsPublisher'] == false,
      ),
    );
    stWantAgree.add(
      rate(st, (r) => r['wantProbe']['control'] == r['wantProbe']['publisher']),
    );
    final stImages = st.where((r) => r['imageFetched'] != null).toList();
    stImageBoth.add(
      rate(
        stImages,
        (r) =>
            r['imageFetched']['control'] == true &&
            r['imageFetched']['publisher'] == true,
      ),
    );
    final decided = st
        .where((r) => r['publisherOfferedFirst'] != null)
        .toList();
    stPubFirstRate.add(
      rate(decided, (r) => r['publisherOfferedFirst'] == true),
    );
    stOfferDelta.add(_medianDelta(st, 'offerAfterReleaseMs'));
    stTiming.add(_medianDelta(st, 'timingProbeMs'));
    stReleaseDelays.addAll(st.map((r) => r['releaseDelayMs']).whereType<int>());
    for (final r in st) {
      final kind = r['kind'] as String;
      final counts = byKind.putIfAbsent(
        kind,
        () => {'n': 0, 'released': 0, 'preRelease': 0, 'failed': 0},
      );
      counts['n'] = counts['n']! + 1;
      if (r['tRelease'] != null) counts['released'] = counts['released']! + 1;
      counts['preRelease'] =
          counts['preRelease']! + (r['preReleaseFramesFromPublisher'] as int);
      if (r['pending'] != null && r['pending']['state'] == 'failed') {
        counts['failed'] = counts['failed']! + 1;
      }
    }
  }
  final detects =
      m0FirstFromPub.every((v) => v == 1.0) &&
      m0WantGap.every((v) => v == 1.0) &&
      m0ImageGap.every((v) => v.isNaN || v == 1.0);
  return {
    'independentSessions': n,
    'unitOfIndependence': 'session (fresh identities, stores, role assignment)',
    'positiveControl': {
      'detectsLeaks': detects,
      'firstSourceIsPublisherRate': _interval(m0FirstFromPub),
      'wantOracleDetectedRate': _interval(m0WantGap),
      'ownImageNotFetchedRate': _interval(m0ImageGap),
      'timingProbeMedianDeltaMs(ctl-pub)': _interval(m0Timing),
      'directDelayMs': _quantiles(m0Delays),
    },
    'staging': {
      'preReleaseViolations': stPreRelease.fold<int>(0, (a, b) => a + b),
      'firstSourceIsRelayRate': _interval(stFirstFromRelay),
      'wantProbeAgreementRate': _interval(stWantAgree),
      'ownImageFetchedBothRate': _interval(stImageBoth),
      'publisherOfferedFirstRate': _interval(stPubFirstRate),
      'offerAfterReleaseMedianDeltaMs(ctl-pub)': _interval(stOfferDelta),
      'timingProbeMedianDeltaMs(ctl-pub)': _interval(stTiming),
      'releaseDelayMs': _quantiles(stReleaseDelays),
      'byKind': byKind,
      'pairedAddedReaderDelayMs': _quantiles(pairedReaderDeltas),
      'sessionMedianAddedReaderDelayMs': _interval(sessionMedianReaderDeltas),
    },
    'sensitivity':
        'deterministic detectors per publication; comparative '
        'statistics are per-session medians with t-intervals across sessions; '
        'fewer than 3 sessions is reported as inconclusive for any comparison',
    'measurementScope':
        'loopback TLS; configured HPKE or matched stub workers; lab-pinned recipients; '
        'six engines share the engine isolate. Response probes cannot establish '
        'independent-device timing indistinguishability. CPU is whole-process, not battery. '
        'Phase order counterbalanced, matched reader/payload lengths; stores grow within each session.',
  };
}

/// Changes one entropy-coded byte near the end of the scan so the content
/// hash differs per index while the marker structure stays intact.
Uint8List _imageVariant(Uint8List source, int index) {
  final bytes = Uint8List.fromList(source);
  var p = bytes.length - 64;
  while (p > 2 && (bytes[p] == 0xFF || bytes[p - 1] == 0xFF)) {
    p--;
  }
  bytes[p] = 1 + ((bytes[p] + index) % 254);
  return bytes;
}

// Add legal JPEG comment segments to exercise a full-sized compressed upload
// without changing dimensions or relying on a separate image encoder.
Uint8List _padImage(Uint8List source, int target) {
  if (target == source.length) return source;
  if (target < source.length + 4 || target > 96 * 1024) {
    throw ArgumentError('Image test size must fit NewsImage limits');
  }
  final out = BytesBuilder()..add(source.sublist(0, 2));
  var extra = target - source.length;
  while (extra > 0) {
    var total = min(extra, 65537);
    if (extra - total > 0 && extra - total < 4) total -= 4;
    final payload = total - 4, length = payload + 2;
    out.add([255, 254, length >> 8, length & 255]);
    out.add(Uint8List(payload));
    extra -= total;
  }
  out.add(source.sublist(2));
  return out.takeBytes();
}

double _medianDelta(List<Map<String, dynamic>> rs, String key) {
  final deltas = <double>[];
  for (final r in rs) {
    final m = r[key];
    if (m is Map && m['publisher'] is int && m['control'] is int) {
      deltas.add(((m['control'] as int) - (m['publisher'] as int)).toDouble());
    }
  }
  if (deltas.isEmpty) return double.nan;
  deltas.sort();
  return deltas[deltas.length ~/ 2];
}

Map<String, dynamic> _interval(List<double> values) {
  final v = values.where((x) => !x.isNaN).toList();
  if (v.isEmpty) return {'n': 0, 'verdict': 'inconclusive'};
  final mean = v.reduce((a, b) => a + b) / v.length;
  if (v.length < 3) {
    return {
      'n': v.length,
      'mean': mean,
      'values': v,
      'verdict': 'inconclusive',
    };
  }
  final variance =
      v.fold<double>(0, (s, x) => s + (x - mean) * (x - mean)) / (v.length - 1);
  if (variance == 0) {
    return {
      'n': v.length,
      'mean': mean,
      'values': v,
      'verdict': 'no sample variation; no uncertainty interval estimated',
    };
  }
  final t =
      const {
        3: 4.303,
        4: 3.182,
        5: 2.776,
        6: 2.571,
        7: 2.447,
        8: 2.365,
      }[v.length] ??
      2.0;
  final half = t * sqrt(variance / v.length);
  return {
    'n': v.length,
    'mean': mean,
    'ci95': [mean - half, mean + half],
    'values': v,
    'verdict': half == 0 ? 'consistent' : 'see interval',
  };
}

Map<String, dynamic> _quantiles(List<int> values) {
  if (values.isEmpty) return {'n': 0};
  final v = List.of(values)..sort();
  int q(double p) => v[min(v.length - 1, (p * v.length).floor())];
  return {
    'n': v.length,
    'median': q(0.5),
    'p95': q(0.95),
    'p99': q(0.99),
    'max': v.last,
  };
}
