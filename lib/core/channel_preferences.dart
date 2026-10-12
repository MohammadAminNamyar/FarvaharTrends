import 'dart:convert';
import 'dart:io';

/// Private display preferences. Never include these in gossip, discovery, peer
/// requests or exported diagnostics: the bounded public relay cache is separate.
class ChannelPreferences {
  ChannelPreferences(this.directory);
  final Directory directory;
  static const maxEntries = 128;
  static const maxFileBytes = 32768;
  static final _id = RegExp(r'^[a-f0-9]{64}$');
  final Set<String> _followed = {};
  final Set<String> _blocked = {};
  final Set<String> _trusted = {};
  bool _loaded = false;
  String? _recoveryWarning;
  Future<void> _tail = Future<void>.value();

  Set<String> get followed => Set.unmodifiable(_followed);
  Set<String> get blocked => Set.unmodifiable(_blocked);
  Set<String> get trusted => Set.unmodifiable(_trusted);
  String? get recoveryWarning => _recoveryWarning;
  bool isFollowed(String id) =>
      _followed.contains(id) && !_blocked.contains(id);
  bool isBlocked(String id) => _blocked.contains(id);
  bool isTrusted(String id) => _trusted.contains(id) && !_blocked.contains(id);
  File get _file => File(
    '${directory.path}${Platform.pathSeparator}channel-preferences.json',
  );

  Future<void> _serial(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load() => _serial(_load);

  Future<void> _load() async {
    if (_loaded) return;
    await directory.create(recursive: true);
    final backup = File('${_file.path}.bak');
    if (!await _file.exists() && await backup.exists()) {
      await backup.rename(_file.path);
    }
    if (await _file.exists()) {
      try {
        if (await _file.length() > maxFileBytes) {
          throw const FormatException(
            'Channel preferences exceed the size limit.',
          );
        }
        final json = jsonDecode(utf8.decode(await _file.readAsBytes()));
        if (json is! Map<String, dynamic>) {
          throw const FormatException('Invalid channel preferences.');
        }
        final keys = switch (json['version']) {
          1 => {'version', 'followed', 'blocked'},
          2 => {'version', 'followed', 'blocked', 'trusted'},
          _ => null,
        };
        if (keys == null ||
            json.length != keys.length ||
            !json.keys.every(keys.contains)) {
          throw const FormatException('Invalid channel preferences.');
        }
        final followed = _readIds(json['followed']);
        final blocked = _readIds(json['blocked']);
        // A v1 file has no trust marks. Upgrade it on the next local mutation.
        final trusted = json['version'] == 2
            ? _readIds(json['trusted'])
            : <String>{};
        followed.removeAll(blocked);
        trusted.removeAll(blocked);
        _followed.addAll(followed);
        _blocked.addAll(blocked);
        _trusted.addAll(trusted);
      } on FormatException {
        // Keep the exact invalid bytes in the same private directory. A corrupt
        // display-preference file must not prevent loading the signing identity.
        var suffix = DateTime.now().microsecondsSinceEpoch;
        File quarantine;
        do {
          quarantine = File('${_file.path}.corrupt.${suffix++}');
        } while (await quarantine.exists());
        await _file.rename(quarantine.path);
        _followed.clear();
        _blocked.clear();
        _trusted.clear();
        await _persist({}, {}, {});
        _recoveryWarning =
            'Saved channel choices could not be read and were reset. '
            'The original file was preserved privately.';
      }
    }
    _loaded = true;
  }

  Set<String> _readIds(dynamic value) {
    if (value is! List ||
        value.length > maxEntries ||
        value.any((id) => id is! String || !_id.hasMatch(id))) {
      throw const FormatException('Invalid channel preference identifiers.');
    }
    return value.cast<String>().toSet();
  }

  Future<void> follow(String id) => _change(id, (followed, blocked, trusted) {
    blocked.remove(id);
    followed.add(id);
  });
  Future<void> unfollow(String id) =>
      _change(id, (followed, blocked, trusted) => followed.remove(id));
  Future<void> block(String id) => _change(id, (followed, blocked, trusted) {
    followed.remove(id);
    trusted.remove(id);
    blocked.add(id);
  });
  Future<void> unblock(String id) =>
      _change(id, (followed, blocked, trusted) => blocked.remove(id));
  Future<void> trust(String id) => _change(id, (followed, blocked, trusted) {
    if (blocked.contains(id)) {
      throw StateError('Unblock the channel before marking it trusted.');
    }
    trusted.add(id);
  });
  Future<void> untrust(String id) =>
      _change(id, (followed, blocked, trusted) => trusted.remove(id));

  Future<void> _change(
    String id,
    void Function(Set<String>, Set<String>, Set<String>) update,
  ) => _serial(() async {
    if (!_id.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Expected a channel fingerprint.');
    }
    await _load();
    final followed = Set<String>.of(_followed),
        blocked = Set<String>.of(_blocked),
        trusted = Set<String>.of(_trusted);
    update(followed, blocked, trusted);
    if (followed.length > maxEntries ||
        blocked.length > maxEntries ||
        trusted.length > maxEntries) {
      throw StateError(
        'At most $maxEntries followed, $maxEntries hidden and $maxEntries trusted channels are supported.',
      );
    }
    if (followed.length == _followed.length &&
        followed.containsAll(_followed) &&
        blocked.length == _blocked.length &&
        blocked.containsAll(_blocked) &&
        trusted.length == _trusted.length &&
        trusted.containsAll(_trusted)) {
      return;
    }
    await _persist(followed, blocked, trusted);
    _followed
      ..clear()
      ..addAll(followed);
    _blocked
      ..clear()
      ..addAll(blocked);
    _trusted
      ..clear()
      ..addAll(trusted);
  });

  Future<void> _persist(
    Set<String> followed,
    Set<String> blocked,
    Set<String> trusted,
  ) async {
    final next = File('${_file.path}.next'), backup = File('${_file.path}.bak');
    await next.writeAsString(
      jsonEncode({
        'version': 2,
        'followed': followed.toList()..sort(),
        'blocked': blocked.toList()..sort(),
        'trusted': trusted.toList()..sort(),
      }),
      flush: true,
    );
    if (await backup.exists()) await backup.delete();
    if (await _file.exists()) await _file.rename(backup.path);
    try {
      await next.rename(_file.path);
    } catch (_) {
      if (!await _file.exists() && await backup.exists()) {
        await backup.rename(_file.path);
      }
      rethrow;
    }
    // Commit already succeeded. A leftover backup is harmless and recoverable.
    try {
      if (await backup.exists()) await backup.delete();
    } on FileSystemException {
      /* Retain backup. */
    }
  }
}
