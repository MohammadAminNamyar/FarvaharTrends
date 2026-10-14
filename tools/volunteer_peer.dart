import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

/// Opt-in, bounded TCP relay. Only public-bootstrap.json may be shared.
/// This CLI never creates channels or publishes news on an operator's behalf.
Future<void> main(List<String> arguments) async {
  RandomAccessFile? lock;
  PeerEngine? engine;
  Timer? heartbeat;
  Timer? deadline;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.writeln(_help);
      return;
    }
    if (options.selfTest) {
      final identity = Identity.generate();
      final restored = Identity.fromJson(identity.toJson());
      final card = PeerCard(
        name: 'Relay self-test',
        host: '192.0.2.10',
        certificatePem: restored.certPem,
        tcpEnrollment: true,
      );
      final decoded = PeerCard.fromJson(card.toJson());
      if (decoded.id != identity.id || !decoded.tcpEnrollment) {
        throw const FormatException('Relay self-test failed.');
      }
      stdout.writeln('Self-test passed; no files or sockets were opened.');
      return;
    }

    final directory = Directory(options.dataDir).absolute;
    await _requireOrdinaryPath(directory.path, directory: true);
    await directory.create(recursive: true);
    await _protect(directory.path, directory: true);
    final lockFile = File('${directory.path}/relay.lock');
    await _requireOrdinaryPath(lockFile.path);
    if (!await lockFile.exists()) await lockFile.create(exclusive: true);
    await _protect(lockFile.path);
    lock = await lockFile.open(mode: FileMode.append);
    // Nonblocking: a second process fails instead of waiting indefinitely.
    await lock.lock(FileLock.exclusive);

    final identityFile = File('${directory.path}/identity.json');
    final configFile = File('${directory.path}/operator-config.json');
    await _requireOrdinaryPath(identityFile.path);
    await _requireOrdinaryPath(configFile.path);
    final hasIdentity = await identityFile.exists();
    final hasConfig = await configFile.exists();
    if (!hasIdentity && hasConfig) {
      throw const FormatException(
        'The existing relay key is missing; no replacement was generated.',
      );
    }
    if (!hasIdentity) {
      // A missing key beside an existing cache/pending write must not silently
      // establish a different identity for previously distributed pins.
      await for (final entry in directory.list(followLinks: false)) {
        if (_base(entry.path) != 'relay.lock') {
          throw const FormatException(
            'State already exists without its relay key; restore it first.',
          );
        }
      }
    }
    final Identity identity;
    if (hasIdentity) {
      await _protect(identityFile.path);
      identity = Identity.fromJson(await _readObject(identityFile, 32768));
    } else {
      // Validate all public inputs before creating the durable private key.
      _Config.create(options);
      identity = Identity.generate();
      await _writeNew(identityFile, identity.toJson());
    }
    final _Config config;
    if (hasConfig) {
      await _protect(configFile.path);
      config = _Config.fromJson(await _readObject(configFile, 4096));
      config.requireMatchingOptions(options);
    } else {
      config = _Config.create(options);
      await _writeNew(configFile, config.toJson());
    }
    final seeds = await _readSeeds(options, identity.id);
    final card = PeerCard(
      name: config.name,
      host: config.advertise,
      port: config.advertisePort,
      certificatePem: identity.certPem,
      tcpEnrollment: config.acceptEnrollment,
    );
    final publicFile = File(
      options.publicOutput ?? '${directory.path}/public-bootstrap.json',
    ).absolute;
    final privateRoot = _normalized(directory.path);
    final outputPath = _normalized(publicFile.path);
    if (outputPath.startsWith('$privateRoot/') &&
        outputPath != '$privateRoot/public-bootstrap.json') {
      throw const FormatException(
        'A public output inside the state directory must be public-bootstrap.json.',
      );
    }
    await _requireOrdinaryPath(publicFile.path);
    final publicBootstrap = <String, dynamic>{
      'version': 1,
      'peers': [card.toJson()],
    };
    if (await publicFile.exists()) {
      final previous = await _readObject(publicFile, 32768);
      if (jsonEncode(previous) != jsonEncode(publicBootstrap)) {
        throw const FormatException(
          'Public output already contains different data; it was not replaced.',
        );
      }
    } else {
      await publicFile.parent.create(recursive: true);
      await _writeNew(publicFile, publicBootstrap);
    }
    stdout.writeln('Public bootstrap: ${publicFile.path}');
    stdout.writeln('Public certificate fingerprint: ${identity.id}');
    if (options.prepareOnly) {
      stdout.writeln('Prepared only; no receiving socket was opened.');
      return;
    }

    final clock = Stopwatch()..start();
    String? previousStatus;
    void report(Map<String, dynamic> status, {bool force = false}) {
      // Never print engine errors, endpoints, labels, channel names or news.
      final summary = jsonEncode({
        'running': status['running'] == true,
        'contacts': status['peerCount'] ?? 0,
        'connected': status['connectedCount'] ?? 0,
        'channels': (status['channels'] as List?)?.length ?? 0,
        'news': status['bulletinCount'] ?? 0,
      });
      if (force || summary != previousStatus) {
        previousStatus = summary;
        stdout.writeln('status $summary');
      }
    }

    final peer = PeerEngine(
      directory: directory,
      identity: identity,
      listenPort: config.listenPort,
      bootstrapPeers: seeds,
      enableLanDiscovery: false,
      enableUdpDiscovery: false,
      acceptTcpEnrollment: config.acceptEnrollment,
      deviceState: () async => {
        'platform': 'volunteer-relay',
        'elapsedRealtimeMs': clock.elapsedMilliseconds,
        'lockStateKnown': false,
      },
      onStatus: report,
    );
    engine = peer;
    await peer.start(activeMode: false);
    stdout.writeln(
      'TCP relay started; new-device enrollment: ${config.acceptEnrollment}. '
      'Small-group limit: ${PeerEngine.maxConnections} simultaneous links.',
    );
    heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(
        peer.snapshot().then(
          (status) => report(status, force: true),
          onError: (Object _) {},
        ),
      );
    });
    final stopped = Completer<void>();
    void stop() {
      if (!stopped.isCompleted) stopped.complete();
    }

    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      signals.add(signal.watch().listen((_) => stop()));
    }
    if (options.runFor != null) {
      deadline = Timer(Duration(seconds: options.runFor!), stop);
    }
    await stopped.future;
  } on FormatException catch (error) {
    // All format messages are fixed validation text, never decoded input.
    stderr.writeln(error.message);
    exitCode = 64;
  } on FileSystemException catch (_) {
    stderr.writeln(
      'Relay storage or exclusive instance lock failed. No state was reset.',
    );
    exitCode = 73;
  } on SocketException catch (_) {
    stderr.writeln(
      'Relay socket could not start. Check the port and firewall.',
    );
    exitCode = 69;
  } catch (_) {
    stderr.writeln(
      'Relay failed; private state and network details were omitted.',
    );
    exitCode = 1;
  } finally {
    heartbeat?.cancel();
    deadline?.cancel();
    for (final subscription in signals) {
      await subscription.cancel();
    }
    try {
      await engine?.stop();
      await lock?.close();
    } catch (_) {
      stderr.writeln(
        'Relay cleanup failed; check that its process has exited.',
      );
      exitCode = 1;
    }
  }
}

