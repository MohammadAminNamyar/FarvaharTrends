import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pilot_platform/pilot_platform.dart';

import 'android_local_wifi.dart';
import 'core/bootstrap_config.dart';
import 'core/identity.dart';
import 'core/identity_roles.dart';
import 'core/delivery_mode.dart';
import 'core/delivery_mode_store.dart';
import 'core/channel_preferences.dart';
import 'core/models.dart';
import 'core/peer_engine.dart';
import 'core/service_lifecycle.dart';
import 'nearby_transports.dart';
import 'internet_overlay.dart';
import 'phone_helper.dart';
import 'testing/device_probe.dart';

export 'core/identity_roles.dart' show IdentityBootstrap;

// A crypto/read failure must never silently erase an existing signing key.
const _vault = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false),
);
@visibleForTesting
FlutterSecureStorage get identityVaultForTesting => _vault;
String? _discoveryLockError;
String? _nearbyError;

Future<List<PeerCard>> loadBootstrapPeers() async {
  const hasOverride = bool.hasEnvironment('PERSIANTREND_BOOTSTRAP_JSON');
  const override = String.fromEnvironment('PERSIANTREND_BOOTSTRAP_JSON');
  return parseBootstrapConfig(
    hasOverride
        ? override
        : await rootBundle.loadString('assets/bootstrap.json'),
  );
}

Future<void> setDiscoveryActive(bool active) async {
  if (!Platform.isAndroid) return;
  try {
    await PilotPlatform.setDiscoveryActive(active);
    _discoveryLockError = null;
  } catch (_) {
    // Wi-Fi multicast is optional; a usable TCP/seed path must still start.
    _discoveryLockError = active
        ? 'multicast_lock_unavailable'
        : 'multicast_lock_release_failed';
  }
}

final _identityRolesBootstrap = IdentityRolesBootstrap(
  read: (key) => _vault.read(key: key),
  write: (key, value) => _vault.write(key: key, value: value),
  generate: () => Isolate.run(() => Identity.generate().toJson()),
  acquire: Platform.isAndroid ? PilotPlatform.acquireIdentityLease : null,
  release: Platform.isAndroid ? PilotPlatform.releaseIdentityLease : null,
);

Future<IdentityRoles> loadIdentityRoles() => _identityRolesBootstrap.load();

/// The peer card always uses the connection key, never the publisher key.
Future<Identity> loadIdentity() async => (await loadIdentityRoles()).connection;

Future<Directory> pilotDirectory() async {
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/pilot-v1',
  );
  await directory.create(recursive: true);
  return directory;
}

Future<Map<String, dynamic>> readDeviceState() async {
  try {
    return {
      ...await PilotPlatform.state(),
      if (_discoveryLockError != null)
        'discoveryLockError': _discoveryLockError,
      if (_nearbyError != null) 'nearbyError': _nearbyError,
    };
  } catch (_) {
    return {
      'platform': Platform.operatingSystem,
      'wallTimeMs': DateTime.now().millisecondsSinceEpoch,
      'elapsedRealtimeMs': null,
      'bootId': null,
      'isLocked': null,
      'lockStateKnown': false,
    };
  }
}

