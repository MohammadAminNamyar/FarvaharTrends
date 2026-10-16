import 'dart:convert';
import 'dart:io';

/// Entirely local reading state. Not included in peer messages or reports.
class ReaderState {
  ReaderState(this.directory, {this.acquire, this.release});
  final Directory directory;
  final Future<String> Function()? acquire;
  final Future<void> Function(String)? release;
  bool notifications = true, initialized = false;
  String? recoveryWarning;
  String images = 'wifiOnly';
  final Set<String> readIds = {}, seenIds = {}, muted = {};
  Future<void> _tail = Future.value();
  File get _file => File('${directory.path}/reader-state.json');
  static final _id = RegExp(r'^[a-f0-9]{64}$');
  Future<void> load() => _transaction(() async {}, persist: false);
  Future<void> markRead(Iterable<String> ids) => _transaction(() async {
    for (final id in ids.where(_id.hasMatch)) {
      readIds.remove(id);
      readIds.add(id);
    }
  });
  Future<void> setNotifications(bool enabled) => _transaction(() async {
    notifications = enabled;
  });
  Future<void> setImages(String mode) => _transaction(() async {
    if (!{'wifiOnly', 'any', 'never'}.contains(mode)) {
      throw ArgumentError('Invalid image preference.');
    }
    images = mode;
  });
  Future<void> setMuted(String id, bool value) => _transaction(() async {
    if (!_id.hasMatch(id)) throw ArgumentError('Invalid channel.');
    value ? muted.add(id) : muted.remove(id);
  });
  Future<List<Map<String, dynamic>>> observe(
    List<Map<String, dynamic>> news,
    Set<String> followed,
    Set<String> blocked,
  ) async {
    final arrivals = <Map<String, dynamic>>[];
    await _transaction(() async {
      for (final item in news) {
        final id = item['id'], channel = item['channelId'];
        if (id is! String || channel is! String) continue;
        if (!initialized || item['receivedVia'] == 'local') readIds.add(id);
        if (initialized &&
            !seenIds.contains(id) &&
            !readIds.contains(id) &&
            notifications &&
            followed.contains(channel) &&
            !blocked.contains(channel) &&
            !muted.contains(channel)) {
          arrivals.add(item);
        }
        seenIds.add(id);
      }
      initialized = true;
    }, protectedIds: news.map((n) => n['id']).whereType<String>().toSet());
    return arrivals;
  }

  Future<void> _transaction(
    Future<void> Function() action, {
    bool persist = true,
    Set<String> protectedIds = const {},
  }) {
    final result = _tail.then((_) async {
      final token = await acquire?.call();
      try {
        await directory.create(recursive: true);
        await _load();
        final before = _encode();
        try {
          await action();
          while (readIds.length > 2048) {
            readIds.remove(
              readIds.firstWhere(
                (id) => !protectedIds.contains(id),
                orElse: () => readIds.first,
              ),
            );
          }
          while (seenIds.length > 2048) {
            seenIds.remove(
              seenIds.firstWhere(
                (id) => !protectedIds.contains(id),
                orElse: () => seenIds.first,
              ),
            );
          }
          if (muted.length > 128) throw StateError('Too many muted channels.');
          final after = jsonEncode(_encode());
          // Keep the lease and reload: the UI and receiver share this file.
          // An unchanged observation needs no flush/rename cycle.
          if (persist &&
              (jsonEncode(before) != after || !await _file.exists())) {
            final pending = File('${_file.path}.next');
            await pending.writeAsString(after, flush: true);
            final backup = File('${_file.path}.bak');
            if (await backup.exists()) await backup.delete();
            if (await _file.exists()) await _file.rename(backup.path);
            await pending.rename(_file.path);
            if (await backup.exists()) await backup.delete();
          }
        } catch (_) {
          _restore(before);
          rethrow;
        }
      } finally {
        if (token != null) await release!(token);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Map<String, dynamic> _encode() => {
    'initialized': initialized,
    'notifications': notifications,
    'images': images,
    'read': readIds.toList(),
    'seen': seenIds.toList(),
    'muted': muted.toList(),
    'version': 1,
  };
  void _restore(Map<String, dynamic> value) {
    initialized = value['initialized'] as bool;
    notifications = value['notifications'] as bool;
    images = value['images'] as String;
    readIds
      ..clear()
      ..addAll((value['read'] as List).cast<String>());
    seenIds
      ..clear()
      ..addAll((value['seen'] as List).cast<String>());
    muted
      ..clear()
      ..addAll((value['muted'] as List).cast<String>());
  }

  Future<void> _load() async {
    final backup = File('${_file.path}.bak');
    if (!await _file.exists() && await backup.exists()) {
      await backup.rename(_file.path);
    }
    if (!await _file.exists()) return;
    try {
      if (await _file.length() > 512 * 1024) throw const FormatException();
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['initialized'] is! bool ||
          raw['notifications'] is! bool ||
          !{'wifiOnly', 'any', 'never'}.contains(raw['images'])) {
        throw const FormatException();
      }
      final sets = <Set<String>>[];
      for (final key in ['read', 'seen', 'muted']) {
        final list = raw[key];
        if (list is! List ||
            list.length > (key == 'muted' ? 128 : 2048) ||
            list.any((id) => id is! String || !_id.hasMatch(id))) {
          throw const FormatException();
        }
        sets.add(list.cast<String>().toSet());
      }
      initialized = raw['initialized'] as bool;
      notifications = raw['notifications'] as bool;
      images = raw['images'] as String;
      readIds
        ..clear()
        ..addAll(sets[0]);
      seenIds
        ..clear()
        ..addAll(sets[1]);
      muted
        ..clear()
        ..addAll(sets[2]);
    } catch (_) {
      // Fail quietly closed for alerts and images, preserving the exact input.
      notifications = false;
      images = 'never';
      initialized = false;
      readIds.clear();
      seenIds.clear();
      muted.clear();
      final quarantined = File('${_file.path}.corrupt');
      if (await quarantined.exists()) await quarantined.delete();
      await _file.rename(quarantined.path);
      await _file.writeAsString(jsonEncode(_encode()), flush: true);
      recoveryWarning =
          'Reading settings were reset; alerts and images are off.';
    }
  }
}
