import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channel_control.dart';
import 'package:persian_trend/core/channel_key_store.dart';
import 'package:persian_trend/core/channel_recovery.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/media_store.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/peer_engine.dart';
import 'package:persian_trend/core/pilot_store.dart';
import 'package:persian_trend/core/reader_state.dart';

void main() {
  late Identity owner, editor, other;
  late SignedChannel channel;
  late Directory scratch;
  final engines = <PeerEngine>[];
  setUpAll(() {
    owner = Identity.generate();
    editor = Identity.generate();
    other = Identity.generate();
    channel = SignedChannel.create(owner, name: 'Security fixture');
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('channel-updates-');
  });
  tearDown(() async {
    for (final engine in engines.reversed) {
      await engine.stop();
    }
    engines.clear();
    await scratch.delete(recursive: true);
  });
  ChannelControl grant({String? nonce}) => ChannelControl.create(
    owner,
    channel,
    kind: 'editor',
    data: {
      'editorCertificatePem': editor.certPem,
      'label': 'Editor',
      'revision': 1,
      'nonce': nonce ?? ChannelControl.randomNonce(),
    },
  );
  ChannelControl policy(
    int revision, {
    List<String> active = const [],
    List<Map<String, dynamic>> removed = const [],
    Map<String, int> floors = const {},
  }) => ChannelControl.create(
    owner,
    channel,
    kind: 'policy',
    data: {
      'revision': revision,
      'activeGrants': active,
      'removed': removed,
      'floors': floors,
    },
  );
  ChannelKeyStore vault() {
    String? contents;
    return ChannelKeyStore(
      read: () async => contents,
      write: (value) async {
        contents = value;
      },
    );
  }

  PeerEngine engine(
    String label,
    Identity identity, {
    ChannelKeyStore? keys,
    String images = 'any',
    String network = 'wifi',
  }) {
    final value = PeerEngine(
      directory: Directory('${scratch.path}/$label'),
      identity: identity,
      channelKeys: keys,
      listenPort: 0,
      enableLanDiscovery: false,
      imageMode: images,
      deviceState: () async => {'network': network, 'isLocked': true},
      onStatus: (_) {},
    );
    engines.add(value);
    return value;
  }

  Future<void> until(
    Future<bool> Function() condition, {
    int seconds = 45,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!await condition()) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for channel update');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> pair(PeerEngine a, PeerEngine b) async {
    await a.start(activeMode: false);
    await b.start(activeMode: false);
    await a.addPeer(
      PeerCard(
        name: 'b',
        host: '127.0.0.1',
        port: b.boundPort,
        certificatePem: b.identity.certPem,
      ),
    );
    await b.addPeer(
      PeerCard(
        name: 'a',
        host: '127.0.0.1',
        port: a.boundPort,
        certificatePem: a.identity.certPem,
      ),
    );
    await a.addPeer(
      PeerCard(
        name: 'b',
        host: '127.0.0.1',
        port: b.boundPort,
        certificatePem: b.identity.certPem,
      ),
    );
    await until(() async => (await a.snapshot())['connectedCount'] == 1);
  }

  test('editor grant is exact-channel, signer-bound and revocable', () {
    final permission = grant();
    final news = SignedBulletin.create(
      editor,
      runId: 'news',
      text: 'Public text',
      sequence: 1,
      channelId: channel.id,
      authorization: permission,
    );
    expect(
      news.verifyForChannel(
        channel,
        policy: policy(1, active: [permission.id]),
      ),
      isTrue,
    );
    expect(news.verifyForChannel(channel, policy: policy(2)), isFalse);
    expect(
      news.verifyForChannel(SignedChannel.create(owner, name: 'Other')),
      isFalse,
    );
    expect(
      SignedBulletin.create(
        other,
        runId: 'news',
        text: 'Impersonation',
        sequence: 1,
        channelId: channel.id,
        authorization: permission,
      ).verifyForChannel(channel),
      isFalse,
    );
    final replacement = grant();
    expect(
      () => SignedBulletin.fromJson({
        ...news.toJson(),
        'authorization': replacement.toJson(),
      }),
      throwsFormatException,
    );
    expect(
      () => ChannelControl.parse(
        permission.toJson(),
        SignedChannel.create(owner, name: 'Different'),
      ),
      throwsFormatException,
    );
    expect(
      () => SignedBulletin.fromJson({...news.toJson(), 'authorization': null}),
      throwsFormatException,
    );
  });
  test('control payload tampering and owner substitution fail', () {
    final signed = policy(1);
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({...signed.body, 'revision': 100})),
    );
    expect(
      () => ChannelControl.parse({
        ...signed.toJson(),
        'payloadBase64': base64Encode(bytes),
        'id': sha256.convert(bytes).toString(),
      }, channel),
      throwsFormatException,
    );
    expect(
      () => ChannelControl.parse({
        ...signed.toJson(),
        'signerCertificatePem': other.certPem,
      }, channel),
      throwsFormatException,
    );
    expect(
      () => policy(1, active: List.filled(9, 'a' * 64)),
      throwsFormatException,
    );
  });
  test(
    'signed removal wins over replay and survives journal compaction',
    () async {
      final store = PilotStore(scratch, localOwnerId: other.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final news = SignedBulletin.create(
        owner,
        runId: 'news',
        text: 'Remove me',
        sequence: 1,
        channelId: channel.id,
      );
      expect(await store.putBulletin(news.toJson()), isTrue);
      final removal = policy(
        2,
        removed: [
          {'id': news.id, 'authorId': owner.id, 'sequence': 1},
        ],
      );
      expect(await store.putChannelPolicy(removal), isTrue);
      expect(store.bulletins, isEmpty);
      expect(await store.putBulletin(news.toJson()), isFalse);
      expect(await store.putChannelPolicy(policy(1)), isFalse);
      final recovered = PilotStore(scratch, localOwnerId: other.id);
      await recovered.load();
      expect(recovered.policyFor(channel.id)!.id, removal.id);
      expect(await recovered.putBulletin(news.toJson()), isFalse);
      final future = SignedBulletin.create(
        owner,
        runId: 'news',
        text: 'New unaffected post',
        sequence: 2,
        channelId: channel.id,
      );
      expect(await recovered.putBulletin(future.toJson()), isTrue);
    },
  );
  test(
    'recovery is encrypted, authenticated, bounded and password independent',
    () {
      final entry = {
        'role': 'owner',
        'channel': channel.toJson(),
        'identity': owner.toJson(),
      };
      final material = {'entry': entry, 'sequence': 9, 'policy': null};
      const password = 'violet canoe orbit pepper 5728';
      final encrypted = ChannelRecovery.encrypt(material, password);
      expect(encrypted, isNot(contains(password)));
      expect(encrypted, isNot(contains('PRIVATE KEY')));
      expect(encrypted, isNot(contains(channel.id)));
      expect(ChannelRecovery.decrypt(encrypted, password)['sequence'], 9);
      expect(
        () => ChannelRecovery.decrypt(encrypted, 'wrong password long enough'),
        throwsFormatException,
      );
      final malformed = jsonDecode(encrypted) as Map<String, dynamic>;
      malformed['memoryKiB'] = 1 << 30;
      expect(
        () => ChannelRecovery.decrypt(jsonEncode(malformed), password),
        throwsFormatException,
      );
      final changed = jsonDecode(encrypted) as Map<String, dynamic>;
      final bytes = base64Decode(changed['ciphertext']);
      bytes[0] ^= 1;
      changed['ciphertext'] = base64Encode(bytes);
      expect(
        () => ChannelRecovery.decrypt(jsonEncode(changed), password),
        throwsFormatException,
      );
      expect(
        () => ChannelRecovery.encrypt(material, 'short'),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test('legacy recovery exports only a per-channel manager key', () async {
    final keys = vault();
    final source = engine('legacy', owner, keys: keys);
    // Simulate channels created by the previous release, which shared a key.
    final store = PilotStore(source.directory, localOwnerId: owner.id);
    await store.load();
    await store.putChannel(channel.toJson());
    final exported = await source.exportChannelRecovery(
      channel.id,
      'violet canoe orbit pepper 5728',
    );
    final material = ChannelRecovery.decrypt(
      exported,
      'violet canoe orbit pepper 5728',
    );
    final entry = material['entry'] as Map;
    expect((entry['identity'] as Map)['id'], isNot(owner.id));
    expect(jsonEncode(entry), isNot(contains(owner.keyPem)));
    final restored = engine('restored', other, keys: vault());
    expect(
      await restored.restoreChannelRecovery(
        exported,
        'violet canoe orbit pepper 5728',
      ),
      channel.id,
    );
    await restored.publishToChannel(
      channelId: channel.id,
      text: 'Recovered owner',
    );
    final public = await restored.snapshot();
    expect((public['channels'] as List).single['owned'], isTrue);
    expect(jsonEncode(public), isNot(contains('PRIVATE KEY')));
    final journal = await File('${restored.directory.path}/pilot.jsonl')
        .readAsString();
    expect(journal, isNot(contains('PRIVATE KEY')));
  }, timeout: const Timeout(Duration(minutes: 4)));
  test(
    'one app grants an editor, receives posts and revokes across TLS',
    () async {
      final a = engine('a', owner, keys: vault());
      final b = engine('b', editor, keys: vault());
      await pair(a, b);
      final created = await a.createChannel(name: 'Independent channel');
      expect(created.ownerId, isNot(owner.id));
      final request = await b.createEditorRequest('Helper');
      final invite = await a.approveEditor(created.id, request);
      await b.acceptEditorInvitation(invite);
      await b.publishToChannel(channelId: created.id, text: 'Editor news');
      await until(
        () async => ((await a.snapshot())['bulletins'] as List).any(
          (v) => v['text'] == 'Editor news',
        ),
      );
      final id = ((jsonDecode(invite) as Map)['grant'] as Map)['id'] as String;
      await a.revokeEditor(created.id, id);
      await until(
        () async =>
            ((await b.snapshot())['channels'] as List)
                .where((v) => v['id'] == created.id)
                .single['canPublish'] ==
            false,
      );
      await expectLater(
        b.publishToChannel(channelId: created.id, text: 'Revoked'),
        throwsStateError,
      );
      expect((await b.snapshot())['bulletins'], isEmpty);
      final outsider = engine('outsider', other, keys: vault());
      await expectLater(
        outsider.acceptEditorInvitation(invite),
        throwsStateError,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'text and hash-checked image sync, removal hides both, text-only persists',
    () async {
      final a = engine('image-a', owner, keys: vault());
      final b = engine('image-b', other, images: 'never');
      await pair(a, b);
      final created = await a.createChannel(name: 'Image channel');
      final photo = await File('assets/brand/logo.jpg').readAsBytes();
      // Fixture is compressed with native/photo test tooling before use below.
      final fixture = File('test/fixtures/news-small.jpg');
      expect(photo, isNotEmpty);
      final bytes = await fixture.readAsBytes();
      await a.publishToChannel(
        channelId: created.id,
        text: 'Text comes first',
        imageBytes: bytes,
      );
      await until(() async => (await b.snapshot())['bulletinCount'] == 1);
      var received = ((await b.snapshot())['bulletins'] as List).single as Map;
      expect((received['image'] as Map)['path'], isNull);
      b.imageMode = 'any';
      await until(
        () async =>
            ((((await b.snapshot())['bulletins'] as List).single
                    as Map)['image']
                as Map)['path'] !=
            null,
        seconds: 65,
      );
      received = ((await b.snapshot())['bulletins'] as List).single as Map;
      expect(
        await File((received['image'] as Map)['path'] as String).readAsBytes(),
        bytes,
      );
      await a.removePublishedNews(created.id, received['id'] as String);
      await until(() async => (await b.snapshot())['bulletinCount'] == 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  for (final preference in ['wifiOnly', 'never']) {
    test(
      'mobile publisher sends an attached image with $preference downloads',
      () async {
        final a = engine(
          'mobile-image-source',
          owner,
          keys: vault(),
          images: preference,
          network: 'cellular',
        );
        final b = engine('wifi-image-reader', other, images: 'wifiOnly');
        final created = await a.createChannel(name: 'Mobile image publisher');
        final bytes = await File('test/fixtures/news-small.jpg').readAsBytes();
        // Publishing before pairing exercises inventory arriving before news.
        await a.publishToChannel(
          channelId: created.id,
          text: 'An attached image',
          imageBytes: bytes,
        );
        await pair(a, b);
        await until(
          () async => (await b.snapshot())['bulletinCount'] == 1,
          seconds: 5,
        );
        await until(
          () async =>
              ((((await b.snapshot())['bulletins'] as List).single
                      as Map)['image']
                  as Map)['path'] !=
              null,
          seconds: 5,
        );
        final news = ((await b.snapshot())['bulletins'] as List).single as Map;
        expect(
          await File((news['image'] as Map)['path'] as String).readAsBytes(),
          bytes,
        );
        expect(a.imageMode, preference);
        expect(b.imageMode, 'wifiOnly');
      },
    );
  }

  test(
    'an image attached after connection is announced without a periodic wait',
    () async {
      final a = engine(
        'live-mobile-publisher',
        owner,
        keys: vault(),
        images: 'wifiOnly',
        network: 'cellular',
      );
      final b = engine('live-wifi-reader', other, images: 'wifiOnly');
      await pair(a, b);
      final created = await a.createChannel(name: 'Live photo');
      final bytes = await File('test/fixtures/news-small.jpg').readAsBytes();
      await a.publishToChannel(
        channelId: created.id,
        text: 'A fresh photo',
        imageBytes: bytes,
      );
      await until(
        () async => (await b.snapshot())['bulletinCount'] == 1,
        seconds: 5,
      );
      await until(
        () async =>
            ((((await b.snapshot())['bulletins'] as List).single
                    as Map)['image']
                as Map)['path'] !=
            null,
        seconds: 5,
      );
    },
  );

  test(
    'a cellular reader keeps Wi-Fi-only downloads until explicitly enabled',
    () async {
      final a = engine('policy-publisher', owner, keys: vault());
      final b = engine(
        'cellular-reader',
        other,
        images: 'wifiOnly',
        network: 'cellular',
      );
      await pair(a, b);
      final created = await a.createChannel(name: 'Reader policy');
      final bytes = await File('test/fixtures/news-small.jpg').readAsBytes();
      await a.publishToChannel(
        channelId: created.id,
        text: 'Text with optional photo',
        imageBytes: bytes,
      );
      await until(
        () async => (await b.snapshot())['bulletinCount'] == 1,
        seconds: 5,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        ((((await b.snapshot())['bulletins'] as List).single as Map)['image']
            as Map)['path'],
        isNull,
      );
      b.imageMode = 'any';
      await b.refreshImageTransfers();
      await until(
        () async =>
            ((((await b.snapshot())['bulletins'] as List).single
                    as Map)['image']
                as Map)['path'] !=
            null,
        seconds: 5,
      );
    },
  );

  test(
    'received images do not gain the publisher mobile-upload exception',
    () async {
      final a = engine('relay-source', owner, keys: vault());
      final b = engine(
        'cellular-relay',
        other,
        images: 'any',
        network: 'cellular',
      );
      await pair(a, b);
      final created = await a.createChannel(name: 'Relay photo');
      final bytes = await File('test/fixtures/news-small.jpg').readAsBytes();
      await a.publishToChannel(
        channelId: created.id,
        text: 'A relayed photo',
        imageBytes: bytes,
      );
      await until(
        () async => (await b.snapshot())['bulletinCount'] == 1,
        seconds: 5,
      );
      await until(
        () async =>
            ((((await b.snapshot())['bulletins'] as List).single
                    as Map)['image']
                as Map)['path'] !=
            null,
        seconds: 5,
      );
      await a.stop();
      b.imageMode = 'wifiOnly';
      final c = engine('relay-reader', editor, images: 'wifiOnly');
      await pair(b, c);
      await until(
        () async => (await c.snapshot())['bulletinCount'] == 1,
        seconds: 5,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        ((((await c.snapshot())['bulletins'] as List).single as Map)['image']
            as Map)['path'],
        isNull,
      );
      b.imageMode = 'any';
      await b.refreshImageTransfers();
      await until(
        () async =>
            ((((await c.snapshot())['bulletins'] as List).single
                    as Map)['image']
                as Map)['path'] !=
            null,
        seconds: 5,
      );
    },
  );

  test(
    'image cache rejects altered bytes, bombs and descriptor substitution',
    () async {
      final bytes = await File('test/fixtures/news-small.jpg').readAsBytes();
      final image = NewsImage.inspect(bytes);
      final store = MediaStore(scratch);
      await store.load();
      await store.put(image, bytes);
      expect(store.has(image.hash), isTrue);
      final bad = Uint8List.fromList(bytes)..[30] ^= 1;
      await expectLater(store.put(image, bad), throwsFormatException);
      expect(
        () => NewsImage.fromJson({...image.toJson(), 'width': 100000}),
        throwsFormatException,
      );
      expect(
        () => NewsImage.inspect(Uint8List(NewsImage.maxBytes + 1)),
        throwsFormatException,
      );
      final restart = MediaStore(scratch);
      await restart.load();
      expect(restart.path(image.hash), isNotNull);
    },
  );
  test(
    'unread, dedup, mute and notification switches remain entirely local',
    () async {
      final state = ReaderState(scratch);
      final id1 = '1' * 64, id2 = '2' * 64, id3 = '3' * 64;
      Map<String, dynamic> news(String id, {String via = 'lan'}) => {
        'id': id,
        'channelId': channel.id,
        'receivedVia': via,
      };
      expect(await state.observe([news(id1)], {channel.id}, {}), isEmpty);
      expect(state.readIds, contains(id1));
      expect(
        await state.observe([news(id1), news(id2)], {channel.id}, {}),
        hasLength(1),
      );
      expect(state.readIds, isNot(contains(id2)));
      expect(await state.observe([news(id2)], {channel.id}, {}), isEmpty);
      await state.setMuted(channel.id, true);
      expect(await state.observe([news(id3)], {channel.id}, {}), isEmpty);
      await state.markRead([id2]);
      await state.setNotifications(false);
      await state.setImages('never');
      final restarted = ReaderState(scratch);
      await restarted.load();
      expect(restarted.readIds, contains(id2));
      expect(restarted.notifications, isFalse);
      expect(restarted.images, 'never');
      expect(restarted.muted, contains(channel.id));
      await File('${scratch.path}/reader-state.json').writeAsString('{broken');
      await restarted.load();
      expect(restarted.notifications, isFalse);
      expect(restarted.images, 'never');
      expect(restarted.recoveryWarning, isNotNull);
    },
  );
  test('signed nicknames survive delivery and cannot be rewritten', () {
    final news = SignedBulletin.create(
      owner,
      runId: 'news',
      text: 'Signed author',
      sequence: 1,
      channelId: channel.id,
      byline: 'روزنه',
    );
    expect(SignedBulletin.fromJson(news.toJson()).byline, 'روزنه');
    expect(news.verifyForChannel(channel), isTrue);
    final body =
        jsonDecode(utf8.decode(base64Decode(news.payloadBase64))) as Map;
    body['byline'] = 'Impersonator';
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final altered = SignedBulletin.fromJson({
      ...news.toJson(),
      'payloadBase64': base64Encode(bytes),
      'id': sha256.convert(bytes).toString(),
    });
    expect(altered.verifyForChannel(channel), isFalse);
    expect(
      () => SignedBulletin.create(
        owner,
        runId: 'news',
        text: 'Bad name',
        sequence: 1,
        channelId: channel.id,
        byline: 'a' * 61,
      ),
      throwsFormatException,
    );
    expect(() => validateNewsByline('hidden\u202ename'), throwsFormatException);
  });
  test('owner can retire a channel across TLS; editors and replay cannot restore it', () async {
    final a = engine('delete-a', owner, keys: vault());
    final b = engine('delete-b', editor, keys: vault());
    await pair(a, b);
    final created = await a.createChannel(name: 'Retire this channel');
    await a.setWriterNickname(created.id, 'Amin');
    await a.publishToChannel(channelId: created.id, text: 'Author footer');
    await until(() async => (await b.snapshot())['bulletinCount'] == 1);
    expect(
      ((await b.snapshot())['bulletins'] as List).single['byline'],
      'Amin',
    );
    await expectLater(b.removeChannel(created.id), throwsStateError);
    await a.removeChannel(created.id);
    await until(
      () async =>
          (await b.snapshot())['bulletinCount'] == 0 &&
          ((await b.snapshot())['channels'] as List).isEmpty,
    );
    expect((await a.snapshot())['channels'], isEmpty);
    await expectLater(
      a.publishToChannel(channelId: created.id, text: 'Deleted channel'),
      throwsStateError,
    );
    final reloaded = PilotStore(b.directory, localOwnerId: editor.id);
    await reloaded.load();
    expect(reloaded.policyFor(created.id)!.deleted, isTrue);
    final entry = a.channelKeys!.entries[created.id]!;
    final signer = Identity.fromJson(
      Map<String, dynamic>.from(entry['identity'] as Map),
    );
    final attempt = ChannelControl.create(
      signer,
      created,
      kind: 'policy',
      data: {'revision': 999, 'activeGrants': [], 'removed': [], 'floors': {}},
    );
    expect(await reloaded.putChannelPolicy(attempt), isFalse);
    expect(reloaded.policyFor(created.id)!.deleted, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
  test(
    'many removals preserve older cached news that the owner did not remove',
    () async {
      final source = engine('many-removals', owner, keys: vault());
      final created = await source.createChannel(name: 'Bounded removals');
      for (var i = 0; i < 32; i++) {
        await source.publishToChannel(channelId: created.id, text: 'item-$i');
      }
      final news = (await source.snapshot())['bulletins'] as List;
      // Remove newest first, crossing the individual-tombstone bound.
      for (final item in news.take(ChannelControl.maxRemovals + 1)) {
        await source.removePublishedNews(created.id, item['id'] as String);
      }
      final remaining = (await source.snapshot())['bulletins'] as List;
      expect(remaining, hasLength(7));
      expect(remaining.map((v) => v['text']), contains('item-0'));
      final reopened = PilotStore(source.directory, localOwnerId: owner.id);
      reopened.managedChannelIds.add(created.id);
      await reopened.load();
      expect(reopened.bulletins, hasLength(7));
      final policy = reopened.policyFor(created.id)!;
      expect(policy.retained, hasLength(7));
      expect(policy.removed, hasLength(ChannelControl.maxRemovals));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'legacy owner recovery remains portable at the eight-editor limit',
    () async {
      final source = engine('legacy-eight', owner, keys: vault());
      final store = PilotStore(source.directory, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final helper = engine('editor-request', editor, keys: vault());
      final request = await helper.createEditorRequest('Helper');
      for (var i = 0; i < ChannelControl.maxEditors; i++) {
        await source.approveEditor(channel.id, request);
      }
      final encrypted = await source.exportChannelRecovery(
        channel.id,
        'violet canoe orbit pepper 5728',
      );
      final recovered = ChannelRecovery.decrypt(
        encrypted,
        'violet canoe orbit pepper 5728',
      );
      expect(((recovered['entry'] as Map)['grants'] as List), hasLength(8));
      expect(
        utf8.encode(encrypted).length,
        lessThan(ChannelRecovery.maxFileBytes),
      );
      final restored = engine('eight-restored', other, keys: vault());
      await restored.restoreChannelRecovery(
        encrypted,
        'violet canoe orbit pepper 5728',
      );
      expect(
        ((await restored.snapshot())['channels'] as List).single['editors'],
        hasLength(8),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
