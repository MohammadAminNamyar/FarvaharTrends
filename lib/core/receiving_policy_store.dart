import 'dart:convert';
import 'dart:io';

/// Opt-in production receiving policy. The only persisted choice today is
/// whether the visible receiving service may start again after a reboot or an
/// OS kill. Missing, interrupted or invalid files fail closed to `false`.
/// The preference never changes what this device shares.
class ReceivingPolicyStore {
  ReceivingPolicyStore(this.directory);

  final Directory directory;
  bool recovered = false;
  static const maxBytes = 256;
  File get _file => File('${directory.path}/receiving-policy.json');
  File get _next => File('${_file.path}.next');
  File get _backup => File('${_file.path}.bak');

  Future<bool> _exists(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;

  Future<bool> load() async {
    recovered = false;
    try {
      // An interrupted commit must not re-arm the service by accident.
      if (await _exists(_next) || await _exists(_backup)) {
        throw const FormatException();
      }
      if (!await _exists(_file)) return false;
      if (await _file.length() > maxBytes) throw const FormatException();
      final data = jsonDecode(utf8.decode(await _file.readAsBytes()));
      if (data is! Map ||
          data.length != 2 ||
          data['version'] != 1 ||
          data['restartAfterReboot'] is! bool) {
        throw const FormatException();
      }
      return data['restartAfterReboot'] as bool;
    } on FormatException {
      recovered = true;
      await _quarantine();
      return false;
    } on FileSystemException {
      recovered = true;
      return false;
    }
  }

  Future<void> _quarantine() async {
    for (final file in [_next, _backup, _file]) {
      try {
        if (await _exists(file)) await file.delete();
      } on FileSystemException catch (_) {}
    }
  }

  Future<void> save({required bool restartAfterReboot}) async {
    await directory.create(recursive: true);
    await _next.writeAsString(
      jsonEncode({'version': 1, 'restartAfterReboot': restartAfterReboot}),
      flush: true,
    );
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
}
