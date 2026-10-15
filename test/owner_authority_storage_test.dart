import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_control.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/owner_authority.dart';
import 'package:farvahar_trends/core/owner_authority_checkpoint.dart';
import 'package:farvahar_trends/core/pilot_store.dart';

void main() {
  late Identity root, owner, replacement;
  late SignedChannel channel;
  late Directory scratch;
  setUpAll(() {
    root = Identity.generate();
    owner = Identity.generate();
    replacement = Identity.generate();
    channel = SignedChannel.create(
      owner,
      name: 'آزمایش بازیابی',
      recoveryCertificatePem: root.certPem,
    );
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('owner-authority-');
  });
  tearDown(() async {
    final expected = Directory('${Directory.current.path}/.tooling/test-tmp')
        .absolute
        .path;
    if (!scratch.absolute.path.startsWith(
      '$expected${Platform.pathSeparator}',
    )) {
      throw StateError('Test directory escaped the project.');
    }
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });
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
  ChannelControl policy(
    Identity writer,
    ChannelControl authority,
    int revision, {
    bool deleted = false,
  }) => ChannelControl.create(
    writer,
    channel,
    kind: 'policy',
    authority: authority,
    data: {
      'revision': revision,
      'activeGrants': [],
      'removed': [],
      'floors': {},
      if (deleted) 'deleted': true,
    },
  );
  SignedBulletin news(Identity writer, ChannelControl proof) =>
      SignedBulletin.create(
        writer,
        runId: 'owner-recovery',
        text: 'خبر آزمایشی',
        sequence: 1,
        channelId: channel.id,
        authorization: proof,
      );

  test(
    'failed first proof write can recover after storage becomes available',
    () async {
      final checkpoint = OwnerAuthorityCheckpoint(scratch);
      await checkpoint.load();
      final obstruction = Directory(
        '${scratch.path}/owner-authorities.json.next',
      );
      await obstruction.create();
      final authority = OwnerAuthority.fromGrant(grant(owner, 1), channel);
      await expectLater(
        checkpoint.remember(authority, channel),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File('${scratch.path}/owner-authorities.json.initialized')
            .exists(),
        isFalse,
      );
      await obstruction.delete();
      expect((await checkpoint.remember(authority, channel)).id, authority.id);
      final restarted = OwnerAuthorityCheckpoint(scratch);
      await restarted.load();
      expect(restarted.known(channel)?.id, authority.id);
    },
  );

  test(
    'rotation persists before old news and policies can be replayed',
    () async {
      final store = PilotStore(scratch, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final first = grant(owner, 1), second = grant(replacement, 2);
      final oldPolicy = policy(owner, first, 1);
      await store.putChannelPolicy(oldPolicy);
      final oldNews = news(owner, first);
      expect(await store.putBulletin(oldNews.toJson()), isTrue);
      final staleJournal = await File('${scratch.path}/pilot.jsonl')
          .readAsString();
      await store.putChannelPolicy(
        policy(owner, first, 9007199254740991, deleted: true),
      );
      expect(
        await store.putChannelPolicy(policy(replacement, second, 1)),
        isTrue,
      );
      expect(store.bulletins, isEmpty);
      expect(await store.putChannelPolicy(oldPolicy), isFalse);
      expect(await store.putBulletin(oldNews.toJson()), isFalse);
      final newNews = news(replacement, second);
      expect(await store.putBulletin(newNews.toJson()), isTrue);
      final reopened = PilotStore(scratch, localOwnerId: owner.id);
      await reopened.load();
      expect(reopened.authorityFor(channel.id)!.generation, 2);
      expect(reopened.bulletins.keys, contains(newNews.id));
      // A stale content journal must not roll back the independent checkpoint.
      await File('${scratch.path}/pilot.jsonl')
          .writeAsString(staleJournal, flush: true);
      final staleRestored = PilotStore(scratch, localOwnerId: owner.id);
      await staleRestored.load();
      expect(staleRestored.authorityFor(channel.id)!.generation, 2);
      expect(staleRestored.policyFor(channel.id), isNull);
      expect(staleRestored.bulletins, isEmpty);
      expect(await staleRestored.putChannelPolicy(oldPolicy), isFalse);
    },
  );

  test(
    'conflicting policy invalidates both owners across compaction and restart',
    () async {
      final store = PilotStore(scratch, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final first = grant(owner, 1), competing = grant(replacement, 1);
      await store.putChannelPolicy(policy(owner, first, 1));
      await store.putBulletin(news(owner, first).toJson());
      expect(
        await store.putChannelPolicy(policy(replacement, competing, 1)),
        isFalse,
      );
      expect(store.authorityFor(channel.id)!.conflicted, isTrue);
      expect(store.policyFor(channel.id), isNull);
      expect(store.bulletins, isEmpty);
      final reopened = PilotStore(scratch, localOwnerId: owner.id);
      await reopened.load();
      expect(reopened.authorityFor(channel.id)!.conflicted, isTrue);
      expect(await reopened.putChannelPolicy(policy(owner, first, 9)), isFalse);
      final next = grant(replacement, 2);
      expect(
        await reopened.putChannelPolicy(policy(replacement, next, 1)),
        isTrue,
      );
      expect(reopened.authorityFor(channel.id)!.conflicted, isFalse);
    },
  );

  test(
    'authority remains known when evictable journal metadata is absent',
    () async {
      final store = PilotStore(scratch, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final current = grant(replacement, 7);
      await store.putChannelPolicy(policy(replacement, current, 1));
      await File('${scratch.path}/pilot.jsonl').writeAsString('', flush: true);
      final reopened = PilotStore(scratch, localOwnerId: owner.id);
      await reopened.load();
      await reopened.putChannel(channel.toJson());
      expect(reopened.authorityFor(channel.id)!.generation, 7);
      expect(
        await reopened.putChannelPolicy(
          policy(owner, grant(owner, 1), 9007199254740991),
        ),
        isFalse,
      );
    },
  );

  test(
    'corrupt committed checkpoint never falls back to old owner backup',
    () async {
      final checkpoint = OwnerAuthorityCheckpoint(scratch);
      await checkpoint.remember(
        OwnerAuthority.fromGrant(grant(owner, 1), channel),
        channel,
      );
      final file = File('${scratch.path}/owner-authorities.json');
      final old = await file.readAsString();
      await checkpoint.remember(
        OwnerAuthority.fromGrant(grant(replacement, 2), channel),
        channel,
      );
      await File('${file.path}.bak').writeAsString(old, flush: true);
      await file.writeAsString('{torn', flush: true);
      await expectLater(
        OwnerAuthorityCheckpoint(scratch).load(),
        throwsStateError,
      );
      await expectLater(PilotStore(scratch).load(), throwsStateError);
    },
  );

  test('interrupted rename recovers the newer flushed checkpoint', () async {
    final checkpoint = OwnerAuthorityCheckpoint(scratch);
    final first = OwnerAuthority.fromGrant(grant(owner, 1), channel);
    final second = OwnerAuthority.fromGrant(grant(replacement, 2), channel);
    await checkpoint.remember(first, channel);
    final file = File('${scratch.path}/owner-authorities.json');
    final old = await file.readAsString();
    await checkpoint.remember(second, channel);
    await file.rename('${file.path}.next');
    await File('${file.path}.bak').writeAsString(old, flush: true);
    final recovered = OwnerAuthorityCheckpoint(scratch);
    await recovered.load();
    expect(recovered.known(channel)!.generation, 2);
    expect(await File('${file.path}.next').exists(), isFalse);
  });

  test(
    'failed content write cannot undo the durable recovery generation',
    () async {
      final store = PilotStore(scratch, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final first = grant(owner, 1), second = grant(replacement, 2);
      await store.putChannelPolicy(policy(owner, first, 1));
      final file = File('${scratch.path}/pilot.jsonl');
      final original = await file.readAsString();
      await file.rename('${file.path}.held');
      await Directory(file.path).create();
      await expectLater(
        store.putChannelPolicy(policy(replacement, second, 1)),
        throwsA(isA<FileSystemException>()),
      );
      await Directory(file.path).delete();
      await file.writeAsString(original, flush: true);
      final recovered = PilotStore(scratch, localOwnerId: owner.id);
      await recovered.load();
      expect(recovered.authorityFor(channel.id)!.generation, 2);
      expect(recovered.policyFor(channel.id), isNull);
      expect(
        await recovered.putChannelPolicy(policy(owner, first, 2)),
        isFalse,
      );
    },
  );

  test('unsolicited channel authority cannot fill permanent proofs; following anchors it', () async {
    final store = PilotStore(scratch, localOwnerId: replacement.id);
    await store.load();
    await store.putChannel(channel.toJson());
    final current = grant(owner, 4);
    await store.putChannelPolicy(policy(owner, current, 1));
    expect(
      await File('${scratch.path}/owner-authorities.json').exists(),
      isFalse,
    );
    await store.setProtectedChannelIds([channel.id]);
    expect(
      await File('${scratch.path}/owner-authorities.json').exists(),
      isTrue,
    );
    await File('${scratch.path}/pilot.jsonl').writeAsString('', flush: true);
    final reopened = PilotStore(scratch, localOwnerId: replacement.id);
    await reopened.load();
    expect(reopened.knownOwnerAuthority(channel)!.generation, 4);
  });

  test(
    'temporary checkpoint rename failure recovers in the same running store',
    () async {
      final store = PilotStore(scratch, localOwnerId: owner.id);
      await store.load();
      await store.putChannel(channel.toJson());
      final first = grant(owner, 1), second = grant(replacement, 2);
      await store.putChannelPolicy(policy(owner, first, 1));
      await store.putBulletin(news(owner, first).toJson());
      final obstruction = Directory(
        '${scratch.path}/owner-authorities.json.bak',
      );
      await obstruction.create();
      final freshPolicy = policy(replacement, second, 1);
      await expectLater(
        store.putChannelPolicy(freshPolicy),
        throwsA(isA<FileSystemException>()),
      );
      expect(() => store.authorityFor(channel.id), throwsStateError);
      await obstruction.delete();
      await store.refreshAuthorityCheckpoint();
      expect(store.authorityFor(channel.id)!.generation, 2);
      expect(store.policyFor(channel.id), isNull);
      expect(store.bulletins, isEmpty);
      expect(await store.putChannelPolicy(freshPolicy), isTrue);
      expect(
        await store.putChannelPolicy(policy(owner, first, 9007199254740991)),
        isFalse,
      );
    },
  );
}
