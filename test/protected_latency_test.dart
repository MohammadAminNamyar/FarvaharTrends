import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farvahar_trends/core/envelope_crypto_worker.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/media_store.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tools/privacy_lab/measurement.dart';

// A separate latency instrument: no snapshots or observer probes are run in
// timed delivery. All modes use the same reader, topology, signing identities,
// message lengths and fresh caches. This does not test anonymity.
void main() {
  test(
    'paired direct stub and HPKE reader admission latency',
    () async {
      final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
      await parent.create(recursive: true);
      final fixture = await File('test/fixtures/news-small.jpg').readAsBytes();
      final results = <Map<String, dynamic>>[];
      final samples =
          int.tryParse(Platform.environment['FT_LATENCY_SAMPLES'] ?? '') ?? 12;
      final sessions =
          int.tryParse(Platform.environment['FT_LATENCY_SESSIONS'] ?? '') ?? 3;
      final processCpu = ProcessCpu();
      for (var session = 0; session < sessions; session++) {
        final identities = List.generate(4, (_) => Identity.generate());
        final signing = Identity.generate();
        final names = ['direct', 'stub', 'hpke'];
        final order = List.generate(3, (i) => names[(i + session) % 3]);
        for (final mode in order) {
          final root = await parent.createTemp('paired-envelope-');
          final engines = <PeerEngine>[];
          final configs = <EnvelopeExperiment>[];
          final clock = Stopwatch()..start();
          final admitted = <String, int>{};
          String? localId;
          final startup = Stopwatch()..start();
          Future<void> until(
            bool Function() condition, {
            int ms = 15000,
          }) async {
            final limit = clock.elapsedMilliseconds + ms;
            while (!condition()) {
              if (clock.elapsedMilliseconds > limit) {
                throw StateError('Latency setup/delivery timeout');
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          }

          try {
            for (var i = 0; i < 4; i++) {
              final config = EnvelopeExperiment(
                guardPeerId: identities[1].id,
                exitPeerIds: [identities[2].id],
                cryptoMode: mode == 'stub'
                    ? EnvelopeCryptoMode.stub
                    : EnvelopeCryptoMode.hpke,
              );
              if (i == 0) config.onLocalPublication = (id) => localId = id;
              if (i == 3) {
                config.onPublicAdmission = (id) =>
                    admitted.putIfAbsent(id, () => clock.elapsedMicroseconds);
              }
              configs.add(config);
              final engine = PeerEngine(
                directory: Directory('${root.path}/$i'),
                identity: identities[i],
                publisherIdentity: i == 0 ? signing : null,
                listenPort: 0,
                discoveryPort: 0,
                enableLanDiscovery: false,
                enableUdpDiscovery: false,
                imageMode: 'any',
                envelopeExperiment: config,
                deviceState: () async => {'network': 'wifi'},
                onStatus: (_) {},
              );
              engines.add(engine);
              await engine.start(activeMode: false);
            }
            for (var i = 0; i < 4; i++) {
              final key = await engines[i].envelopePublicKey();
              for (final config in configs) {
                config.recipientKeys[identities[i].id] = key;
              }
            }
            PeerCard card(int i) => PeerCard(
              name: 'latency $i',
              host: '127.0.0.1',
              port: engines[i].boundPort,
              certificatePem: identities[i].certPem,
            );
            for (final pair in [(0, 1), (1, 2), (2, 3), (0, 3)]) {
              await engines[pair.$1].addPeer(card(pair.$2));
              await engines[pair.$2].addPeer(card(pair.$1));
            }
            // Snapshot polling is setup only; it is never used to discover a
            // timed publication's id or completion.
            final ready = clock.elapsedMilliseconds + 15000;
            while (true) {
              var all = true;
              for (final engine in engines) {
                all = all && (await engine.snapshot())['connectedCount'] == 2;
              }
              if (all) break;
              if (clock.elapsedMilliseconds > ready) {
                throw StateError('Latency links');
              }
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
            final channel = await engines[0].createChannel(
              name: 'latency setup',
            );
            await until(() => admitted.containsKey(channel.id));
            final startupMs = startup.elapsedMilliseconds;
            final rows = <Map<String, dynamic>>[];
            Future<Map<String, dynamic>> publication(
              int index, {
              required bool measured,
            }) async {
              Uint8List? image;
              if (measured && index % 6 == 5) {
                image = Uint8List.fromList(fixture);
                var p = image.length - 64;
                while (image[p] == 255 || image[p - 1] == 255) {
                  p--;
                }
                image[p] =
                    1 +
                    ((image[p] +
                            index +
                            session * 17 +
                            names.indexOf(mode) * 37) %
                        254);
              }
              final hash = image == null ? null : NewsImage.inspect(image).hash;
              localId = null;
              final started = clock.elapsedMicroseconds;
              final id = mode == 'direct'
                  ? await (() async {
                      await engines[0].publishToChannel(
                        channelId: channel.id,
                        text: 'آزمایش همسان $index',
                        imageBytes: image,
                      );
                      return localId!;
                    })()
                  : await engines[0].publishProtected(
                      channelId: channel.id,
                      text: 'آزمایش همسان $index',
                      imageBytes: image,
                    );
              final returned = clock.elapsedMicroseconds;
              String? failure;
              try {
                await until(() => admitted.containsKey(id));
              } catch (e) {
                failure = '$e';
              }
              int? imageReady;
              if (hash != null && failure == null) {
                try {
                  await until(() => configs[3].fetchedImages.contains(hash));
                  imageReady = clock.elapsedMicroseconds - started;
                } catch (e) {
                  failure = 'image: $e';
                }
              }
              final row = <String, dynamic>{
                'index': index,
                'kind': image == null ? 'text' : 'image',
                'callMs': (returned - started) / 1000,
                'readerReadyMs': admitted[id] == null
                    ? null
                    : (admitted[id]! - started) / 1000,
                'imageReadyMs': imageReady == null ? null : imageReady / 1000,
                'failure': failure,
              };
              // Let the ordinary echo and image forwarding drain equally in all
              // modes, rather than charging them to the next timed publication.
              await Future<void>.delayed(const Duration(milliseconds: 250));
              return row;
            }

            for (var i = 0; i < 3; i++) {
              await publication(-3 + i, measured: false);
            }
            final cpuStart = processCpu.readMs(), wall = Stopwatch()..start();
            for (var i = 0; i < samples; i++) {
              rows.add(await publication(i, measured: true));
            }
            final cpu = processCpu.readMs() - cpuStart;
            results.add({
              'session': session,
              'mode': mode,
              'order': order,
              'startupMs': startupMs,
              'records': rows,
              'processCpuMs': cpu,
              'wallMs': wall.elapsedMilliseconds,
              'applicationEgressBytes': configs.fold<int>(
                0,
                (sum, c) => sum + (c.stats['applicationEgressBytes'] ?? 0),
              ),
              'egressScope': 'all four engines including startup/warmup; application bytes, excluding TLS/TCP/radio overhead',
              'cpuScope': 'four engine contexts and workers in one Windows process; measured posts and drains, not phone battery',
              'stats': configs.map((c) => c.stats).toList(),
            });
            stdout.writeln(
              'PAIRED_LATENCY session=$session mode=$mode complete=${rows.where((r) => r['failure'] == null).length}/${rows.length}',
            );
          } finally {
            for (final engine in engines) {
              await engine.stop();
            }
            if (root.absolute.path.startsWith(
              '${parent.absolute.path}${Platform.pathSeparator}',
            )) {
              await root.delete(recursive: true);
            }
          }
        }
      }
      final file = File(
        'artifacts/privacy-lab/paired-envelope-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.json',
      );
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scope': 'host loopback; warmed routes; paired fresh arms; same keys/payload lengths within session; no anonymity or battery inference',
          'results': results,
        }),
      );
      expect(
        results
            .expand((r) => r['records'] as List)
            .where((r) => r['failure'] != null),
        isEmpty,
      );
    },
    skip: Platform.environment['FT_LATENCY_RUN'] != '1',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
