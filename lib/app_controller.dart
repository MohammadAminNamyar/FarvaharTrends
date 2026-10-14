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
import 'core/bootstrap_store.dart';
import 'core/identity.dart';
import 'core/channel_key_store.dart';
import 'core/reader_state.dart';
import 'core/identity_roles.dart';
import 'core/delivery_mode.dart';
import 'core/delivery_mode_store.dart';
import 'core/channel_preferences.dart';
import 'core/connection_report.dart' as diagnostics;
import 'core/models.dart';
import 'core/peer_contact.dart';
import 'core/peer_contact_store.dart';
import 'core/peer_engine.dart';
import 'core/receiving_policy_store.dart';
import 'core/service_lifecycle.dart';
import 'core/user_errors.dart';
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
const _appVersion = String.fromEnvironment(
  'FLUTTER_BUILD_NAME',
  defaultValue: 'development',
);

/// Built-in starting peers merged with the device's imported domestic seed.
/// Imported entries win over asset duplicates; the overall caps still apply.
Future<BootstrapConfig> loadBootstrapConfig(
  Directory directory, {
  BootstrapStore? store,
}) async {
  const hasOverride = bool.hasEnvironment('PERSIANTREND_BOOTSTRAP_JSON');
  const override = String.fromEnvironment('PERSIANTREND_BOOTSTRAP_JSON');
  final asset = parseBootstrapConfig(
    hasOverride
        ? override
        : await rootBundle.loadString('assets/bootstrap.json'),
  );
  final imported = await (store ?? BootstrapStore(directory)).load();
  return combineBootstrapConfigs(imported.toConfig(), asset);
}

Future<List<PeerCard>> loadBootstrapPeers(Directory directory) async =>
    (await loadBootstrapConfig(directory)).peers;

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

