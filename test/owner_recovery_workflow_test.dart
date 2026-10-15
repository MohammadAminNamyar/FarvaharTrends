import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channel_key_store.dart';
import 'package:farvahar_trends/core/channel_recovery.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/peer_engine.dart';

void main() {
  late Directory scratch;
  late Identity connection;
  String? vaultText;
  var failWrite = false;
  final engines = <PeerEngine>[];
  const password = 'violet canoe orbit pepper 5728';
  setUpAll(() {
    connection = Identity.generate();
  });
  setUp(() async {
    final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
    await parent.create(recursive: true);
    scratch = await parent.createTemp('owner-workflow-');
    vaultText = null;
    failWrite = false;
  });
  tearDown(() async {
    for (final value in engines) {
      await value.stop();
    }
    engines.clear();
    final expected = Directory('${Directory.current.path}/.tooling/test-tmp')
        .absolute
        .path;
    if (!scratch.absolute.path.startsWith(
      '$expected${Platform.pathSeparator}',
    )) {
      throw StateError('Invalid test cleanup.');
    }
    await scratch.delete(recursive: true);
  });
  PeerEngine make(String name) {
    final engine = PeerEngine(
      directory: Directory('${scratch.path}/$name'),
      identity: connection,
      channelKeys: ChannelKeyStore(
        read: () async => vaultText,
        write: (text) async {
          if (failWrite) {
            throw const FileSystemException('Injected key write failure');
          }
          vaultText = text;
        },
      ),
      listenPort: 0,
      enableLanDiscovery: false,
      deviceState: () async => {'network': 'none'},
      onStatus: (_) {},
    );
    engines.add(engine);
    return engine;
  }

  Future<Map<String, dynamic>> prepare(PeerEngine engine) async => jsonDecode(
    await engine.prepareProtectedChannel(
      name: 'بازیابی آزمایشی',
      description: 'Only invented test news',
      password: password,
    ),
  ) as Map<String, dynamic>;
  List<String> strings(dynamic value) {
    if (value is String) return [value];
    if (value is List) return value.expand(strings).toList();
    if (value is Map) return value.values.expand(strings).toList();
    return [];
  }

  test(
    'save cancellation publishes nothing and retains no recovery secret',
    () async {
      final engine = make('cancel');
      final pending = await prepare(engine);
      expect(vaultText, isNull);
      expect((await engine.snapshot())['channels'], isEmpty);
      await engine.cancelProtectedChannel(pending['token'] as String);
      await expectLater(
        engine.commitProtectedChannel(pending['token'] as String),
        throwsStateError,
      );
      expect((await engine.snapshot())['channels'], isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('saved kit commits idempotently without retaining its private key or password', () async {
    final engine = make('commit');
    final pending = await prepare(engine);
    final id = await engine.commitProtectedChannel(pending['token'] as String);
    expect(await engine.commitProtectedChannel(pending['token'] as String), id);
    final kit = await ChannelRecovery.decryptOwnerKitAsync(
      pending['file'] as String,
      password,
    );
    final recovery = Identity.fromJson(
      Map<String, dynamic>.from(kit['recoveryIdentity'] as Map),
    );
    expect(strings(jsonDecode(vaultText!)), isNot(contains(recovery.keyPem)));
    expect(strings(jsonDecode(vaultText!)), isNot(contains(password)));
    final entries = (jsonDecode(vaultText!) as Map)['entries'] as Map;
    expect(entries.length, 1);
    expect((entries[id]['identity'] as Map)['id'], isNot(recovery.id));
    final journal = await File('${scratch.path}/commit/pilot.jsonl')
        .readAsString();
    expect(journal, isNot(contains('PRIVATE KEY')));
    expect(journal, isNot(contains(password)));
    final snapshot = await engine.snapshot();
    expect((snapshot['channels'] as List).single['owned'], isTrue);
    expect((snapshot['channels'] as List).single['recoverable'], isTrue);
    await engine.publishToChannel(channelId: id, text: 'خبر با کلید جداگانه');
    expect((await engine.snapshot())['bulletins'], hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('saved kit survives interrupted preparation and recovery requires another save', () async {
    final original = make('original');
    final first = await prepare(original);
    await original.stop();
    expect(vaultText, isNull);
    final recovered = make('recovered');
    final next = jsonDecode(
      await recovered.prepareOwnerRecovery(first['file'] as String, password),
    ) as Map;
    expect(next['generation'], 2);
    expect(vaultText, isNull);
    expect((await recovered.snapshot())['channels'], isEmpty);
    await recovered.cancelProtectedChannel(next['token'] as String);
    expect((await recovered.snapshot())['channels'], isEmpty);
    final retried = jsonDecode(
      await recovered.prepareOwnerRecovery(first['file'] as String, password),
    ) as Map;
    final id = await recovered.commitProtectedChannel(
      retried['token'] as String,
    );
    expect(id, first['channelId']);
    final snapshot = await recovered.snapshot();
    expect((snapshot['channels'] as List).single['ownerGeneration'], 2);
    final futureKit = await ChannelRecovery.decryptOwnerKitAsync(
      retried['file'] as String,
      password,
    );
    expect(futureKit['generation'], 2);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('key-store failure is retryable and does not announce a half-created channel', () async {
    final engine = make('failed-write');
    final pending = await prepare(engine);
    failWrite = true;
    await expectLater(
      engine.commitProtectedChannel(pending['token'] as String),
      throwsA(isA<FileSystemException>()),
    );
    expect(vaultText, isNull);
    expect((await engine.snapshot())['channels'], isEmpty);
    failWrite = false;
    expect(
      await engine.commitProtectedChannel(pending['token'] as String),
      pending['channelId'],
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'owner kit rejects wrong passwords, oversized input and format relabeling',
    () async {
      final engine = make('encryption');
      final pending = await prepare(engine);
      final file = pending['file'] as String;
      await expectLater(
        ChannelRecovery.decryptOwnerKitAsync(file, '$password-wrong'),
        throwsFormatException,
      );
      await expectLater(
        ChannelRecovery.decryptOwnerKitAsync(
          'x' * (ChannelRecovery.maxFileBytes + 1),
          password,
        ),
        throwsFormatException,
      );
      final relabeled = Map<String, dynamic>.from(jsonDecode(file) as Map)
        ..['version'] = 1
        ..['kind'] = 'channel-recovery';
      await expectLater(
        ChannelRecovery.decryptAsync(jsonEncode(relabeled), password),
        throwsFormatException,
      );
      await expectLater(
        engine.prepareProtectedChannel(
          name: 'Weak',
          description: '',
          password: 'weak',
        ),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'offline kit can recover a channel retired by its online owner key',
    () async {
      final engine = make('retired');
      final prepared = await prepare(engine);
      final id = await engine.commitProtectedChannel(
        prepared['token'] as String,
      );
      await engine.removeChannel(id);
      expect((await engine.snapshot())['channels'], isEmpty);
      final recovered = jsonDecode(
        await engine.prepareOwnerRecovery(prepared['file'] as String, password),
      ) as Map;
      expect(recovered['generation'], 2);
      await engine.commitProtectedChannel(recovered['token'] as String);
      await engine.publishToChannel(channelId: id, text: 'خبر پس از بازیابی');
      expect((await engine.snapshot())['channels'], hasLength(1));
      expect((await engine.snapshot())['bulletins'], hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
