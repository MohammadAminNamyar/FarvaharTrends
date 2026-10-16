// Executable apparatus checks; does not connect to ADB or touch a device.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'android_worker.dart';

void main() {
  final root = Directory.systemTemp.createTempSync('farvahar-worker-check-');
  try {
    File('${root.path}/probe-arm64').writeAsBytesSync([1, 2, 3]);
    final source = File(
      '${root.path}/source/tools/privacy_lab/roundprobe/main.go',
    );
    source.parent.createSync(recursive: true);
    source.writeAsStringSync('package main\n');
    final config = <String, Object>{
      'schema': 1,
      'serial': 'R3CRC0R5HKA',
      'architecture': 'arm64',
      'remoteDirectory': '/data/local/tmp/farvahar-protocol-${'a' * 32}',
      'binarySha256': sha256.convert([1, 2, 3]).toString(),
      'sourceSha256': {
        'roundprobe/main.go': sha256
            .convert(source.readAsBytesSync())
            .toString(),
      },
    };
    final file = File('${root.path}/worker-config.json');
    file.writeAsStringSync(jsonEncode(config));
    final worker = AndroidLabWorker.load(file.path);
    final args = worker.arguments([
      '-mode',
      'network-schedule-atomic-pipe',
      '-kbps',
      '5000',
    ]);
    if (args[0] != '-s' ||
        args[1] != config['serial'] ||
        args[4] != '${config['remoteDirectory']}/run-probe' ||
        worker.sourceFiles.length != 1) {
      throw StateError('Wrong shell-free launcher arguments');
    }
    void rejects(void Function() call) {
      var rejected = false;
      try {
        call();
      } catch (_) {
        rejected = true;
      }
      if (!rejected) throw StateError('Invalid launch configuration accepted');
    }

    for (final bad in ['a;echo', 'a b', r'$(echo)', '../file']) {
      rejects(() => worker.arguments([bad]));
    }
    for (final change in <Map<String, Object>>[
      {'serial': 'device;echo'},
      {'remoteDirectory': '/data/local/tmp'},
      {'remoteDirectory': '/data/local/tmp/farvahar-protocol-${'a' * 32}/..'},
      {'architecture': 'unknown'},
      {'binarySha256': 'wrong'},
      {
        'sourceSha256': {'roundprobe/../main.go': 'wrong'},
      },
      {
        'sourceSha256': {'roundprobe/main.go': 'wrong'},
      },
    ]) {
      file.writeAsStringSync(jsonEncode({...config, ...change}));
      rejects(() => AndroidLabWorker.load(file.path));
    }
    stdout.writeln(
      'Android worker configuration, source binding and shell argument checks passed',
    );
  } finally {
    root.deleteSync(
      recursive: true,
    ); // Only this freshly created test directory.
  }
}