@pragma('vm:entry-point')
void serviceMain(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  PeerEngine? engine;
  NearbyTransports? nearby;
  InternetOverlay? overlay;
  PhoneHelper? helper;
  Map<String, dynamic> overlayState = {'state': 'starting'};
  final probe = DeviceProbe(readDeviceState);
  const cacheOnlyTest =
      DeviceProbe.enabled &&
      bool.fromEnvironment('PERSIANTREND_E2E_CACHE_ONLY');
  Future<void> queue = Future.value();
  final initialized = Completer<void>();
  // A reopened Activity can send commands while the native service is still
  // initializing. Listen before the first await, then queue behind readiness.
  unawaited(
    initialized.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
  );
  service.on('command').listen((command) {
    if (command == null) return;
    queue = queue.then((_) async {
      try {
        await initialized.future;
        switch (command['action']) {
          case 'snapshot':
            await nearby?.refresh();
            unawaited(overlay?.refresh());
            final device = await readDeviceState();
            for (final transport in ['wifiDirect', 'bluetooth']) {
              if (device[transport] is Map) {
                service.invoke('nearbyStatus', {
                  'transport': transport,
                  'state': device[transport],
                });
              }
            }
            service.invoke('status', {
              ...await engine!.snapshot(),
              'overlay': overlayState,
            });
          case 'addPeer':
            await engine!.addPeer(
              PeerCard.fromJson(
                Map<String, dynamic>.from(command['peer'] as Map),
              ),
            );
          case 'removePeer':
            await engine!.removePeer(command['id'] as String);
          case 'publish':
            await engine!.publish(
              runId: command['runId'] as String,
              text: command['text'] as String,
            );
          case 'createChannel':
            await engine!.createChannel(
              name: command['name'] as String,
              description: command['description'] as String,
            );
          case 'publishToChannel':
            await engine!.publishToChannel(
              channelId: command['channelId'] as String,
              text: command['text'] as String,
            );
          case 'export':
            service.invoke('report', {
              'requestId': command['requestId'],
              'report': await engine!.exportReport(),
            });
          case 'stop':
            Object? stopError;
            try {
              await helper?.stop();
            } catch (_) {}
            try {
              await overlay?.stop();
            } catch (_) {}
            try {
              await nearby?.stop();
            } catch (_) {
              _nearbyError = 'nearby_stop_failed';
            }
            try {
              await engine!.stop();
            } catch (error) {
              stopError = error;
            }
            await setDiscoveryActive(false);
            if (stopError == null) {
              service.invoke('completed', {'requestId': command['requestId']});
            } else {
              service.invoke('failure', {
                'message': 'Receiving stopped with a storage error.',
                'requestId': command['requestId'],
              });
            }
            service.invoke('stopped', {});
            await service.stopSelf();
            return;
        }
        if (command['action'] != 'stop') {
          service.invoke('status', {
            ...await engine!.snapshot(),
            'overlay': overlayState,
          });
        }
        service.invoke('completed', {'requestId': command['requestId']});
      } catch (error) {
        service.invoke('failure', {
          'message': error.toString(),
          'requestId': command['requestId'],
        });
      }
    });
  });
  try {
    final directory = await pilotDirectory();
    final identities = await loadIdentityRoles();
    engine = PeerEngine(
      directory: directory,
      identity: identities.connection,
      publisherIdentity: identities.publisher,
      deliveryMode: await DeliveryModeStore(directory).load(),
      localWifiTransport: Platform.isAndroid
          ? AndroidLocalWifiTransport()
          : null,
      bootstrapPeers: await loadBootstrapPeers(),
      enablePeerReferrals: true,
      acceptTcpEnrollment: true,
      enableLanDiscovery: !cacheOnlyTest,
      enableUdpDiscovery: !cacheOnlyTest,
      deviceState: readDeviceState,
      onStatus: (value) {
        probe.record(value);
        service.invoke('status', {...value, 'overlay': overlayState});
      },
    );
    await setDiscoveryActive(true);
    await engine.start(activeMode: true);
    nearby = NearbyTransports(
      engine,
      onError: (value) => _nearbyError = value,
      onState: (transport, state) => service.invoke('nearbyStatus', {
        'transport': transport,
        'state': state,
      }),
    );
    if (!cacheOnlyTest) await nearby.start();
    if (!engine.nearbyOnly) {
      helper = PhoneHelper(engine);
      await helper.start();
      if (!cacheOnlyTest)
        overlay = InternetOverlay(
          engine,
          onState: (value) {
            overlayState = value;
            service.invoke('overlayStatus', value);
          },
        );
      await overlay?.start();
    } else {
      overlayState = {'state': 'disabled'};
    }
    initialized.complete();
    service.invoke('ready', {});
    service.invoke('status', {
      ...await engine.snapshot(),
      'overlay': overlayState,
    });
  } catch (error) {
    if (!initialized.isCompleted) initialized.completeError(error);
    service.invoke('failure', {
      'message': 'Receiving service could not start: $error',
    });
    try {
      try {
        await helper?.stop();
      } catch (_) {}
      try {
        await overlay?.stop();
      } catch (_) {}
      try {
        await nearby?.stop();
      } catch (_) {}
      try {
        await engine?.stop();
      } catch (_) {}
    } finally {
      await setDiscoveryActive(false);
      await service.stopSelf();
    }
  }
}

