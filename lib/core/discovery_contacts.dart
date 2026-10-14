import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bootstrap_config.dart';
import 'identity.dart';

/// A helper explicitly advertises its discovery endpoint. This signature proves
/// the connection key's claim, not reachability, geography or publisher trust.
class DiscoveryContact {
  DiscoveryContact._(
    this.value,
    this.id,
    this.host,
    this.port,
    this.expiresAtMs,
  );

  static const lifetimeMs = 5 * 60 * 1000;
  static const reconnectMs = 7 * 24 * 60 * 60 * 1000;
  final Map<String, dynamic> value;
  final String id;
  final String host;
  final int port;
  final int expiresAtMs;
  String get endpoint => '$host:$port';

  static DiscoveryContact create(Identity identity, String host, int port) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'farvahartrends/discovery-contact/v1',
      'certificatePem': identity.certPem,
      'host': host,
      'port': port,
      'issuedAtMs': now,
      'expiresAtMs': now + lifetimeMs,
    };
    return parse({
      ...body,
      'signature': identity.sign(
        Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
    });
  }

  static DiscoveryContact parse(
    Map<String, dynamic> value, {
    bool forReconnect = false,
    int? nowMs,
  }) {
    if (value.length != 8 ||
        utf8.encode(jsonEncode(value)).length > 4096 ||
        value['version'] != 1 ||
        value['kind'] != 'farvahartrends/discovery-contact/v1' ||
        value['certificatePem'] is! String ||
        value['host'] is! String ||
        value['port'] is! int ||
        value['issuedAtMs'] is! int ||
        value['expiresAtMs'] is! int ||
        value['signature'] is! String) {
      throw const FormatException('Invalid discovery contact.');
    }
    final host = value['host'] as String;
    final port = value['port'] as int;
    if (normalizeDhtBootstrapEntry('$host:$port') != '$host:$port') {
      throw const FormatException('Invalid discovery address.');
    }
    final issued = value['issuedAtMs'] as int;
    final expires = value['expiresAtMs'] as int;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (issued < 0 ||
        expires > 9007199254740991 ||
        expires <= issued ||
        expires - issued > lifetimeMs ||
        issued > now + 30000 ||
        expires + (forReconnect ? reconnectMs : 0) <= now) {
      throw const FormatException('Discovery contact expired.');
    }
    final body = <String, dynamic>{
      'version': 1,
      'kind': 'farvahartrends/discovery-contact/v1',
      'certificatePem': value['certificatePem'],
      'host': host,
      'port': port,
      'issuedAtMs': issued,
      'expiresAtMs': expires,
    };
    final certificate = value['certificatePem'] as String;
    if (!Identity.verify(
      certificate,
      Uint8List.fromList(utf8.encode(jsonEncode(body))),
      value['signature'] as String,
    )) {
      throw const FormatException('Invalid discovery signature.');
    }
    return DiscoveryContact._(
      Map.unmodifiable({...body, 'signature': value['signature']}),
      Identity.certificateId(certificate),
      host,
      port,
      expires,
    );
  }
}

/// Bounded, app-private unverified hints. Expired hints may be probed locally,
/// but never forwarded. A successful DHT probe is recorded by the worklet in a
/// separate routing cache. One introducer cannot fill this entire hint store.
class DiscoveryContacts {
  DiscoveryContacts(this.directory);
  final Directory directory;
  static const maxContacts = 16;
  final Map<String, DiscoveryContact> contacts = {};
  final Map<String, String> _sources = {};
  File get _file => File('${directory.path}/discovery-contacts.json');
  Future<void> _tail = Future.value();

  void expire() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in contacts.keys.toList()) {
      if (contacts[key]!.expiresAtMs + DiscoveryContact.reconnectMs <= now) {
        contacts.remove(key);
        _sources.remove(key);
      }
    }
  }

  bool add(DiscoveryContact contact, String introducedBy) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(introducedBy)) return false;
    expire();
    final key = '${contact.id}@${contact.endpoint}';
    final previous = contacts[key];
    if (previous != null && previous.expiresAtMs >= contact.expiresAtMs) {
      return false;
    }
    if (previous == null) {
      // Keep room for a helper whose mobile address changes. Replacement is
      // limited to older leases from that owner, or expired hints; live hints
      // from other owners cannot be evicted by fresh unverified identities.
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldest = contacts.keys.toList()
        ..sort(
          (a, b) =>
              contacts[a]!.expiresAtMs.compareTo(contacts[b]!.expiresAtMs),
        );
      final remove = <String>{};
      final sameOwner = oldest
          .where((k) => contacts[k]!.id == contact.id)
          .toList();
      if (sameOwner.length >= 2) {
        if (contacts[sameOwner.first]!.expiresAtMs >= contact.expiresAtMs) {
          return false;
        }
        remove.add(sameOwner.first);
      }
      final sameSource = oldest
          .where((k) => !remove.contains(k) && _sources[k] == introducedBy)
          .toList();
      if (sameSource.length >= 4) {
        if (contacts[sameSource.first]!.expiresAtMs > now) return false;
        remove.add(sameSource.first);
      }
      if (contacts.length - remove.length >= maxContacts) {
        final expired = oldest.where(
          (k) => !remove.contains(k) && contacts[k]!.expiresAtMs <= now,
        );
        if (expired.isEmpty) return false;
        remove.add(expired.first);
      }
      for (final old in remove) {
        contacts.remove(old);
        _sources.remove(old);
      }
      if (contacts.length >= maxContacts ||
          _sources.values.where((v) => v == introducedBy).length >= 4 ||
          contacts.values.where((v) => v.id == contact.id).length >= 2) {
        return false;
      }
    }
    contacts[key] = contact;
    _sources.putIfAbsent(key, () => introducedBy);
    return true;
  }

  void remove(String id) {
    for (final key in contacts.keys.toList()) {
      if (contacts[key]!.id == id || _sources[key] == id) {
        contacts.remove(key);
        _sources.remove(key);
      }
    }
  }

  List<DiscoveryContact> get fresh {
    expire();
    final now = DateTime.now().millisecondsSinceEpoch;
    return contacts.values.where((c) => c.expiresAtMs > now).toList();
  }

  Future<void> load() async {
    contacts.clear();
    _sources.clear();
    try {
      if (!await _file.exists() || await _file.length() > 80 * 1024) return;
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! Map ||
          raw['version'] != 1 ||
          raw['contacts'] is! List ||
          (raw['contacts'] as List).length > maxContacts) {
        return;
      }
      for (final entry in raw['contacts'] as List) {
        try {
          if (entry is! Map ||
              entry['value'] is! Map<String, dynamic> ||
              entry['source'] is! String) {
            continue;
          }
          add(
            DiscoveryContact.parse(
              entry['value'] as Map<String, dynamic>,
              forReconnect: true,
            ),
            entry['source'] as String,
          );
        } on FormatException {
          /* An invalid hint cannot hide the other entries. */
        }
      }
    } on FileSystemException {
      /* Nearby receiving remains available. */
    } on FormatException {
      /* A corrupt optional cache is ignored. */
    }
  }

  Future<void> save() {
    expire();
    final encoded = jsonEncode({
      'version': 1,
      'contacts': [
        for (final entry in contacts.entries)
          {'value': entry.value.value, 'source': _sources[entry.key]},
      ],
    });
    final write = _tail.then((_) async {
      await directory.create(recursive: true);
      final next = File('${_file.path}.next');
      await next.writeAsString(encoded, flush: true);
      await next.rename(_file.path);
    });
    _tail = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
