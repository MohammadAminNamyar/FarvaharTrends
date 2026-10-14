import 'dart:convert';
import 'dart:io';

import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';

// Generate public signed fixtures once; never save their private keys.
void main() {
  final channels = [
    for (var i = 0; i < 128; i++)
      SignedChannel.create(Identity.generate(), name: 'Stranger $i').toJson(),
  ];
  final file = File('test/fixtures/stranger_channels.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(channels));
  stdout.writeln(
    'Generated 128 public signed channel fixtures; no keys saved.',
  );
}