const _help = '''FarvaharTrends small-group volunteer TCP relay
First preparation:
  --advertise <numeric-IPv4> [--port 45871] [--advertise-port 45871]
  --accept-enrollment --prepare-only
Run an existing prepared relay:
  [--data-dir <private-state-directory>] [--bootstrap <public-json>]...
  [--seed <public-peer-card-json>]... [--run-for <1..86400 seconds>]

--data-dir defaults to .tooling/volunteer-peer in the working directory.
--public-output writes only a public bootstrap; default is inside the state dir.
--name sets the initial public relay label. --self-test uses no files/sockets.
Without --accept-enrollment, only previously configured/pinned peers can join.
First-run endpoint/enrollment settings persist; conflicting later flags fail.
The advertised address may be a NAT frontend; configure its TCP port mapping.
The listener uses wildcard IPv4 and, when available, IPv6; UDP is disabled.
Only public-bootstrap.json may be shared. Keep all other state private.
This relay provides neither anonymity nor guaranteed shutdown reachability.''';

class _Options {
  bool help = false;
  bool selfTest = false;
  bool prepareOnly = false;
  bool acceptEnrollment = false;
  String dataDir = '${Directory.current.path}/.tooling/volunteer-peer';
  String? publicOutput;
  String? advertise;
  String? name;
  int? port;
  int? advertisePort;
  int? runFor;
  final bootstrapFiles = <String>[];
  final seedFiles = <String>[];

