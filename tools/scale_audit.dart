// Local workload only. Does not contact a DHT, emulator or public network.
import 'dart:convert';
import 'dart:io';

import 'package:persian_trend/core/channel_control.dart';
import 'package:persian_trend/core/channels.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';
import 'package:persian_trend/core/pilot_store.dart';

Future<void> main() async {
  final base = Directory('${Directory.current.path}/.local-only/scale-audit');
  await base.create(recursive: true);
  final work = await base.createTemp('cache-');
  final owners = List.generate(3, (_) => Identity.generate());
  final reader = Identity.generate();
  final channels = [
    for (var i = 0; i < 24; i++)
      SignedChannel.create(owners[i % 3], name: 'Workload ${i + 1}'),
  ];
  final store = PilotStore(work, localOwnerId: reader.id);
  await store.load();
  for (final channel in channels) {
    await store.putChannel(channel.toJson());
  }
  final grant = ChannelControl.create(
    owners.first,
    channels.first,
    kind: 'editor',
    data: {
      'editorCertificatePem': owners[1].certPem,
      'label': 'Editor',
      'revision': 1,
      'nonce': ChannelControl.randomNonce(),
    },
  );
  int frameBytes(SignedBulletin b) => utf8
      .encode('${jsonEncode({'type': 'bulletin', 'value': b.toJson()})}\n')
      .length;
  final ordinary = SignedBulletin.create(
    owners.first,
    runId: 'news',
    text: 'خبر عمومی ' * 30,
    sequence: 1,
    channelId: channels.first.id,
  );
  final delegated = SignedBulletin.create(
    owners[1],
    runId: 'news',
    text: ordinary.text,
    sequence: 1,
    channelId: channels.first.id,
    authorization: grant,
  );
  final verify = Stopwatch()..start();
  for (var i = 0; i < 1000; i++) {
    if (!delegated.verifyForChannel(channels.first)) {
      throw StateError('Signature verification failed');
    }
  }
  verify.stop();
  stdout.writeln(
    'Verification phase complete: ${verify.elapsedMilliseconds} ms',
  );
  final timer = Stopwatch()..start();
  var peakJournal = 0;
  for (var i = 0; i < 1536; i++) {
    final channel = channels[i % channels.length];
    final news = SignedBulletin.create(
      owners[i % 3],
      runId: 'news',
      text: 'news-$i ${'ا' * 490}',
      sequence: i ~/ channels.length + 1,
      channelId: channel.id,
    );
    await store.putBulletin(
      news.toJson(),
      observation: {
        'receivedVia': 'overlay',
        'receivedNetwork': 'cellular',
        'receivedAtWallMs': DateTime.now().millisecondsSinceEpoch,
      },
    );
    final size = await File('${work.path}/pilot.jsonl').length();
    if (size > peakJournal) peakJournal = size;
    if (i % 256 == 255) {
      stdout.writeln('Durable news: ${i + 1}, ${timer.elapsedMilliseconds} ms');
    }
  }
  stdout.writeln('Starting variable-size diagnostic history');
  // Large diagnostic records exercise byte limits rather than row limits alone.
  for (var i = 0; i < 900; i++) {
    await store.event({
      'event': 'bounded-diagnostics',
      'index': i,
      for (var k = 0; k < 64; k++) 'field-$k': 'ع' * 1024,
    });
  }
  final before = store.bulletins.keys.toSet();
  final reopen = PilotStore(work, localOwnerId: reader.id);
  await reopen.load();
  if (reopen.bulletins.keys.toSet().difference(before).isNotEmpty ||
      before.difference(reopen.bulletins.keys.toSet()).isNotEmpty ||
      reopen.bulletins.length > PilotStore.maxBulletins ||
      reopen.channels.length != 24) {
    throw StateError('Cache changed on restart or exceeded quota');
  }
  timer.stop();
  var diskBytes = 0;
  await for (final file in work.list(recursive: true)) {
    if (file is File) diskBytes += await file.length();
  }
  final result = {
    'kind': 'measured local workload; not a million-device or mobile benchmark',
    'publishedObjects': 1536,
    'publishers': 3,
    'channels': reopen.channels.length,
    'retainedNews': reopen.bulletins.length,
    'retainedEvents': reopen.events.length,
    'journalBytes': await File('${work.path}/pilot.jsonl').length(),
    'diskBytes': diskBytes,
    'peakJournalBytesDuringNews': peakJournal,
    'restartPreservedRetainedIds': true,
    'elapsedMsIncludingSigningDiskAndRestart': timer.elapsedMilliseconds,
    'editorVerification1000Ms': verify.elapsedMilliseconds,
    'ordinaryBulletinFrameBytes': frameBytes(ordinary),
    'editorBulletinFrameBytes': frameBytes(delegated),
    'excludedCosts': [
      'DHT discovery',
      'NAT traversal',
      'radio traffic',
      'Android battery',
      'network propagation',
    ],
  };
  await File('${base.path}/measured.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
}
