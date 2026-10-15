import 'dart:convert';
import 'dart:io';

import 'channels.dart';
import 'owner_authority.dart';

/// Public recovery proofs retained independently of the evictable news journal.
/// A corrupt committed checkpoint fails closed rather than restoring an older
/// owner's authority. This does not protect against an attacker rolling back
/// every file on a compromised device.
class OwnerAuthorityCheckpoint {
  OwnerAuthorityCheckpoint(this.directory);
  final Directory directory;
  static const maxEntries = 128;
  static const maxBytes = 3 * 1024 * 1024;
  final Map<String, Map<String, dynamic>> _rows = {};
  final Map<String, OwnerAuthority> _verified = {};
  bool _loaded = false;
  bool get isLoaded => _loaded;
  File get _file => File('${directory.path}/owner-authorities.json');
  File get _next => File('${_file.path}.next');
  File get _backup => File('${_file.path}.bak');
  File get _initialized => File('${_file.path}.initialized');

  OwnerAuthority? known(SignedChannel channel) {
    if (!_loaded) throw StateError('Owner checkpoint is not loaded.');
    final row = _rows[channel.id];
    return row == null
        ? null
        : _verified.putIfAbsent(
            channel.id,
            () => OwnerAuthority.parse(
              Map<String, dynamic>.from(row['authority'] as Map),
              channel,
            ),
          );
  }

  Future<Map<String, Map<String, dynamic>>> _read(File source) async {
    if (await source.length() > maxBytes) throw const FormatException();
    final raw = jsonDecode(await source.readAsString());
    if (raw is! Map ||
        raw.length != 2 ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['entries'] is! Map ||
        (raw['entries'] as Map).length > maxEntries) {
      throw const FormatException();
    }
    final entries = <String, Map<String, dynamic>>{};
    for (final row in (raw['entries'] as Map).entries) {
      if (row.value is! Map || (row.value as Map).length != 2) {
        throw const FormatException();
      }
      final channel = SignedChannel.fromJson(
        Map<String, dynamic>.from(row.value['channel'] as Map),
      );
      final authority = OwnerAuthority.parse(
        Map<String, dynamic>.from(row.value['authority'] as Map),
        channel,
      );
      if (row.key != channel.id) throw const FormatException();
      entries[channel.id] = {
        'channel': channel.toJson(),
        'authority': authority.toJson(),
      };
    }
    return entries;
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      Map<String, Map<String, dynamic>> rows = {};
      final committed = await _file.exists();
      if (committed) {
        // Do not hide corruption of an acknowledged generation with a backup.
        rows = await _read(_file);
      } else if (await _backup.exists()) {
        rows = await _read(_backup);
      }
      var recoveredPending = false;
      if (await _next.exists()) {
        try {
          final pending = await _read(_next);
          for (final row in pending.entries) {
            final channel = SignedChannel.fromJson(
              Map<String, dynamic>.from(row.value['channel'] as Map),
            );
            final incoming = OwnerAuthority.parse(
              Map<String, dynamic>.from(row.value['authority'] as Map),
              channel,
            );
            final prior = rows[row.key];
            final merged = prior == null
                ? incoming
                : OwnerAuthority.parse(
                    Map<String, dynamic>.from(prior['authority'] as Map),
                    channel,
                  ).merge(incoming);
            rows[row.key] = {
              'channel': channel.toJson(),
              'authority': merged.toJson(),
            };
          }
          recoveredPending = true;
        } on FormatException {
          // An incomplete unacknowledged write can leave a torn pending file.
        }
      }
      if (!committed && rows.isEmpty && await _initialized.exists()) {
        throw const FormatException();
      }
      if (recoveredPending || (!committed && rows.isNotEmpty)) {
        await _commit(rows);
      }
      _rows
        ..clear()
        ..addAll(rows);
      _verified.clear();
      _loaded = true;
    } catch (_) {
      throw StateError(
        'Owner recovery proofs could not be read. Older authority was not restored.',
      );
    }
  }

  Future<OwnerAuthority> remember(
    OwnerAuthority incoming,
    SignedChannel channel,
  ) async {
    await load();
    final verified = OwnerAuthority.parse(incoming.toJson(), channel);
    final previous = known(channel);
    final merged = previous?.merge(verified) ?? verified;
    if (previous?.id == merged.id) return merged;
    if (previous == null && _rows.length >= maxEntries) {
      throw StateError(
        'Owner recovery proof storage is full. Existing authority was preserved.',
      );
    }
    final rows = {
      ..._rows,
      channel.id: {'channel': channel.toJson(), 'authority': merged.toJson()},
    };
    try {
      await _commit(rows);
      _rows
        ..clear()
        ..addAll(rows);
      _verified[channel.id] = merged;
      return merged;
    } catch (_) {
      _loaded = false;
      try {
        await load();
        // A cleanup error after the commit must not turn a durable authority
        // advance into an apparent rollback or require regenerating keys.
        if (known(channel)?.id == merged.id) return merged;
      } catch (_) {
        // Remain fail-closed while the underlying storage is unavailable.
      }
      rethrow;
    }
  }

  Future<void> _commit(Map<String, Map<String, dynamic>> rows) async {
    final encoded = jsonEncode({'version': 1, 'entries': rows});
    if (rows.length > maxEntries || utf8.encode(encoded).length > maxBytes) {
      throw StateError('Owner recovery proof storage is full.');
    }
    await directory.create(recursive: true);
    // A failed first pending write has never acknowledged any authority.
    // Do not mark that empty store initialized until a complete proof is durable.
    await _next.writeAsString(encoded, flush: true);
    if (!await _initialized.exists()) {
      await _initialized.writeAsString('1', flush: true);
    }
    if (await _file.exists()) {
      if (await _backup.exists()) await _backup.delete();
      await _file.rename(_backup.path);
    }
    await _next.rename(_file.path);
    if (await _backup.exists()) await _backup.delete();
  }
}