  static _Options parse(List<String> args) {
    final options = _Options();
    final seen = <String>{};
    for (var index = 0; index < args.length; index++) {
      final flag = args[index];
      if (flag != '--bootstrap' && flag != '--seed' && !seen.add(flag)) {
        throw const FormatException('Duplicate relay option.');
      }
      String value() {
        if (++index >= args.length || args[index].startsWith('--')) {
          throw const FormatException('Missing relay option value.');
        }
        return args[index];
      }

      switch (flag) {
        case '--help':
        case '-h':
          options.help = true;
        case '--self-test':
          options.selfTest = true;
        case '--prepare-only':
          options.prepareOnly = true;
        case '--accept-enrollment':
          options.acceptEnrollment = true;
        case '--data-dir':
          options.dataDir = value();
        case '--public-output':
          options.publicOutput = value();
        case '--advertise':
          options.advertise = _ipv4(value());
        case '--name':
          options.name = value();
        case '--port':
          options.port = _port(value());
        case '--advertise-port':
          options.advertisePort = _port(value());
        case '--run-for':
          options.runFor = int.tryParse(value()) ?? 0;
        case '--bootstrap':
          options.bootstrapFiles.add(value());
        case '--seed':
          options.seedFiles.add(value());
        default:
          throw const FormatException('Unknown relay option; use --help.');
      }
    }
    if (options.help) return options;
    if (options.selfTest && args.length != 1) {
      throw const FormatException('Use --self-test alone.');
    }
    if ((options.runFor != null &&
            (options.runFor! < 1 || options.runFor! > 86400)) ||
        (options.prepareOnly && options.runFor != null) ||
        options.bootstrapFiles.length + options.seedFiles.length > 16) {
      throw const FormatException('Invalid duration or too many seed files.');
    }
    return options;
  }
}

class _Config {
  const _Config(
    this.advertise,
    this.listenPort,
    this.advertisePort,
    this.name,
    this.acceptEnrollment,
  );
  final String advertise;
  final int listenPort;
  final int advertisePort;
  final String name;
  final bool acceptEnrollment;

  factory _Config.create(_Options options) {
    if (options.advertise == null) {
      throw const FormatException(
        '--advertise is required for new relay state.',
      );
    }
    final name = options.name ?? 'FarvaharTrends volunteer peer';
    if (name.trim().isEmpty ||
        name.length > 80 ||
        utf8.encode(name).length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('Relay name must be 1–80 plain characters.');
    }
    return _Config(
      options.advertise!,
      options.port ?? 45871,
      options.advertisePort ?? options.port ?? 45871,
      name.trim(),
      options.acceptEnrollment,
    );
  }

  factory _Config.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['advertise'] is! String ||
        json['listenPort'] is! int ||
        json['advertisePort'] is! int ||
        json['name'] is! String ||
        json['acceptEnrollment'] is! bool ||
        json.length != 6) {
      throw const FormatException('Stored operator configuration is invalid.');
    }
    return _Config.create(
      _Options()
        ..advertise = _ipv4(json['advertise'] as String)
        ..port = _port('${json['listenPort']}')
        ..advertisePort = _port('${json['advertisePort']}')
        ..name = json['name'] as String
        ..acceptEnrollment = json['acceptEnrollment'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'advertise': advertise,
    'listenPort': listenPort,
    'advertisePort': advertisePort,
    'name': name,
    'acceptEnrollment': acceptEnrollment,
  };

  void requireMatchingOptions(_Options options) {
    if ((options.advertise != null && options.advertise != advertise) ||
        (options.port != null && options.port != listenPort) ||
        (options.advertisePort != null &&
            options.advertisePort != advertisePort) ||
        (options.name != null && options.name!.trim() != name) ||
        (options.acceptEnrollment && !acceptEnrollment)) {
      throw const FormatException(
        'Existing operator settings differ; they were not overwritten.',
      );
    }
  }
}

