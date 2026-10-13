import 'dart:io';

import 'package:crypto/crypto.dart';

void main() {
  const directory = 'packages/flutter_pear';
  final bytes = <int>[];
  for (final name in [
    'persiantrend.js',
    'persiantrend-routing.js',
    'persiantrend-discovery.js',
    'persiantrend-cooldown.js',
    'desktop-ipc.js',
    'package-lock.json',
  ]) {
    bytes.addAll(File('$directory/pear-end/$name').readAsBytesSync());
  }
  final version = sha256.convert(bytes).toString().substring(0, 16);
  File('$directory/pear-end/version.js')
      .writeAsStringSync("'use strict'\nmodule.exports = '$version'\n");
  File('$directory/lib/src/bundle_version.dart').writeAsStringSync(
    '// Generated transport-source fingerprint; regenerate with tools/build-overlay.ps1.\n'
    "const String kPearEndBundleVersion = '$version';\n",
  );
  stdout.writeln('Transport source fingerprint: $version');
}
