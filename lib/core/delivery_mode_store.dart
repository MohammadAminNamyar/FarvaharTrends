import 'dart:convert';
import 'dart:io';

import 'delivery_mode.dart';

/// A missing, invalid or interrupted preference always selects nearby only.
/// Backups are used to roll back failed writes, never to restore a broader mode.
class DeliveryModeStore {
  DeliveryModeStore(this.directory);

  final Directory directory;
  bool recovered = false;
  static const maxBytes = 256;
  File get _file => File('${directory.path}/delivery-mode.json');
  File get _nearbyLatch => File('${directory.path}/delivery-mode.nearby-only');

  Future<DeliveryMode> load() async {
    try {
      // The restrictive choice takes precedence even if its later JSON commit
      // was interrupted. Never resume an older all-networks preference.
      if (await _nearbyLatch.exists()) return DeliveryMode.nearbyOnly;
      if (!await _file.exists()) return DeliveryMode.nearbyOnly;
      if (await _file.length() > maxBytes) throw const FormatException();
      final data = jsonDecode(utf8.decode(await _file.readAsBytes()));
      if (data is! Map ||
          data.length != 2 ||
          data['version'] != 1 ||
          !data.containsKey('mode')) {
        throw const FormatException();
      }
      return switch (data['mode']) {
        'nearbyOnly' => DeliveryMode.nearbyOnly,
        'allNetworks' => DeliveryMode.allNetworks,
        _ => throw const FormatException(),
      };
    } on FormatException {
      recovered = true;
      return DeliveryMode.nearbyOnly;
    } on FileSystemException {
      recovered = true;
      return DeliveryMode.nearbyOnly;
    }
  }

  Future<void> save(DeliveryMode mode) async {
    await directory.create(recursive: true);
    if (mode == DeliveryMode.nearbyOnly) {
      await _nearbyLatch.writeAsString('1', flush: true);
    }
    final next = File('${_file.path}.next');
    final backup = File('${_file.path}.bak');
    await next.writeAsString(
      jsonEncode({'version': 1, 'mode': mode.name}),
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
    try {
      if (await backup.exists()) await backup.delete();
    } on FileSystemException catch (_) {}
    // Broader access is enabled only after its complete durable commit.
    if (mode == DeliveryMode.allNetworks && await _nearbyLatch.exists()) {
      await _nearbyLatch.delete();
    }
  }
}
