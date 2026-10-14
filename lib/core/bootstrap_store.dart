import 'dart:convert';
import 'dart:io';

import 'bootstrap_config.dart';
import 'models.dart';

/// A starting-peer card imported on this device, with its import time so the
/// hint can expire. Cards here are dialing hints, never trust or publishing.
class ImportedPeer {
  const ImportedPeer(this.card, this.importedAtMs);
  final PeerCard card;
  final int importedAtMs;
}

/// An operator DHT bootstrap node imported on this device.
class ImportedDhtNode {
  const ImportedDhtNode(this.entry, this.importedAtMs);
  final String entry;
  final int importedAtMs;
}

class ImportedBootstrap {
  const ImportedBootstrap({
    this.peers = const <ImportedPeer>[],
    this.dhtBootstrap = const <ImportedDhtNode>[],
  });
  static const empty = ImportedBootstrap();
  final List<ImportedPeer> peers;
  final List<ImportedDhtNode> dhtBootstrap;
  bool get isEmpty => peers.isEmpty && dhtBootstrap.isEmpty;

  BootstrapConfig toConfig() => BootstrapConfig(
    peers: List<PeerCard>.unmodifiable(peers.map((peer) => peer.card)),
    dhtBootstrap: List<String>.unmodifiable(
      dhtBootstrap.map((node) => node.entry),
    ),
  );
}

/// App-private, bounded store of runtime-imported starting peers (a domestic
/// seed). Nothing here is gossiped automatically. Writes use the same
/// next/backup commit as other preferences; an unreadable file is quarantined
/// and reported through [recoveryWarning] instead of blocking startup.
class BootstrapStore {
  BootstrapStore(this.directory, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Directory directory;
  final int Function() _now;
  static const maxPeers = maxBootstrapPeers;
  static const maxDhtBootstrap = maxDhtBootstrapEntries;
  static const maxBytes = maxBootstrapConfigBytes;
  static const maxAgeMs = 90 * 24 * 60 * 60 * 1000;
  static const _fileName = 'bootstrap-imported.json';

  /// A machine code set when the stored file could not be used.
  String? recoveryWarning;
  bool get recovered => recoveryWarning != null;

  File get _file => File('${directory.path}/$_fileName');
  File get _backup => File('${_file.path}.bak');
  File get _next => File('${_file.path}.next');
  File get _quarantine => File('${_file.path}.corrupt');

  Future<bool> _exists(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// Non-expired imported entries. Expired entries disappear on load and are
  /// dropped from the file on the next save.
  Future<ImportedBootstrap> load() async {
    recoveryWarning = null;
    for (final candidate in [_file, _backup]) {
      if (!await _exists(candidate)) continue;
      try {
        final value = await _read(candidate);
        if (candidate.path != _file.path) {
          recoveryWarning = 'bootstrap_backup_restored';
          if (await _exists(_file)) await _file.delete();
          await candidate.rename(_file.path);
        }
        return value;
      } on FormatException {
        await _quarantineFile(candidate);
      } on FileSystemException {
        await _quarantineFile(candidate);
      } on ArgumentError {
        await _quarantineFile(candidate);
      }
    }
    return ImportedBootstrap.empty;
  }

  Future<void> _quarantineFile(File candidate) async {
    recoveryWarning = 'bootstrap_recovery';
    try {
      if (await _exists(_quarantine)) await _quarantine.delete();
      await candidate.rename(_quarantine.path);
    } on FileSystemException catch (_) {
      try {
        await candidate.delete();
      } on FileSystemException catch (_) {}
    }
  }

  Future<ImportedBootstrap> _read(File file) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('Imported starting peers exceed the limit.');
    }
    final data = jsonDecode(utf8.decode(await file.readAsBytes()));
    if (data is! Map<String, dynamic> ||
        data.length != 3 ||
        data['version'] != 1 ||
        data['peers'] is! List ||
        data['dhtBootstrap'] is! List ||
        (data['peers'] as List).length > maxPeers ||
        (data['dhtBootstrap'] as List).length > maxDhtBootstrap) {
      throw const FormatException('Invalid imported starting peers.');
    }
    final now = _now();
    final peers = <ImportedPeer>[];
    for (final entry in data['peers'] as List) {
      if (entry is! Map<String, dynamic> ||
          entry.length != 2 ||
          entry['importedAtMs'] is! int) {
        throw const FormatException('Invalid imported starting peer.');
      }
      final importedAt = entry['importedAtMs'] as int;
      final card = parseBootstrapPeer(entry['card']);
      if (_expired(importedAt, now)) continue;
      peers.add(ImportedPeer(card, importedAt));
    }
    final nodes = <ImportedDhtNode>[];
    for (final entry in data['dhtBootstrap'] as List) {
      if (entry is! Map<String, dynamic> ||
          entry.length != 2 ||
          entry['entry'] is! String ||
          entry['importedAtMs'] is! int) {
        throw const FormatException('Invalid imported DHT bootstrap entry.');
      }
      final importedAt = entry['importedAtMs'] as int;
      final node = normalizeDhtBootstrapEntry(entry['entry'] as String);
      if (_expired(importedAt, now)) continue;
      nodes.add(ImportedDhtNode(node, importedAt));
    }
    // Validate the combined shape exactly as a configuration document.
    mergeBootstrapPeers(peers.map((peer) => peer.card));
    parseDhtBootstrapEntries(nodes.map((node) => node.entry).toList());
    return ImportedBootstrap(peers: peers, dhtBootstrap: nodes);
  }

