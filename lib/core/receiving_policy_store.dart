import 'dart:convert';
import 'dart:io';

/// Fresh installs use public discovery. Damaged settings recover without
/// re-enabling announcement, public bootstrap or optional routing assistance.
class ReceivingPolicy {
  const ReceivingPolicy({
    this.restartAfterReboot = false,
    this.internetAnnounce = true,
    this.publicDiscovery = true,
    this.discoveryHelper = false,
  });

  static const defaults = ReceivingPolicy();
  static const recovery = ReceivingPolicy(
    internetAnnounce: false,
    publicDiscovery: false,
  );

  /// Let the visible receiving service start again after a reboot or an OS
  /// kill. Off by default; an explicit in-app Stop disarms it for the session.
  final bool restartAfterReboot;

  /// Announce this installation on the public Internet discovery topic so
  /// other phones can find it. When off, the phone still dials announcing
  /// peers, cached contacts, starting peers and nearby devices, but does not
  /// publish its own presence to the DHT. On by default so discovery works.
  final bool internetAnnounce;
  final bool publicDiscovery;
  final bool discoveryHelper;

  ReceivingPolicy copyWith({
    bool? restartAfterReboot,
    bool? internetAnnounce,
    bool? publicDiscovery,
    bool? discoveryHelper,
  }) => ReceivingPolicy(
    restartAfterReboot: restartAfterReboot ?? this.restartAfterReboot,
    internetAnnounce: internetAnnounce ?? this.internetAnnounce,
    publicDiscovery: publicDiscovery ?? this.publicDiscovery,
    discoveryHelper: discoveryHelper ?? this.discoveryHelper,
  );

  Map<String, dynamic> toJson() => {
    'version': 3,
    'restartAfterReboot': restartAfterReboot,
    'internetAnnounce': internetAnnounce,
    'publicDiscovery': publicDiscovery,
    'discoveryHelper': discoveryHelper,
  };
}

/// Crash-safe persistence for [ReceivingPolicy]. Version 1 files carried only
/// `restartAfterReboot`; they load with the default announce setting.
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

  Future<ReceivingPolicy> load() async {
    recovered = false;
    try {
      // An interrupted commit must not re-arm the service by accident.
      if (await _exists(_next) || await _exists(_backup)) {
        throw const FormatException();
      }
      if (!await _exists(_file)) return ReceivingPolicy.defaults;
      if (await _file.length() > maxBytes) throw const FormatException();
      final data = jsonDecode(utf8.decode(await _file.readAsBytes()));
      if (data is! Map || data['restartAfterReboot'] is! bool) {
        throw const FormatException();
      }
      final restart = data['restartAfterReboot'] as bool;
      switch (data['version']) {
        case 1:
          if (data.length != 2) throw const FormatException();
          return ReceivingPolicy(restartAfterReboot: restart);
        case 2:
          if (data.length != 3 || data['internetAnnounce'] is! bool) {
            throw const FormatException();
          }
          return ReceivingPolicy(
            restartAfterReboot: restart,
            internetAnnounce: data['internetAnnounce'] as bool,
          );
        case 3:
          if (data.length != 5 ||
              data['internetAnnounce'] is! bool ||
              data['publicDiscovery'] is! bool ||
              data['discoveryHelper'] is! bool) {
            throw const FormatException();
          }
          return ReceivingPolicy(
            restartAfterReboot: restart,
            internetAnnounce: data['internetAnnounce'] as bool,
            publicDiscovery: data['publicDiscovery'] as bool,
            discoveryHelper: data['discoveryHelper'] as bool,
          );
        default:
          throw const FormatException();
      }
    } on FormatException {
      recovered = true;
      await _quarantine();
      // Persist the conservative choice so the next launch does not interpret
      // a quarantined file as a fresh installation and enable public services.
      try {
        await save(ReceivingPolicy.recovery);
      } on FileSystemException catch (_) {}
      return ReceivingPolicy.recovery;
    } on FileSystemException {
      recovered = true;
      return ReceivingPolicy.recovery;
    }
  }

  Future<void> _quarantine() async {
    for (final file in [_next, _backup, _file]) {
      try {
        if (await _exists(file)) await file.delete();
      } on FileSystemException catch (_) {}
    }
  }

  Future<void> save(ReceivingPolicy policy) async {
    await directory.create(recursive: true);
    await _next.writeAsString(jsonEncode(policy.toJson()), flush: true);
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
