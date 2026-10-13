import 'dart:convert';
import 'dart:io';

import 'peer_contact.dart';

/// App-private bounded contact cache. No publisher/subscription information.
class PeerContactStore {
  PeerContactStore(this.directory, {this.allowLoopbackForTesting = false});
  final Directory directory;
  final bool allowLoopbackForTesting;
  static const maxContacts = 16;
  static const maxBytes = 80 * 1024;
  File get _file => File('${directory.path}/helper-contacts.json');
  Future<void> _tail = Future.value();

  Future<List<PeerContact>> load() => _load(false);
  Future<List<PeerContact>> loadForReconnect() => _load(true);

  Future<List<PeerContact>> _load(bool reconnect) async {
    try {
      if (!await _file.exists() || await _file.length() > maxBytes) return [];
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['contacts'] is! List ||
          (raw['contacts'] as List).length > maxContacts) {
        return [];
      }
      final result = <String, PeerContact>{};
      for (final item in raw['contacts'] as List) {
        try {
          if (item is! Map<String, dynamic>) continue;
          final contact = reconnect
              ? PeerContact.readCached(
                  item,
                  allowLoopbackForTesting: allowLoopbackForTesting,
                )
              : PeerContact.parse(
                  item,
                  allowLoopbackForTesting: allowLoopbackForTesting,
                );
          final previous = result[contact.id];
          if (previous == null || contact.issuedAtMs > previous.issuedAtMs) {
            result[contact.id] = contact;
          }
        } on FormatException {
          /* An expired/bad record cannot suppress others. */
        }
      }
      return result.values.toList();
    } on FileSystemException {
      return [];
    } on FormatException {
      return [];
    }
  }

  Future<void> save(Iterable<PeerContact> contacts) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = contacts
        .where(
          (contact) =>
              contact.expiresAtMs + PeerContact.maxReconnectAgeMs > now,
        )
        .take(maxContacts)
        .map((contact) => contact.toJson())
        .toList();
    final encoded = jsonEncode({'version': 1, 'contacts': values});
    if (utf8.encode(encoded).length > maxBytes) {
      throw StateError('Contact cache is too large.');
    }
    final operation = _tail.then((_) async {
      await directory.create(recursive: true);
      final pending = File('${_file.path}.next');
      await pending.writeAsString(encoded, flush: true);
      await pending.rename(_file.path);
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
