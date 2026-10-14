import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/app_controller.dart';
import 'package:persian_trend/core/delivery_mode.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity connection;
  late Identity publisher;

  setUpAll(() async {
    connection = Identity.generate();
    publisher = Identity.generate();
    for (final entry in {
      'Manrope': 'assets/fonts/Manrope.ttf',
      'Vazirmatn': 'assets/fonts/Vazirmatn.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  Future<_ModeController> showApp(
    WidgetTester tester, {
    String language = 'fa',
    DeliveryMode? mode,
    double scale = 1,
    Size size = const Size(390, 844),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final app = _ModeController(connection, publisher)..languageCode = language;
    if (mode != null) app.deliveryMode = mode;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      PersianTrendApp(controller: app, initialize: false, animateRadar: false),
    );
    await tester.pumpAndSettle();
    return app;
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    final scrollable = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    if (finder.evaluate().isEmpty) {
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pump();
      await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Finder option(DeliveryMode mode) =>
      find.byKey(ValueKey('delivery-mode-${mode.name}'));

  testWidgets('Farsi defaults to automatic all networks with nearby fallback', (
    tester,
  ) async {
    final app = await showApp(tester);
    await reveal(tester, find.byKey(const ValueKey('delivery-mode-card')));
    expect(app.deliveryMode, DeliveryMode.allNetworks);
    expect(find.text('فقط نزدیک'), findsOneWidget);
    expect(find.text('همهٔ شبکه‌ها'), findsOneWidget);
    expect(
      tester.widget<InkWell>(option(DeliveryMode.nearbyOnly)).onTap,
      isNotNull,
    );
    expect(
      tester.widget<InkWell>(option(DeliveryMode.allNetworks)).onTap,
      isNull,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('delivery-mode-explanation')))
          .data,
      allOf(
        contains('دیتای موبایل یا هر وای‌فای'),
        contains('وای‌فای محلی و بلوتوث هم فعال می‌مانند'),
        contains('همتای قابل دسترس'),
      ),
    );
    expect(
      Directionality.of(tester.element(option(DeliveryMode.nearbyOnly))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'English defaults to automatic all networks with honest route status',
    (tester) async {
      final app = await showApp(tester, language: 'en');
      await reveal(tester, option(DeliveryMode.allNetworks));
      expect(app.deliveryMode, DeliveryMode.allNetworks);
      expect(
        tester.widget<InkWell>(option(DeliveryMode.allNetworks)).onTap,
        isNull,
      );
      expect(
        find.textContaining('Automatic: Internet and domestic routes'),
        findsOneWidget,
      );
      await reveal(
        tester,
        find.byKey(const ValueKey('transport-priority-card')),
      );
      expect(find.text('1. Internet / domestic IP'), findsOneWidget);
      expect(find.text('Finding Internet peers automatically'), findsOneWidget);
      expect(
        find.textContaining('local Wi-Fi and Bluetooth available for fallback'),
        findsOneWidget,
      );
      expect(find.text('Blocked in this mode'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'An existing Farsi Nearby only choice keeps mobile data restricted',
    (tester) async {
      final app = await showApp(tester, mode: DeliveryMode.nearbyOnly);
      await reveal(tester, option(DeliveryMode.nearbyOnly));
      expect(app.deliveryMode, DeliveryMode.nearbyOnly);
      expect(
        tester.widget<InkWell>(option(DeliveryMode.nearbyOnly)).onTap,
        isNull,
      );
      expect(
        find.textContaining('برای برنامه‌های دیگر روشن بماند'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('English switches explicitly to all networks and back', (
    tester,
  ) async {
    final app = await showApp(
      tester,
      language: 'en',
      mode: DeliveryMode.nearbyOnly,
    );
    await reveal(tester, option(DeliveryMode.allNetworks));
    await tester.tap(option(DeliveryMode.allNetworks));
    await tester.pumpAndSettle();
    expect(app.deliveryMode, DeliveryMode.allNetworks);
    expect(app.changes, [DeliveryMode.allNetworks]);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('delivery-mode-explanation')))
          .data,
      contains('expose your connection IP'),
    );
    await reveal(tester, find.byKey(const ValueKey('transport-priority-card')));
    expect(find.text('1. Internet / domestic IP'), findsOneWidget);
    expect(find.text('Blocked in this mode'), findsNothing);
    await reveal(tester, option(DeliveryMode.nearbyOnly));
    await tester.tap(option(DeliveryMode.nearbyOnly));
    await tester.pumpAndSettle();
    expect(app.deliveryMode, DeliveryMode.nearbyOnly);
    await reveal(tester, find.byKey(const ValueKey('transport-priority-card')));
    expect(find.text('1. Local Wi-Fi'), findsOneWidget);
    expect(find.text('2. Bluetooth'), findsOneWidget);
    expect(find.text('Blocked in this mode'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Switching disables both choices until the operation finishes', (
    tester,
  ) async {
    final app = await showApp(
      tester,
      language: 'en',
      mode: DeliveryMode.nearbyOnly,
    );
    app.modeGate = Completer<void>();
    await reveal(tester, option(DeliveryMode.allNetworks));
    await tester.tap(option(DeliveryMode.allNetworks));
    await tester.pump();
    expect(app.busy, isTrue);
    expect(find.text('Preparing your connection…'), findsOneWidget);
    for (final mode in DeliveryMode.values) {
      expect(tester.widget<InkWell>(option(mode)).onTap, isNull);
    }
    app.modeGate!.complete();
    await tester.pumpAndSettle();
    expect(app.deliveryMode, DeliveryMode.allNetworks);
    expect(app.busy, isFalse);
    expect(app.changes, [DeliveryMode.allNetworks]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A failed switch keeps the selected mode and displays the error',
    (tester) async {
      final app = await showApp(
        tester,
        language: 'en',
        mode: DeliveryMode.nearbyOnly,
      );
      app.failNextChange = true;
      await reveal(tester, option(DeliveryMode.allNetworks));
      await tester.tap(option(DeliveryMode.allNetworks));
      await tester.pumpAndSettle();
      expect(app.deliveryMode, DeliveryMode.nearbyOnly);
      expect(app.error, contains('Could not save your connection choice.'));
      expect(app.busy, isFalse);
      await reveal(tester, option(DeliveryMode.allNetworks));
      await tester.tap(option(DeliveryMode.allNetworks));
      await tester.pumpAndSettle();
      expect(app.deliveryMode, DeliveryMode.allNetworks);
      expect(app.error, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Changing mode while paused does not suggest receiving resumed', (
    tester,
  ) async {
    final app = await showApp(
      tester,
      language: 'en',
      mode: DeliveryMode.nearbyOnly,
    );
    app.running = false;
    app.notifyListeners();
    await tester.pumpAndSettle();
    await reveal(tester, option(DeliveryMode.allNetworks));
    await tester.tap(option(DeliveryMode.allNetworks));
    await tester.pumpAndSettle();
    expect(app.running, isFalse);
    await reveal(tester, find.byKey(const ValueKey('discovery-status')));
    expect(find.text('Receiving is paused'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Nearby mode does not label stale remote connections as active', (
    tester,
  ) async {
    final app = await showApp(
      tester,
      language: 'en',
      mode: DeliveryMode.nearbyOnly,
    );
    app.snapshot['activeTransportCounts'] = {'ip': 7};
    app.notifyListeners();
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('transport-priority-card')));
    expect(find.text('Blocked in this mode'), findsNWidgets(2));
    expect(find.text('7 active'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A channel owned by the separate publisher keeps its write action',
    (tester) async {
      final app = await showApp(tester, language: 'en');
      final channelId = 'c' * 64;
      app.snapshot['channels'] = [
        {
          'id': channelId,
          'name': 'My public channel',
          'description': 'Updates',
          'ownerId': publisher.id,
          'owned': true,
        },
      ];
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(connection.id, isNot(publisher.id));
      expect(app.isChannelFollowed(channelId), isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Channels'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('My public channel'), findsOneWidget);
      expect(
        find.byKey(ValueKey('channel-compose-$channelId')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('follow-$channelId')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Reader settings expose the reboot opt-in with its limits', (
    tester,
  ) async {
    final app = await showApp(tester);
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('restart-after-reboot'));
    await tester.dragUntilVisible(
      toggle,
      find.byType(SingleChildScrollView).last,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('ادامهٔ دریافت پس از راه‌اندازی مجدد'), findsOneWidget);
    expect(
      find.textContaining('توقف اجباری و مدیریت باتری سازنده'),
      findsOneWidget,
    );
    expect(find.textContaining('تغییر نمی‌دهد'), findsOneWidget);
    expect(app.restartAfterReboot, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.restartChanges, [true]);
    expect(app.restartAfterReboot, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.restartChanges, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('English reboot opt-in copy names what still stops it', (
    tester,
  ) async {
    await showApp(tester, language: 'en');
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('restart-after-reboot'));
    await tester.dragUntilVisible(
      toggle,
      find.byType(SingleChildScrollView).last,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.text('Keep receiving after reboot'), findsOneWidget);
    expect(find.textContaining('Force-stop'), findsOneWidget);
    expect(
      find.textContaining('does not change what is shared'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final language in ['fa', 'en']) {
    testWidgets(
      '$language privacy distinguishes readers without promising safety',
      (tester) async {
        await showApp(tester, language: language);
        final notice = language == 'fa'
            ? 'خواندن یا بازنشر خبر به‌معنای نویسنده‌بودن شما نیست.'
            : 'Reading or forwarding news does not mean you originally published it.';
        expect(find.textContaining(notice), findsNothing);
        await reveal(tester, find.byKey(const ValueKey('privacy-details')));
        await tester.tap(
          find.text(language == 'fa' ? 'جزئیات حریم خصوصی' : 'Privacy details'),
        );
        await tester.pumpAndSettle();
        await reveal(tester, find.textContaining(notice));
        final text = tester.widget<Text>(find.textContaining(notice)).data!;
        expect(
          text,
          contains(
            language == 'fa'
                ? 'حتی دریافت خبر از خارج ایران، امنیت یا ناشناس‌ماندن شما را تضمین نمی‌کند.'
                : 'Receiving news from outside Iran does not guarantee safety or anonymity.',
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('$language mode selection fits a narrow screen at large text', (
      tester,
    ) async {
      await showApp(
        tester,
        language: language,
        mode: DeliveryMode.nearbyOnly,
        size: const Size(360, 800),
        scale: 1.8,
      );
      await reveal(tester, option(DeliveryMode.allNetworks));
      expect(tester.takeException(), isNull);
      await tester.tap(option(DeliveryMode.allNetworks));
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.byKey(const ValueKey('transport-priority-card')),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Render $language delivery mode preview', (tester) async {
      await showApp(tester, language: language);
      await reveal(tester, find.byKey(const ValueKey('delivery-mode-card')));
      final finder = find.byKey(const ValueKey('pilot-preview'));
      final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path =
              '${Directory.current.path}/artifacts/ui-mode-$language.png';
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    });
  }
}

/// Only the presentation boundary is faked; mode persistence and socket routing
/// have separate controller and engine tests.
class _ModeController extends AppController {
  _ModeController(Identity connection, Identity publisher) {
    identity = connection;
    publisherIdentity = publisher;
    loading = false;
    running = true;
    activeMode = true;
    snapshot = {
      'running': true,
      'connectedCount': 0,
      'discoveredCount': 0,
      'discoveryState': 'searching',
      'channels': <Map<String, dynamic>>[],
      'peers': <Map<String, dynamic>>[],
      'bulletins': <Map<String, dynamic>>[],
    };
  }

  final changes = <DeliveryMode>[];
  final restartChanges = <bool>[];
  Completer<void>? modeGate;
  bool failNextChange = false;

  @override
  Future<void> setRestartAfterReboot(bool value) async {
    restartAfterReboot = value;
    restartChanges.add(value);
    notifyListeners();
  }

  @override
  Future<void> setDeliveryMode(DeliveryMode value) async {
    await modeGate?.future;
    if (failNextChange) {
      failNextChange = false;
      throw StateError('Could not save your connection choice.');
    }
    deliveryMode = value;
    changes.add(value);
    notifyListeners();
  }
}