  bool _expired(int importedAtMs, int now) =>
      importedAtMs < 0 ||
      importedAtMs > now + 60 * 1000 ||
      now - importedAtMs > maxAgeMs;

  /// Merge a validated document into the store. Re-imported entries refresh
  /// their import time; the newest entries are kept when a cap is reached.
  Future<ImportedBootstrap> import(BootstrapConfig config) async {
    final existing = await load();
    final now = _now();
    final peers = <String, ImportedPeer>{
      for (final peer in existing.peers)
        '${peer.card.id}|${peer.card.host}|${peer.card.port}': peer,
    };
    for (final card in config.peers) {
      peers['${card.id}|${card.host}|${card.port}'] = ImportedPeer(card, now);
    }
    final nodes = <String, ImportedDhtNode>{
      for (final node in existing.dhtBootstrap) node.entry: node,
    };
    for (final entry in config.dhtBootstrap) {
      nodes[entry] = ImportedDhtNode(entry, now);
    }
    final merged = ImportedBootstrap(
      peers: _newest(peers.values, (peer) => peer.importedAtMs, maxPeers),
      dhtBootstrap: _newest(
        nodes.values,
        (node) => node.importedAtMs,
        maxDhtBootstrap,
      ),
    );
    await save(merged);
    return merged;
  }

  static List<T> _newest<T>(
    Iterable<T> values,
    int Function(T) importedAt,
    int cap,
  ) {
    final sorted = values.toList()
      ..sort((a, b) => importedAt(b).compareTo(importedAt(a)));
    return List<T>.unmodifiable(sorted.take(cap));
  }

  Future<void> save(ImportedBootstrap value) async {
    final now = _now();
    final peers = value.peers
        .where((peer) => !_expired(peer.importedAtMs, now))
        .take(maxPeers);
    final nodes = value.dhtBootstrap
        .where((node) => !_expired(node.importedAtMs, now))
        .take(maxDhtBootstrap);
    // Reject documents that would not load back.
    mergeBootstrapPeers(peers.map((peer) => peer.card));
    parseDhtBootstrapEntries(nodes.map((node) => node.entry).toList());
    final encoded = jsonEncode({
      'version': 1,
      'peers': [
        for (final peer in peers)
          {'card': peer.card.toJson(), 'importedAtMs': peer.importedAtMs},
      ],
      'dhtBootstrap': [
        for (final node in nodes)
          {'entry': node.entry, 'importedAtMs': node.importedAtMs},
      ],
    });
    if (utf8.encode(encoded).length > maxBytes) {
      throw StateError('Imported starting peers are too large to save.');
    }
    await directory.create(recursive: true);
    await _next.writeAsString(encoded, flush: true);
    if (await _backup.exists()) await _backup.delete();
    if (await _file.exists()) await _file.rename(_backup.path);
    try {
      await _next.rename(_file.path);
    } catch (_) {
      if (!await _file.exists() && await _backup.exists()) {
        await _backup.rename(_file.path);
      }
      rethrow;
    }
    try {
      if (await _backup.exists()) await _backup.delete();
    } on FileSystemException catch (_) {}
  }

  /// Forget every imported entry, including quarantined copies.
  Future<void> clear() async {
    for (final file in [_next, _backup, _file, _quarantine]) {
      try {
        if (await _exists(file)) await file.delete();
      } on FileSystemException catch (_) {}
    }
  }
}
