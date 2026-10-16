// Research tool only: no import from the application, no public discovery.
// Run from the repository root with `dart run tools/privacy_lab/baseline.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

import 'measurement.dart';

double percentile(List<double> values, double p) {
  if (values.isEmpty) return double.nan;
  final sorted = [...values]..sort();
  return sorted[max(0, (p * sorted.length).ceil() - 1)];
}

Future<void> main(List<String> args) async {
  final samples = args.isEmpty ? 40 : int.parse(args.first);
  final hops = args.length < 2 ? 1 : int.parse(args[1]);
  if (samples < 1 || samples > 100 || hops < 1 || hops > 4) {
    throw ArgumentError('Use 1..100 samples and 1..4 TCP hops.');
  }
  final base = Directory('.local-only/privacy-lab')
    ..createSync(recursive: true);
  final work = base.createTempSync('baseline-');
  final clock = Stopwatch()..start();
  final cpu = ProcessCpu();
  final engines = <PeerEngine>[];
  final links = <MeteredLink>[];
  final rows = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schema': 2,
    'experiment': 'existing PeerEngine over pinned TLS on Windows loopback',
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
    'dart': Platform.version,
    'hops': hops,
    'requestedSamples': samples,
    'clock': 'one process monotonic Stopwatch; no cross-device wall clocks',
    'endpoint': 'receiver durable-store snapshot visibility, not UI rendering',
    'excluded': ['radio', 'Android', 'DHT', 'NAT', 'mixing', 'battery'],
    'polling': 'bounds retained; actual interval includes snapshot cost',
    'rows': rows,
  };
  final sourceFiles = [
    ...Directory('lib/core').listSync(recursive: true).whereType<File>(),
    ...Directory('tools/privacy_lab')
        .listSync(recursive: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart')),
    File('pubspec.lock'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  report['sourceSha256'] = {
    for (final file in sourceFiles)
      file.path.replaceAll('\\', '/'): sha256
          .convert(file.readAsBytesSync())
          .toString(),
  };
  report['gitHead'] = (await Process.run('git', [
    'rev-parse',
    'HEAD',
  ])).stdout.toString().trim();
  report['cpuScope'] = 'GetProcessTimes: all engines, observers and proxy tasks in this process; not whole-device CPU';
  report['byteScope'] = 'TLS byte streams counted once per link; excludes TCP/IP headers, retransmits and radios';
  List<Map<String, int>> bytes() => links.map((p) => p.snapshot()).toList();
  var cpuStart = 0.0;
  var phaseStart = 0;
  Future<void> until(Future<bool> Function() condition) async {
    final end = clock.elapsedMilliseconds + 20000;
    while (!await condition()) {
      if (clock.elapsedMilliseconds > end) {
        throw TimeoutException(
          'Local route setup',
          const Duration(seconds: 20),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  try {
    final identities = List.generate(hops + 1, (_) => Identity.generate());
    // Keys are ephemeral lab keys. Never read the installed app's identity.
    for (var i = 0; i <= hops; i++) {
      final engine = PeerEngine(
        directory: Directory('${work.path}/peer-$i'),
        identity: identities[i],
        listenPort: 0,
        enableLanDiscovery: false,
        enableUdpDiscovery: false,
        deviceState: () async => {'platform': 'windows-loopback-lab'},
        onStatus: (_) {},
      );
      engines.add(engine);
      await engine.start(activeMode: false);
    }
    for (var i = 0; i < hops; i++) {
      // Enrol both certificates, but dial only left -> right. This avoids two
      // racing connections from contaminating the per-link byte count.
      await engines[i + 1].addPeer(
        PeerCard(
          name: 'Isolated benchmark',
          certificatePem: identities[i].certPem,
        ),
      );
      final proxy = await MeteredLink.start(
        (await engines[i + 1].snapshot())['listenPort'] as int,
      );
      links.add(proxy);
      await engines[i].addPeer(
        PeerCard(
          name: 'Isolated benchmark',
          host: '127.0.0.1',
          port: proxy.port,
          certificatePem: identities[i + 1].certPem,
        ),
      );
    }
    for (var i = 0; i <= hops; i++) {
      final expected = i == 0 || i == hops ? 1 : 2;
      await until(
        () async => (await engines[i].snapshot())['connectedCount'] == expected,
      );
    }
    final channel = await engines.first.createChannel(
      name: 'آزمایش محلی اندازه‌گیری',
      description: 'این خبرها فقط در آزمایش محلی ساخته می‌شوند.',
    );
    await until(
      () async => ((await engines.last.snapshot())['channels'] as List).any(
        (dynamic row) => row['id'] == channel.id,
      ),
    );
    // Mix short/long Farsi deterministically; record JIT warm-up separately.
    for (var n = -5; n < samples; n++) {
      if (n == 0) {
        report['tlsBytesBeforeMeasurement'] = bytes();
        cpuStart = cpu.readMs();
        phaseStart = clock.elapsedMicroseconds;
      }
      final text =
          'آزمایش $n — ${'مسئولیت‌پذیری و اطلاع‌رسانی؛ ' * (n.isEven ? 2 : 16)}';
      final beforeBytes = bytes();
      final started = clock.elapsedMicroseconds;
      var lastAbsent = started;
      final publish = engines.first.publishToChannel(
        channelId: channel.id,
        text: text,
      );
      int? publishFinished;
      Object? publicationError;
      final observedPublish = publish.then<void>(
        (_) {
          publishFinished = clock.elapsedMicroseconds;
        },
        onError: (Object e, StackTrace _) {
          publicationError = e;
        },
      );
      int? received;
      var polls = 0;
      while (clock.elapsedMicroseconds - started < 10000000) {
        final beforeRead = clock.elapsedMicroseconds;
        final state = await engines.last.snapshot();
        polls++;
        if ((state['bulletins'] as List).any(
          (dynamic row) => row['text'] == text,
        )) {
          received = clock.elapsedMicroseconds;
          break;
        }
        lastAbsent = beforeRead;
        if (publicationError != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await observedPublish;
      rows.add({
        'index': n,
        'warmup': n < 0,
        'textUtf8Bytes': utf8.encode(text).length,
        'received': received != null,
        'lowerMs': (lastAbsent - started) / 1000,
        'upperMs': received == null ? null : (received - started) / 1000,
        'publishCompletedMs': publishFinished == null
            ? null
            : (publishFinished! - started) / 1000,
        'polls': polls,
        'tlsBytesDeltaUntilObserved': [
          for (var link = 0; link < links.length; link++)
            {
              for (final key in beforeBytes[link].keys)
                key: links[link].snapshot()[key]! - beforeBytes[link][key]!,
            },
        ],
        if (publicationError != null) 'error': '$publicationError',
      });
      if (received == null) {
        break; // Preserve a failure; don't hide it by retries.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (phaseStart > 0) {
      final cpuEnd = cpu.readMs();
      final wallMs = (clock.elapsedMicroseconds - phaseStart) / 1000;
      report['measuredPhaseResources'] = {
        'processCpuMs': cpuEnd - cpuStart,
        'wallMs': wallMs,
        'averageLogicalCores': (cpuEnd - cpuStart) / wallMs,
        'includes': 'publication, verification/storage, observer, proxy, public gossip, 300ms inter-sample idle',
        'cpuCumulativeResolution': 'Windows process accounting; do not interpret very small deltas as exact',
      };
      report['tlsBytesAfterMeasurement'] = bytes();
    }
    final measured = rows.where((r) => r['warmup'] == false).toList();
    final upper = measured
        .where((r) => r['received'] == true)
        .map((r) => r['upperMs'] as double)
        .toList();
    report['summary'] = {
      'completed': measured.length,
      'successful': upper.length,
      'failed': measured.where((r) => r['received'] != true).length,
      'unattempted': samples - measured.length,
      'warmupFailures': rows
          .where((r) => r['warmup'] == true && r['received'] != true)
          .length,
      'upperP50Ms': upper.isEmpty ? null : percentile(upper, .5),
      'upperP95Ms': upper.isEmpty ? null : percentile(upper, .95),
      'upperP99Ms': upper.isEmpty ? null : percentile(upper, .99),
      'upperMaxMs': upper.isEmpty ? null : upper.reduce(max),
      'maxObservationWidthMs': upper.isEmpty
          ? null
          : measured
                .where((r) => r['received'] == true)
                .map((r) => (r['upperMs'] as double) - (r['lowerMs'] as double))
                .reduce(max),
      'meaning': 'Observed local baseline; empirical quantiles, no population guarantee',
    };
    report['lastReceiverStatus'] =
        Map<String, dynamic>.from(await engines.last.snapshot())..removeWhere(
          (k, _) => ![
            'connectedCount',
            'rejectedCount',
            'trafficDeferred',
            'lastError',
          ].contains(k),
        );
    if (upper.length != samples) exitCode = 2;
  } catch (error, stack) {
    report['fatal'] = '$error';
    report['stack'] = '$stack';
    exitCode = 1;
  } finally {
    // Mark proxy teardown first so ordinary shutdown EOFs are not test failures.
    for (final proxy in links) {
      await proxy.close();
    }
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    report['proxyErrors'] = links.expand((p) => p.errors).toList();
    report['elapsedMsIncludingSetup'] = clock.elapsedMilliseconds;
    report['peakRssBytesProcess'] = ProcessInfo.maxRss;
    final output = File('${work.path}/result.json');
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
