import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_control.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/owner_authority.dart';

void main() {
  late Identity root, owner, replacement;
  late SignedChannel channel;
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
  ChannelControl grant(
    Identity signer,
    Identity writer,
    int generation, {
    SignedChannel? target,
  }) => ChannelControl.create(
    signer,
    target ?? channel,
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
    List<String> editors = const [],
  }) => ChannelControl.create(
    writer,
    channel,
    kind: 'policy',
    authority: authority,
    data: {
      'revision': revision,
      'activeGrants': editors,
      'removed': [],
      'floors': {},
      if (deleted) 'deleted': true,
    },
  );
  SignedBulletin news(Identity writer, {ChannelControl? proof}) =>
      SignedBulletin.create(
        writer,
        runId: 'owner-recovery',
        text: 'خبر آزمایشی',
        sequence: 1,
        channelId: channel.id,
        authorization: proof,
      );

  test('v2 metadata binds an independent immutable recovery certificate', () {
    final restored = SignedChannel.fromJson(channel.toJson());
    expect(restored.recoverable, isTrue);
    expect(restored.recoveryId, root.id);
    expect(
      () => SignedChannel.create(
        owner,
        name: 'Unsafe',
        recoveryCertificatePem: owner.certPem,
      ),
      throwsFormatException,
    );
    final changed = SignedChannel.create(
      owner,
      name: channel.name,
      recoveryCertificatePem: replacement.certPem,
    );
    expect(changed.id, isNot(channel.id));
    expect(SignedChannel.create(owner, name: 'Legacy').recoverable, isFalse);
  });

  test(
    'stolen owner cannot sign recovery grants or bypass them with bare news',
    () {
      expect(() => grant(owner, replacement, 2), throwsFormatException);
      expect(() => grant(root, root, 2), throwsFormatException);
      final first = grant(root, owner, 1);
      final state = OwnerAuthority.fromGrant(first, channel);
      final current = policy(owner, first, 1);
      expect(
        news(owner)
            .verifyForChannel(channel, policy: current, ownerAuthority: state),
        isFalse,
      );
      expect(
        news(
          owner,
          proof: first,
        ).verifyForChannel(channel, policy: current, ownerAuthority: state),
        isTrue,
      );
      expect(news(owner, proof: first).verifyForChannel(channel), isFalse);
    },
  );

  test(
    'higher generation defeats max revision, deletion and old owner news',
    () {
      final first = grant(root, owner, 1), second = grant(root, replacement, 2);
      final oldState = OwnerAuthority.fromGrant(first, channel);
      final current = oldState.merge(OwnerAuthority.fromGrant(second, channel));
      final stale = policy(owner, first, 9007199254740991, deleted: true);
      expect(current.allows(stale), isFalse);
      expect(current.merge(oldState).generation, 2);
      expect(
        news(owner, proof: first).verifyForChannel(
          channel,
          policy: policy(replacement, second, 1),
          ownerAuthority: current,
        ),
        isFalse,
      );
      expect(
        news(replacement, proof: second).verifyForChannel(
          channel,
          policy: policy(replacement, second, 1),
          ownerAuthority: current,
        ),
        isTrue,
      );
      expect(
        news(
          replacement,
          proof: second,
        ).verifyForChannel(channel, policy: stale, ownerAuthority: current),
        isFalse,
      );
    },
  );

  test('same generation conflicts survive serialization and require a new generation', () {
    final a = grant(root, owner, 4), b = grant(root, replacement, 4);
    final conflict = OwnerAuthority.fromGrant(
      a,
      channel,
    ).merge(OwnerAuthority.fromGrant(b, channel));
    expect(conflict.conflicted, isTrue);
    final restored = OwnerAuthority.parse(
      jsonDecode(jsonEncode(conflict.toJson())) as Map<String, dynamic>,
      channel,
    );
    expect(restored.id, conflict.id);
    expect(restored.allows(a), isFalse);
    expect(restored.allows(b), isFalse);
    expect(
      restored.merge(OwnerAuthority.fromGrant(a, channel)).conflicted,
      isTrue,
    );
    final third = grant(root, replacement, 4);
    expect(
      restored.merge(OwnerAuthority.fromGrant(third, channel)).grants.length,
      2,
    );
    final resolved = restored.merge(
      OwnerAuthority.fromGrant(grant(root, owner, 5), channel),
    );
    expect(resolved.conflicted, isFalse);
    expect(resolved.generation, 5);
  });

  test('signed controls reject substitution of a different owner grant', () {
    final first = grant(root, owner, 1);
    // Even reusing an online certificate must not transplant old permissions
    // into a later generation, or into a conflicting grant of the same one.
    final later = grant(root, owner, 2);
    final conflict = grant(root, owner, 1);
    final controls = [
      policy(owner, first, 1),
      ChannelControl.create(
        owner,
        channel,
        kind: 'editor',
        authority: first,
        data: {
          'editorCertificatePem': replacement.certPem,
          'label': 'Writer',
          'revision': 1,
          'nonce': ChannelControl.randomNonce(),
        },
      ),
    ];
    for (final control in controls) {
      for (final substituted in [later, conflict]) {
        expect(
          () => ChannelControl.parse({
            ...control.toJson(),
            'authority': substituted.toJson(),
          }, channel),
          throwsFormatException,
        );
      }
    }
  });

  test('editor authority is scoped to its recovery generation', () {
    final first = grant(root, owner, 1), second = grant(root, replacement, 2);
    final editor = ChannelControl.create(
      owner,
      channel,
      kind: 'editor',
      authority: first,
      data: {
        'editorCertificatePem': replacement.certPem,
        'label': 'Writer',
        'revision': 1,
        'nonce': ChannelControl.randomNonce(),
      },
    );
    final post = news(replacement, proof: editor);
    expect(
      post.verifyForChannel(
        channel,
        policy: policy(owner, first, 1, editors: [editor.id]),
        ownerAuthority: OwnerAuthority.fromGrant(first, channel),
      ),
      isTrue,
    );
    expect(
      post.verifyForChannel(
        channel,
        policy: policy(replacement, second, 1),
        ownerAuthority: OwnerAuthority.fromGrant(second, channel),
      ),
      isFalse,
    );
  });

  test('cross-channel, duplicate, oversized and extra-field authority fails closed', () {
    final first = grant(root, owner, 1);
    final state = OwnerAuthority.fromGrant(first, channel);
    final other = SignedChannel.create(
      owner,
      name: 'Other',
      recoveryCertificatePem: root.certPem,
    );
    expect(
      () => ChannelControl.parse(first.toJson(), other),
      throwsFormatException,
    );
    expect(
      () => OwnerAuthority.parse({...state.toJson(), 'trusted': true}, channel),
      throwsFormatException,
    );
    expect(
      () => OwnerAuthority.parse({
        ...state.toJson(),
        'grants': [first.toJson(), first.toJson()],
      }, channel),
      throwsFormatException,
    );
    expect(
      () => OwnerAuthority.parse({
        ...state.toJson(),
        'grants': List.filled(3, first.toJson()),
      }, channel),
      throwsFormatException,
    );
    final forged = {...first.toJson(), 'signerCertificatePem': owner.certPem};
    expect(() => ChannelControl.parse(forged, channel), throwsFormatException);
    expect(() => grant(root, owner, 0), throwsFormatException);
    expect(() => grant(root, owner, 9007199254740992), throwsFormatException);
    expect(
      () => ChannelControl.create(
        owner,
        channel,
        kind: 'manager',
        data: {
          'managerCertificatePem': replacement.certPem,
          'nonce': ChannelControl.randomNonce(),
        },
      ),
      throwsFormatException,
    );
  });
}
