import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_engine.dart';

void main() {
  late Identity local;
  late List<Identity> senders;
  late Directory directory;
  late PeerEngine engine;
  final sockets = <SecureSocket>[];
  final requestedChannels = <String>{};
  Completer<void>? sampleGate;
  var blockedSamples = 0;

  setUpAll(() {
    local = Identity.generate();
    senders = List.generate(7, (_) => Identity.generate());
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    directory = await parent.createTemp('pending-concurrency-');
    requestedChannels.clear();
    sampleGate = null;
    blockedSamples = 0;
    engine = PeerEngine(
      directory: directory,
      identity: local,
      listenPort: 0,
      discoveryPort: 0,
      enableLanDiscovery: false,
      deviceState: () async {
        final gate = sampleGate;
        if (gate != null) {
          blockedSamples++;
          await gate.future;
        }
        return {'network': 'wifi'};
      },
      onStatus: (_) {},
    );
  });
  tearDown(() async {
    if (sampleGate != null && !sampleGate!.isCompleted) sampleGate!.complete();
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await engine.stop();
    await directory.delete(recursive: true);
  });

  Future<void> connectSenders(int count) async {
    for (final sender in senders.take(count)) {
      await engine.addPeer(
        PeerCard(
          name: 'Concurrency test peer',
          host: '',
          port: 45871,
          certificatePem: sender.certPem,
        ),
      );
    }
    await engine.start(activeMode: false);
    final port = (await engine.snapshot())['listenPort'] as int;
    for (var i = 0; i < count; i++) {
      final sender = senders[i];
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        port,
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(sender.certPem))
          ..usePrivateKeyBytes(utf8.encode(sender.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(local.certPem)),
        onBadCertificate: (certificate) =>
            Identity.certificateId(certificate.pem) == local.id,
        timeout: const Duration(seconds: 3),
      );
      sockets.add(socket);
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final frame = jsonDecode(line) as Map<String, dynamic>;
            if (frame['type'] == 'want') {
              requestedChannels.addAll(
                (frame['channels'] as List).cast<String>(),
              );
            }
          }, onError: (Object _) {});
      await until(
        () async => (await engine.snapshot())['connectedCount'] == i + 1,
      );
    }
  }

  Future<String> sendMissingChannel(int sender, int sequence) async {
    final channelId = (sender * 100 + sequence)
        .toRadixString(16)
        .padLeft(64, '0');
    final bulletin = SignedBulletin.create(
      senders[sender],
      runId: 'pending-concurrency',
      text: 'Benign missing metadata test $sender/$sequence',
      sequence: sequence,
      channelId: channelId,
    );
    sockets[sender].write(
      '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
    );
    await sockets[sender].flush();
    return channelId;
  }

  test(
    'concurrent network sampling cannot exceed global pending capacity',
    () async {
      await connectSenders(7);
      var pending = 0;
      for (var sender = 0; sender < 4; sender++) {
        for (var sequence = 1; sequence <= (sender == 3 ? 3 : 4); sequence++) {
          await sendMissingChannel(sender, sequence);
          pending++;
          await until(
            () async =>
                (await engine.snapshot())['pendingBulletinCount'] == pending,
          );
        }
      }
      expect(pending, 15);
      sampleGate = Completer<void>();
      final newChannels = <String>[];
      for (var sender = 4; sender < 7; sender++) {
        newChannels.add(await sendMissingChannel(sender, 1));
      }
      // All three independent link processors are suspended after seeing the
      // same preexisting 15 entries. Their capacity decision must follow this
      // await rather than reserve three unbounded slots before it.
      await until(() async => blockedSamples == 3);
      sampleGate!.complete();
      await until(() async => newChannels.every(requestedChannels.contains));
      expect((await engine.snapshot())['pendingBulletinCount'], 16);
      expect((await engine.snapshot())['connectedCount'], 7);
    },
  );

  test(
    'stop invalidates a pending insertion suspended in network sampling',
    () async {
      await connectSenders(1);
      sampleGate = Completer<void>();
      await sendMissingChannel(0, 1);
      await until(() async => blockedSamples == 1);
      final stopping = engine.stop();
      await until(() async => (await engine.snapshot())['connectedCount'] == 0);
      sampleGate!.complete();
      await stopping;
      expect((await engine.snapshot())['running'], false);
      expect((await engine.snapshot())['pendingBulletinCount'], 0);
      await engine.start(activeMode: false);
      expect((await engine.snapshot())['pendingBulletinCount'], 0);
    },
  );

  test('dropped old link cannot commit sampled news after restart', () async {
    await connectSenders(1);
    final channel = SignedChannel.create(
      senders.first,
      name: 'Known metadata before stop',
    );
    sockets.first.write(
      '${jsonEncode({'type': 'channel', 'value': channel.toJson()})}\n',
    );
    await sockets.first.flush();
    await until(
      () async => ((await engine.snapshot())['channels'] as List).length == 1,
    );
    sampleGate = Completer<void>();
    final bulletin = SignedBulletin.create(
      senders.first,
      runId: 'pending-concurrency',
      text: 'Verified news must belong to its receiving session',
      sequence: 1,
      channelId: channel.id,
    );
    sockets.first.write(
      '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
    );
    await sockets.first.flush();
    await until(() async => blockedSamples == 1);
    // This processor is no longer in the live-link map when stop collects
    // processors to await. Its captured session must still invalidate it.
    sockets.first.destroy();
    await until(() async => (await engine.snapshot())['connectedCount'] == 0);
    await engine.stop();
    await engine.start(activeMode: false);
    sampleGate!.complete();
    await connectSenders(1);
    final fresh = SignedBulletin.create(
      senders.first,
      runId: 'pending-concurrency',
      text: 'Fresh session still accepts valid news',
      sequence: 2,
      channelId: channel.id,
    );
    sockets.last.write(
      '${jsonEncode({'type': 'bulletin', 'value': fresh.toJson()})}\n',
    );
    await sockets.last.flush();
    await until(
      () async => ((await engine.snapshot())['bulletins'] as List).any(
        (value) => value['id'] == fresh.id,
      ),
    );
    expect(
      ((await engine.snapshot())['bulletins'] as List).map(
        (value) => value['id'],
      ),
      [fresh.id],
    );
  });

  test('metadata arriving during sampling immediately resolves the news', () async {
    await connectSenders(2);
    final channel = SignedChannel.create(
      senders.first,
      name: 'Metadata supplied by another relay',
    );
    final bulletin = SignedBulletin.create(
      senders.first,
      runId: 'pending-concurrency',
      text: 'No metadata retransmission should be necessary',
      sequence: 1,
      channelId: channel.id,
    );
    sampleGate = Completer<void>();
    sockets.first.write(
      '${jsonEncode({'type': 'bulletin', 'value': bulletin.toJson()})}\n',
    );
    await sockets.first.flush();
    await until(() async => blockedSamples == 1);
    // The second real TLS link admits metadata while news on the first link
    // is suspended. Metadata itself never requests device-state sampling.
    sockets.last.write(
      '${jsonEncode({'type': 'channel', 'value': channel.toJson()})}\n',
    );
    await sockets.last.flush();
    await until(
      () async => ((await engine.snapshot())['channels'] as List).length == 1,
    );
    expect((await engine.snapshot())['pendingBulletinCount'], 0);
    sampleGate!.complete();
    // Neither fake client answers metadata requests. Success must follow the
    // recheck of already admitted metadata, rather than a lucky retransmission.
    await until(() async => (await engine.snapshot())['bulletinCount'] == 1);
    expect((await engine.snapshot())['pendingBulletinCount'], 0);
    expect((await engine.snapshot())['bulletins'].single['id'], bulletin.id);
  });
}

Future<void> until(Future<bool> Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!await predicate()) {
    if (clock.elapsed > const Duration(seconds: 12)) {
      fail('Pending bulletin concurrency condition timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