class AppController extends ChangeNotifier {
  AppController();

  @visibleForTesting
  AppController.forTesting({
    required Directory directory,
    required this.identity,
    Identity? publisherIdentity,
    required PeerEngine Function() createEngine,
  }) : publisherIdentity = publisherIdentity ?? identity,
       _engineFactory = createEngine {
    _directory = directory;
    _channelPreferences = ChannelPreferences(directory);
    loading = false;
  }

  Identity? identity;
  Identity? publisherIdentity;
  DeliveryMode deliveryMode = DeliveryMode.allNetworks;
  Map<String, dynamic> device = {};
  Map<String, dynamic> snapshot = {};
  Map<String, Map<String, dynamic>> nearbyStates = {};
  bool loading = true, busy = false, running = false, activeMode = false;
  String? error;
  String label = 'Test phone';
  String advertisedHost = '';
  String languageCode = 'fa';
  List<PeerCard> _bootstrapPeers = [];
  PeerEngine? _local;
  NearbyTransports? _localNearby;
  Directory? _directory;
  ChannelPreferences? _channelPreferences;
  final _service = FlutterBackgroundService();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Completer<void>> _commands = {};
  final Map<String, Completer<String>> _exports = {};
  final String _sessionId = base64UrlEncode(
    List<int>.generate(12, (_) => Random.secure().nextInt(256)),
  );
  PeerEngine Function()? _engineFactory;
  Future<void>? _initialization;
  Future<void> _settingsTail = Future<void>.value();
  bool _disposed = false;
  int _request = 0;

  @visibleForTesting
  String nextRequestId() => '$_sessionId:${++_request}';

