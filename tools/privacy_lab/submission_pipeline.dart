// Research only. Both candidates fail their integration gates.
// Measures identical signed objects through two separate, equivalent stores.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

import 'measurement.dart';
import 'android_worker.dart';

Future<void> until(Future<bool> Function() check) async {
  final clock = Stopwatch()..start();
  while (!await check()) {
    if (clock.elapsedMilliseconds > 20000) throw TimeoutException('Lab setup');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class PublicArm {
  PublicArm(this.directory, this.identities);
  final Directory directory;
  final List<Identity> identities;
  final engines = <PeerEngine>[];
  final meters = <MeteredLink>[];
  SecureSocket? sender;
  final errors = <String>[];

  Future<void> start() async {
    for (var i = 1; i <= 2; i++) {
      final engine = PeerEngine(
        directory: Directory('${directory.path}/peer-$i'),
        identity: identities[i],
        listenPort: 0,
        enableLanDiscovery: false,
        enableUdpDiscovery: false,
        deviceState: () async => {'platform': 'isolated-public-release-lab'},
        onStatus: (_) {},
      );
      engines.add(engine);
      await engine.start(activeMode: false);
    }
    await engines[1].addPeer(
      PeerCard(
        name: 'Lab public release',
        certificatePem: identities[1].certPem,
      ),
    );
    final readerMeter = await MeteredLink.start(
      (await engines[1].snapshot())['listenPort'] as int,
    );
    meters.add(readerMeter);
    await engines[0].addPeer(
      PeerCard(
        name: 'Lab reader',
        host: '127.0.0.1',
        port: readerMeter.port,
        certificatePem: identities[2].certPem,
      ),
    );
    await engines[0].addPeer(
      PeerCard(
        name: 'Lab released input',
        certificatePem: identities[0].certPem,
      ),
    );
    final inputMeter = await MeteredLink.start(
      (await engines[0].snapshot())['listenPort'] as int,
    );
    meters.insert(0, inputMeter);
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(identities[0].certPem))
      ..usePrivateKeyBytes(utf8.encode(identities[0].keyPem))
      ..setTrustedCertificatesBytes(utf8.encode(identities[1].certPem))
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
    sender = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      inputMeter.port,
      context: context,
      onBadCertificate: (cert) =>
          Identity.certificateId(cert.pem) == identities[1].id,
      timeout: const Duration(seconds: 5),
    );
    sender!.listen(
      (_) {},
      onError: (Object error) {
        if (errors.length < 10) errors.add('$error');
      },
    );
    await until(
      () async =>
          (await engines[0].snapshot())['connectedCount'] == 2 &&
          (await engines[1].snapshot())['connectedCount'] == 1,
    );
  }

  List<Map<String, int>> bytes() => meters.map((m) => m.snapshot()).toList();
  Future<void> close() async {
    for (final meter in meters) {
      await meter.close();
    }
    sender?.destroy();
    for (final engine in engines.reversed) {
      await engine.stop();
    }
  }
}

Map<String, double> stats(List<double> input) {
  final sorted = [...input]..sort();
  if (sorted.isEmpty) return {};
  double q(double p) => sorted[max(0, (p * sorted.length).ceil() - 1)];
  return {'p50': q(.5), 'p95': q(.95), 'p99': q(.99), 'max': sorted.last};
}

