import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:farvahar_trends/core/bounded_journal.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/envelope_crypto_worker.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Identity client, receiver;
  late Directory root;
  late PeerEngine engine;
  late EnvelopeExperiment config;
  late EnvelopeCryptoWorker producer;
  SecureSocket? socket;
  bool transportClosed = false;
  final replies = <Map<String, dynamic>>[];

  Future<void> until(bool Function() ready) async {
    final watch = Stopwatch()..start();
    while (!ready()) {
      if (watch.elapsed > const Duration(seconds: 15)) {
        fail('Relay condition timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> start({bool experiment = true}) async {
    transportClosed = false;
    engine = PeerEngine(
      directory: Directory('${root.path}/receiver'),
      identity: receiver,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      envelopeExperiment: experiment ? config : null,
      onStatus: (_) {},
      deviceState: () async => {'network': 'wifi'},
    );
    await engine.start(activeMode: false);
    await engine.addPeer(
      PeerCard(name: 'laboratory ingress', certificatePem: client.certPem),
    );
    socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      engine.boundPort,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(client.certPem))
        ..usePrivateKeyBytes(utf8.encode(client.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(receiver.certPem)),
      onBadCertificate: (certificate) =>
          Identity.certificateId(certificate.pem) == receiver.id,
    );
    transportClosed = false;
    final connectedSocket = socket!;
    connectedSocket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            replies.add(jsonDecode(line) as Map<String, dynamic>);
          },
          onDone: () {
            if (identical(socket, connectedSocket)) transportClosed = true;
          },
        );
    socket!.write(
      '${jsonEncode({
        'type': 'inventory',
        'features': [config.feature, 'channel-v2', 'owner-recovery-v1'],
        'channels': [],
        'bulletins': [],
        'receipts': [],
        'policies': [],
        'media': [],
      })}\n',
    );
    await socket!.flush();
    await until(() => replies.any((f) => f['type'] == 'inventory'));
  }

  Future<Uint8List> cell(Map<String, dynamic> inner) async {
    final outer = await producer.seal(
      inner,
      exitId: receiver.id,
      exitKey: await engine.envelopePublicKey(),
      guardKey: producer.publicKey,
    );
    return (await producer.openEntry(outer))['cell'] as Uint8List;
  }

  Future<void> send(Uint8List bytes) async {
    socket!.write(
      '${jsonEncode({'type': 'envelope', 'stage': 'exit', 'cell': base64Encode(bytes)})}\n',
    );
    await socket!.flush();
  }

  Map<String, dynamic> fragment(
    String id,
    String group,
    Uint8List bytes, {
    int n = 1,
  }) => {'o': id, 'g': group, 'i': 0, 'n': n, 'p': base64Encode(bytes)};
  Uint8List bundleValue(String type, Map<String, dynamic> value) {
    final meta = utf8.encode(jsonEncode({'type': type, 'value': value}));
    final bytes = Uint8List(4 + meta.length);
    ByteData.sublistView(bytes).setUint32(0, meta.length);
    bytes.setRange(4, bytes.length, meta);
    return bytes;
  }

  Uint8List bundle(SignedChannel channel) => bundleValue('channel', channel.toJson());

  setUpAll(() {
    client = Identity.generate();
    receiver = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    root = await parent.createTemp('protected-relay-');
    config = EnvelopeExperiment();
    replies.clear();
    producer = await EnvelopeCryptoWorker.start(
      Directory('${root.path}/producer'),
      mode: EnvelopeCryptoMode.hpke,
    );
    await start();
  });
  tearDown(() async {
    socket?.destroy();
    await engine.stop();
    await producer.close();
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp')
        .absolute
        .path;
    if (root.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
      await root.delete(recursive: true);
    }
  });

  test('tampered opaque cells do not blame entry; valid data releases once despite replay', () async {
    final channel = SignedChannel.create(client, name: 'آزمایش رمزگذاری');
    final valid = await cell(fragment(channel.id, '1' * 32, bundle(channel)));
    final corrupt = Uint8List.fromList(valid)..[valid.length - 1] ^= 1;
    await send(corrupt);
    await until(() => (config.stats['invalidRelayedObjects'] ?? 0) == 1);
    await send(valid);
    await until(() => config.stats['objectsReleased'] == 1);
    await send(valid);
    await until(() => config.stats['cellsReceivedAtExit'] == 2);
    expect(config.stats['objectsReleased'], 1);
    final snapshot = await engine.snapshot();
    expect(snapshot['connectedCount'], 1);
    expect((snapshot['channels'] as List).single['id'], channel.id);
  });

  test('ordinary app engine does not enable envelope ingress through peer negotiation', () async {
    socket!.destroy();
    await engine.stop();
    replies.clear();
    await start(experiment: false);
    await send(Uint8List(EnvelopeCryptoWorker.innerSize));
    await until(() => transportClosed);
    expect(
      (await engine.snapshot()).containsKey('envelopeExperiment'),
      isFalse,
    );
    expect(config.stats['cellsReceivedAtExit'], 0);
  });

  test(
    'bad publisher signature is discarded instead of repeatedly reverified',
    () async {
      final channel = SignedChannel.create(client, name: 'اعتبار امضا');
      await send(await cell(fragment(channel.id, '3' * 32, bundle(channel))));
      await until(() => config.stats['objectsReleased'] == 1);
      final news = SignedBulletin.create(
        client,
        runId: 'news',
        text: 'آزمون امضای نامعتبر',
        sequence: 1,
        channelId: channel.id,
      );
      final invalid = news.toJson()
        ..['signature'] = base64Encode(Uint8List(256));
      await send(
        await cell(
          fragment(news.id, '4' * 32, bundleValue('bulletin', invalid)),
        ),
      );
      await until(() => (config.stats['invalidRelayedObjects'] ?? 0) == 1);
      await Future<void>.delayed(const Duration(milliseconds: 3400));
      expect(config.stats['invalidRelayedObjects'], 1);
      expect((await engine.snapshot())['bulletinCount'], 0);
      expect((await engine.snapshot())['connectedCount'], 1);
    },
  );

  test('incomplete fragment groups are bounded per physical entry and survive restart', () async {
    for (var i = 0; i < 5; i++) {
      await send(
        await cell(
          fragment(
            'a' * 64,
            i.toRadixString(16).padLeft(32, '0'),
            Uint8List(5600),
            n: 2,
          ),
        ),
      );
    }
    await until(() => config.stats['exitCapacity'] == 1);
    expect(config.stats['cellsReceivedAtExit'], 4);
    socket!.destroy();
    await engine.stop();
    final journal = BoundedJournal(
      File('${root.path}/receiver/envelope-exit-x2.jsonl'),
      maxEntries: 128,
      maxStateBytes: 1536 * 1024,
      maxJournalBytes: 4 * 1024 * 1024,
    );
    await journal.load();
    expect(journal.rows.length, 4);
    expect(journal.stateBytes, lessThan(40 * 1024));
    replies.clear();
    await start();
    await send(await cell(fragment('b' * 64, '9' * 32, Uint8List(5600), n: 2)));
    await until(() => config.stats['exitCapacity'] == 2);
    expect((await engine.snapshot())['connectedCount'], 1);
  });

  test('acknowledged held release resumes after restart without publisher resubmission', () async {
    config.holdAtExit = true;
    final channel = SignedChannel.create(client, name: 'بازیابی پس از توقف');
    final sealed = await cell(fragment(channel.id, '2' * 32, bundle(channel)));
    await send(sealed);
    await until(() => replies.any((f) => f['type'] == 'envelopeAck'));
    expect((await engine.snapshot())['channels'], isEmpty);
    socket!.destroy();
    await engine.stop();
    config.holdAtExit = false;
    replies.clear();
    await start();
    await until(() => config.stats['objectsReleased'] == 1);
    expect((await engine.snapshot())['channels'].single['id'], channel.id);
    expect(config.stats['cellsReceivedAtExit'], 1);
  });
}