  void _ensureAlive() {
    if (_disposed) throw StateError('This screen has closed.');
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _ensureAlive();
      _directory = await pilotDirectory();
      _ensureAlive();
      _channelPreferences = ChannelPreferences(_directory!);
      await _channelPreferences!.load();
      _ensureAlive();
      final identities = await loadIdentityRoles();
      identity = identities.connection;
      publisherIdentity = identities.publisher;
      _ensureAlive();
      device = await readDeviceState();
      _bootstrapPeers = await loadBootstrapPeers();
      await loadDisplaySettings();
      await loadDeliveryMode();
      _ensureAlive();
      if (_channelPreferences!.recoveryWarning != null) {
        error = languageCode == 'fa'
            ? 'انتخاب‌های ذخیره‌شدهٔ کانال‌ها قابل خواندن نبود. لطفاً انتخاب‌های دنبال‌کردن، پنهان‌کردن و اعتماد را دوباره تنظیم کنید.'
            : 'Saved channel choices could not be read. Please set your follow, hide and trust choices again.';
      }
      if (Platform.isAndroid) {
        _subscriptions.add(
          _service.on('nearbyStatus').listen((data) {
            if (_disposed) return;
            if (data?['transport'] is String && data?['state'] is Map) {
              nearbyStates[data!['transport'] as String] =
                  Map<String, dynamic>.from(data['state'] as Map);
              notifyListeners();
            }
          }),
        );
        _subscriptions.add(
          _service.on('status').listen((data) {
            if (_disposed) return;
            if (data != null) {
              snapshot = data;
              notifyListeners();
            }
          }),
        );
        _subscriptions.add(
          _service.on('overlayStatus').listen((data) {
            if (_disposed || data == null) return;
            snapshot = {...snapshot, 'overlay': data};
            notifyListeners();
          }),
        );
        _subscriptions.add(
          _service.on('failure').listen((data) {
            if (_disposed) return;
            final requestId = data?['requestId'];
            // Ignore replies to an earlier Activity's command. Its command
            // IDs cannot be reused by this controller instance.
            if (requestId != null &&
                !_commands.containsKey(requestId) &&
                !_exports.containsKey(requestId)) {
              return;
            }
            final message = data?['message']?.toString() ?? 'Receiving failed';
            error = message;
            _commands
                .remove(data?['requestId'])
                ?.completeError(StateError(message));
            _exports
                .remove(data?['requestId'])
                ?.completeError(StateError(message));
            notifyListeners();
          }),
        );
        _subscriptions.add(
          _service
              .on('completed')
              .listen(
                (data) => _commands.remove(data?['requestId'])?.complete(),
              ),
        );
        _subscriptions.add(
          _service.on('report').listen((data) {
            if (!_disposed && data != null && data['report'] is String) {
              _exports
                  .remove(data['requestId'])
                  ?.complete(data['report'] as String);
            }
          }),
        );
        _subscriptions.add(
          _service.on('stopped').listen((_) {
            if (_disposed) return;
            running = false;
            activeMode = false;
            notifyListeners();
          }),
        );
        // Configure attaches this UI isolate's event stream even when the
        // native service survived a previous Activity/UI engine instance.
        await _service.configure(
          androidConfiguration: AndroidConfiguration(
            onStart: serviceMain,
            autoStart: false,
            autoStartOnBoot: false,
            isForegroundMode: true,
            notificationChannelId: 'persiantrend_receiving',
            initialNotificationTitle: languageCode == 'fa'
                ? 'پرشین‌ترند · دریافت و همگام‌سازی'
                : 'PersianTrend · receiving and syncing',
            initialNotificationContent: languageCode == 'fa'
                ? 'جست‌وجوی همتاها و دریافت خبرهای امضاشده. برای توقف، برنامه را باز کنید.'
                : 'Finding peers and receiving signed news. Open the app to stop.',
            foregroundServiceNotificationId: 771,
            foregroundServiceTypes: [AndroidForegroundType.connectedDevice],
          ),
          iosConfiguration: IosConfiguration(autoStart: false),
        );
        _ensureAlive();
        if (await _service.isRunning()) {
          _ensureAlive();
          await PilotPlatform.requestNearbyPermissions();
          activeMode = true;
          running = true;
          await _send('snapshot');
          // An older/background engine cannot keep using a broader policy
          // than the durable preference loaded by this Activity.
          if (snapshot['deliveryMode'] != deliveryMode.name) {
            await stop();
          }
        } else {
          _local = _makeEngine();
          snapshot = await _local!.snapshot();
        }
      } else {
        _local = _makeEngine();
        snapshot = await _local!.snapshot();
      }
      loading = false;
      _ensureAlive();
      if (!running) {
        busy = true;
        notifyListeners();
        try {
          await start(active: Platform.isAndroid);
        } finally {
          busy = false;
        }
      }
    } catch (ex) {
      error = ex.toString();
    }
    loading = false;
    notifyListeners();
  }

  PeerEngine _makeEngine() {
    _ensureAlive();
    if (_engineFactory != null) return _engineFactory!();
    return PeerEngine(
      directory: _directory!,
      identity: identity!,
      publisherIdentity: publisherIdentity!,
      deliveryMode: deliveryMode,
      localWifiTransport: Platform.isAndroid
          ? AndroidLocalWifiTransport()
          : null,
      bootstrapPeers: _bootstrapPeers,
      deviceState: readDeviceState,
      onStatus: (value) {
        if (_disposed) return;
        snapshot = value;
        notifyListeners();
      },
    );
  }

  Future<void> perform(Future<void> Function() action) async {
    if (_disposed) return;
    if (busy || loading) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } catch (ex) {
      error = ex.toString();
    }
    busy = false;
    notifyListeners();
  }

  Future<void> start({required bool active}) async {
    _ensureAlive();
    if (identity == null) throw StateError('Identity is not ready');
    await _reconcileService();
    if (running) await stop();
    _ensureAlive();
    // Service startup reads the same durable mode. If the preference cannot be
    // committed, stay stopped rather than starting a stale, broader policy.
    if (_directory != null) {
      await _persistDeliveryMode();
    }
    if (active && Platform.isAndroid) {
      await PilotPlatform.requestNotifications();
      await PilotPlatform.requestNearbyPermissions();
      _ensureAlive();
      await _localNearby?.stop();
      _localNearby = null;
      await _local?.stop();
      await setDiscoveryActive(false);
      _local = null;
      final ready = Completer<void>();
      final sub = _service.on('ready').listen((_) {
        if (!ready.isCompleted) ready.complete();
      });
      final failure = _service.on('failure').listen((data) {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError(
              data?['message']?.toString() ??
                  'Receiving service could not start',
            ),
          );
        }
      });
      // Attach the handler before invoking the native start operation.
      final readyResult = ready.future.timeout(const Duration(seconds: 40));
      unawaited(
        readyResult.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      try {
        _ensureAlive();
        if (!await _service.startService()) {
          throw StateError('Android could not start receiving');
        }
        await readyResult;
      } catch (startupError) {
        if (!ready.isCompleted) ready.completeError(startupError);
        // Never launch a local engine alongside an uncertain native service.
        running = await _service.isRunning();
        activeMode = running;
        if (running) {
          try {
            await _send('stop');
            await waitForServiceStop(_service.isRunning);
          } catch (_) {
            running = await _service.isRunning();
            activeMode = running;
            if (running) {
              throw StateError(
                'Receiving did not start cleanly and may still be stopping. Use Stop receiving before starting another mode.',
              );
            }
          }
        }
        running = false;
        activeMode = false;
        if (!_disposed) {
          _local = _makeEngine();
          snapshot = await _local!.snapshot();
        }
        rethrow;
      } finally {
        await sub.cancel();
        await failure.cancel();
      }
      running = true;
      activeMode = true;
      if (_disposed) return; // The authorized foreground service survives UI.
      await _send('snapshot');
      // An optional system Bluetooth dialog must not hold IP receiving or the
      // primary UI behind its result. Native nearby refresh observes enabling.
      if (!DeviceProbe.enabled) unawaited(_enableBluetoothAfterReceiving());
    } else {
      _local ??= _makeEngine();
      final local = _local!;
      await setDiscoveryActive(true);
      try {
        await local.start(activeMode: false);
        _ensureAlive();
        if (Platform.isAndroid) {
          _localNearby = NearbyTransports(
            _local!,
            onError: (value) => _nearbyError = value,
            onState: (transport, state) {
              nearbyStates[transport] = state;
              notifyListeners();
            },
          );
          await _localNearby!.start();
          _ensureAlive();
        }
      } catch (_) {
        // Startup may fail after sockets or radios have already been opened.
        // Finish rollback even if one optional transport fails to stop.
        try {
          await _localNearby?.stop();
        } catch (_) {}
        _localNearby = null;
        try {
          await local.stop();
        } catch (_) {}
        await setDiscoveryActive(false);
        running = false;
        activeMode = false;
        rethrow;
      }
      running = true;
      activeMode = false;
      snapshot = await _local!.snapshot();
    }
    device = await readDeviceState();
    notifyListeners();
  }

  Future<void> _enableBluetoothAfterReceiving() async {
    if (_disposed || !Platform.isAndroid || !running || !activeMode) return;
    try {
      await PilotPlatform.enableBluetooth();
    } catch (_) {
      _nearbyError = 'bluetooth_enable_unavailable';
      notifyListeners();
    }
  }

  @visibleForTesting
  Future<void> loadDeliveryMode() async {
    _ensureAlive();
    final store = DeliveryModeStore(_directory!);
    deliveryMode = await store.load();
    if (store.recovered) {
      error = languageCode == 'fa'
          ? 'تنظیم اتصال قابل خواندن نبود؛ حالت فقط نزدیک انتخاب شد.'
          : 'The connection setting could not be read. Nearby only was selected.';
    }
    notifyListeners();
  }

  /// Close every existing route before changing policy. A failed commit leaves
  /// receiving paused, and a later start must commit this policy successfully.
  Future<void> setDeliveryMode(DeliveryMode value) => _saveSettings(() async {
    if (value == deliveryMode) return;
    await _reconcileService();
    final resume = running;
    final active = activeMode;
    await stop();
    deliveryMode = value;
    notifyListeners();
    await _local?.stop();
    _local = null;
    _local = _makeEngine();
    snapshot = await _local!.snapshot();
    await _persistDeliveryMode();
    if (resume) await start(active: active);
    notifyListeners();
  });

  Future<void> _persistDeliveryMode() async {
    try {
      await DeliveryModeStore(_directory!).save(deliveryMode);
    } catch (_) {
      throw StateError(
        languageCode == 'fa'
            ? 'تنظیم اتصال ذخیره نشد. دریافت متوقف است؛ پس از بررسی فضای ذخیره‌سازی دوباره تلاش کنید.'
            : 'The connection setting could not be saved. Receiving remains paused. Check available storage and try again.',
      );
    }
  }

  Future<void> stop() async {
    _ensureAlive();
    if (Platform.isAndroid && await _service.isRunning()) {
      await _send('stop');
      await waitForServiceStop(_service.isRunning);
      _local = null;
    } else {
      await _localNearby?.stop();
      _localNearby = null;
      await _local?.stop();
    }
    await setDiscoveryActive(false);
    running = false;
    activeMode = false;
    nearbyStates = {};
    _local ??= _makeEngine();
    snapshot = await _local!.snapshot();
    notifyListeners();
  }

  Future<void> refresh() async {
    _ensureAlive();
    device = await readDeviceState();
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('snapshot');
    } else {
      _local ??= _makeEngine();
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> enableNearby() async {
    _ensureAlive();
    if (!Platform.isAndroid) return;
    await PilotPlatform.requestNearbyPermissions();
    await PilotPlatform.enableBluetooth();
    await refresh();
  }

  Future<void> _reconcileService() async {
    _ensureAlive();
    if (!Platform.isAndroid || identity == null) return;
    final nativeRunning = await _service.isRunning();
    _ensureAlive();
    if (nativeRunning) {
      await _localNearby?.stop();
      _localNearby = null;
      await _local?.stop();
      _local = null;
      running = true;
      activeMode = true;
    } else if (activeMode || _local == null) {
      running = false;
      activeMode = false;
      _local = _makeEngine();
      snapshot = await _local!.snapshot();
    }
  }

  PeerCard ownCard({String? host}) => PeerCard(
    name: label,
    host: host ?? advertisedHost,
    certificatePem: identity!.certPem,
  );

  Future<void> _saveSettings(Future<void> Function() action) {
    _ensureAlive();
    final result = _settingsTail.then((_) {
      _ensureAlive();
      return action();
    });
    _settingsTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @visibleForTesting
  Future<void> loadDisplaySettings() async {
    _ensureAlive();
    final store = DisplaySettingsStore(_directory!, identity!);
    final settings = await store.load();
    _ensureAlive();
    if (settings != null) {
      label = settings['label']!;
      advertisedHost = settings['host']!;
      languageCode = settings['languageCode']!;
    }
    if (store.recovered) {
      error = languageCode == 'fa'
          ? 'تنظیمات نمایش قابل خواندن نبود؛ تنظیمات امن بازیابی شد.'
          : 'Display settings could not be read; safe settings were restored.';
    }
  }

  Future<void> saveDisplay(String name, String host) => _saveSettings(() async {
    final card = PeerCard(
      name: name,
      host: host,
      certificatePem: identity!.certPem,
    );
    await DisplaySettingsStore(_directory!, identity!).save({
      'label': card.name,
      'host': card.host,
      'languageCode': languageCode,
    });
    label = card.name;
    advertisedHost = card.host;
    notifyListeners();
  });

  Future<void> setLanguageCode(String value) async {
    if (value != 'fa' && value != 'en') {
      throw ArgumentError('Unsupported language');
    }
    await _saveSettings(() async {
      if (_directory != null) {
        await DisplaySettingsStore(
          _directory!,
          identity!,
        ).save({'label': label, 'host': advertisedHost, 'languageCode': value});
      }
      languageCode = value;
      notifyListeners();
    });
  }

  Set<String> get blockedChannelIds =>
      _channelPreferences?.blocked ?? const <String>{};

  Set<String> get followedChannelIds {
    final followed = <String>{...?_channelPreferences?.followed};
    for (final value in snapshot['channels'] as List? ?? const []) {
      if (value is Map &&
          value['ownerId'] == publisherIdentity?.id &&
          value['id'] is String) {
        followed.add(value['id'] as String);
      }
    }
    return followed.difference(blockedChannelIds);
  }

  bool isChannelBlocked(String id) => blockedChannelIds.contains(id);
  bool isChannelFollowed(String id) => followedChannelIds.contains(id);
  bool isChannelTrusted(String id) =>
      _channelPreferences?.isTrusted(id) ?? false;

  Future<void> followChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.follow(id));
  Future<void> unfollowChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.unfollow(id));
  Future<void> blockChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.block(id));
  Future<void> unblockChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.unblock(id));
  Future<void> trustChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.trust(id));
  Future<void> untrustChannel(String id) =>
      _changeChannelPreference((prefs) => prefs.untrust(id));

  Future<void> _changeChannelPreference(
    Future<void> Function(ChannelPreferences) change,
  ) async {
    _ensureAlive();
    final preferences = _channelPreferences;
    if (preferences == null) {
      throw StateError('Channel preferences are not ready');
    }
    await change(preferences);
    notifyListeners();
  }

  Future<void> createChannel(String name, String description) async {
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('createChannel', {'name': name, 'description': description});
    } else {
      _local ??= _makeEngine();
      await _local!.createChannel(name: name, description: description);
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> publishToChannel(String channelId, String text) async {
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('publishToChannel', {'channelId': channelId, 'text': text});
    } else {
      _local ??= _makeEngine();
      await _local!.publishToChannel(channelId: channelId, text: text);
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> addPeer(PeerCard peer) async {
    if (peer.id == identity!.id) {
      throw StateError(
        'This is this phone’s card. Import the other phone’s card.',
      );
    }
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('addPeer', {'peer': peer.toJson()});
    } else {
      _local ??= _makeEngine();
      await _local!.addPeer(peer);
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> removePeer(String id) async {
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('removePeer', {'id': id});
    } else {
      _local ??= _makeEngine();
      await _local!.removePeer(id);
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> publish(String runId, String text) async {
    await _reconcileService();
    if (!running) {
      throw StateError('Start receiving before sending a test bulletin.');
    }
    if (activeMode && Platform.isAndroid) {
      await _send('publish', {'runId': runId, 'text': text});
    } else {
      await _local!.publish(runId: runId, text: text);
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<void> export() async {
    await _reconcileService();
    String report;
    if (activeMode && Platform.isAndroid) {
      final requestId = nextRequestId();
      final result = Completer<String>();
      _exports[requestId] = result;
      _service.invoke('command', {'action': 'export', 'requestId': requestId});
      try {
        report = await result.future.timeout(const Duration(seconds: 20));
      } finally {
        _exports.remove(requestId);
      }
    } else {
      _local ??= _makeEngine();
      report = await _local!.exportReport();
    }
    _ensureAlive();
    await PilotPlatform.exportReport(report);
  }

  Future<void> _send(
    String action, [
    Map<String, dynamic> data = const {},
  ]) async {
    _ensureAlive();
    if (!await _service.isRunning()) {
      running = false;
      activeMode = false;
      _local = null;
      throw StateError(
        'Android stopped receiving. Start receiving again to resume.',
      );
    }
    _ensureAlive();
    final requestId = nextRequestId();
    final done = Completer<void>();
    _commands[requestId] = done;
    _service.invoke('command', {
      'action': action,
      'requestId': requestId,
      ...data,
    });
    try {
      await done.future.timeout(const Duration(seconds: 25));
    } finally {
      _commands.remove(requestId);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    final closed = StateError('This screen has closed.');
    for (final command in _commands.values) {
      if (!command.isCompleted) command.completeError(closed);
    }
    for (final result in _exports.values) {
      if (!result.isCompleted) result.completeError(closed);
    }
    _commands.clear();
    _exports.clear();
    final nearby = _localNearby;
    final local = _local;
    _localNearby = null;
    _local = null;
    // Only UI-owned resources stop here. Android's explicitly started
    // foreground service belongs to its own isolate and keeps receiving.
    unawaited(() async {
      try {
        await nearby?.stop();
      } catch (_) {}
      try {
        await local?.stop();
      } catch (_) {}
      if (nearby != null || local != null) {
        await setDiscoveryActive(false);
      }
    }());
    super.dispose();
  }
}

/// Small, crash-recoverable display preferences, separate from private channel
/// choices. Invalid files never prevent startup or change the signing identity.
class DisplaySettingsStore {
  DisplaySettingsStore(this.directory, this.identity);
  final Directory directory;
  final Identity identity;
  bool recovered = false;
  static const maxBytes = 4096;
  File get _file => File('${directory.path}/display.json');

  Map<String, String> _validate(Object? value) {
    if (value is! Map ||
        value['label'] is! String ||
        value['host'] is! String ||
        (value['languageCode'] != null &&
            value['languageCode'] != 'fa' &&
            value['languageCode'] != 'en')) {
      throw const FormatException('Invalid display settings.');
    }
    final card = PeerCard(
      name: value['label'] as String,
      host: value['host'] as String,
      certificatePem: identity.certPem,
    );
    return {
      'label': card.name,
      'host': card.host,
      'languageCode': value['languageCode'] as String? ?? 'fa',
    };
  }

  Future<Map<String, String>> _read(File file) async {
    if (await file.length() > maxBytes) {
      throw const FormatException('Display settings exceed the size limit.');
    }
    return _validate(jsonDecode(utf8.decode(await file.readAsBytes())));
  }

  Future<Map<String, String>?> load() async {
    final backup = File('${_file.path}.bak');
    for (final candidate in [_file, backup]) {
      if (!await candidate.exists()) continue;
      try {
        final value = await _read(candidate);
        if (candidate.path != _file.path) {
          recovered = true;
          if (await _file.exists()) await _file.delete();
          await candidate.rename(_file.path);
        }
        return value;
      } on FormatException {
        recovered = true;
      } on ArgumentError {
        recovered = true;
      } on FileSystemException {
        recovered = true;
      }
    }
    return null;
  }

  Future<void> save(Map<String, String> value) async {
    final validated = _validate(value);
    await directory.create(recursive: true);
    final next = File('${_file.path}.next');
    final backup = File('${_file.path}.bak');
    await next.writeAsString(jsonEncode(validated), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await _file.exists()) await _file.rename(backup.path);
    try {
      await next.rename(_file.path);
    } catch (_) {
      if (!await _file.exists() && await backup.exists()) {
        await backup.rename(_file.path);
      }
      rethrow;
    }
    // A successful commit remains successful if old-backup cleanup fails.
    try {
      if (await backup.exists()) await backup.delete();
    } on FileSystemException catch (_) {}
  }
}
