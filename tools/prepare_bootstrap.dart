import 'dart:convert';
import 'dart:io';

import 'package:persian_trend/core/bootstrap_config.dart';
import 'package:persian_trend/core/models.dart';

/// Validate public relay exports with the same parser used by the application.
/// This command opens no network connection and never reads a private identity.
Future<void> main(List<String> arguments) async {
  try {
    final inputs = <String>[];
    String? output;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if ((argument == '--bootstrap' || argument == '--output-directory') &&
          index + 1 < arguments.length) {
        final value = arguments[++index];
        if (argument == '--bootstrap') {
          inputs.add(value);
        } else if (output == null) {
          output = value;
        } else {
          throw const FormatException('Specify one output directory.');
        }
      } else {
        throw const FormatException(
          'Use --bootstrap <public JSON> and --output-directory <project artifact directory>.',
        );
      }
    }
    if (inputs.isEmpty || inputs.length > maxBootstrapPeers || output == null) {
      throw const FormatException(
        'Supply 1–16 public bootstrap files and an output directory.',
      );
    }
    final project = File.fromUri(Platform.script).parent.parent.absolute;
    final directory = Directory(output).absolute;
    final projectPrefix = '${project.path}${Platform.pathSeparator}';
    final normalizedOutput = directory.uri.normalizePath().toFilePath();
    if (!normalizedOutput.toLowerCase().startsWith(
      projectPrefix.toLowerCase(),
    )) {
      throw const FormatException(
        'Generated files must stay inside the project.',
      );
    }
    final cards = <PeerCard>[];
    final nodes = <String>[];
    for (final path in inputs) {
      final file = File(path);
      if (await file.length() > maxBootstrapConfigBytes) {
        throw const FormatException('A bootstrap file exceeds 128 KiB.');
      }
      // A bounded stream also enforces the limit if a file grows after stat.
      final bytes = <int>[];
      await for (final chunk in file.openRead()) {
        if (bytes.length + chunk.length > maxBootstrapConfigBytes) {
          throw const FormatException('A bootstrap file exceeds 128 KiB.');
        }
        bytes.addAll(chunk);
      }
      final parsed = parseBootstrapConfig(utf8.decode(bytes));
      cards.addAll(parsed.peers);
      nodes.addAll(parsed.dhtBootstrap.where((node) => !nodes.contains(node)));
    }
    final peers = mergeBootstrapPeers(cards);
    final dhtBootstrap = parseDhtBootstrapEntries(nodes);
    if (peers.isEmpty) {
      throw const FormatException(
        'A volunteer APK needs at least one configured starting peer.',
      );
    }
    final config = BootstrapConfig(
      peers: peers,
      dhtBootstrap: dhtBootstrap,
    ).toJson();
    final encoded = jsonEncode(config);
    // Recheck the combined UTF-8 envelope, not only its individual inputs.
    parseBootstrapConfig(encoded);
    await directory.create(recursive: true);
    await File('${directory.path}/bootstrap.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
      flush: true,
    );
    await File('${directory.path}/dart-defines.json').writeAsString(
      jsonEncode({'PERSIANTREND_BOOTSTRAP_JSON': encoded}),
      flush: true,
    );
    stdout.writeln(
      'Validated ${peers.length} public dialing hints and ${dhtBootstrap.length} DHT bootstrap nodes.',
    );
    stdout.writeln('Configuration: ${directory.path}/bootstrap.json');
    stdout.writeln('Dart defines: ${directory.path}/dart-defines.json');
    stdout.writeln(
      'No network probe was performed. Verify endpoint consent, reachability and relay operation separately.',
    );
  } on FormatException catch (error) {
    stderr.writeln('Bootstrap validation failed: ${error.message}');
    exitCode = 64;
  } on FileSystemException {
    stderr.writeln('Bootstrap files could not be read or generated.');
    exitCode = 74;
  }
}
