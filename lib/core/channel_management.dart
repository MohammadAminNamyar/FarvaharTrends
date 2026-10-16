part of 'peer_engine.dart';

/// Reuses verified values only within one synchronous access calculation.
/// Never retained across awaits or snapshots: revocation and recovery must be
/// checked again against the latest store before the next operation.
class _ChannelAccess {
  _ChannelAccess(this.engine, this.channel);
  final PeerEngine engine;
  final SignedChannel channel;
  late final policy = engine._store.policyFor(channel.id);
  late final authority = engine._store.knownOwnerAuthority(channel);
  late final entry = engine.channelKeys?.entries[channel.id];
  late final grant = ChannelControl.parse(
    Map<String, dynamic>.from(entry!['authorization'] as Map),
    channel,
  );
  late final bool owned = _owned();
  late final bool canPublish = _canPublish();

  bool _owned() {
    if (channel.recoverable) {
      if (entry?['role'] != 'owner' || entry?['authorization'] is! Map) {
        return false;
      }
      return authority?.allows(grant) == true;
    }
    return entry?['role'] == 'owner' ||
        channel.ownedBy(engine.publisherIdentity);
  }

  bool _canPublish() {
    if (policy?.deleted == true) return false;
    if (channel.recoverable && policy == null) return false;
    if (owned) return true;
    if (entry?['role'] != 'editor') return false;
    final editorGrant = grant;
    if (channel.recoverable &&
        (policy == null || authority?.allows(editorGrant) != true)) {
      return false;
    }
    return policy == null ||
        (policy!.signerId == editorGrant.signerId &&
            (policy!.revision < editorGrant.revision ||
                policy!.activeGrants.contains(editorGrant.id)));
  }

  List<Map<String, dynamic>> get editors {
    final grants = entry?['grants'] as List? ?? [];
    final active = policy?.activeGrants ?? [];
    return active.map((grantId) {
      final raw = grants.where((v) => (v as Map)['id'] == grantId).firstOrNull;
      if (raw == null) {
        return <String, dynamic>{
          'id': grantId,
          'label': 'Editor ${grantId.substring(0, 8)}',
          'fingerprint': null,
        };
      }
      if (raw is Map && raw.length == 3 && raw['fingerprint'] is String) {
        return Map<String, dynamic>.from(raw);
      }
      final editor = ChannelControl.parse(
        Map<String, dynamic>.from(raw as Map),
        channel,
      );
      return <String, dynamic>{
        'id': editor.id,
        'label': editor.body['label'],
        'fingerprint': editor.editorId,
      };
    }).toList();
  }
}

extension ChannelManagement on PeerEngine {
  bool _isOwner(SignedChannel channel) => _ChannelAccess(this, channel).owned;
  bool _canPublish(SignedChannel channel) =>
      _ChannelAccess(this, channel).canPublish;
  List<Map<String, dynamic>> _editorSummary(String id) =>
      _ChannelAccess(this, _channels[id]!).editors;
  Future<(Identity, ChannelControl?)> _publishingCredentials(String id) async {
    await channelKeys?.load();
    final channel = _channels[id];
    if (channel == null || !_canPublish(channel)) {
      throw StateError(
        'Publishing permission is unavailable or has been revoked.',
      );
    }
    final entry = channelKeys?.entries[id];
    if (entry == null) return (publisherIdentity, null);
    return (
      Identity.fromJson(Map<String, dynamic>.from(entry['identity'] as Map)),
      entry['authorization'] is Map
          ? ChannelControl.parse(
              Map<String, dynamic>.from(entry['authorization'] as Map),
              channel,
            )
          : null,
    );
  }

  Future<Map<String, dynamic>> _ownerEntry(String id) async {
    if (channelKeys == null) {
      throw StateError('Protected channel storage is unavailable.');
    }
    await channelKeys!.load();
    final channel = _channels[id];
    if (channel == null ||
        !_isOwner(channel) ||
        _store.policyFor(id)?.deleted == true) {
      throw StateError('Only the channel owner can manage this channel.');
    }
    var entry = channelKeys!.entries[id];
    if (entry == null) {
      // Never export the legacy publisher key shared by older channels.
      final manager = Identity.fromJson(
        await Isolate.run(() => Identity.generate().toJson()),
      );
      final authority = ChannelControl.create(
        publisherIdentity,
        channel,
        kind: 'manager',
        data: {
          'managerCertificatePem': manager.certPem,
          'nonce': ChannelControl.randomNonce(),
        },
      );
      entry = {
        'role': 'owner',
        'channel': channel.toJson(),
        'identity': manager.toJson(),
        'authorization': authority.toJson(),
      };
      await channelKeys!.put(entry);
      _store.managedChannelIds.add(id);
    }
    if (entry['role'] != 'owner') throw StateError('Owner access is required.');
    return jsonDecode(jsonEncode(entry)) as Map<String, dynamic>;
  }