Future<void> main(List<String> args) async {
  final samples = args.isEmpty ? 20 : int.parse(args[0]);
  final candidate = args.length < 2 ? 'fpp0' : args[1];
  final kbps = args.length < 3 ? 0 : int.parse(args[2]);
  final rttMs = args.length < 4 ? 0 : int.parse(args[3]);
  if (args.length > 6) throw ArgumentError('Unexpected pipeline arguments');
  final wireCodec = args.length < 6 ? 'json' : args[5];
  if (!['json', 'cbor-v1', 'cbor-framed-v1'].contains(wireCodec)) {
    throw ArgumentError('Unsupported private RPC codec');
  }
  final androidWorker = args.length >= 5 && args[4].isNotEmpty
      ? AndroidLabWorker.load(args[4])
      : null;
  final frozenCompletion = candidate == 'fpp1frozen';
  final atomicPublication = candidate == 'fpp1atomic' || frozenCompletion;
  if (androidWorker != null && !atomicPublication) {
    throw ArgumentError('Android apparatus requires fpp1atomic or fpp1frozen');
  }
  final networkCandidate = [
    'fpp1net',
    'fpp1frozen',
    'fpp1setup',
    'fpp1durable',
    'fpp1outbox',
    'fpp1scheduled',
    'fpp1fused',
    'fpp1atomic',
  ].contains(candidate);
  if (!networkCandidate && wireCodec != 'json') {
    throw ArgumentError('Compact RPC requires a network candidate');
  }
  final roleLocalSetup = [
    'fpp1frozen',
    'fpp1setup',
    'fpp1durable',
    'fpp1outbox',
    'fpp1scheduled',
    'fpp1fused',
    'fpp1atomic',
  ].contains(candidate);
  final roleLocalOutbox = [
    'fpp1frozen',
    'fpp1outbox',
    'fpp1scheduled',
    'fpp1fused',
    'fpp1atomic',
  ].contains(candidate);
  final commonCutoff = [
    'fpp1frozen',
    'fpp1scheduled',
    'fpp1fused',
    'fpp1atomic',
  ].contains(candidate);
  if (kbps < 0 ||
      kbps > 1000000 ||
      rttMs < 0 ||
      rttMs > 2000 ||
      (!networkCandidate && (kbps != 0 || rttMs != 0))) {
    throw ArgumentError(
      'Link pacing requires a network candidate and supported nonnegative values',
    );
  }
  if (![
    'fpp1frozen',
    'fpp0',
    'fpp1',
    'fpp1net',
    'fpp1setup',
    'fpp1durable',
    'fpp1outbox',
    'fpp1scheduled',
    'fpp1fused',
    'fpp1atomic',
  ].contains(candidate)) {
    throw ArgumentError(
      'Use fpp0, fpp1, fpp1net, fpp1setup, fpp1durable, fpp1outbox, fpp1scheduled, fpp1fused, fpp1atomic or fpp1frozen',
    );
  }
  if (samples < 1 || samples > 1000) throw ArgumentError('Use 1..1000 pairs');
  final binary =
      androidWorker?.binary.path ??
      (candidate == 'fpp0'
          ? '.tooling/privacy-research/sphinxprobe.exe'
          : '.tooling/privacy-research/roundprobe.exe');
  final root = Directory('.local-only/privacy-lab')
    ..createSync(recursive: true);
  final run = root.createTempSync('pipeline-');
  final report = <String, Object?>{
    'schema': 1,
    'experiment': '$candidate paired application-envelope pipeline',
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
    'requestedPairs': samples,
    'privateRpcCodec': wireCodec,
    'endpoint':
        'signed bytes ready to receiver verified/flushed store visibility',
    'clock': 'one Dart monotonic clock includes Go IPC, candidate component and public distribution',
    if (androidWorker != null) 'androidWorker': androidWorker.metadata(),
    'privatePathScope': candidate == 'fpp0'
        ? 'three local Sphinx TCP stages with sample-driven covers'
        : candidate == 'fpp1'
        ? 'in-memory DC-net component with continuous simulated two-second rounds; no private sockets'
        : roleLocalSetup
        ? '11 independent role processes with verifiable anonymous setup over loopback mutual TLS; laboratory controller and supplied roster'
        : '11 independent role processes over loopback mutual TLS with a laboratory controller and centrally provisioned keys',
    'control': 'identical signed bundle; separate stores; identical two-hop public path; alternating AB/BA order',
    'durableRoleCheckpoints': candidate == 'fpp1durable' || roleLocalOutbox,
    'roleLocalOutboxIncluded': roleLocalOutbox,
    'commonCutoffIncluded': commonCutoff,
    'fusedReservationAcceptanceAndBulkPrepare': [
      'fpp1frozen',
      'fpp1fused',
      'fpp1atomic',
    ].contains(candidate),
    'atomicPublicationCheckpoints': atomicPublication,
    'frozenCompletion': frozenCompletion,
    if (frozenCompletion) 'completionPolicy': 'fresh reservation cutoff unchanged; signed two-second slack only for authenticated frozen completion; two-second admission lead; experimental, not a security acceptance',
    if (commonCutoff) 'clockScope': 'common signed schedule with assumed 100 ms role-clock error; no physical clock admission; live monotonic anchors are lost on restart',
    if (roleLocalOutbox) 'localSubmissionScope': 'protected arm includes private enqueue, synchronized queue commit and a timer independent of submissions; direct arm bypasses the protected queue',
    'excludes': [
      'UI rendering',
      'publisher signing',
      if (!roleLocalOutbox) 'publisher outbox',
      if (roleLocalOutbox) 'all-action application policy, durable application retry adapter and decentralized schedule',
      'real radio',
      if (androidWorker == null) 'Android',
      if (androidWorker != null) 'Android APK/public reader and independent physical role devices; only native private roles run on Android',
      'NAT',
      'discovery',
      if (candidate == 'fpp0') 'continuous covers',
      if (candidate != 'fpp0') 'continuous mobile-radio cover workload',
      'battery',
      if (candidate == 'fpp1')
        'private-network transport and distributed setup',
      if (candidate == 'fpp1net')
        'real peer topology, distributed anonymous setup and physical network',
      if (roleLocalSetup) 'cold setup (reported separately), real peer topology, admission and physical network',
    ],
    'securityGatePassed': false,
    'productionIntegrationAllowed': false,
    'knownFailure': candidate == 'fpp0'
        ? 'malicious-entry isolation; simulated cohort and sample-driven covers'
        : roleLocalSetup
        ? 'supplied roster; Sybil isolation, anonymous jamming, intersection and fixed-cohort churn; not an anonymity evaluation'
        : 'central setup fixture; Sybil isolation, anonymous jamming and fixed-cohort churn; not an anonymity evaluation',
  };
  final rows = <Map<String, dynamic>>[];
  report['rows'] = rows;
  final files = [
    ...Directory('lib/core').listSync(recursive: true).whereType<File>(),
    ...Directory('tools/privacy_lab')
        .listSync(recursive: true)
        .whereType<File>(),
    File('pubspec.lock'),
    File('pubspec.yaml'),
    if (androidWorker == null) File(binary),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final snapshotFiles = <String, File>{
    for (final file in files) file.path.replaceAll('\\', '/'): file,
    if (androidWorker != null) ...{
      'device/worker-binary': androidWorker.binary,
      'device/worker-config.json': androidWorker.configFile,
      ...androidWorker.sourceFiles,
    },
  };
  report['sourceAndBinarySha256'] = {
    for (final entry in snapshotFiles.entries)
      entry.key: sha256.convert(entry.value.readAsBytesSync()).toString(),
  };
  // Retain sources and worker binary; experimental files can change later.
  for (final entry in snapshotFiles.entries) {
    final snapshot = File('${run.path}/source/${entry.key}');
    snapshot.parent.createSync(recursive: true);
    entry.value.copySync(snapshot.path);
  }
  report['sourceSnapshot'] = 'source';
  report['gitHead'] = (await Process.run('git', [
    'rev-parse',
    'HEAD',
  ])).stdout.toString().trim();
  final cpu = ProcessCpu();
  final clock = Stopwatch()..start();
  final arms = <PublicArm>[];
  Process? worker;
  StreamIterator<String>? responses;
  var workerErrors = '';
  try {
    final identities = List.generate(3, (_) => Identity.generate());
    final publisher = Identity.generate();
    // Publisher has no direct public transport or app peer identity here.
    final channel = SignedChannel.create(
      publisher,
      name: 'آزمایش مقایسه مسیر انتشار',
    );
    for (final name in ['direct', 'protected']) {
      final arm = PublicArm(Directory('${run.path}/$name'), identities);
      arms.add(arm);
      await arm.start();
    }
    final workerArguments = [
      '-mode',
      frozenCompletion
          ? 'network-frozen-pipe'
          : candidate == 'fpp1atomic'
          ? 'network-schedule-atomic-pipe'
          : candidate == 'fpp1fused'
          ? 'network-schedule-fused-pipe'
          : candidate == 'fpp1scheduled'
          ? 'network-schedule-pipe'
          : roleLocalOutbox
          ? 'network-outbox-pipe'
          : candidate == 'fpp1durable'
          ? 'network-durable-pipe'
          : candidate == 'fpp1setup'
          ? 'network-setup-pipe'
          : candidate == 'fpp1net'
          ? 'network-pipe'
          : 'pipe-lab',
      '-payload',
      '8192',
      '-hops',
      '3',
      if (networkCandidate) ...[
        '-kbps',
        '$kbps',
        '-rtt-ms',
        '$rttMs',
        '-wire',
        wireCodec,
      ],
    ];
    worker = await Process.start(
      androidWorker == null
          ? binary
          : '.tooling/android-sdk/platform-tools/adb.exe',
      androidWorker == null
          ? workerArguments
          : androidWorker.arguments(workerArguments),
    );
    worker.stderr.transform(utf8.decoder).listen((text) {
      if (workerErrors.length < 16000) workerErrors += text;
    });
    responses = StreamIterator(
      worker.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    if (!await responses.moveNext().timeout(
      Duration(seconds: 30 + (11 * rttMs / 1000).ceil()),
    )) {
      throw StateError('Mix worker failed to start');
    }
    final ready = jsonDecode(responses.current) as Map;
    if (ready['ready'] != true || ready['securityGatePassed'] != false) {
      throw StateError('Unexpected research worker');
    }
    if (roleLocalOutbox && ready['roleLocalOutboxes'] != true) {
      throw StateError('Private queue candidate was not enabled');
    }
    if (atomicPublication &&
        ready['atomicPublicationCheckpoints'] != true) {
      throw StateError(
        'Atomic publication checkpoint candidate was not enabled',
      );
    }
    if (frozenCompletion &&
        (ready['frozenCompletion'] != true ||
            ready['scheduleAdmissionLeadMs'] != 2000 ||
            (ready['commonSchedule'] as Map?)?['Proposal']?['CompletionSlackNano'] != 2000000000)) {
      throw StateError('Frozen completion schedule differs from the requested policy');
    }
    if (androidWorker != null &&
        (ready['runtimeOS'] != 'android' ||
            ready['runtimeArch'] != androidWorker.architecture)) {
      throw StateError(
        'Worker did not run on the prepared Android architecture',
      );
    }
    report['mixConfiguration'] = ready;
    if (networkCandidate &&
        ((ready['linkProfile'] as Map?)?['wireCodec'] ?? 'json') != wireCodec) {
      throw StateError('Private RPC codec differs from requested profile');
    }
    for (var pair = -2; pair < samples; pair++) {
      // Vary request phase against the independently running round timer.
      // This delay precedes both paired observations and is not subtracted from
      // a measured publication. Idle component rounds continue during it.
      if (candidate != 'fpp0') {
        await Future<void>.delayed(
          Duration(milliseconds: ((pair + 2) * 977) % 2000),
        );
      }
      final bulletin = SignedBulletin.create(
        publisher,
        runId: 'privacy-lab',
        sequence: pair + 3,
        channelId: channel.id,
        text:
            'آزمایش ${pair + 3} — ${'مسئولیت‌پذیری و اطلاع‌رسانی؛ ' * (pair.isEven ? 2 : 16)}',
      );
      final payload = utf8.encode(
        '${jsonEncode({'type': 'channel', 'value': channel.toJson()})}\n'
        '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
      );
      final row = <String, dynamic>{
        'pair': pair,
        'warmup': pair < 0,
        'signedBundleBytes': payload.length,
      };
      rows.add(row);
      final order = pair.isEven ? [0, 1] : [1, 0];
      for (final index in order) {
        final protected = index == 1;
        final arm = arms[index];
        final before = arm.bytes();
        final cpuStart = cpu.readMs();
        final started = clock.elapsedMicroseconds;
        Map<String, dynamic>? mix;
        var released = payload;
        if (protected) {
          final requestId = pair + 3;
          worker.stdin.writeln(
            jsonEncode({
              'id': requestId,
              'payload': base64Encode(payload),
              'slotWaitMs': ((pair + 2) * 977) % 2000,
            }),
          );
          await worker.stdin.flush();
          if (!await responses.moveNext().timeout(
            const Duration(seconds: 12),
          )) {
            throw StateError('Protected path stopped; no direct fallback');
          }
          mix = Map<String, dynamic>.from(jsonDecode(responses.current) as Map);
          if (mix['id'] != requestId) throw StateError('Wrong release');
          released = base64Decode(mix.remove('payload') as String);
          if (sha256.convert(released) != sha256.convert(payload)) {
            throw StateError('Protected path changed application bytes');
          }
        }
        final publicStart = clock.elapsedMicroseconds;
        arm.sender!.add(released);
        await arm.sender!.flush();
        var lastAbsent = publicStart;
        int? received;
        while (clock.elapsedMicroseconds - started < 15000000) {
          final beforeRead = clock.elapsedMicroseconds;
          final state = await arm.engines.last.snapshot();
          if ((state['bulletins'] as List).any(
            (dynamic item) => item['id'] == bulletin.id,
          )) {
            received = clock.elapsedMicroseconds;
            break;
          }
          lastAbsent = beforeRead;
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        row[protected ? 'protected' : 'direct'] = {
          'received': received != null,
          'lowerMs': (lastAbsent - started) / 1000,
          'upperMs': received == null ? null : (received - started) / 1000,
          'prePublicMs': (publicStart - started) / 1000,
          'dartProcessCpuMs': cpu.readMs() - cpuStart,
          'mix': mix,
          'publicTlsByteDelta': [
            for (var link = 0; link < arm.meters.length; link++)
              {
                for (final key in before[link].keys)
                  key: arm.meters[link].snapshot()[key]! - before[link][key]!,
              },
          ],
        };
        if (received == null) {
          throw TimeoutException('Public reader store did not receive');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      row['additionalLowerMs'] =
          (row['protected']['lowerMs'] as num) -
          (row['direct']['upperMs'] as num);
      row['additionalUpperMs'] =
          (row['protected']['upperMs'] as num) -
          (row['direct']['lowerMs'] as num);
    }
    final measured = rows.where((r) => r['warmup'] == false).toList();
    report['summary'] = {
      'completedPairs': measured.length,
      'additionalUpperMs': stats(
        measured
            .map((r) => (r['additionalUpperMs'] as num).toDouble())
            .toList(),
      ),
      'additionalLowerMs': stats(
        measured
            .map((r) => (r['additionalLowerMs'] as num).toDouble())
            .toList(),
      ),
      'directUpperMs': stats(
        measured
            .map((r) => (r['direct']['upperMs'] as num).toDouble())
            .toList(),
      ),
      'protectedUpperMs': stats(
        measured
            .map((r) => (r['protected']['upperMs'] as num).toDouble())
            .toList(),
      ),
      'timingGatePassed': false,
      'gateReason': 'local characterization only; physical-route and complete private-protocol evidence missing',
    };
  } catch (error, stack) {
    report['fatal'] = '$error';
    report['stack'] = '$stack';
    exitCode = 1;
  } finally {
    if (worker != null) {
      try {
        await worker.stdin.close();
      } catch (error) {
        report['workerStdinCloseError'] = '$error';
      }
      try {
        report['workerExitCode'] = await worker.exitCode.timeout(
          Duration(seconds: androidWorker == null ? 5 : 20),
        );
      } on TimeoutException {
        worker.kill();
        report['workerForcedStop'] = true;
      }
    }
    await responses?.cancel();
    for (final arm in arms) {
      await arm.close();
    }
    report['workerErrors'] = workerErrors;
    report['publicErrors'] = arms.expand((arm) => arm.errors).toList();
    report['proxyErrors'] = arms
        .expand((arm) => arm.meters)
        .expand((m) => m.errors)
        .toList();
    report['elapsedMsIncludingSetup'] = clock.elapsedMilliseconds;
    final output = File('${run.path}/result.json');
    output.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    stdout.writeln(
      jsonEncode({
        'result': output.absolute.path,
        'summary': report['summary'],
        'fatal': report['fatal'],
      }),
    );
  }
}
