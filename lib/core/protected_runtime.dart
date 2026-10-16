part of 'peer_engine.dart';

// Experimental only. A configured recipient key is a laboratory pin, not a
// discovery protocol. These bounds mitigate resource exhaustion, not Sybils.
extension ProtectedPublication on PeerEngine {
  static const _lifetimeMs = 10 * 60 * 1000;
  static const _maxFragments = 24;
  static const _maxBundleBytes = 128 * 1024;

  Future<T> _protectedSerial<T>(Future<T> Function() action) {
    final next = _protectedWork.then((_) => action());
    _protectedWork = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  int get _protectedNow => DateTime.now().millisecondsSinceEpoch;
  Directory get _pendingImages =>
      Directory('${directory.path}/pending-images-x2');
  File _pendingImage(String hash) => File('${_pendingImages.path}/$hash.jpg');
  BoundedJournal get _pendingJournal => _protectedJournals['pending']!;
  BoundedJournal get _entryJournal => _protectedJournals['entry']!;
  BoundedJournal get _exitJournal => _protectedJournals['exit']!;

  List<Map<String, dynamic>> get pendingPublicationSummaries =>
      _pendingPublications.values.map((p) => p.summary()).toList();

  /// White-box laboratory invariant check; never a network request or receipt.
  Map<String, bool> inspectProtectedObject(String id) {
    if (envelopeExperiment == null) throw StateError('Experiment disabled');
    final record = _pendingPublications[id];
    final hash = record?.imageHash;
    return {
      'publicObject':
          _store.channels.containsKey(id) || _store.bulletins.containsKey(id),
      'indexedImage': hash != null && _store.referencedImage(hash) != null,
      'publicImageBytes': hash != null && _media.has(hash),
    };
  }

  Future<Uint8List> envelopePublicKey() async {
    if (envelopeExperiment == null || _envelopeCrypto == null) {
      throw StateError('Start an experimental engine first');
    }
    return Uint8List.fromList(_envelopeCrypto!.publicKey);
  }

  Future<void> _loadProtectedState() async {
    final config = envelopeExperiment;
    if (config == null) return;
    if (!_protectedLoaded) {
      _protectedJournals.addAll({
        'pending': BoundedJournal(
          File('${directory.path}/pending-publications-x2.jsonl'),
        ),
        'entry': BoundedJournal(
          File('${directory.path}/envelope-entry-x2.jsonl'),
          maxEntries: 64,
        ),
        'exit': BoundedJournal(
          File('${directory.path}/envelope-exit-x2.jsonl'),
          maxEntries: 128,
          maxStateBytes: 1536 * 1024,
          maxJournalBytes: 4 * 1024 * 1024,
        ),
      });
      for (final journal in _protectedJournals.values) {
        await journal.load();
      }
      _pendingPublications.clear();
      for (final row in _pendingJournal.rows.values) {
        final record = PendingPublication.fromJson(row);
        _pendingPublications[record.id] = record;
      }
      _entryOrigins.addAll(_entryJournal.rows);
      await _pendingImages.create(recursive: true);
      await _prunePendingImages();
      _protectedLoaded = true;
    }
    _envelopeCrypto ??= await EnvelopeCryptoWorker.start(
      directory,
      mode: config.cryptoMode,
    );
  }

  void _startProtectedTimer() {
    if (envelopeExperiment == null) return;
    _protectedTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!_running || _protectedTickQueued) return;
      _protectedTickQueued = true;
      unawaited(
        _protectedSerial(_protectedTick)
            .catchError((Object _) {
              envelopeExperiment!.count('backgroundErrors');
            })
            .whenComplete(() => _protectedTickQueued = false),
      );
    });
  }

  Future<void> _protectedTick() async {
    if (!_running) return;
    _exitLastAttempt.removeWhere(
      (key, _) => !_exitJournal.rows.containsKey(key),
    );
    final now = _protectedNow;
    for (final item in _entryJournal.rows.entries.toList()) {
      if (item.value['expires'] as int <= now) {
        await _entryJournal.remove(item.key);
        _entryOrigins.remove(item.key);
        _entryLastForward.remove(item.key);
      } else if (now - (_entryLastForward[item.key] ?? 0) >= 3000) {
        await _forwardEntry(item.key, item.value);
      }
    }
    for (final item in _exitJournal.rows.entries.toList()) {
      if (item.value['expires'] as int <= now) {
        await _exitJournal.remove(item.key);
      } else if (item.value['released'] != true) {
        final link = _links[item.value['from']];
        if (link != null && !link.closed) await _releaseGroup(item.key, link);
      }
    }
    for (final record in _pendingPublications.values.toList()) {
      if (!_running) return;
      if (record.state == 'echoed' || record.state == 'failed') continue;
      if (_hasPublicObject(record.type, record.id)) {
        await _markEchoed(record);
        continue;
      }
      final config = envelopeExperiment!;
      final deadline = record.ackedWallMs != null
          ? config.echoDeadline.inMilliseconds
          : config.ackDeadline.inMilliseconds;
      final since = record.ackedWallMs ?? record.sealedWallMs ?? 0;
      if (record.state == 'composed' || now - since >= deadline) {
        if (record.attempts >= config.maxAttempts) {
          record.state = 'failed';
          record.failedMs = _clock.elapsedMilliseconds;
          config.count('failed');
          await _savePending(record);
        } else {
          if (record.attempts > 0) record.exitIndex++;
          await _sealAndSend(record);
        }
      }
    }
  }

  bool _hasPublicObject(String type, String id) => switch (type) {
    'channel' => _store.channels.containsKey(id),
    'bulletin' => _store.bulletins.containsKey(id),
    _ => false,
  };

  Future<void> _savePending(PendingPublication record) =>
      _pendingJournal.put(record.id, record.toJson());

  Future<void> _reservePending() async {
    if (!_running || envelopeExperiment == null || _envelopeCrypto == null) {
      throw StateError('Protected publishing requires a running experiment');
    }
    while (_pendingPublications.length >= 100) {
      final old = _pendingPublications.values
          .where((p) => p.state == 'echoed')
          .firstOrNull;
      if (old == null) throw StateError('Pending publication capacity');
      await _pendingJournal.remove(old.id);
      _pendingPublications.remove(old.id);
    }
  }

  Future<SignedChannel> createProtectedChannel({
    required String name,
    String description = '',
  }) => _serial(
    () => _protectedSerial(() async {
      await _reservePending();
      // This laboratory entry point deliberately excludes recovery/channel keys:
      // normal createChannel writes those directly into the public store.
      if (channelKeys != null) {
        throw StateError('Recovery bundle staging is not implemented');
      }
      final start = Stopwatch()..start();
      final channel = SignedChannel.create(
        publisherIdentity,
        name: name,
        description: description,
      );
      final record = PendingPublication(
        id: channel.id,
        type: 'channel',
        value: channel.toJson(),
        composedMs: _clock.elapsedMilliseconds,
      );
      record.timings['composition'] = start.elapsedMilliseconds;
      await _stage(record);
      return channel;
    }),
  );

  Future<String> publishProtected({
    required String channelId,
    required String text,
    String runId = 'news',
    Uint8List? imageBytes,
  }) => _serial(
    () => _protectedSerial(() async {
      await _reservePending();
      final start = Stopwatch()..start();
      final credentials = await _publishingCredentials(channelId);
      final latest = _store.bulletins.values
          .map(SignedBulletin.fromJson)
          .where(
            (v) => v.channelId == channelId && v.sourceId == credentials.$1.id,
          )
          .fold<int>(0, (a, b) => max(a, b.sequence));
      await _store.advanceChannelSequence(channelId, latest);
      final image = imageBytes == null ? null : NewsImage.inspect(imageBytes);
      final bulletin = SignedBulletin.create(
        credentials.$1,
        authorization: credentials.$2,
        runId: runId,
        text: text,
        channelId: channelId,
        sequence: await _store.nextChannelSequence(channelId),
        image: image,
      );
      final record = PendingPublication(
        id: bulletin.id,
        type: 'bulletin',
        value: bulletin.toJson(),
        imageHash: image?.hash,
        imageDescriptor: image?.toJson(),
        composedMs: _clock.elapsedMilliseconds,
      );
      record.timings['composition'] = start.elapsedMilliseconds;
      if (image != null) {
        var stored = 0;
        await for (final file in _pendingImages.list()) {
          if (file is File) stored += await file.length();
        }
        if (stored + imageBytes!.length > 2 * 1024 * 1024) {
          throw StateError('Pending image capacity');
        }
        await _pendingImage(image.hash).writeAsBytes(imageBytes, flush: true);
      }
      await _stage(record);
      return bulletin.id;
    }),
  );

  Future<void> _stage(PendingPublication record) async {
    final config = envelopeExperiment!;
    record.exitIndex = config.nextExitIndex ?? 0;
    config.nextExitIndex = null;
    final watch = Stopwatch()..start();
    await _savePending(record);
    record.timings['initialJournal'] = watch.elapsedMilliseconds;
    _pendingPublications[record.id] = record;
    await _sealAndSend(record);
  }

  Future<void> resendProtected(String id) => _serial(
    () => _protectedSerial(() async {
      final record = _pendingPublications[id];
      if (record == null || record.state == 'echoed') return;
      record.attempts = 0;
      record.state = 'composed';
      record.ackedWallMs = null;
      await _savePending(record);
      await _sealAndSend(record);
    }),
  );

  Future<void> _sealAndSend(PendingPublication record) async {
    final config = envelopeExperiment!;
    final guard = _links[config.guardPeerId];
    if (!_running ||
        guard == null ||
        guard.closed ||
        !guard.envelope ||
        config.exitPeerIds.isEmpty) {
      return;
    }
    final exit =
        config.exitPeerIds[record.exitIndex % config.exitPeerIds.length];
    final guardKey = config.recipientKeys[guard.peerId],
        exitKey = config.recipientKeys[exit];
    if (guardKey == null ||
        exitKey == null ||
        exit == guard.peerId ||
        exit == identity.id) {
      return;
    }
    final meta = utf8.encode(
      jsonEncode({
        'type': record.type,
        'value': record.value,
        'image': ?record.imageDescriptor,
      }),
    );
    final image = record.imageHash == null
        ? Uint8List(0)
        : await _pendingImage(record.imageHash!).readAsBytes();
    if (meta.length > 32 * 1024 ||
        meta.length + image.length + 4 > _maxBundleBytes) {
      throw StateError('Protected bundle too large');
    }
    final bundle = Uint8List(4 + meta.length + image.length);
    ByteData.sublistView(bundle).setUint32(0, meta.length);
    bundle.setRange(4, 4 + meta.length, meta);
    bundle.setRange(4 + meta.length, bundle.length, image);
    final count = (bundle.length / EnvelopeCryptoWorker.chunkBytes).ceil();
    final attempt = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    record.attempts++;
    if (record.attempts > 1) config.count('resends');
    record.state = 'sealed';
    record.exitPeerId = exit;
    record.sealedMs = _clock.elapsedMilliseconds;
    record.sealedWallMs = _protectedNow;
    record.ackedWallMs = null;
    final crypto = Stopwatch(), sending = Stopwatch(), journal = Stopwatch();
    for (var i = 0; i < count; i++) {
      crypto.start();
      final cell = await _envelopeCrypto!.seal(
        {
          'o': record.id,
          'g': attempt,
          'i': i,
          'n': count,
          'p': base64Encode(
            bundle.sublist(
              i * EnvelopeCryptoWorker.chunkBytes,
              min(bundle.length, (i + 1) * EnvelopeCryptoWorker.chunkBytes),
            ),
          ),
        },
        exitId: exit,
        exitKey: exitKey,
        guardKey: guardKey,
      );
      crypto.stop();
      record.lastCellHash = EnvelopeCell.hash(cell);
      journal.start();
      await _savePending(record);
      journal.stop();
      sending.start();
      final sent = await _send(guard, {
        'type': 'envelope',
        'stage': 'entry',
        'cell': base64Encode(cell),
      });
      sending.stop();
      if (!sent) {
        config.count('cellSendRefused');
        break;
      }
      config.count('cellsSent');
      config.count('envelopeBytesSent', cell.length);
    }
    record.timings.addAll({
      'seal': crypto.elapsedMilliseconds,
      'send': sending.elapsedMilliseconds,
      'sealJournal': journal.elapsedMilliseconds,
    });
    await _savePending(record);
  }

  Future<void> _handleEnvelope(
    _Link link,
    Map<String, dynamic> frame,
  ) => _protectedSerial(() async {
    if (!_running || link.closed || !link.envelope) return;
    final stage = frame['stage'], encoded = frame['cell'];
    if (!{'entry', 'exit'}.contains(stage) ||
        encoded is! String ||
        encoded.length > 10924) {
      throw const FormatException('Envelope frame');
    }
    _traffic(link.peerId);
    if (!_allowGlobal(link, TrafficResource.envelopeDecryptions, 1)) {
      envelopeExperiment!.count('decryptDeferred');
      return;
    }
    final bytes = base64Decode(encoded);
    final config = envelopeExperiment!;
    config.count('envelopeBytesReceived', bytes.length);
    if (stage == 'entry') {
      if (config.silentAtEntry) return;
      final opened = await _envelopeCrypto!.openEntry(bytes);
      final exit = opened['exitId'] as String;
      // A lab-configured exit set also prevents an arbitrary routing oracle.
      if (!config.exitPeerIds.contains(exit) ||
          exit == identity.id ||
          exit == link.peerId) {
        return;
      }
      final inner = opened['cell'] as Uint8List;
      final hash = EnvelopeCell.hash(inner),
          outerHash = EnvelopeCell.hash(bytes);
      final existing = _entryJournal.rows[hash];
      if (existing != null && existing['from'] != link.peerId) return;
      if (existing == null &&
          _entryJournal.rows.values
                  .where((r) => r['from'] == link.peerId)
                  .length >=
              24) {
        config.count('entryCapacity');
        return;
      }
      final row =
          existing ??
          {
            'from': link.peerId,
            'exit': exit,
            'outerHash': outerHash,
            'cell': base64Encode(inner),
            'expires': _protectedNow + _lifetimeMs,
          };
      try {
        await _entryJournal.put(hash, row);
      } on StateError {
        config.count('entryCapacity');
        return;
      }
      _entryOrigins[hash] = row;
      config.count('cellsReceivedAtEntry');
      await _send(link, {
        'type': 'envelopeAck',
        'stage': 'entry',
        'hash': outerHash,
      });
      await _forwardEntry(hash, row);
    } else {
      // The entry cannot authenticate opaque inner ciphertext on behalf of
      // publishers. Invalid inner contents consume work but no transport strike.
      try {
        final inner = await _envelopeCrypto!.openExit(bytes);
        await _acceptFragment(link, inner, EnvelopeCell.hash(bytes));
      } on FormatException {
        config.count('invalidRelayedObjects');
      }
    }
  });

  Future<void> _forwardEntry(String hash, Map<String, dynamic> row) async {
    if (envelopeExperiment!.dropAtEntry) return;
    final exit = _links[row['exit']];
    if (exit == null || exit.closed || !exit.envelope) {
      envelopeExperiment!.count('exitUnreachable');
      return;
    }
    _entryLastForward[hash] = _protectedNow;
    if (await _send(exit, {
      'type': 'envelope',
      'stage': 'exit',
      'cell': row['cell'],
    })) {
      envelopeExperiment!.count('cellsForwarded');
      envelopeExperiment!.count(
        'envelopeBytesSent',
        EnvelopeCryptoWorker.innerSize,
      );
    }
  }

  Future<void> _acceptFragment(
    _Link link,
    Map<String, dynamic> inner,
    String hash,
  ) async {
    final id = inner['o'],
        group = inner['g'],
        i = inner['i'],
        count = inner['n'],
        payload = inner['p'];
    if (inner.length != 5 ||
        id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        group is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(group) ||
        i is! int ||
        count is! int ||
        count < 1 ||
        count > _maxFragments ||
        i < 0 ||
        i >= count ||
        payload is! String ||
        payload.length > 7468) {
      throw const FormatException('Envelope fragment');
    }
    final bytes = base64Decode(payload);
    if (bytes.isEmpty ||
        bytes.length > EnvelopeCryptoWorker.chunkBytes ||
        (i < count - 1 && bytes.length != EnvelopeCryptoWorker.chunkBytes)) {
      throw const FormatException('Fragment length');
    }
    final key = sha256
        .convert(utf8.encode('${link.peerId}:$id:$group'))
        .toString();
    final old = _exitJournal.rows[key];
    if (old == null) {
      final active = _exitJournal.rows.values.where(
        (r) => r['released'] != true,
      );
      if (active.length >= 16 ||
          active.where((r) => r['from'] == link.peerId).length >= 4) {
        envelopeExperiment!.count('exitCapacity');
        return;
      }
      while (_exitJournal.rows.length >= 120) {
        final done = _exitJournal.rows.entries
            .where((r) => r.value['released'] == true)
            .firstOrNull;
        if (done == null) return;
        await _exitJournal.remove(done.key);
      }
    }
    if (old?['released'] != true) {
      if (old != null && old['count'] != count) {
        throw const FormatException('Fragment count changed');
      }
      final parts = Map<String, dynamic>.from(old?['parts'] as Map? ?? {});
      if (parts.containsKey('$i') && parts['$i'] != payload) {
        throw const FormatException('Fragment changed');
      }
      parts['$i'] = payload;
      final row = {
        'id': id,
        'from': link.peerId,
        'count': count,
        'parts': parts,
        'expires': old?['expires'] ?? _protectedNow + _lifetimeMs,
        'released': false,
      };
      try {
        await _exitJournal.put(key, row);
      } on StateError {
        envelopeExperiment!.count('exitCapacity');
        return;
      }
    }
    envelopeExperiment!.count('cellsReceivedAtExit');
    await _send(link, {'type': 'envelopeAck', 'stage': 'exit', 'hash': hash});
    await _releaseGroup(key, link);
  }

  Future<void> _releaseGroup(String key, _Link physical) async {
    try {
      await _releaseGroupImpl(key, physical);
    } on FormatException {
      await _exitJournal.remove(key);
      envelopeExperiment!.count('invalidRelayedObjects');
    } on TypeError {
      await _exitJournal.remove(key);
      envelopeExperiment!.count('invalidRelayedObjects');
    }
  }

  Future<void> _releaseGroupImpl(String key, _Link physical) async {
    final row = _exitJournal.rows[key];
    final config = envelopeExperiment!;
    if (!_running ||
        physical.closed ||
        row == null ||
        row['released'] == true ||
        config.dropAtExit ||
        config.holdAtExit) {
      return;
    }
    final parts = row['parts'] as Map;
    if (parts.length != row['count']) return;
    final lastAttempt = _exitLastAttempt[key];
    if (lastAttempt != null && _clock.elapsedMilliseconds - lastAttempt < 3000) {
      return;
    }
    _exitLastAttempt[key] = _clock.elapsedMilliseconds;
    _traffic(physical.peerId);
    if (!_allowGlobal(physical, TrafficResource.relayAdmissions, 1)) {
      config.count('relayAdmissionDeferred');
      return;
    }
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < parts.length; i++) {
      builder.add(base64Decode(parts['$i'] as String));
    }
    final bytes = builder.takeBytes();
    if (bytes.length < 4 || bytes.length > _maxBundleBytes) {
      throw const FormatException('Bundle length');
    }
    final length = ByteData.sublistView(bytes).getUint32(0);
    if (length > 32 * 1024 || length + 4 > bytes.length) {
      throw const FormatException('Bundle metadata');
    }
    final meta = jsonDecode(
      utf8.decode(bytes.sublist(4, 4 + length)),
    ) as Map<String, dynamic>;
    final type = meta['type'],
        value = Map<String, dynamic>.from(meta['value'] as Map);
    if (!{'channel', 'bulletin'}.contains(type) || value['id'] != row['id']) {
      throw const FormatException('Bundle object');
    }
    NewsImage? image;
    final media = Uint8List.sublistView(bytes, 4 + length);
    if (meta['image'] != null) {
      image = NewsImage.fromJson(
        Map<String, dynamic>.from(meta['image'] as Map),
      );
      final actual = NewsImage.inspect(media);
      if (jsonEncode(image.toJson()) != jsonEncode(actual.toJson()) ||
          type != 'bulletin' ||
          SignedBulletin.fromJson(value).image?.hash != image.hash) {
        throw const FormatException('Bundle image');
      }
    } else if (media.isNotEmpty ||
        (type == 'bulletin' && SignedBulletin.fromJson(value).image != null)) {
      throw const FormatException('Missing image');
    }
    // No new slot, ingress charge, or invented peer. Verification and receiver
    // object budgets still apply, charged to the physical entry's allowance.
    final ingress =
        _Link(
            physical.socket,
            'relayed',
            true,
            transport: physical.transport,
            routeId: physical.routeId,
            connectedAtMs: physical.connectedAtMs,
            allowance: physical.allowance,
            relayIngress: true,
          )
          ..modern = true
          ..ownerRecovery = true;
    final previouslyPublic = _hasPublicObject(
      type as String,
      row['id'] as String,
    );
    final rejectedBefore = config.stats['invalidRelayedObjects'] ?? 0;
    try {
      if (!previouslyPublic) {
        await _handle(ingress, {'type': type, 'value': value});
      }
    } on FormatException {
      _discardPublisherObject(ingress, 'invalid_relay_object');
      await _exitJournal.remove(key);
      return;
    }
    if (!_hasPublicObject(type, row['id'] as String)) {
      if ((config.stats['invalidRelayedObjects'] ?? 0) > rejectedBefore) {
        await _exitJournal.remove(key);
      }
      return;
    }
    if (image != null) {
      final admitted = SignedBulletin.fromJson(_store.bulletins[row['id']]!);
      if (admitted.image?.hash != image.hash) {
        throw const FormatException('Image is not referenced by admitted news');
      }
      if (!_media.has(image.hash)) {
        await _media.put(image, media);
        for (final link in _links.values.toList()) {
          await _sendInventory(link);
        }
      }
    }
    await _exitJournal.put(key, {
      'id': row['id'],
      'from': row['from'],
      'released': true,
      'expires': row['expires'],
    });
    config.count(
      previouslyPublic ? 'duplicateRelayObjects' : 'objectsReleased',
    );
    config.note('released', _clock.elapsedMilliseconds, {'id': row['id']});
  }

  Future<void> releaseHeldRelayedObjects(String viaPeerId) =>
      _protectedSerial(() async {
        final link = _links[viaPeerId];
        if (link == null) return;
        for (final item in _exitJournal.rows.entries.toList()) {
          if (item.value['from'] == viaPeerId) {
            await _releaseGroup(item.key, link);
          }
        }
      });

  Future<void> _handleEnvelopeAck(_Link link, Map<String, dynamic> frame) =>
      _protectedSerial(() async {
        final hash = frame['hash'], stage = frame['stage'];
        if (hash is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
            !{'entry', 'exit'}.contains(stage)) {
          throw const FormatException('Envelope acknowledgement');
        }
        final row = _entryOrigins[hash];
        if (stage == 'exit' && row != null && row['exit'] == link.peerId) {
          final publisher = _links[row['from']];
          if (publisher != null) {
            await _send(publisher, {
              'type': 'envelopeAck',
              'stage': 'exit',
              'hash': row['outerHash'],
            });
          }
          await _entryJournal.remove(hash);
          _entryOrigins.remove(hash);
          _entryLastForward.remove(hash);
        }
        if (link.peerId != envelopeExperiment!.guardPeerId) return;
        for (final record in _pendingPublications.values) {
          if (record.lastCellHash != hash ||
              record.state == 'echoed' ||
              record.state == 'failed') {
            continue;
          }
          record.ackedWallMs ??= _protectedNow;
          record.ackedMs ??= _clock.elapsedMilliseconds;
          record.state = 'acked';
          if (stage == 'exit') {
            record.exitAckedMs = _clock.elapsedMilliseconds;
            envelopeExperiment!.count('exitAcks');
          } else {
            envelopeExperiment!.count('entryAcks');
          }
          await _savePending(record);
        }
      });

  Future<void> _protectedEchoed(String id) =>
      _protectedSerial(() async {
        final record = _pendingPublications[id];
        if (record != null && record.state != 'echoed') {
          await _markEchoed(record);
        }
      }).catchError((Object _) {
        envelopeExperiment?.count('journalErrors');
      });

  Future<void> _markEchoed(PendingPublication record) async {
    record.state = 'echoed';
    record.echoedMs = _clock.elapsedMilliseconds;
    record.echoedWallMs = _protectedNow;
    await _savePending(record);
    envelopeExperiment!.count('echoed');
    await _prunePendingImages();
  }

  Future<void> _prunePendingImages() async {
    final retained = _pendingPublications.values
        .where((p) => p.state != 'echoed')
        .map((p) => p.imageHash)
        .whereType<String>()
        .toSet();
    await for (final file in _pendingImages.list()) {
      final name = file.uri.pathSegments.last;
      if (file is File &&
          RegExp(r'^[a-f0-9]{64}\.jpg$').hasMatch(name) &&
          !retained.contains(name.substring(0, 64))) {
        await file.delete();
      }
    }
  }
}