Future<List<PeerCard>> _readSeeds(_Options options, String selfId) async {
  final peers = <String, PeerCard>{};
  void add(Map<String, dynamic> value) {
    final card = PeerCard.fromJson(value);
    if (card.id == selfId) return;
    if (card.host.isEmpty) {
      throw const FormatException('A relay seed needs a numeric endpoint.');
    }
    final existing = peers[card.id];
    if (existing != null &&
        jsonEncode(existing.toJson()) != jsonEncode(card.toJson())) {
      throw const FormatException('Seed files contain conflicting peer cards.');
    }
    peers[card.id] = card;
    if (peers.length > PeerEngine.maxPeers) {
      throw const FormatException('Too many relay seed identities.');
    }
  }

  for (final path in options.seedFiles) {
    add(await _readObject(File(path), 16384));
  }
  for (final path in options.bootstrapFiles) {
    final value = await _readObject(File(path), 256 * 1024);
    if (value['version'] != 1 ||
        value['peers'] is! List ||
        value.length != 2 ||
        (value['peers'] as List).length > PeerEngine.maxPeers) {
      throw const FormatException('Invalid bounded relay bootstrap.');
    }
    for (final raw in value['peers'] as List) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('Invalid relay seed card.');
      }
      add(raw);
    }
  }
  return peers.values.toList(growable: false);
}

Future<Map<String, dynamic>> _readObject(File file, int maximum) async {
  if (await file.length() > maximum) {
    throw const FormatException('Relay input file exceeds its size limit.');
  }
  final bytes = await file
      .openRead(0, maximum + 1)
      .fold<List<int>>(<int>[], (result, chunk) => result..addAll(chunk));
  if (bytes.length > maximum) {
    throw const FormatException('Relay input file exceeds its size limit.');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Relay input must be a JSON object.');
  }
  return value;
}

Future<void> _writeNew(File file, Map<String, dynamic> value) async {
  final pending = File('${file.path}.next');
  await pending.create(exclusive: true);
  await _protect(pending.path);
  await pending.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
  if (await file.exists()) {
    throw const FormatException(
      'Relay state changed; existing data was preserved.',
    );
  }
  await pending.rename(file.path);
}

Future<void> _requireOrdinaryPath(String path, {bool directory = false}) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type !=
          (directory
              ? FileSystemEntityType.directory
              : FileSystemEntityType.file)) {
    throw const FormatException(
      'Relay state must use ordinary files/directories.',
    );
  }
}

Future<void> _protect(String path, {bool directory = false}) async {
  final ProcessResult result;
  if (Platform.isWindows) {
    // A constant script, with its path passed as data rather than shell code.
    result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'''
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$kind = $env:FARVAHARTRENDS_ACL_KIND
if ($kind -eq 'directory') {
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
} else {
  $acl = [Security.AccessControl.FileSecurity]::new()
  $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
}
$acl.SetOwner($sid)
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $env:FARVAHARTRENDS_ACL_PATH -AclObject $acl
''',
      ],
      environment: {
        'FARVAHARTRENDS_ACL_PATH': path,
        'FARVAHARTRENDS_ACL_KIND': directory ? 'directory' : 'file',
      },
    );
  } else {
    result = await Process.run('/bin/chmod', [
      directory ? '700' : '600',
      '--',
      path,
    ]);
  }
  if (result.exitCode != 0) {
    throw const FormatException('Could not restrict relay state permissions.');
  }
}

String _ipv4(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null ||
      address.type != InternetAddressType.IPv4 ||
      address.isLoopback ||
      address.isMulticast ||
      address.rawAddress.first == 0 ||
      address.rawAddress.first >= 240 ||
      address.address == '255.255.255.255') {
    throw const FormatException(
      'Use an explicit numeric unicast advertised IPv4.',
    );
  }
  return address.address;
}

int _port(String value) {
  final port = int.tryParse(value) ?? 0;
  if (port < 1 || port > 65535) {
    throw const FormatException('Relay port must be between 1 and 65535.');
  }
  return port;
}

String _normalized(String path) {
  final value = File(path).absolute.uri
      .normalizePath()
      .toFilePath()
      .replaceAll('\\', '/');
  return Platform.isWindows ? value.toLowerCase() : value;
}

String _base(String path) => path.replaceAll('\\', '/').split('/').last;