ChannelKeyStore channelKeyVault() => ChannelKeyStore(
  read: () => _vault.read(key: 'channelKeysV1'),
  write: (value) => _vault.write(key: 'channelKeysV1', value: value),
  acquire: Platform.isAndroid ? PilotPlatform.acquireIdentityLease : null,
  release: Platform.isAndroid ? PilotPlatform.releaseIdentityLease : null,
);
ReaderState readerState(Directory directory) => ReaderState(
  directory,
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
      if (_appVersion != 'development') 'appVersion': _appVersion,
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
  ReaderState? reader;
  String readerLanguage = 'fa';
  Map<String, dynamic>? latestReaderSnapshot;
  bool processingReader = false;
  Future<void> updateReader(Map<String, dynamic> value) async {
    latestReaderSnapshot = value;
    if (processingReader || reader == null) return;
    processingReader = true;
    try {
      while (latestReaderSnapshot != null) {
        final next = latestReaderSnapshot!;
        latestReaderSnapshot = null;
        final preferences = ChannelPreferences(reader.directory);
        await preferences.load();
        final followed = <String>{...preferences.followed};
        for (final channel in next['channels'] as List? ?? []) {
          if (channel is Map &&
              channel['canPublish'] == true &&
              channel['id'] is String) {
            followed.add(channel['id'] as String);
          }
        }
        final news = (next['bulletins'] as List? ?? [])
            .whereType<Map>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
        final arrivals = await reader!.observe(
          news,
          followed,
          preferences.blocked,
        );
        engine?.imageMode = reader!.images;
        engine?.setProtectedChannelIds(
          followed.difference(preferences.blocked),
        );
        final count = news
            .where(
              (v) =>
                  followed.contains(v['channelId']) &&
                  !preferences.blocked.contains(v['channelId']) &&
                  !reader!.muted.contains(v['channelId']) &&
                  !reader.readIds.contains(v['id']),
            )
            .length;
        await PilotPlatform.postNewsNotification(
          reader!.notifications ? count : 0,
          readerLanguage,
          alert: arrivals.isNotEmpty,
        );
        service.invoke('readerChanged', {
          'recoveryWarning': reader!.recoveryWarning != null,
        });
      }
    } catch (_) {
      service.invoke('readerChanged', {
        'recoveryWarning': reader.recoveryWarning != null,
      });
    } finally {
      processingReader = false;
    }
  }

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
        dynamic result;
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
          case 'clearTemporaryLog':
            await engine!.clearTemporaryLog();
            service.invoke('status', {
              ...await engine!.snapshot(),
              'overlay': overlayState,
            });
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
              imageBytes: command['image'] is String
                  ? base64Decode(command['image'] as String)
                  : null,
            );
          case 'exportChannelRecovery':
            result = await engine!.exportChannelRecovery(
              command['channelId'] as String,
              command['password'] as String,
            );
          case 'restoreChannelRecovery':
            result = await engine!.restoreChannelRecovery(
              command['file'] as String,
              command['password'] as String,
            );
          case 'createEditorRequest':
            result = await engine!.createEditorRequest(
              command['label'] as String,
            );
          case 'inspectEditorRequest':
            result = jsonEncode(
              engine!.inspectEditorRequest(command['file'] as String),
            );
          case 'approveEditor':
            result = await engine!.approveEditor(
              command['channelId'] as String,
              command['file'] as String,
            );
          case 'acceptEditorInvitation':
            result = await engine!.acceptEditorInvitation(
              command['file'] as String,
            );
          case 'removeChannel':
            await engine!.removeChannel(command['channelId'] as String);
          case 'setWriterNickname':
            await engine!.setWriterNickname(
              command['channelId'] as String,
              command['nickname'] as String,
            );
          case 'revokeEditor':
            await engine!.revokeEditor(
              command['channelId'] as String,
              command['grantId'] as String,
            );
          case 'removePublishedNews':
            await engine!.removePublishedNews(
              command['channelId'] as String,
              command['newsId'] as String,
            );
          case 'readerSettings':
            readerLanguage = command['language'] as String? ?? 'fa';
            await reader?.load();
            if (reader != null) engine!.imageMode = reader.images;
            await engine!.refreshImageTransfers();
            await updateReader(await engine!.snapshot());
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
              service.invoke('completed', {
                'requestId': command['requestId'],
                'result': result,
              });
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
        service.invoke('completed', {
          'requestId': command['requestId'],
          'result': result,
        });
      } catch (error) {
        service.invoke('failure', {
          'message': error.toString(),
          'code': userError(error).code,
          'requestId': command['requestId'],
        });
      }
    });
  });
  try {
    final directory = await pilotDirectory();
    final identities = await loadIdentityRoles();
    readerLanguage =
        (await DisplaySettingsStore(
          directory,
          identities.connection,
        ).load())?['languageCode'] ??
        'fa';
    reader = readerState(directory);
    await reader.load();
    final preferences = ChannelPreferences(directory);
    await preferences.load();
    final receivingPolicy = await ReceivingPolicyStore(directory).load();
    final bootstrap = await loadBootstrapConfig(directory);
    engine = PeerEngine(
      protectedChannelIds: preferences.followed.difference(preferences.blocked),
      channelKeys: channelKeyVault(),
      imageMode: reader.images,
      directory: directory,
      identity: identities.connection,
      publisherIdentity: identities.publisher,
      deliveryMode: await DeliveryModeStore(directory).load(),
      localWifiTransport: Platform.isAndroid
          ? AndroidLocalWifiTransport()
          : null,
      bootstrapPeers: bootstrap.peers,
      enablePeerReferrals: true,
      acceptTcpEnrollment: true,
      enableLanDiscovery: !cacheOnlyTest,
      enableUdpDiscovery: !cacheOnlyTest,
      deviceState: readDeviceState,
      onStatus: (value) {
        probe.record({...value, 'overlay': overlayState});
        unawaited(updateReader(value));
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
      if (!cacheOnlyTest) {
        overlay = InternetOverlay(
          engine,
          // Phones are ephemeral DHT clients: they never answer routing
          // queries from strangers. Operator-supplied domestic DHT nodes from
          // the bootstrap document are tried before the hyperdht defaults.
          announce: receivingPolicy.internetAnnounce,
          dhtBootstrap: bootstrap.dhtBootstrap,
          dhtEphemeral: true,
          networkKey: () async {
            final state = await readDeviceState();
            return state['stateUnavailable'] == true
                ? null
                : state['activeNetworkEpoch'] as String?;
          },
          onState: (value) {
            overlayState = value;
            unawaited(
              engine!.snapshot().then(
                (v) => probe.record({...v, 'overlay': value}),
              ),
            );
            service.invoke('overlayStatus', value);
          },
        );
      }
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
  AppController() : _configureServiceHook = null;

  @visibleForTesting
  AppController.forTesting({
    required Directory directory,
    required this.identity,
    Identity? publisherIdentity,
    ReaderState? reader,
    required PeerEngine Function() createEngine,
    Future<void> Function(bool autoStartOnBoot)? configureService,
  }) : publisherIdentity = publisherIdentity ?? identity,
       _engineFactory = createEngine,
       _configureServiceHook = configureService {
    _directory = directory;
    _channelPreferences = ChannelPreferences(directory);
    _reader = reader;
    _surfaceRecoveryWarnings();
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
  final List<String> _localErrorDetails = [];
  List<String> get localErrorDetails => List.unmodifiable(_localErrorDetails);
  void recordFailure(Object exception, {String? code}) {
    final detail = exception.toString();
    _localErrorDetails.add(
      detail.length > 512 ? detail.substring(0, 512) : detail,
    );
    if (_localErrorDetails.length > 20) _localErrorDetails.removeAt(0);
    error = userError(exception, code: code).text(languageCode);
  }

  void _surfaceRecoveryWarnings() {
    final codes = [
      if (_channelPreferences?.recoveryWarning != null) 'channel_recovery',
      if (_readerRecoveryWarningPending || _reader?.recoveryWarning != null)
        'reader_recovery',
    ];
    final messages = [
      for (final code in codes) userError('', code: code).text(languageCode),
      if (_bootstrapRecoveryWarning)
        languageCode == 'fa'
            ? 'فهرست همتاهای شروع واردشده قابل خواندن نبود و کنار گذاشته شد. همتاهای داخلی برنامه همچنان استفاده می‌شوند.'
            : 'The imported starting-peer list could not be read and was set aside. Built-in starting peers are still used.',
    ];
    if (messages.isNotEmpty) error = messages.join('\n');
  }

  String label = 'Test phone';
  String advertisedHost = '';
  String languageCode = 'fa';
  String get appVersion => _appVersion;
  BootstrapConfig _bootstrapConfig = BootstrapConfig.empty;
  BootstrapStore? _bootstrapStore;
  bool _bootstrapRecoveryWarning = false;

  /// Starting peers and operator DHT nodes in effect for the next engine:
  /// the built-in asset merged with the device's imported domestic seed.
  BootstrapConfig get bootstrapConfig => _bootstrapConfig;

  /// Saved opt-in: let the visible receiving service start again after a
  /// reboot or an OS kill. An explicit in-app Stop disarms the service for
  /// the session without changing this saved choice.
  bool restartAfterReboot = false;

  /// Saved choice: announce this installation on the public Internet
  /// discovery topic. Off means reader-only on the Internet: the phone still
  /// dials peers it learns about, but publishes no presence to the DHT.
  bool internetAnnounce = true;
  final Future<void> Function(bool autoStartOnBoot)? _configureServiceHook;
  PeerEngine? _local;
  NearbyTransports? _localNearby;
  Directory? _directory;
  ChannelPreferences? _channelPreferences;
  ReaderState? _reader;
  bool _readerRecoveryWarningPending = false;
  final _service = FlutterBackgroundService();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Completer<dynamic>> _commands = {};
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
      _reader = readerState(_directory!);
      await _reader!.load();
      _ensureAlive();
      final identities = await loadIdentityRoles();
      identity = identities.connection;
      publisherIdentity = identities.publisher;
      _ensureAlive();
      device = await readDeviceState();
      await loadBootstrapConfiguration();
      await loadDisplaySettings();
      await loadDeliveryMode();
      await loadReceivingPolicy();
      _ensureAlive();
      _surfaceRecoveryWarnings();
      if (Platform.isAndroid) {
        _subscriptions.add(
          _service.on('readerChanged').listen((data) {
            if (data?['recoveryWarning'] == true) {
              _readerRecoveryWarningPending = true;
            }
            unawaited(_refreshReader());
          }),
        );
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
              unawaited(_refreshReader());
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
            recordFailure(message, code: data?['code'] as String?);
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
                (data) => _commands
                    .remove(data?['requestId'])
                    ?.complete(data?['result']),
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
        // Boot re-arming stays armed only while the service is running.
        final nativeRunning = await _service.isRunning();
        _ensureAlive();
        await _configureService(
          autoStartOnBoot: restartAfterReboot && nativeRunning,
        );
        _ensureAlive();
        if (nativeRunning) {
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
      recordFailure(ex);
    }
    loading = false;
    notifyListeners();
  }

  /// The plugin stores `autoStartOnBoot` natively; the boot receiver and the
  /// sticky restart path honor it. Everything else here is session wiring.
  Future<void> _configureService({required bool autoStartOnBoot}) async {
    if (_configureServiceHook != null) {
      await _configureServiceHook(autoStartOnBoot);
      return;
    }
    if (!Platform.isAndroid) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: serviceMain,
        autoStart: false,
        autoStartOnBoot: autoStartOnBoot,
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
  }

  @visibleForTesting
  Future<void> loadReceivingPolicy() async {
    _ensureAlive();
    final store = ReceivingPolicyStore(_directory!);
    final policy = await store.load();
    restartAfterReboot = policy.restartAfterReboot;
    internetAnnounce = policy.internetAnnounce;
    if (store.recovered) {
      error = languageCode == 'fa'
          ? 'تنظیمات دریافت قابل خواندن نبود و به حالت پیش‌فرض برگشت.'
          : 'The receiving settings could not be read and were reset to their defaults.';
    }
    notifyListeners();
  }

  ReceivingPolicy get _receivingPolicy => ReceivingPolicy(
    restartAfterReboot: restartAfterReboot,
    internetAnnounce: internetAnnounce,
  );

  Future<void> _persistReceivingPolicy(ReceivingPolicy policy) async {
    try {
      await ReceivingPolicyStore(_directory!).save(policy);
    } catch (_) {
      throw StateError(
        languageCode == 'fa'
            ? 'تنظیم دریافت ذخیره نشد. فضای ذخیره‌سازی را بررسی کنید و دوباره تلاش کنید.'
            : 'The receiving setting could not be saved. Check available storage and try again.',
      );
    }
  }

  /// Persist the announce choice, then restart receiving so the Internet
  /// overlay joins the discovery topic with the new setting. Nearby and
  /// cached-contact paths are unaffected either way.
  Future<void> setInternetAnnounce(bool value) => _saveSettings(() async {
    if (value == internetAnnounce) return;
    await _persistReceivingPolicy(
      _receivingPolicy.copyWith(internetAnnounce: value),
    );
    internetAnnounce = value;
    notifyListeners();
    if (!running || deliveryMode == DeliveryMode.nearbyOnly) return;
    final active = activeMode;
    await stop();
    await start(active: active);
    notifyListeners();
  });

  /// Persist the opt-in first, then re-arm the running service to match.
  /// While receiving is stopped the service stays disarmed until the next
  /// normal start, so an explicit Stop is never undone by a reboot.
  Future<void> setRestartAfterReboot(bool value) => _saveSettings(() async {
    if (value == restartAfterReboot) return;
    await _persistReceivingPolicy(
      _receivingPolicy.copyWith(restartAfterReboot: value),
    );
    restartAfterReboot = value;
    await _configureService(autoStartOnBoot: value && running);
    notifyListeners();
  });

  @visibleForTesting
  Future<void> loadBootstrapConfiguration() async {
    _ensureAlive();
    final store = _bootstrapStore ??= BootstrapStore(_directory!);
    _bootstrapConfig = await loadBootstrapConfig(_directory!, store: store);
    _bootstrapRecoveryWarning = store.recoveryWarning == 'bootstrap_recovery';
    if (_bootstrapRecoveryWarning) _surfaceRecoveryWarnings();
  }

  /// Validate pasted text without side effects: a pairing token, one peer
  /// card or a starting-peer document (version 1 or 2). This phone's own card
  /// is left out; a document that only contained it is reported as such.
  BootstrapConfig parseBootstrapDocument(String text) {
    final parsed = parseBootstrapInput(text);
    final own = identity?.id;
    final cards = parsed.peers.where((card) => card.id != own).toList();
    if (parsed.peers.isNotEmpty &&
        cards.isEmpty &&
        parsed.dhtBootstrap.isEmpty) {
      throw const FormatException(
        'This is your own card. Use the other phone’s card.',
      );
    }
    if (cards.isEmpty && parsed.dhtBootstrap.isEmpty) {
      throw const FormatException('The starting-peer list is empty.');
    }
    return BootstrapConfig(
      peers: List<PeerCard>.unmodifiable(cards),
      dhtBootstrap: parsed.dhtBootstrap,
    );
  }

  /// Store dialing hints locally and pair every listed card, exactly like a
  /// manual card import. Nothing is gossiped; trust stays explicit per card.
  Future<BootstrapConfig> importBootstrapDocument(String text) async {
    _ensureAlive();
    final document = parseBootstrapDocument(text);
    final hints = BootstrapConfig(
      peers: document.peers.where((card) => card.host.isNotEmpty).toList(),
      dhtBootstrap: document.dhtBootstrap,
    );
    if (!hints.isEmpty && _directory != null) {
      final store = _bootstrapStore ??= BootstrapStore(_directory!);
      await store.import(hints);
      await loadBootstrapConfiguration();
    }
    for (final card in document.peers) {
      await addPeer(card);
    }
    notifyListeners();
    return document;
  }

  /// A version 2 document with this device's card (when it has a dialing
  /// address), currently valid public helper contacts and imported DHT nodes.
  /// LAN and loopback hints are never exported.
  Future<String> exportBootstrapDocument() async {
    _ensureAlive();
    final own = ownCard();
    final cards = <PeerCard>[if (own.host.isNotEmpty) own];
    var dhtBootstrap = const <String>[];
    if (_directory != null) {
      for (final contact in await PeerContactStore(_directory!).load()) {
        final address = InternetAddress.tryParse(contact.peer.host);
        if (address != null && PeerContact.isPublicAddress(address)) {
          cards.add(contact.peer);
        }
      }
      final store = _bootstrapStore ??= BootstrapStore(_directory!);
      dhtBootstrap = (await store.load()).toConfig().dhtBootstrap;
    }
    final document = combineBootstrapConfigs(
      BootstrapConfig(peers: cards),
      BootstrapConfig(dhtBootstrap: dhtBootstrap),
    );
    return jsonEncode(document.toJson());
  }

  /// Forget every imported starting peer and DHT node. Paired peers and
  /// built-in starting peers are unaffected.
  Future<void> removeImportedBootstrap() async {
    _ensureAlive();
    if (_directory == null) return;
    final store = _bootstrapStore ??= BootstrapStore(_directory!);
    await store.clear();
    await loadBootstrapConfiguration();
    notifyListeners();
  }

  PeerEngine _makeEngine() {
    _ensureAlive();
    if (_engineFactory != null) return _engineFactory!();
    return PeerEngine(
      directory: _directory!,
      channelKeys: channelKeyVault(),
      protectedChannelIds: followedChannelIds,
      imageMode: _reader?.images ?? 'wifiOnly',
      identity: identity!,
      publisherIdentity: publisherIdentity!,
      deliveryMode: deliveryMode,
      localWifiTransport: Platform.isAndroid
          ? AndroidLocalWifiTransport()
          : null,
      bootstrapPeers: _bootstrapConfig.peers,
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
      recordFailure(ex);
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
    // A normal start re-arms the saved opt-in before the service launches.
    // Only the visible foreground service may be restarted by the system.
    await _configureService(autoStartOnBoot: restartAfterReboot && active);
    _ensureAlive();
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
    // Disarm boot/sticky restarts before the service goes down so an explicit
    // Stop is never resurrected; the saved preference itself is untouched.
    await _configureService(autoStartOnBoot: false);
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

  Future<String> copyableConnectionReport() async {
    await refresh();
    return const JsonEncoder.withIndent('  ').convert(
      diagnostics.connectionReport(
        snapshot: snapshot,
        device: device,
        running: running,
        activeMode: activeMode,
        deliveryMode: deliveryMode.name,
        connectionId: identity?.id,
      ),
    );
  }

  Future<void> clearTemporaryLog() async {
    _localErrorDetails.clear();
    _ensureAlive();
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('clearTemporaryLog');
    } else {
      _local ??= _makeEngine();
      await _local!.clearTemporaryLog();
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
      await _readerSettingsChanged();
      notifyListeners();
    });
  }

  Set<String> get blockedChannelIds =>
      _channelPreferences?.blocked ?? const <String>{};

  Set<String> get followedChannelIds {
    final followed = <String>{...?_channelPreferences?.followed};
    for (final value in snapshot['channels'] as List? ?? const []) {
      if (value is Map &&
          (value['ownerId'] == publisherIdentity?.id ||
              value['canPublish'] == true ||
              value['owned'] == true) &&
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

  Future<void> followChannel(String id) async {
    await markChannelRead(id);
    await _changeChannelPreference((prefs) => prefs.follow(id));
  }

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
    await _readerSettingsChanged();
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

  bool get newsNotifications => _reader?.notifications ?? true;
  String get imageMode => _reader?.images ?? 'wifiOnly';
  bool isChannelMuted(String id) => _reader?.muted.contains(id) ?? false;
  int unreadFor(String id) => (snapshot['bulletins'] as List? ?? [])
      .whereType<Map>()
      .where(
        (v) =>
            v['channelId'] == id &&
            v['receivedVia'] != 'local' &&
            v['localPublication'] != true &&
            !(_reader?.readIds.contains(v['id']) ?? true) &&
            isChannelFollowed(id),
      )
      .length;
  int get unreadCount =>
      followedChannelIds.fold(0, (count, id) => count + unreadFor(id));
  Future<void> _refreshReader() async {
    try {
      await _reader?.load();
      _surfaceRecoveryWarnings();
      if (!Platform.isAndroid || !activeMode) {
        await _reader?.observe(
          (snapshot['bulletins'] as List? ?? [])
              .whereType<Map>()
              .map((v) => Map<String, dynamic>.from(v))
              .toList(),
          followedChannelIds,
          blockedChannelIds,
        );
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> markChannelRead(String id) async {
    await _reader?.markRead(
      (snapshot['bulletins'] as List? ?? [])
          .whereType<Map>()
          .where((v) => v['channelId'] == id)
          .map((v) => v['id'])
          .whereType<String>(),
    );
    await _readerSettingsChanged();
    notifyListeners();
  }

  Future<void> setNewsNotifications(bool enabled) async {
    await _reader?.setNotifications(enabled);
    if (enabled && Platform.isAndroid) {
      await PilotPlatform.requestNotifications();
    }
    await _readerSettingsChanged();
    notifyListeners();
  }

  Future<void> setImageMode(String mode) async {
    await _reader?.setImages(mode);
    _local?.imageMode = mode;
    await _local?.refreshImageTransfers();
    await _readerSettingsChanged();
    notifyListeners();
  }

  Future<void> setChannelMuted(String id, bool value) async {
    await _reader?.setMuted(id, value);
    await _readerSettingsChanged();
    notifyListeners();
  }

  Future<void> _readerSettingsChanged() async {
    _local?.setProtectedChannelIds(followedChannelIds);
    if (Platform.isAndroid && activeMode && await _service.isRunning()) {
      await _send('readerSettings', {'language': languageCode});
    }
  }

  Future<void> publishNewsWithImage(
    String id,
    String text,
    Uint8List image,
  ) async {
    await _reconcileService();
    if (activeMode && Platform.isAndroid) {
      await _send('publishToChannel', {
        'channelId': id,
        'text': text,
        'image': base64Encode(image),
      });
    } else {
      _local ??= _makeEngine();
      await _local!.publishToChannel(
        channelId: id,
        text: text,
        imageBytes: image,
      );
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
  }

  Future<String?> channelAction(
    String action,
    Map<String, dynamic> args,
  ) async {
    await _reconcileService();
    dynamic result;
    if (activeMode && Platform.isAndroid) {
      result = await _send(action, args);
    } else {
      _local ??= _makeEngine();
      switch (action) {
        case 'exportChannelRecovery':
          result = await _local!.exportChannelRecovery(
            args['channelId'] as String,
            args['password'] as String,
          );
        case 'restoreChannelRecovery':
          result = await _local!.restoreChannelRecovery(
            args['file'] as String,
            args['password'] as String,
          );
        case 'createEditorRequest':
          result = await _local!.createEditorRequest(args['label'] as String);
        case 'inspectEditorRequest':
          result = jsonEncode(
            _local!.inspectEditorRequest(args['file'] as String),
          );
        case 'approveEditor':
          result = await _local!.approveEditor(
            args['channelId'] as String,
            args['file'] as String,
          );
        case 'acceptEditorInvitation':
          result = await _local!.acceptEditorInvitation(args['file'] as String);
        case 'removeChannel':
          await _local!.removeChannel(args['channelId'] as String);
        case 'setWriterNickname':
          await _local!.setWriterNickname(
            args['channelId'] as String,
            args['nickname'] as String,
          );
        case 'revokeEditor':
          await _local!.revokeEditor(
            args['channelId'] as String,
            args['grantId'] as String,
          );
        case 'removePublishedNews':
          await _local!.removePublishedNews(
            args['channelId'] as String,
            args['newsId'] as String,
          );
        default:
          throw ArgumentError('Unknown channel action.');
      }
      snapshot = await _local!.snapshot();
    }
    notifyListeners();
    return result as String?;
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

  Future<dynamic> _send(
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
    final done = Completer<dynamic>();
    _commands[requestId] = done;
    _service.invoke('command', {
      'action': action,
      'requestId': requestId,
      ...data,
    });
    try {
      return await done.future.timeout(
        Duration(seconds: action.contains('Recovery') ? 120 : 25),
      );
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
