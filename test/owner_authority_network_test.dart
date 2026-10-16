import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_control.dart';
import 'package:farvahar_trends/core/channel_key_store.dart';
import 'package:farvahar_trends/core/channel_recovery.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  late Identity root, owner, replacement, reader;
  late SignedChannel channel;
  late Directory scratch;
  final engines = <PeerEngine>[];
  final sockets = <Socket>[];
  const password = 'violet canoe orbit pepper 5728';
  setUpAll(() {
    root = Identity.generate();
    owner = Identity.generate();
    replacement = Identity.generate();
    reader = Identity.generate();
    channel = SignedChannel.create(
      owner,
      name: 'خبرهای بازیابی',
      recoveryCertificatePem: root.certPem,
    );
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('owner-network-');
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
    final expected = Directory('${Directory.current.path}/.tooling/test-tmp')
        .absolute
        .path;
    if (!scratch.absolute.path.startsWith(
      '$expected${Platform.pathSeparator}',
    )) {
      throw StateError('Invalid test cleanup path.');
    }
    await scratch.delete(recursive: true);
  });
  ChannelKeyStore vault() {
    String? text;
    return ChannelKeyStore(
      read: () async => text,
      write: (value) async {
        text = value;
      },
    );
  }

  PeerEngine engine(String name, Identity connection) {
    final value = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: connection,
      channelKeys: vault(),
      listenPort: 0,
      enableLanDiscovery: false,
      deviceState: () async => {'network': 'wifi'},
      onStatus: (_) {},
    );
    engines.add(value);
    return value;
  }

  ChannelControl grant(Identity writer, int generation) =>
      ChannelControl.create(
        root,
        channel,
        kind: 'owner',
        data: {
          'ownerCertificatePem': writer.certPem,
          'generation': generation,
          'nonce': ChannelControl.randomNonce(),
        },
      );
  ChannelControl policy(Identity writer, ChannelControl authority) =>
      ChannelControl.create(
        writer,
        channel,
        kind: 'policy',
        authority: authority,
        data: {'revision': 1, 'activeGrants': [], 'removed': [], 'floors': {}},
      );
  Future<String> backup(Identity writer, ChannelControl authority) =>
      ChannelRecovery.encryptAsync({
        'entry': {
          'role': 'owner',
          'channel': channel.toJson(),
          'identity': writer.toJson(),
          'authorization': authority.toJson(),
        },
        'sequence': 0,
        'policy': policy(writer, authority).toJson(),
      }, password);
  Future<void> until(FutureOr<bool> Function() predicate) async {
    final clock = Stopwatch()..start();
    while (!await predicate()) {
      if (clock.elapsed > const Duration(seconds: 20)) {
        fail('Owner authority did not converge.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> pair(PeerEngine a, PeerEngine b) async {
    await a.start(activeMode: false);
    await b.start(activeMode: false);
    final cardA = PeerCard(
      name: 'A',
      host: '127.0.0.1',
      port: a.boundPort,
      certificatePem: a.identity.certPem,
    );
    final cardB = PeerCard(
      name: 'B',
      host: '127.0.0.1',
      port: b.boundPort,
      certificatePem: b.identity.certPem,
    );
    await a.addPeer(cardB);
    await b.addPeer(cardA);
    await a.addPeer(cardB);
    await until(() async => (await a.snapshot())['connectedCount'] as int > 0);
  }

  Future<List<String>> texts(PeerEngine value) async =>
      ((await value.snapshot())['bulletins'] as List)
          .map((v) => v['text'] as String)
          .toList();

  test('replacement authority reaches a fresh reader through a relay and revokes old publisher', () async {
    final a = engine('old', owner),
        b = engine('replacement', replacement),
        c = engine('reader', reader);
    final first = grant(owner, 1);
    final original = await backup(owner, first);
    await a.restoreChannelRecovery(original, password);
    final beforeRecovery = ((await a.snapshot())['channels'] as List).single;
    expect(beforeRecovery['owned'], true);
    expect(beforeRecovery['canPublish'], true);
    await pair(a, b);
    await a.publishToChannel(channelId: channel.id, text: 'خبر قدیمی');
    await until(() async => (await texts(b)).contains('خبر قدیمی'));
    final second = grant(replacement, 2);
    await b.restoreChannelRecovery(await backup(replacement, second), password);
    await b.publishToChannel(channelId: channel.id, text: 'خبر با مالک تازه');
    await until(() async => (await texts(a)).contains('خبر با مالک تازه'));
    expect(await texts(a), isNot(contains('خبر قدیمی')));
    final afterRecovery = ((await a.snapshot())['channels'] as List).single;
    expect(afterRecovery['owned'], false);
    expect(afterRecovery['canPublish'], false);
    expect(afterRecovery['ownerGeneration'], 2);
    await expectLater(
      a.publishToChannel(channelId: channel.id, text: 'stolen-key post'),
      throwsStateError,
    );
    await expectLater(
      b.restoreChannelRecovery(original, password),
      throwsStateError,
    );
    await a.stop();
    await pair(b, c);
    await until(() async => (await texts(c)).contains('خبر با مالک تازه'));
    expect(await texts(c), isNot(contains('خبر قدیمی')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a pre-recovery peer receives legacy news but no v2 objects or inventory IDs', () async {
    final target = engine('publisher', owner);
    await target.restoreChannelRecovery(
      await backup(owner, grant(owner, 1)),
      password,
    );
    final legacy = await target.createChannel(name: 'Legacy still supported');
    await target.publishToChannel(channelId: channel.id, text: 'Protected');
    await target.publishToChannel(channelId: legacy.id, text: 'Legacy');
    await target.addPeer(
      PeerCard(
        name: 'old peer',
        host: '',
        port: 45871,
        certificatePem: reader.certPem,
      ),
    );
    await target.start(activeMode: false);
    final frames = <Map<String, dynamic>>[];
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      target.boundPort,
      context: SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(reader.certPem))
        ..usePrivateKeyBytes(utf8.encode(reader.keyPem))
        ..setTrustedCertificatesBytes(utf8.encode(owner.certPem)),
      onBadCertificate: (cert) => Identity.certificateId(cert.pem) == owner.id,
    );
    sockets.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => frames.add(jsonDecode(line) as Map<String, dynamic>));
    socket.write(
      '${jsonEncode({
        'type': 'inventory',
        'features': ['channel-v2', 'discovery-v1'],
        'channels': [],
        'bulletins': [],
        'receipts': [],
      })}\n',
    );
    await socket.flush();
    await until(
      () => frames.any(
        (f) =>
            f['type'] == 'inventory' &&
            (f['channels'] as List).contains(legacy.id),
      ),
    );
    socket.write(
      '${jsonEncode({
        'type': 'want',
        'channels': [legacy.id, channel.id],
        'bulletins': [],
        'receipts': [],
      })}\n',
    );
    await socket.flush();
    await until(
      () => frames.any(
        (f) => f['type'] == 'channel' && (f['value'] as Map)['id'] == legacy.id,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(frames.any((f) => f['type'] == 'ownerAuthority'), isFalse);
    expect(
      frames
          .where((f) => f['type'] == 'inventory')
          .any((f) => (f['channels'] as List).contains(channel.id)),
      isFalse,
    );
    expect(
      frames
          .where((f) => f['type'] == 'channel')
          .any((f) => (f['value'] as Map)['id'] == channel.id),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
