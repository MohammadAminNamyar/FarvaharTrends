import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_platform/pilot_platform.dart';
import 'package:persian_trend/app_controller.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/delivery_mode.dart';
import 'package:persian_trend/core/delivery_mode_store.dart';
import 'package:persian_trend/core/peer_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity identity;
  late Directory directory;

  setUpAll(() => identity = Identity.generate());
  setUp(() async {
    final parent = Directory(
      '${Directory.current.path}/artifacts/controller-tests',
    );
    await parent.create(recursive: true);
    directory = await parent.createTemp('case-');
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  AppController controller(PeerEngine engine) => AppController.forTesting(
    directory: directory,
    identity: identity,
    createEngine: () => engine,
  );

  test('Different UI lifetimes never reuse service command IDs', () {
    final a = AppController();
    final b = AppController();
    expect(a.nextRequestId(), isNot(b.nextRequestId()));
    expect(a.nextRequestId().split(':').last, '2');
    a.dispose();
    b.dispose();
  });

  test(
    'Identity vault never asks Android secure storage to reset on error',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      await identityVaultForTesting.read(key: 'identity-options-regression');
      await identityVaultForTesting.write(
        key: 'identity-options-regression',
        value: 'test-only',
      );
      expect(calls.map((call) => call.method), ['read', 'write']);
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['resetOnError'], 'false');
        expect(
          options['keyCipherAlgorithm'],
          'RSA_ECB_OAEPwithSHA_256andMGF1Padding',
        );
        expect(options['storageCipherAlgorithm'], 'AES_GCM_NoPadding');
      }
    },
  );

  test(
    'A failed local startup stops resources before reporting failure',
    () async {
      final engine = _Engine(directory, identity)..failStart = true;
      final app = controller(engine);
      await expectLater(app.start(active: false), throwsStateError);
      expect(engine.stops, 1);
      expect(app.running, isFalse);
      app.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'Closing a UI during local startup cannot leave a receiver running',
    () async {
      final gate = Completer<void>();
      final engine = _Engine(directory, identity)..startGate = gate;
      final app = controller(engine);
      final started = app.start(active: false);
      final assertion = expectLater(started, throwsStateError);
      await engine.enteredStart.future;
      app.dispose();
      gate.complete();
      await assertion;
      expect(engine.stops, greaterThanOrEqualTo(1));
      expect(engine.receiving, isFalse);
      expect(() => app.notifyListeners(), returnsNormally);
      await expectLater(app.refresh(), throwsStateError);
    },
  );

  test('Offline publishing stores news without resuming receiving', () async {
    final engine = PeerEngine(
      directory: directory,
      identity: identity,
      deviceState: () async => {},
      onStatus: (_) {},
      enableLanDiscovery: false,
      listenPort: 0,
    );
    final app = controller(engine);
    await app.createChannel('Offline notices', '');
    final channels = app.snapshot['channels'] as List;
    final channelId = (channels.single as Map)['id'] as String;
    await app.publishToChannel(channelId, 'Saved while paused');
    expect(app.running, isFalse);
    expect(
      (app.snapshot['bulletins'] as List).single['text'],
      'Saved while paused',
    );
    expect(app.snapshot['running'], isFalse);
    app.dispose();
    await engine.stop();
  });

  test('Changing delivery mode while paused keeps receiving paused', () async {
    final engine = _Engine(directory, identity);
    final app = controller(engine);
    expect(app.deliveryMode, DeliveryMode.allNetworks);
    await app.setDeliveryMode(DeliveryMode.nearbyOnly);
    expect(app.deliveryMode, DeliveryMode.nearbyOnly);
    expect(app.running, isFalse);
    expect(engine.receiving, isFalse);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
    app.dispose();
  });

  test(
    'Changing delivery mode closes routes before commit and resumes once',
    () async {
      final engine = _Engine(directory, identity);
      final app = controller(engine);
      await app.start(active: false);
      expect(engine.starts, 1);
      await app.setDeliveryMode(DeliveryMode.nearbyOnly);
      expect(engine.stops, greaterThanOrEqualTo(2));
      expect(engine.starts, 2);
      expect(app.running, isTrue);
      expect(
        await DeliveryModeStore(directory).load(),
        DeliveryMode.nearbyOnly,
      );
      app.dispose();
    },
  );

  test('Failed delivery mode commit leaves routes stopped and future start fails closed', () async {
    final engine = _Engine(directory, identity);
    final app = controller(engine);
    await app.setDeliveryMode(DeliveryMode.allNetworks);
    await app.start(active: false);
    await Directory('${directory.path}/delivery-mode.json.next').create();
    await expectLater(
      app.setDeliveryMode(DeliveryMode.nearbyOnly),
      throwsStateError,
    );
    expect(app.deliveryMode, DeliveryMode.nearbyOnly);
    expect(app.running, isFalse);
    expect(engine.receiving, isFalse);
    expect(await DeliveryModeStore(directory).load(), DeliveryMode.nearbyOnly);
    final starts = engine.starts;
    await expectLater(app.start(active: false), throwsStateError);
    expect(engine.starts, starts);
    expect(engine.receiving, isFalse);
    app.dispose();
  });

  test(
    'Publisher-owned channels remain followed when connection key changes',
    () async {
      final connection = Identity.generate();
      final engine = _Engine(directory, connection);
      final app = AppController.forTesting(
        directory: directory,
        identity: connection,
        publisherIdentity: identity,
        createEngine: () => engine,
      );
      final channelId = 'a' * 64;
      app.snapshot = {
        'channels': [
          {'id': channelId, 'ownerId': identity.id},
        ],
      };
      expect(app.followedChannelIds, {channelId});
      expect(app.ownCard().id, connection.id);
      expect(app.publisherIdentity!.id, identity.id);
      app.dispose();
    },
  );

  test(
    'Invalid and oversized display files cannot prevent safe recovery',
    () async {
      final settings = File('${directory.path}/display.json');
      await settings.writeAsString('x' * (DisplaySettingsStore.maxBytes + 1));
      final app = controller(_Engine(directory, identity));
      await app.loadDisplaySettings();
      expect(app.label, 'Test phone');
      expect(app.advertisedHost, isEmpty);
      expect(app.languageCode, 'fa');
      expect(app.error, isNotNull);
      app.dispose();
    },
  );

  test(
    'A valid backup recovers an interrupted display settings commit',
    () async {
      await File('${directory.path}/display.json').writeAsString('{');
      await File('${directory.path}/display.json.bak').writeAsString(
        jsonEncode({
          'label': 'Recovered phone',
          'host': '192.168.1.4',
          'languageCode': 'en',
        }),
      );
      final app = controller(_Engine(directory, identity));
      await app.loadDisplaySettings();
      expect(app.label, 'Recovered phone');
      expect(app.advertisedHost, '192.168.1.4');
      expect(app.languageCode, 'en');
      expect(
        await File('${directory.path}/display.json.bak').exists(),
        isFalse,
      );
      app.dispose();
    },
  );

  test(
    'Display choices change only after durable commit and writes serialize',
    () async {
      final app = controller(_Engine(directory, identity));
      await Future.wait([
        app.saveDisplay('New phone', '192.168.1.5'),
        app.setLanguageCode('en'),
      ]);
      final saved = jsonDecode(
        await File('${directory.path}/display.json').readAsString(),
      );
      expect(saved, {
        'label': 'New phone',
        'host': '192.168.1.5',
        'languageCode': 'en',
      });
      await Directory('${directory.path}/display.json.next').create();
      await expectLater(
        app.saveDisplay('Unsaved name', ''),
        throwsA(isA<FileSystemException>()),
      );
      expect(app.label, 'New phone');
      expect(app.advertisedHost, '192.168.1.5');
      await expectLater(
        app.setLanguageCode('fa'),
        throwsA(isA<FileSystemException>()),
      );
      expect(app.languageCode, 'en');
      app.dispose();
    },
  );

  test(
    'Independent first-run engines reread vault after native lease acquisition',
    () async {
      String? saved;
      var generated = 0;
      final lease = _Lease();
      IdentityBootstrap bootstrap() => IdentityBootstrap(
        read: () async => saved,
        write: (value) async {
          saved = value;
        },
        generate: () async {
          generated++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return identity.toJson();
        },
        acquire: lease.acquire,
        release: lease.release,
      );
      final a = bootstrap(), b = bootstrap();
      final results = await Future.wait([a.load(), a.load(), b.load()]);
      expect(results.map((value) => value.id).toSet(), {identity.id});
      expect(generated, 1);
      expect(lease.acquisitions, 2);
      expect(lease.releases, 2);
    },
  );

  test('Native lease method calls bracket vault reads and writes', () async {
    const channel = MethodChannel('persiantrend/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final lease = _Lease();
    final events = <String>[];
    String? saved;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'acquireIdentityLease':
          final token = await lease.acquire();
          events.add('acquire:$token');
          return token;
        case 'releaseIdentityLease':
          final token = (call.arguments as Map)['token'] as String;
          events.add('release:$token');
          await lease.release(token);
          return null;
        default:
          throw StateError('Unexpected native call');
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    IdentityBootstrap bootstrap() => IdentityBootstrap(
      acquire: PilotPlatform.acquireIdentityLease,
      release: PilotPlatform.releaseIdentityLease,
      read: () async {
        events.add('read');
        return saved;
      },
      generate: () async {
        events.add('generate');
        return identity.toJson();
      },
      write: (value) async {
        events.add('write');
        saved = value;
      },
    );
    final ids = await Future.wait([bootstrap().load(), bootstrap().load()]);
    expect(ids.map((id) => id.id).toSet(), {identity.id});
    expect(events, [
      'acquire:1',
      'read',
      'generate',
      'write',
      'release:1',
      'acquire:2',
      'read',
      'release:2',
    ]);
  });

  test('Vault or lease errors never create a replacement identity', () async {
    var generated = 0;
    var released = 0;
    final corrupt = IdentityBootstrap(
      read: () async => '{"keyPem":"PRIVATE-KEY-MUST-NOT-APPEAR',
      write: (_) async {},
      generate: () async {
        generated++;
        return identity.toJson();
      },
      acquire: () async => 'lease',
      release: (_) async {
        released++;
      },
    );
    await expectLater(
      corrupt.load(),
      throwsA(
        predicate(
          (error) =>
              error is FormatException &&
              !error.toString().contains('PRIVATE-KEY-MUST-NOT-APPEAR'),
        ),
      ),
    );
    expect(generated, 0);
    expect(released, 1);
    final denied = IdentityBootstrap(
      read: () async => null,
      write: (_) async {},
      generate: () async {
        generated++;
        return identity.toJson();
      },
      acquire: () async => throw StateError('Lease unavailable'),
      release: (_) async {
        released++;
      },
    );
    await expectLater(denied.load(), throwsStateError);
    expect(generated, 0);
    expect(released, 1);
  });

  test(
    'Failed identity write releases lease and allows a safe retry',
    () async {
      var writes = 0;
      var released = 0;
      String? saved;
      final bootstrap = IdentityBootstrap(
        read: () async => saved,
        write: (value) async {
          if (++writes == 1) throw StateError('Storage unavailable');
          saved = value;
        },
        generate: () async => identity.toJson(),
        acquire: () async => 'lease',
        release: (_) async {
          released++;
        },
      );
      await expectLater(bootstrap.load(), throwsStateError);
      expect((await bootstrap.load()).id, identity.id);
      expect(released, 2);
    },
  );
}

class _Engine extends PeerEngine {
  _Engine(Directory directory, Identity identity)
    : super(
        directory: directory,
        identity: identity,
        deviceState: () async => {},
        onStatus: (_) {},
        enableLanDiscovery: false,
      );
  bool failStart = false, receiving = false;
  int stops = 0, starts = 0;
  Completer<void>? startGate;
  final enteredStart = Completer<void>();
  @override
  Future<void> start({required bool activeMode}) async {
    receiving = true;
    starts++;
    if (!enteredStart.isCompleted) enteredStart.complete();
    await startGate?.future;
    if (failStart) throw StateError('Startup failed after opening a receiver');
    receiving = true;
  }

  @override
  Future<void> stop() async {
    receiving = false;
    stops++;
  }

  @override
  Future<Map<String, dynamic>> snapshot() async => {'running': receiving};
}

class _Lease {
  Future<void> _tail = Future<void>.value();
  final Map<String, Completer<void>> _releases = {};
  int acquisitions = 0, releases = 0;
  Future<String> acquire() async {
    final previous = _tail;
    final gate = Completer<void>();
    final token = '${++acquisitions}';
    _tail = gate.future;
    _releases[token] = gate;
    await previous;
    return token;
  }

  Future<void> release(String token) async {
    releases++;
    _releases.remove(token)!.complete();
  }
}
