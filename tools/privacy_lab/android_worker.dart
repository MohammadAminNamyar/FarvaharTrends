// Local laboratory launcher only. ADB carries stdin/stdout; no port forwarding,
// host routing changes, or application installation is involved.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class AndroidLabWorker {
  AndroidLabWorker._(
    this.configFile,
    this.serial,
    this.remoteDirectory,
    this.architecture,
    this.binary,
    this.sourceFiles,
    this.binarySha256,
  );

  final File configFile;
  final String serial;
  final String remoteDirectory;
  final String architecture;
  final File binary;
  final Map<String, File> sourceFiles;
  final String binarySha256;

  static AndroidLabWorker load(String path) {
    final file = File(path).absolute;
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final serial = data['serial'];
    final remote = data['remoteDirectory'];
    final architecture = data['architecture'];
    if (data['schema'] != 1 ||
        serial is! String ||
        !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(serial) ||
        remote is! String ||
        !RegExp(r'^/data/local/tmp/farvahar-protocol-[a-f0-9]{32}$')
            .hasMatch(remote) ||
        !['arm64', 'amd64'].contains(architecture)) {
      throw FormatException('Invalid bounded Android laboratory configuration');
    }
    final binary = File('${file.parent.path}/probe-$architecture');
    final binaryHash = sha256.convert(binary.readAsBytesSync()).toString();
    if (binaryHash != data['binarySha256']) {
      throw StateError('Prepared Android binary hash changed');
    }
    final hashes = data['sourceSha256'] as Map<String, dynamic>;
    if (hashes.isEmpty || hashes.length > 500) {
      throw FormatException('Invalid source inventory');
    }
    final sources = <String, File>{};
    for (final entry in hashes.entries) {
      final parts = entry.key.split('/');
      if (parts.length < 2 ||
          !['roundprobe', 'setupprobe', 'verdictprobe'].contains(parts.first) ||
          parts.any(
            (p) =>
                p.isEmpty ||
                p == '.' ||
                p == '..' ||
                !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(p),
          ) ||
          !(parts.last.endsWith('.go') ||
              ['go.mod', 'go.sum'].contains(parts.last))) {
        throw FormatException('Invalid source inventory path');
      }
      final source = File(
        '${file.parent.path}/source/tools/privacy_lab/${entry.key}',
      );
      if (sha256.convert(source.readAsBytesSync()).toString() != entry.value) {
        throw StateError('Prepared source hash changed: ${entry.key}');
      }
      sources['device/source/${entry.key}'] = source;
    }
    return AndroidLabWorker._(
      file,
      serial,
      remote,
      architecture as String,
      binary,
      sources,
      binaryHash,
    );
  }

  List<String> arguments(List<String> workerArguments) {
    // adb shell serializes its remote command. Only fixed flags/mode names and
    // integers from the bounded lab adapter are accepted; never pass shell text.
    if (workerArguments.any((a) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a))) {
      throw ArgumentError('Unsafe Android worker argument');
    }
    return [
      '-s',
      serial,
      'shell',
      '-T',
      '$remoteDirectory/run-probe',
      ...workerArguments,
    ];
  }

  Map<String, Object> metadata() => {
    'serial': serial,
    'architecture': architecture,
    'remoteDirectory': remoteDirectory,
    'binarySha256': binarySha256,
    'scope': 'all eleven native roles on one Android device; host public stores and monotonic observer; USB/ADB overhead included; not radio or independent-device evidence',
  };
}
