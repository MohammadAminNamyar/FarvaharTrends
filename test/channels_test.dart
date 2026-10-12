import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/pilot_store.dart';

void main() {
  late Identity owner;
  late Identity other;
  late SignedChannel channel;

  setUpAll(() {
    owner = Identity.generate();
    other = Identity.generate();
    channel = SignedChannel.create(
      owner,
      name: 'خبرهای آزمایشی',
      description: 'Only benign invented news.',
    );
  });

  group('channel ownership and signature', () {
    test('self-contained metadata authenticates a key without peer trust', () {
      final received = SignedChannel.fromJson(channel.toJson());
      expect(received.id, channel.id);
      expect(received.name, 'خبرهای آزمایشی');
      expect(received.ownerId, owner.id);
      expect(received.ownedBy(owner), isTrue);
      expect(received.ownedBy(other), isFalse);
      expect(received.toJson().containsKey('keyPem'), isFalse);
      expect(received.toJson().containsKey('trusted'), isFalse);
      // No paired peer or claim of a real-world source is needed to verify a key.
      expect(received.ownerCertificatePem, owner.certPem);
    });

    test('same display name never transfers another channel identity', () {
      final imitation = SignedChannel.create(other, name: channel.name);
      expect(imitation.name, channel.name);
      expect(imitation.id, isNot(channel.id));
      expect(imitation.ownerId, isNot(channel.ownerId));
      expect(imitation.ownedBy(owner), isFalse);
      final second = SignedChannel.create(owner, name: channel.name);
      expect(second.id, isNot(channel.id));
    });

    test('tampering, signer substitution and fabricated ownership fail', () {
      expect(
        () => SignedChannel.fromJson({
          ...channel.toJson(),
          'ownerCertificatePem': other.certPem,
        }),
        throwsFormatException,
      );
      final changed = {..._body(channel.toJson()), 'name': 'Rewritten name'};
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(changed)));
      expect(
        () => SignedChannel.fromJson({
          ...channel.toJson(),
          'payloadBase64': base64Encode(bytes),
          'id': sha256.convert(bytes).toString(),
        }),
        throwsFormatException,
      );
      expect(
        () => SignedChannel.fromJson(
          _signedChannel(other, _body(channel.toJson())),
        ),
        throwsFormatException,
      );
      expect(
        () => SignedChannel.fromJson({...channel.toJson(), 'owned': true}),
        throwsFormatException,
      );
    });

    test('a generic signature cannot be replayed as a channel signature', () {
      final bytes = base64Decode(channel.payloadBase64);
      expect(
        () => SignedChannel.fromJson({
          ...channel.toJson(),
          'signature': owner.sign(bytes),
        }),
        throwsFormatException,
      );
      expect(
        () => SignedChannel.fromJson(
          _signedChannel(owner, {
            ..._body(channel.toJson()),
            'domain': 'receipt',
          }),
        ),
        throwsFormatException,
      );
    });

    test('names and descriptions are bounded before signing', () {
      final clean = SignedChannel.create(
        owner,
        name: '  کانال  ',
        description: '  line one\nline two  ',
      );
      expect(clean.name, 'کانال');
      expect(clean.description, 'line one\nline two');
      for (final name in ['', ' ', 'x' * 81, 'hidden\nname']) {
        expect(
          () => SignedChannel.create(owner, name: name),
          throwsFormatException,
        );
      }
      expect(
        () => SignedChannel.create(owner, name: 'News', description: 'x' * 501),
        throwsFormatException,
      );
      expect(
        () => SignedChannel.fromJson({
          ...channel.toJson(),
          'ownerCertificatePem': 'x' * 17000,
        }),
        throwsFormatException,
      );
    });
  });

  group('channel-linked news', () {
    SignedBulletin news(Identity publisher, String? channelId) =>
        SignedBulletin.create(
          publisher,
          runId: 'channel-test',
          text: 'خبر ساختگی برای آزمایش',
          sequence: 1,
          channelId: channelId,
        );

    test(
      'publisher certificate verifies relayed news for its exact channel',
      () {
        final received = SignedBulletin.fromJson(
          news(owner, channel.id).toJson(),
        );
        expect(received.channelId, channel.id);
        expect(received.verifyForChannel(channel), isTrue);
        // The publisher need not be the transport peer or in a local peer map.
        expect(received.verifyAgainst({}, other), isFalse);
      },
    );

    test('another key cannot publish into an existing channel', () {
      expect(news(other, channel.id).verifyForChannel(channel), isFalse);
      final otherChannel = SignedChannel.create(owner, name: 'Other channel');
      expect(news(owner, otherChannel.id).verifyForChannel(channel), isFalse);
      expect(news(owner, null).verifyForChannel(channel), isFalse);
    });

    test('rehashing altered news cannot preserve owner authorization', () {
      final original = news(owner, channel.id);
      final body = {
        ..._body(original.toJson()),
        'text': 'Altered after signing',
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      final changed = SignedBulletin.fromJson({
        ...original.toJson(),
        'payloadBase64': base64Encode(bytes),
        'id': sha256.convert(bytes).toString(),
      });
      expect(changed.verifyForChannel(channel), isFalse);
      expect(() => news(owner, 'not-a-channel-id'), throwsFormatException);
    });
  });

  group('durable channel metadata', () {
    late Directory scratch;

    setUp(() async {
      final parent = Directory(
        '${Directory.current.path}${Platform.pathSeparator}.tooling'
        '${Platform.pathSeparator}test-tmp',
      );
      await parent.create(recursive: true);
      scratch = await parent.createTemp('channels-');
    });

    tearDown(() async {
      // Only this freshly created directory inside the permitted project tree.
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });

    test('owned channel survives journal reopening and compaction', () async {
      final store = PilotStore(scratch);
      await store.load();
      expect(await store.putChannel(channel.toJson()), isTrue);
      expect(await store.putChannel(channel.toJson()), isFalse);
      final reopened = PilotStore(scratch);
      await reopened.load(); // Loading also compacts to a snapshot.
      final restored = SignedChannel.fromJson(reopened.channels[channel.id]!);
      expect(restored.ownedBy(owner), isTrue);
      expect(restored.name, channel.name);
      final compacted = PilotStore(scratch);
      await compacted.load();
      expect(compacted.channels.keys, [channel.id]);
    });

    test(
      'invalid metadata is neither persisted nor recovered as authority',
      () async {
        final store = PilotStore(scratch);
        await store.load();
        await store.putChannel(channel.toJson());
        final invalid = {
          ...channel.toJson(),
          'ownerCertificatePem': other.certPem,
        };
        await expectLater(store.putChannel(invalid), throwsFormatException);
        await File('${scratch.path}${Platform.pathSeparator}pilot.jsonl')
            .writeAsString(
              '${jsonEncode({'kind': 'channel', 'value': invalid})}\n',
              mode: FileMode.append,
              flush: true,
            );
        final reopened = PilotStore(scratch);
        await reopened.load();
        expect(reopened.channels.keys, [channel.id]);
        expect(
          SignedChannel.fromJson(reopened.channels[channel.id]!).ownerId,
          owner.id,
        );
      },
    );

    test('old pilot snapshots without channels remain readable', () async {
      await File(
        '${scratch.path}${Platform.pathSeparator}pilot.jsonl',
      ).writeAsString(
        '${jsonEncode({'kind': 'snapshot', 'peers': {}, 'bulletins': {}, 'receipts': {}, 'publications': {}, 'events': [], 'sequence': 7})}\n',
        flush: true,
      );
      final store = PilotStore(scratch);
      await store.load();
      expect(store.channels, isEmpty);
      expect(await store.nextSequence(), 8);
      expect(await store.putChannel(channel.toJson()), isTrue);
    });

    test(
      'channel publication counters are independent and survive restart',
      () async {
        final second = SignedChannel.create(owner, name: 'Second channel');
        final store = PilotStore(scratch);
        await store.load();
        await store.putChannel(channel.toJson());
        await store.putChannel(second.toJson());
        expect(await store.nextChannelSequence(channel.id), 1);
        expect(await store.nextChannelSequence(channel.id), 2);
        expect(await store.nextChannelSequence(second.id), 1);
        // A reserved number can survive without a bulletin after a crash.
        final reopened = PilotStore(scratch);
        await reopened.load();
        expect(await reopened.nextChannelSequence(channel.id), 3);
        expect(await reopened.nextChannelSequence(second.id), 2);
        expect(await reopened.nextSequence(), 1);
        final compacted = PilotStore(scratch);
        await compacted.load();
        expect(compacted.channelSequences[channel.id], 3);
        expect(compacted.channelSequences[second.id], 2);
      },
    );

    test(
      'unknown channels cannot allocate a persistent publication counter',
      () async {
        final store = PilotStore(scratch);
        await store.load();
        await expectLater(
          store.nextChannelSequence(channel.id),
          throwsStateError,
        );
        expect(store.channelSequences, isEmpty);
      },
    );

    test(
      'capacity rejects new channels without evicting known owners',
      () async {
        final store = PilotStore(scratch);
        await store.load();
        await store.putChannel(channel.toJson());
        final publishers = [
          owner,
          for (
            var i = 1;
            i < PilotStore.maxChannels ~/ PilotStore.maxChannelsPerPublisher;
            i++
          )
            Identity.generate(),
        ];
        for (var i = 1; i < PilotStore.maxChannels; i++) {
          await store.putChannel(
            SignedChannel.create(
              publishers[i ~/ PilotStore.maxChannelsPerPublisher],
              name: 'Channel $i',
            ).toJson(),
          );
        }
        final extra = SignedChannel.create(other, name: 'One too many');
        await expectLater(store.putChannel(extra.toJson()), throwsStateError);
        expect(store.channels.length, PilotStore.maxChannels);
        expect(store.channels.containsKey(channel.id), isTrue);
        expect(await store.putChannel(channel.toJson()), isFalse);
        final reopened = PilotStore(scratch);
        await reopened.load();
        expect(reopened.channels.length, PilotStore.maxChannels);
        expect(reopened.channels.containsKey(channel.id), isTrue);
      },
      // 128 RSA signatures, flushed journal writes and verified compaction can
      // exceed the default 30 seconds on a busy Windows development machine.
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

Map<String, dynamic> _body(Map<String, dynamic> envelope) =>
    jsonDecode(utf8.decode(base64Decode(envelope['payloadBase64'] as String)))
        as Map<String, dynamic>;

Map<String, dynamic> _signedChannel(
  Identity signer,
  Map<String, dynamic> body,
) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
  return {
    'id': sha256.convert(bytes).toString(),
    'payloadBase64': base64Encode(bytes),
    'signature': signer.sign(
      Uint8List.fromList([...utf8.encode('$channelSigningDomain\n'), ...bytes]),
    ),
    'ownerCertificatePem': signer.certPem,
  };
}
