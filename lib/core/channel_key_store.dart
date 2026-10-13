import 'dart:convert';

import 'channel_control.dart';
import 'channels.dart';
import 'identity.dart';
import 'models.dart' show validateNewsByline;

/// Private key material. Production injects the platform's protected vault.
/// It is never written to the public journal or included in status snapshots.
class ChannelKeyStore {
  ChannelKeyStore({
    required this.read,
    required this.write,
    this.acquire,
    this.release,
  });
  final Future<String?> Function() read;
  final Future<void> Function(String) write;
  final Future<String> Function()? acquire;
  final Future<void> Function(String)? release;
  static const maxEntries = 32;
  static const maxPending = 8;
  final Map<String, Map<String, dynamic>> entries = {};
  final Map<String, Map<String, dynamic>> pending = {};
  Future<void> _tail = Future.value();

  Future<void> load() => _serial(() async {
    await _read();
  });
  Future<void> _read() async {
    final text = await read();
    if (text == null) {
      entries.clear();
      pending.clear();
      return;
    }
    try {
      if (utf8.encode(text).length > 1024 * 1024) throw const FormatException();
      final json = jsonDecode(text);
      if (json is! Map ||
          json['version'] != 1 ||
          json['entries'] is! Map ||
          json['pending'] is! Map ||
          (json['entries'] as Map).length > maxEntries ||
          (json['pending'] as Map).length > maxPending) {
        throw const FormatException();
      }
      final restored = <String, Map<String, dynamic>>{};
      for (final row in (json['entries'] as Map).entries) {
        final value = Map<String, dynamic>.from(row.value as Map);
        validateEntry(value);
        if (row.key != (value['channel'] as Map)['id']) {
          throw const FormatException();
        }
        restored[row.key as String] = value;
      }
      final requests = <String, Map<String, dynamic>>{};
      for (final row in (json['pending'] as Map).entries) {
        final identity = Identity.fromJson(
          Map<String, dynamic>.from(row.value as Map),
        );
        if (identity.id != row.key) throw const FormatException();
        requests[identity.id] = identity.toJson();
      }
      entries
        ..clear()
        ..addAll(restored);
      pending
        ..clear()
        ..addAll(requests);
    } catch (_) {
      throw const FormatException(
        'Channel keys could not be read. No keys were replaced.',
      );
    }
  }

  static void validateEntry(Map<String, dynamic> entry) {
    final fields = {
      'role',
      'channel',
      'identity',
      if (entry.containsKey('authorization')) 'authorization',
      if (entry.containsKey('grants')) 'grants',
      if (entry.containsKey('nickname')) 'nickname',
    };
    if (entry.length != fields.length || !entry.keys.every(fields.contains)) {
      throw const FormatException('Invalid channel key record.');
    }
    if (entry.containsKey('nickname')) {
      if (entry['nickname'] is! String) {
        throw const FormatException('Invalid nickname.');
      }
      validateNewsByline(entry['nickname'] as String);
    }
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(entry['channel'] as Map),
    );
    final identity = Identity.fromJson(
      Map<String, dynamic>.from(entry['identity'] as Map),
    );
    ChannelControl? authorization;
    if (entry['authorization'] is Map) {
      authorization = ChannelControl.parse(
        Map<String, dynamic>.from(entry['authorization'] as Map),
        channel,
      );
    }
    if (entry.containsKey('grants')) {
      final grants = entry['grants'];
      if (entry['role'] != 'owner' ||
          grants is! List ||
          grants.length > ChannelControl.maxEditors) {
        throw const FormatException('Invalid editor list.');
      }
      for (final raw in grants) {
        if (raw is Map &&
            raw.length == 3 &&
            raw['id'] is String &&
            raw['label'] is String &&
            raw['fingerprint'] is String) {
          if (!ChannelControl.fingerprint.hasMatch(raw['id'] as String) ||
              !ChannelControl.fingerprint.hasMatch(
                raw['fingerprint'] as String,
              ) ||
              (raw['label'] as String).isEmpty ||
              (raw['label'] as String).length > 80 ||
              utf8.encode(raw['label'] as String).length > 256 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw['label'] as String)) {
            throw const FormatException('Invalid editor summary.');
          }
          continue;
        }
        final grant = ChannelControl.parse(
          Map<String, dynamic>.from(raw as Map),
          channel,
        );
        if (grant.kind != 'editor' || grant.signerId != identity.id) {
          throw const FormatException('Invalid editor authority.');
        }
      }
    }
    if (entry['role'] == 'owner') {
      if (authorization != null &&
          (authorization.kind != 'manager' ||
              authorization.managerId != identity.id)) {
        throw const FormatException('Invalid manager key.');
      }
      if (identity.id != channel.ownerId &&
          (authorization?.kind != 'manager' ||
              authorization?.managerId != identity.id)) {
        throw const FormatException('Invalid channel ownership.');
      }
    } else if (entry['role'] == 'editor') {
      if (authorization?.kind != 'editor' ||
          authorization?.editorId != identity.id) {
        throw const FormatException('Invalid editor key.');
      }
    } else {
      throw const FormatException('Invalid channel role.');
    }
  }

  Future<void> put(Map<String, dynamic> entry) => _serial(() async {
    validateEntry(entry);
    await _read();
    final id = (entry['channel'] as Map)['id'] as String;
    if (!entries.containsKey(id) && entries.length >= maxEntries) {
      throw StateError('Channel key storage is full.');
    }
    final existing = entries[id];
    if (existing?['role'] == 'owner' && entry['role'] != 'owner') {
      throw StateError(
        'An editor invitation cannot replace channel ownership.',
      );
    }
    final next = {...entries, id: entry};
    final requests = {...pending}..remove((entry['identity'] as Map)['id']);
    await _persist(next, requests);
  });

  Future<void> putPending(Identity identity) => _serial(() async {
    await _read();
    if (pending.length >= maxPending) {
      throw StateError('Too many pending editor requests.');
    }
    await _persist(entries, {...pending, identity.id: identity.toJson()});
  });

  Future<void> _persist(
    Map<String, Map<String, dynamic>> next,
    Map<String, Map<String, dynamic>> requests,
  ) async {
    final encoded = jsonEncode({
      'version': 1,
      'entries': next,
      'pending': requests,
    });
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw StateError('Channel key storage is full. No keys were replaced.');
    }
    await write(encoded);
    entries
      ..clear()
      ..addAll(next);
    pending
      ..clear()
      ..addAll(requests);
  }

  Future<void> _serial(Future<void> Function() action) {
    final result = _tail.then((_) async {
      final token = await acquire?.call();
      try {
        await action();
      } finally {
        if (token != null) await release!(token);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