  ChannelControl _makePolicy(
    Map<String, dynamic> entry, {
    List<String>? active,
    List<Map<String, dynamic>>? removed,
    Map<String, int>? floors,
    bool deleted = false,
    List<String>? retained,
  }) {
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(entry['channel'] as Map),
    );
    final signer = Identity.fromJson(
      Map<String, dynamic>.from(entry['identity'] as Map),
    );
    final previous = _store.policyFor(channel.id);
    return ChannelControl.create(
      signer,
      channel,
      kind: 'policy',
      authority: entry['authorization'] is Map
          ? ChannelControl.parse(
              Map<String, dynamic>.from(entry['authorization'] as Map),
              channel,
            )
          : null,
      data: {
        if (deleted || previous?.deleted == true) 'deleted': true,
        if (retained != null || (previous?.retained.isNotEmpty ?? false))
          'retained': retained ?? previous!.retained,
        'revision': (previous?.revision ?? 0) + 1,
        'activeGrants': active ?? previous?.activeGrants ?? <String>[],
        'removed': removed ?? previous?.removed ?? <Map<String, dynamic>>[],
        'floors': floors ?? previous?.floors ?? <String, int>{},
      },
    );
  }

  Future<void> _savePolicy(ChannelControl policy) async {
    await _store.putChannelPolicy(policy);
    await _pruneImages();
    _queueGossip([
      {'type': 'channel', 'value': _store.channels[policy.channelId]},
      {'type': 'channelPolicy', 'value': policy.toJson()},
    ]);
    _notify();
  }

  Future<String> exportChannelRecovery(String channelId, String password) =>
      _serial(() async {
        await _load();
        final entry = await _ownerEntry(channelId);
        final material = {
          'entry': entry,
          'sequence': _store.channelSequences[channelId] ?? 0,
          'policy': _store.channelPolicies[channelId],
        };
        return ChannelRecovery.encryptAsync(material, password);
      });
  Future<String> restoreChannelRecovery(String file, String password) =>
      _serial(() async {
        await _load();
        if (channelKeys == null) {
          throw StateError('Protected channel storage is unavailable.');
        }
        final material = await ChannelRecovery.decryptAsync(file, password);
        final entry = Map<String, dynamic>.from(material['entry'] as Map);
        final channel = SignedChannel.fromJson(
          Map<String, dynamic>.from(entry['channel'] as Map),
        );
        ChannelControl? policy;
        if (material['policy'] != null) {
          policy = ChannelControl.parse(
            Map<String, dynamic>.from(material['policy'] as Map),
            channel,
          );
          if (policy.kind != 'policy') {
            throw const FormatException('Invalid recovery policy.');
          }
        }
        if (channel.recoverable) {
          final grant = ChannelControl.parse(
            Map<String, dynamic>.from(entry['authorization'] as Map),
            channel,
          );
          final known = _store.knownOwnerAuthority(channel);
          if ((known != null &&
                  !known
                      .merge(OwnerAuthority.fromGrant(grant, channel))
                      .allows(grant)) ||
              (policy != null && policy.ownerGrant?.id != grant.id)) {
            throw StateError(
              'This backup does not match the current channel owner. Use the recovery kit.',
            );
          }
        }
        await channelKeys!.put(entry);
        _store.managedChannelIds.add(channel.id);
        await _store.putChannel(channel.toJson());
        if (policy != null) await _store.putChannelPolicy(policy);
        await _store.advanceChannelSequence(
          channel.id,
          material['sequence'] as int,
        );
        _syncChannels();
        _queueGossip([
          {'type': 'channel', 'value': channel.toJson()},
          if (policy != null)
            {'type': 'channelPolicy', 'value': policy.toJson()},
        ]);
        _notify();
        return channel.id;
      });
  Future<String> createEditorRequest(String label) => _serial(() async {
    await _load();
    if (channelKeys == null) {
      throw StateError('Protected channel storage is unavailable.');
    }
    final clean = label.trim();
    if (clean.isEmpty ||
        clean.length > 80 ||
        utf8.encode(clean).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(clean)) {
      throw const FormatException('Enter a short editor name.');
    }
    final editor = Identity.fromJson(
      await Isolate.run(() => Identity.generate().toJson()),
    );
    await channelKeys!.putPending(editor);
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'kind': 'editor-request',
          'label': clean,
          'certificatePem': editor.certPem,
          'nonce': ChannelControl.randomNonce(),
        }),
      ),
    );
    return jsonEncode({
      'payloadBase64': base64Encode(bytes),
      'signature': editor.sign(bytes),
    });
  });
  Map<String, dynamic> inspectEditorRequest(String file) {
    try {
      if (utf8.encode(file).length > 16 * 1024) throw const FormatException();
      final raw = jsonDecode(file) as Map;
      if (raw.length != 2) throw const FormatException();
      final bytes = base64Decode(raw['payloadBase64'] as String);
      if (base64Encode(bytes) != raw['payloadBase64']) {
        throw const FormatException();
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map;
      if (body.length != 5 ||
          body['version'] != 1 ||
          body['kind'] != 'editor-request' ||
          body['label'] is! String ||
          (body['label'] as String).trim().isEmpty ||
          (body['label'] as String).length > 80 ||
          utf8.encode(body['label']).length > 256 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(body['label']) ||
          body['nonce'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(body['nonce']) ||
          !Identity.verify(
            body['certificatePem'] as String,
            bytes,
            raw['signature'] as String,
          )) {
        throw const FormatException();
      }
      return {
        'label': body['label'],
        'fingerprint': Identity.certificateId(body['certificatePem'] as String),
        'certificatePem': body['certificatePem'],
      };
    } catch (_) {
      throw const FormatException('Invalid editor request.');
    }
  }

  Future<String> approveEditor(String channelId, String request) => _serial(
    () async {
      await _load();
      final requested = inspectEditorRequest(request);
      final entry = await _ownerEntry(channelId);
      final channel = _channels[channelId]!;
      final previous = _store.policyFor(channelId);
      final active = previous?.activeGrants ?? <String>[];
      if (active.length >= ChannelControl.maxEditors) {
        throw StateError('Remove an editor before adding another (maximum 8).');
      }
      final signer = Identity.fromJson(
        Map<String, dynamic>.from(entry['identity'] as Map),
      );
      final grant = ChannelControl.create(
        signer,
        channel,
        kind: 'editor',
        authority: entry['authorization'] is Map
            ? ChannelControl.parse(
                Map<String, dynamic>.from(entry['authorization'] as Map),
                channel,
              )
            : null,
        data: {
          'editorCertificatePem': requested['certificatePem'],
          'label': requested['label'],
          'revision': (previous?.revision ?? 0) + 1,
          'nonce': ChannelControl.randomNonce(),
        },
      );
      final grants =
          (entry['grants'] as List? ?? [])
              .where((v) => active.contains((v as Map)['id']))
              .toList()
            ..add({
              'id': grant.id,
              'label': requested['label'],
              'fingerprint': grant.editorId,
            });
      entry['grants'] = grants;
      await channelKeys!.put(entry);
      final policy = _makePolicy(entry, active: [...active, grant.id]);
      await _savePolicy(policy);
      return jsonEncode({
        'version': 1,
        'kind': 'editor-invitation',
        'channel': channel.toJson(),
        'grant': grant.toJson(),
        'policy': policy.toJson(),
      });
    },
  );
  Future<String> acceptEditorInvitation(String file) => _serial(() async {
    await _load();
    if (channelKeys == null || utf8.encode(file).length > 64 * 1024) {
      throw const FormatException('Invalid invitation.');
    }
    final raw = jsonDecode(file) as Map;
    if (raw.length != 5 ||
        raw['version'] != 1 ||
        raw['kind'] != 'editor-invitation') {
      throw const FormatException('Invalid invitation.');
    }
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(raw['channel'] as Map),
    );
    final grant = ChannelControl.parse(
      Map<String, dynamic>.from(raw['grant'] as Map),
      channel,
    );
    final policy = ChannelControl.parse(
      Map<String, dynamic>.from(raw['policy'] as Map),
      channel,
    );
    if (grant.kind != 'editor' ||
        policy.kind != 'policy' ||
        !policy.activeGrants.contains(grant.id) ||
        policy.signerId != grant.signerId) {
      throw const FormatException('Invalid invitation authority.');
    }
    await channelKeys!.load();
    final key =
        channelKeys!.pending[grant.editorId] ??
        channelKeys!.entries[channel.id]?['identity'];
    if (key is! Map || key['id'] != grant.editorId) {
      throw StateError(
        'This invitation belongs to the device that created the editor request.',
      );
    }
    final current = _store.policyFor(channel.id);
    if (current != null &&
        current.revision >= grant.revision &&
        !current.activeGrants.contains(grant.id)) {
      throw StateError('This invitation has been revoked.');
    }
    await channelKeys!.put({
      'role': 'editor',
      'channel': channel.toJson(),
      'identity': Map<String, dynamic>.from(key),
      'authorization': grant.toJson(),
    });
    _store.managedChannelIds.add(channel.id);
    await _store.putChannel(channel.toJson());
    await _store.putChannelPolicy(policy);
    _syncChannels();
    _notify();
    return channel.id;
  });
  Future<void> revokeEditor(String channelId, String grantId) =>
      _serial(() async {
        await _load();
        final entry = await _ownerEntry(channelId);
        final active = _store.policyFor(channelId)?.activeGrants ?? <String>[];
        if (!active.contains(grantId)) {
          throw StateError('Editor permission is no longer active.');
        }
        await _savePolicy(
          _makePolicy(
            entry,
            active: active.where((id) => id != grantId).toList(),
          ),
        );
        entry['grants'] = (entry['grants'] as List? ?? [])
            .where((v) => (v as Map)['id'] != grantId)
            .toList();
        await channelKeys!.put(entry);
        _notify();
      });
  Future<void> removeChannel(String channelId) => _serial(() async {
    await _load();
    final entry = await _ownerEntry(channelId);
    await _savePolicy(_makePolicy(entry, deleted: true));
  });
  Future<void> setWriterNickname(String channelId, String nickname) =>
      _serial(() async {
        await _load();
        if (channelKeys == null) {
          throw StateError('Protected channel storage is unavailable.');
        }
        await _publishingCredentials(channelId);
        final entry = channelKeys!.entries[channelId] == null
            ? await _ownerEntry(channelId)
            : Map<String, dynamic>.from(channelKeys!.entries[channelId]!);
        final clean = nickname.trim();
        if (clean.isEmpty) {
          entry.remove('nickname');
        } else {
          validateNewsByline(clean);
          entry['nickname'] = clean;
        }
        await channelKeys!.put(entry);
        _notify();
      });

  Future<void> removePublishedNews(
    String channelId,
    String newsId,
  ) => _serial(() async {
    await _load();
    final entry = await _ownerEntry(channelId);
    final raw = _store.bulletins[newsId];
    if (raw == null) {
      throw StateError('This news is no longer in the local cache.');
    }
    final news = SignedBulletin.fromJson(raw);
    if (news.channelId != channelId) {
      throw StateError('The news belongs to a different channel.');
    }
    final previous = _store.policyFor(channelId);
    final removed = previous?.removed ?? <Map<String, dynamic>>[];
    final floors = previous?.floors ?? <String, int>{};
    removed.add({
      'id': news.id,
      'authorId': news.sourceId,
      'sequence': news.sequence,
    });
    while (removed.length > ChannelControl.maxRemovals) {
      final old = removed.removeAt(0);
      final author = old['authorId'] as String;
      floors[author] = max(floors[author] ?? 1, (old['sequence'] as int) + 1);
    }
    // Inactive editor keys already fail current policy; their floors need no space.
    final activeAuthors = {
      _channels[channelId]!.ownerId,
      (entry['identity'] as Map)['id'],
      ..._editorSummary(channelId).map((v) => v['fingerprint']),
    };
    floors.removeWhere((author, _) => !activeAuthors.contains(author));
    final preserved = _store.bulletins.values
        .map(SignedBulletin.fromJson)
        .where(
          (v) =>
              v.channelId == channelId &&
              !removed.any((row) => row['id'] == v.id) &&
              v.id != newsId &&
              v.sequence < (floors[v.sourceId] ?? 1),
        )
        .map((v) => v.id)
        .take(PilotStore.maxBulletinsPerChannel)
        .toList();
    await _savePolicy(
      _makePolicy(entry, removed: removed, floors: floors, retained: preserved),
    );
  });
}
