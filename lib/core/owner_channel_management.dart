part of 'peer_engine.dart';

class _PreparedOwnerChannel {
  _PreparedOwnerChannel(this.entry, this.policy, this.atMs);
  final Map<String, dynamic> entry;
  final ChannelControl policy;
  final int atMs;
}

extension OwnerChannelManagement on PeerEngine {
  void _expireOwnerPreparations() {
    final cutoff =
        _clock.elapsedMilliseconds - const Duration(minutes: 10).inMilliseconds;
    _preparedOwnerChannels.removeWhere((_, value) => value.atMs < cutoff);
    _completedOwnerChannels.removeWhere((_, value) => value.atMs < cutoff);
  }

  Future<void> _prepareOwnerStorage() async {
    await _load();
    if (channelKeys == null) {
      throw StateError('Protected channel storage is unavailable.');
    }
    await channelKeys!.load();
    _expireOwnerPreparations();
    if (_preparedOwnerChannels.length >= 4) {
      throw StateError('Finish or cancel a pending channel first.');
    }
  }

  String _rememberOwnerPreparation(Map<String, dynamic> prepared) {
    final entry = Map<String, dynamic>.from(prepared['entry'] as Map);
    ChannelKeyStore.validateEntry(entry);
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(entry['channel'] as Map),
    );
    final policy = ChannelControl.parse(
      Map<String, dynamic>.from(prepared['policy'] as Map),
      channel,
    );
    final token = ChannelControl.randomNonce();
    _preparedOwnerChannels[token] = _PreparedOwnerChannel(
      entry,
      policy,
      _clock.elapsedMilliseconds,
    );
    // Only encrypted recovery material and an opaque completion token leave
    // the engine. The offline private key is not retained in pending state.
    return jsonEncode({
      'token': token,
      'file': prepared['file'],
      'channelId': channel.id,
      'generation': policy.generation,
    });
  }

  Future<String> prepareProtectedChannel({
    required String name,
    required String description,
    required String password,
  }) => _serial(() async {
    ChannelRecovery.validatePassword(password);
    await _prepareOwnerStorage();
    if (channelKeys!.entries.keys
            .where((id) => _store.policyFor(id)?.deleted != true)
            .length >=
        16) {
      throw StateError('This device can manage up to 16 channels.');
    }
    final prepared = await _prepareNewOwnerAsync(name, description, password);
    return _rememberOwnerPreparation(prepared);
  });

  Future<String> prepareOwnerRecovery(String file, String password) =>
      _serial(() async {
        ChannelRecovery.validatePassword(password);
        await _prepareOwnerStorage();
        final material = await ChannelRecovery.decryptOwnerKitAsync(
          file,
          password,
        );
        final channel = SignedChannel.fromJson(
          Map<String, dynamic>.from(material['channel'] as Map),
        );
        final known = _store.knownOwnerAuthority(channel)?.generation ?? 0;
        final next = max(known, material['generation'] as int) + 1;
        if (next > 9007199254740991) {
          throw StateError('Owner generation is exhausted.');
        }
        final prepared = await _prepareRecoveredOwnerAsync(
          material,
          next,
          password,
        );
        return _rememberOwnerPreparation(prepared);
      });

  Future<void> cancelProtectedChannel(String token) => _serial(() async {
    _preparedOwnerChannels.remove(token);
  });

  Future<String> commitProtectedChannel(String token) => _serial(() async {
    await _load();
    _expireOwnerPreparations();
    final completed = _completedOwnerChannels[token];
    if (completed != null) return completed.channelId;
    final prepared = _preparedOwnerChannels[token];
    if (prepared == null) {
      throw StateError(
        'Preparation expired. Open the saved recovery kit or start again.',
      );
    }
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(prepared.entry['channel'] as Map),
    );
    await channelKeys!.load();
    if (!channelKeys!.entries.containsKey(channel.id) &&
        channelKeys!.entries.keys
                .where((id) => _store.policyFor(id)?.deleted != true)
                .length >=
            16) {
      throw StateError('This device can manage up to 16 channels.');
    }
    final known = _store.knownOwnerAuthority(channel);
    if (known != null &&
        !known
            .merge(
              OwnerAuthority.fromGrant(prepared.policy.ownerGrant!, channel),
            )
            .allows(prepared.policy)) {
      throw StateError(
        'Newer or conflicting owner authority arrived. Repeat recovery using the latest known generation.',
      );
    }
    await channelKeys!.put(prepared.entry);
    _store.managedChannelIds.add(channel.id);
    await _store.putChannel(channel.toJson());
    await _store.putChannelPolicy(prepared.policy);
    if (_store.authorityFor(channel.id)?.allows(prepared.policy) != true) {
      throw StateError('Owner authority changed during recovery.');
    }
    _syncChannels();
    await _pruneImages();
    _queueGossip([
      {'type': 'channel', 'value': channel.toJson()},
      {
        'type': 'ownerAuthority',
        'value': _store.authorityFor(channel.id)!.toJson(),
      },
      {'type': 'channelPolicy', 'value': _store.channelPolicies[channel.id]},
    ]);
    _preparedOwnerChannels.remove(token);
    _completedOwnerChannels[token] = (
      channelId: channel.id,
      atMs: _clock.elapsedMilliseconds,
    );
    while (_completedOwnerChannels.length > 8) {
      _completedOwnerChannels.remove(_completedOwnerChannels.keys.first);
    }
    _notify();
    return channel.id;
  });
}

// Top-level isolate boundaries deliberately capture only serializable inputs;
// closures created inside the engine queue can capture its sockets/Futures.
Future<Map<String, dynamic>> _prepareNewOwnerAsync(
  String name,
  String description,
  String password,
) => Isolate.run(() {
  final recovery = Identity.generate(), owner = Identity.generate();
  final channel = SignedChannel.create(
    owner,
    name: name,
    description: description,
    recoveryCertificatePem: recovery.certPem,
  );
  return _prepareOwnerMaterial(channel, owner, recovery, 1, password);
});

Future<Map<String, dynamic>> _prepareRecoveredOwnerAsync(
  Map<String, dynamic> material,
  int generation,
  String password,
) => Isolate.run(() {
  final recovery = Identity.fromJson(
    Map<String, dynamic>.from(material['recoveryIdentity'] as Map),
  );
  final channel = SignedChannel.fromJson(
    Map<String, dynamic>.from(material['channel'] as Map),
  );
  return _prepareOwnerMaterial(
    channel,
    Identity.generate(),
    recovery,
    generation,
    password,
  );
});

Map<String, dynamic> _prepareOwnerMaterial(
  SignedChannel channel,
  Identity owner,
  Identity recovery,
  int generation,
  String password,
) {
  final grant = ChannelControl.create(
    recovery,
    channel,
    kind: 'owner',
    data: {
      'ownerCertificatePem': owner.certPem,
      'generation': generation,
      'nonce': ChannelControl.randomNonce(),
    },
  );
  final policy = ChannelControl.create(
    owner,
    channel,
    kind: 'policy',
    authority: grant,
    data: {'revision': 1, 'activeGrants': [], 'removed': [], 'floors': {}},
  );
  return {
    'entry': {
      'role': 'owner',
      'channel': channel.toJson(),
      'identity': owner.toJson(),
      'authorization': grant.toJson(),
    },
    'policy': policy.toJson(),
    'file': ChannelRecovery.encryptOwnerKit({
      'channel': channel.toJson(),
      'recoveryIdentity': recovery.toJson(),
      'generation': generation,
    }, password),
  };
}
