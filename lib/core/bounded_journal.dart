import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Bounded app-private WAL. A durable append precedes the in-memory change.
/// Only a torn final line can be recovered; corruption of a committed line fails
/// closed rather than silently rolling publication/acknowledgement state back.
class BoundedJournal {
  BoundedJournal(
    this.file, {
    this.maxEntries = 128,
    this.maxStateBytes = 1024 * 1024,
    this.maxJournalBytes = 3 * 1024 * 1024,
  });
  final File file;
  final int maxEntries, maxStateBytes, maxJournalBytes;
  final Map<String, Map<String, dynamic>> _rows = {};
  final Map<String, int> _sizes = {};
  int _stateBytes = 0, _diskBytes = 0;
  bool _loaded = false;
  Future<void> _tail = Future.value();
  Map<String, Map<String, dynamic>> get rows => UnmodifiableMapView(_rows);
  int get stateBytes => _stateBytes;
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> load() => _serial(() async {
    if (_loaded) return;
    await file.parent.create(recursive: true);
    final backup = File('${file.path}.bak');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    if (await file.exists()) {
      if (await file.length() > maxJournalBytes + maxStateBytes * 2) {
        throw const FormatException('Envelope journal exceeds recovery limit');
      }
      final bytes = await file.readAsBytes();
      var start = 0;
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != 10) continue;
        final envelope =
            jsonDecode(utf8.decode(bytes.sublist(start, i))) as Map;
        final payload = envelope['payload'] as String;
        if (sha256.convert(utf8.encode(payload)).toString() !=
            envelope['sha256']) {
          throw const FormatException('Envelope journal checksum');
        }
        _apply(jsonDecode(payload) as Map<String, dynamic>);
        start = i + 1;
      }
      // Any bytes after the last newline are an uncommitted torn append.
    }
    await _compact();
    _loaded = true;
  });
  Future<void> put(String id, Map<String, dynamic> value) => _serial(() async {
    _requireLoaded();
    final copy = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    _check(id, copy);
    await _append({'op': 'put', 'id': id, 'value': copy});
  });
  Future<void> remove(String id) => _serial(() async {
    _requireLoaded();
    if (_rows.containsKey(id)) await _append({'op': 'remove', 'id': id});
  });
  void _requireLoaded() {
    if (!_loaded) throw StateError('Journal not loaded');
  }

  void _check(String id, Map<String, dynamic> value) {
    final size = utf8.encode(jsonEncode(value)).length + id.length;
    if (id.length > 128 ||
        (!_rows.containsKey(id) && _rows.length >= maxEntries) ||
        _stateBytes - (_sizes[id] ?? 0) + size > maxStateBytes) {
      throw StateError('Envelope journal capacity');
    }
  }

  void _apply(Map<String, dynamic> record) {
    switch (record['op']) {
      case 'snapshot':
        _rows.clear();
        _sizes.clear();
        _stateBytes = 0;
        for (final entry in (record['rows'] as Map).entries) {
          _put(
            entry.key as String,
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      case 'put':
        _put(
          record['id'] as String,
          Map<String, dynamic>.from(record['value'] as Map),
        );
      case 'remove':
        final id = record['id'] as String;
        _stateBytes -= _sizes.remove(id) ?? 0;
        _rows.remove(id);
      default:
        throw const FormatException('Unknown journal operation');
    }
  }

  void _put(String id, Map<String, dynamic> value) {
    _check(id, value);
    final size = utf8.encode(jsonEncode(value)).length + id.length;
    _stateBytes += size - (_sizes[id] ?? 0);
    _sizes[id] = size;
    _rows[id] = Map.unmodifiable(value);
  }

  List<int> _encode(Map<String, dynamic> record) {
    final payload = jsonEncode(record);
    return utf8.encode(
      '${jsonEncode({'payload': payload, 'sha256': sha256.convert(utf8.encode(payload)).toString()})}\n',
    );
  }

  Future<void> _append(Map<String, dynamic> record) async {
    final bytes = _encode(record);
    if (_diskBytes + bytes.length > maxJournalBytes) await _compact();
    if (_diskBytes + bytes.length > maxJournalBytes) {
      throw StateError('Journal disk capacity');
    }
    try {
      await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      _diskBytes += bytes.length;
      _apply(record);
    } catch (_) {
      _loaded = false;
      rethrow;
    }
  }

  Future<void> _compact() async {
    try {
      final bytes = _encode({'op': 'snapshot', 'rows': _rows});
      if (bytes.length > maxJournalBytes) throw StateError('Snapshot capacity');
      final next = File('${file.path}.next'), backup = File('${file.path}.bak');
      await next.writeAsBytes(bytes, flush: true);
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await file.rename(backup.path);
      await next.rename(file.path);
      if (await backup.exists()) await backup.delete();
      _diskBytes = bytes.length;
    } catch (_) {
      // Replacement may have moved the committed journal to .bak. Never
      // append to a new empty primary before load() recovers that state.
      _loaded = false;
      rethrow;
    }
  }

  Future<void> flush() => _tail;
}
