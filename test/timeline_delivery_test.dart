import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_control.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/news_timeline.dart';
import 'package:farvahar_trends/core/peer_engine.dart';
import 'package:farvahar_trends/core/reader_state.dart';

void main() {
  test('TLS multi-writer catch-up, duplicate, restart and signed removal', () async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    final scratch = await parent.createTemp('timeline-e2e-');
    final writer = Identity.generate(),
        editor = Identity.generate(),
        reader = Identity.generate();
    final channel = SignedChannel.create(writer, name: 'Timeline');
    final grant = ChannelControl.create(
      writer,
      channel,
      kind: 'editor',
      data: {
        'editorCertificatePem': editor.certPem,
        'label': 'Second writer',
        'revision': 1,
        'nonce': ChannelControl.randomNonce(),
      },
    );
    ChannelControl policy(int revision, List<Map<String, dynamic>> removed) =>
        ChannelControl.create(
          writer,
          channel,
          kind: 'policy',
          data: {
            'revision': revision,
            'activeGrants': [grant.id],
            'removed': removed,
            'floors': <String, int>{},
          },
        );
    // Re-sign deliberately skewed clocks. These are valid hostile/old-clock
    // publisher inputs, not modifications that bypass signature admission.
    SignedBulletin signed(Identity who, int seq, int time) {
      final initial = SignedBulletin.create(
        who,
        runId: 'news',
        text: '${who.id.substring(0, 5)}-$seq',
        sequence: seq,
        channelId: channel.id,
        authorization: who == editor ? grant : null,
      );
      final body =
          jsonDecode(utf8.decode(base64Decode(initial.payloadBase64))) as Map;
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({...body, 'createdAtMs': time})),
      );
      return SignedBulletin.fromJson({
        ...initial.toJson(),
        'id': sha256.convert(bytes).toString(),
        'payloadBase64': base64Encode(bytes),
        'signature': who.sign(bytes),
      });
    }

    final old = signed(writer, 1, 1770000003000);
    final rollback = signed(writer, 2, 1770000001000);
    final middle = signed(editor, 1, 1770000002000);
    final newest = signed(editor, 2, 1770000004000);
    final engines = <PeerEngine>[];
    final sockets = <SecureSocket>[];
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      for (final engine in engines) {
        await engine.stop();
      }
      await scratch.delete(recursive: true);
    });
    PeerEngine engine() {
      final value = PeerEngine(
        directory: scratch,
        identity: reader,
        listenPort: 0,
        enableLanDiscovery: false,
        deviceState: () async => {'network': 'wifi'},
        onStatus: (_) {},
      );
      engines.add(value);
      return value;
    }

    Future<SecureSocket> connect(PeerEngine receiver) async {
      await receiver.addPeer(
        PeerCard(name: 'sender', certificatePem: writer.certPem),
      );
      await receiver.start(activeMode: false);
      final socket = await SecureSocket.connect(
        InternetAddress.loopbackIPv4,
        receiver.boundPort,
        context: SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(writer.certPem))
          ..usePrivateKeyBytes(utf8.encode(writer.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(reader.certPem)),
        onBadCertificate: (cert) =>
            Identity.certificateId(cert.pem) == reader.id,
      );
      socket.listen((_) {}, onError: (Object _) {});
      sockets.add(socket);
      socket.write(
        '${jsonEncode({
          'type': 'inventory',
          'features': ['channel-v2'],
          'channels': [],
          'bulletins': [],
          'receipts': [],
        })}\n',
      );
      await socket.flush();
      return socket;
    }

    Future<void> send(
      SecureSocket socket,
      String type,
      Map<String, dynamic> value,
    ) async {
      socket.write('${jsonEncode({'type': type, 'value': value})}\n');
      await socket.flush();
    }

    Future<List<Map<String, dynamic>>> waitNews(
      PeerEngine receiver,
      int count,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 12));
      while (true) {
        final news = ((await receiver.snapshot())['bulletins'] as List)
            .cast<Map<String, dynamic>>();
        if (news.length == count) return news;
        if (DateTime.now().isAfter(deadline)) {
          fail('TLS timeline expected $count, got ${news.length}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    final first = engine(), socket = await connect(first);
    await send(socket, 'channel', channel.toJson());
    await send(socket, 'channelPolicy', policy(1, []).toJson());
    // Opposite delivery order, including writer clock rollback.
    for (final post in [rollback, newest, middle, old]) {
      await send(socket, 'bulletin', post.toJson());
    }
    final received = await waitNews(first, 4);
    expect(orderNews(received).map((n) => n['id']), [
      newest.id,
      rollback.id,
      old.id,
      middle.id,
    ]);
    final observation = received.singleWhere(
      (n) => n['id'] == old.id,
    )['receivedAtWallMs'];
    expect(observation, isA<int>());
    // Repeated content and a forged duplicate envelope cannot replace verified
    // content or its first receive timestamp; neither tears down the TLS peer.
    for (var i = 0; i < 20; i++) {
      await send(socket, 'bulletin', old.toJson());
    }
    await send(socket, 'bulletin', {...old.toJson(), 'signature': 'forged'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(((await first.snapshot())['bulletins'] as List).length, 4);
    expect((await first.snapshot())['connectedCount'], 1);
    socket.destroy();
    await first.stop();
    final second = engine(), resumed = await connect(second);
    final restored = await waitNews(second, 4);
    expect(
      orderNews(restored).map((n) => n['id']),
      orderNews(received).map((n) => n['id']),
    );
    expect(
      restored.singleWhere((n) => n['id'] == old.id)['receivedAtWallMs'],
      observation,
    );
    await send(
      resumed,
      'channelPolicy',
      policy(2, [
        {
          'id': rollback.id,
          'authorId': writer.id,
          'sequence': rollback.sequence,
        },
      ]).toJson(),
    );
    final kept = await waitNews(second, 3);
    expect(kept.map((n) => n['id']), isNot(contains(rollback.id)));
    await send(resumed, 'bulletin', rollback.toJson());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(((await second.snapshot())['bulletins'] as List).length, 3);
  });

  test(
    'retained unread/read state survives 3000 other arrivals and restart',
    () async {
      final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
      await parent.create(recursive: true);
      final scratch = await parent.createTemp('reader-churn-');
      addTearDown(() => scratch.delete(recursive: true));
      final state = ReaderState(scratch), channel = 'c' * 64;
      Map<String, dynamic> item(int n, {bool local = false}) => {
        'id': n.toRadixString(16).padLeft(64, '0'),
        'channelId': channel,
        'receivedVia': local ? 'local' : 'overlay',
      };
      final read = item(1), unread = item(2);
      await state.observe([read], {channel}, {});
      expect(await state.observe([read, unread], {channel}, {}), [unread]);
      for (var batch = 0; batch < 15; batch++) {
        await state.observe(
          [
            read,
            unread,
            for (var n = 0; n < 200; n++)
              item(3 + batch * 200 + n, local: true),
          ],
          {channel},
          {},
        );
      }
      expect(state.readIds, contains(read['id']));
      expect(state.readIds, isNot(contains(unread['id'])));
      expect(state.seenIds, containsAll([read['id'], unread['id']]));
      expect(state.readIds.length, lessThanOrEqualTo(2048));
      expect(state.seenIds.length, lessThanOrEqualTo(2048));
      final restarted = ReaderState(scratch);
      expect(await restarted.observe([read, unread], {channel}, {}), isEmpty);
      expect(restarted.readIds, contains(read['id']));
      expect(restarted.readIds, isNot(contains(unread['id'])));
    },
  );
}
