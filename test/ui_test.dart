import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/app_controller.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/main.dart';

final _ownedId = '1'.padLeft(64, '1');
final _secondOwnedId = '3'.padLeft(64, '3');
final _otherId = '2'.padLeft(64, '2');
final _anotherId = '4'.padLeft(64, '4');
final _otherOwner = 'a'.padLeft(64, 'a');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity identity;

  setUpAll(() async {
    identity = Identity.generate();
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

  Future<_PreviewController> showApp(
    WidgetTester tester, {
    String language = 'en',
    Size size = const Size(390, 844),
    double scale = 1,
    bool running = true,
    bool animate = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final app = _PreviewController(identity)
      ..languageCode = language
      ..running = running;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('test-app-preview'),
        child: PersianTrendApp(
          key: UniqueKey(),
          controller: app,
          initialize: false,
          animateRadar: animate,
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/brand/logo.jpg'),
        tester.element(find.byType(Scaffold)),
      ),
    );
    if (animate) {
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
    return app;
  }

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(
      find
          .descendant(of: find.byType(NavigationBar), matching: find.text(name))
          .last,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Farsi timeout copy never exposes an English exception', (
    tester,
  ) async {
    final app = await showApp(tester, language: 'fa');
    await app.perform(
      () async => throw TimeoutException('Secret internal stack/path'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('زمان انتظار تمام شد. لطفاً دوباره تلاش کنید.'),
      findsOneWidget,
    );
    expect(find.textContaining('TimeoutException'), findsNothing);
    expect(find.textContaining('Secret internal'), findsNothing);
    expect(app.localErrorDetails.single, contains('TimeoutException'));
  });

  testWidgets('reader settings show the current build version', (tester) async {
    final app = await showApp(tester, language: 'fa');
    await tester.tap(find.byKey(const ValueKey('reader-settings')));
    await tester.pumpAndSettle();
    final version = find.byKey(const ValueKey('reader-app-version'));
    expect(version, findsOneWidget);
    final label = tester.widget<Text>(version).data!;
    expect(
      label,
      app.appVersion == 'development'
          ? 'نسخهٔ توسعه'
          : contains(app.appVersion),
    );
    expect(tester.takeException(), isNull);
  });

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
    } else {
      await tester.ensureVisible(finder);
    }
    await tester.pumpAndSettle();
  }

  Future<void> capture(
    WidgetTester tester,
    String name, {
    bool wholeApp = false,
  }) async {
    final finder = find.byKey(
      ValueKey(wholeApp ? 'test-app-preview' : 'pilot-preview'),
    );
    void repaint(Element element) {
      if (element is RenderObjectElement) element.renderObject.markNeedsPaint();
      element.visitChildren(repaint);
    }

    repaint(tester.element(finder));
    await tester.pump();
    final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('${Directory.current.path}/artifacts');
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('Farsi is the default language with RTL and bundled typeface', (
    tester,
  ) async {
    final app = _PreviewController(identity);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      PersianTrendApp(controller: app, initialize: false, animateRadar: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('پرشین‌ترند'), findsOneWidget);
    expect(find.text('در جست‌وجوی همتاها'), findsOneWidget);
    final context = tester.element(
      find.byKey(const ValueKey('discovery-card')),
    );
    expect(Directionality.of(context), TextDirection.rtl);
    expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, 'Vazirmatn');
    expect(Localizations.localeOf(context).languageCode, 'fa');
    expect(find.text('Numeric IP address'), findsNothing);
    expect(find.text('Import a peer card or starting-peer list'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Language switch changes locale, direction and controls', (
    tester,
  ) async {
    final app = await showApp(tester, language: 'fa');
    await tester.tap(find.byKey(const ValueKey('language-switch')));
    await tester.pumpAndSettle();
    expect(app.languageCode, 'en');
    expect(find.text('Connection'), findsWidgets);
    expect(
      Directionality.of(
        tester.element(find.byKey(const ValueKey('discovery-card'))),
      ),
      TextDirection.ltr,
    );
    await tab(tester, 'Channels');
    expect(find.text('Create a channel'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('language-switch')));
    await tester.pumpAndSettle();
    expect(app.languageCode, 'fa');
    expect(find.text('ساخت کانال'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Discovery honestly distinguishes searching, waiting and connected',
    (tester) async {
      final app = await showApp(tester);
      expect(find.text('Searching for peers'), findsOneWidget);
      expect(find.byKey(const ValueKey('peer-radar')), findsOneWidget);
      app.update({'discoveryState': 'waitingForBootstrap'});
      await tester.pumpAndSettle();
      expect(find.text('Waiting for a starting peer'), findsOneWidget);
      expect(
        find.text(
          'Discovery continues over available paths. Connecting to other devices depends on network conditions.',
        ),
        findsOneWidget,
      );
      app.update({'connectedCount': 2, 'discoveredCount': 2});
      await tester.pumpAndSettle();
      expect(find.text('You are connected'), findsOneWidget);
      app.running = false;
      app.update({});
      await tester.pumpAndSettle();
      expect(find.text('Receiving is paused'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Live radar animates without inventing contacts', (tester) async {
    await showApp(tester, animate: true);
    final radar = find.byKey(const ValueKey('peer-radar'));
    expect(
      find.descendant(of: radar, matching: find.text('0')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in ['fa', 'en']) {
    testWidgets('$language connection counts exclude remembered peers', (
      tester,
    ) async {
      final app = await showApp(tester, language: language);
      app.update({'connectedCount': 1, 'discoveredCount': 2, 'peerCount': 2});
      await tester.pumpAndSettle();
      final radar = find.byKey(const ValueKey('peer-radar'));
      final metric = find.byKey(const ValueKey('active-connections-metric'));
      final one = language == 'fa' ? '۱' : '1';
      final two = language == 'fa' ? '۲' : '2';
      expect(
        find.descendant(of: radar, matching: find.text(one)),
        findsOneWidget,
      );
      await reveal(tester, metric);
      expect(
        find.descendant(of: metric, matching: find.text(one)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: metric, matching: find.text(two)),
        findsNothing,
      );
      expect(
        find.text(language == 'fa' ? 'اتصال‌های فعال' : 'ACTIVE CONNECTIONS'),
        findsOneWidget,
      );
      expect(
        find.text(language == 'fa' ? 'همتای پیدا‌شده' : 'DISCOVERED PEERS'),
        findsNothing,
      );
      app.update({'connectedCount': 0});
      await tester.pumpAndSettle();
      final zero = language == 'fa' ? '۰' : '0';
      final scrollable = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: radar, matching: find.text(zero)),
        findsOneWidget,
      );
      await reveal(tester, metric);
      expect(
        find.descendant(of: metric, matching: find.text(zero)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'An outbound discovery sender failure does not mark the LAN receiver unavailable',
    (tester) async {
      final app = await showApp(tester);
      await reveal(
        tester,
        find.byKey(const ValueKey('transport-priority-card')),
      );
      for (final diagnostic in [
        'discovery_multicast_sender_failed_os_error_101',
        'discovery_unicast_sender_failed_os_error_10051',
        'discovery_multicast_sender_closed',
        'discovery_unicast_sender_closed',
      ]) {
        app.update({'discoveryLastError': diagnostic});
        await tester.pumpAndSettle();
        expect(find.text('Limited discovery; still searching'), findsOneWidget);
        expect(find.text('Discovery unavailable'), findsNothing);
      }
      app.update({'discoveryLastError': 'discovery_bind_failed_os_error_98'});
      await tester.pumpAndSettle();
      expect(find.text('Discovery unavailable'), findsOneWidget);
      expect(find.text('Limited discovery; still searching'), findsNothing);
      app.languageCode = 'fa';
      app.update({
        'discoveryLastError': 'discovery_multicast_sender_failed_os_error_101',
      });
      await tester.pumpAndSettle();
      expect(find.text('کشف محدود؛ جست‌وجو ادامه دارد'), findsOneWidget);
      expect(find.text('کشف محلی در دسترس نیست'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Connection exposes pause and resume without Advanced tools', (
    tester,
  ) async {
    final app = await showApp(tester);
    final toggle = find.byKey(const ValueKey('toggle-receiving'));
    await reveal(tester, toggle);
    expect(find.byTooltip('Pause receiving'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.running, isFalse);
    expect(find.byTooltip('Resume receiving'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.running, isTrue);
    expect(find.byTooltip('Pause receiving'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A legacy out-of-range timestamp cannot crash a followed feed', (
    tester,
  ) async {
    final app = await showApp(tester);
    app.update({
      'channels': [_foreignChannel(_otherId, 'Legacy channel')],
      'bulletins': [
        {
          ..._newsItem(_otherId, 'Readable legacy news'),
          'createdAtMs': 9007199254740991,
        },
      ],
    });
    await app.followChannel(_otherId);
    await tab(tester, 'News');
    expect(find.text('Readable legacy news'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['fa', 'en']) {
    testWidgets('$language connection privacy states GPS and network limits', (
      tester,
    ) async {
      await showApp(tester, language: language);
      await reveal(tester, find.byKey(const ValueKey('privacy-details')));
      await tester.tap(
        find.text(language == 'fa' ? 'جزئیات حریم خصوصی' : 'Privacy details'),
      );
      await tester.pumpAndSettle();
      final text = language == 'fa'
          ? 'سرور مرکزی اجباری برای جمع‌آوری خبر یا انتخاب‌های شما نداریم. خبرهای عمومی میان همتاها جابه‌جا می‌شوند؛ انتخاب دنبال‌کردن و اعتماد روی این گوشی می‌ماند. در حالت همهٔ شبکه‌ها، شبکهٔ کشف عمومی به یافتن همتاها کمک می‌کند و همتاهای آن می‌توانند اطلاعات اتصال را ببینند. کلید انتشار از کلید اتصال جداست. موقعیت GPS را نمی‌خوانیم.'
          : 'There is no required central server collecting your news or choices. Public news moves between peers; follow and trust choices stay on this phone. In All networks mode, a public discovery network helps find peers and its peers can observe connection metadata. Publishing and connections use separate keys. We do not read your GPS location.';
      await reveal(tester, find.text(text));
      expect(find.text(text), findsOneWidget);
      final limits = language == 'fa'
          ? 'خواندن یا بازنشر خبر به‌معنای نویسنده‌بودن شما نیست. حتی دریافت خبر از خارج ایران، امنیت یا ناشناس‌ماندن شما را تضمین نمی‌کند.\n\nهمتای نزدیک و زمان ارسال ممکن است شما را مشخص کند. در حالت همهٔ شبکه‌ها، همتاها و اپراتور IP اتصال شما را می‌بینند. ارتباط‌های هویتی نسخه‌های قبلی پاک نمی‌شوند.'
          : 'Reading or forwarding news does not mean you originally published it. Receiving news from outside Iran does not guarantee safety or anonymity.\n\nNearby peers and timing may identify you. In All networks mode, peers and your provider can see your connection IP. Earlier identity links cannot be erased.';
      await reveal(tester, find.text(limits));
      expect(find.text(limits), findsOneWidget);
      expect(find.byKey(const ValueKey('change-network-mode')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'An offline user can create a channel and save news while paused',
    (tester) async {
      final app = await showApp(tester, running: false);
      await tab(tester, 'Channels');
      await tester.tap(find.byKey(const ValueKey('create-channel')));
      await tester.pumpAndSettle();
      expect(find.text('A home for your updates'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('channel-name')),
        'Public notices',
      );
      await tester.enterText(
        find.byKey(const ValueKey('channel-description')),
        'Useful public updates',
      );
      await tester.tap(find.text('Create channel'));
      await tester.pumpAndSettle();
      expect(app.channelCreations, [
        ('Public notices', 'Useful public updates'),
      ]);
      expect(find.text('Your channel'), findsOneWidget);
      final publish = find.byKey(ValueKey('channel-compose-$_ownedId'));
      await reveal(tester, publish);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('news-text')),
        'This is a public test update.',
      );
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('news-review-text')), findsOneWidget);
      expect(app.newsPublications, isEmpty);
      await tester.tap(find.text('Sign & publish'));
      await tester.pumpAndSettle();
      expect(app.newsPublications, [
        (_ownedId, 'This is a public test update.'),
      ]);
      expect(app.running, isFalse);
      await tab(tester, 'News');
      expect(find.text('This is a public test update.'), findsOneWidget);
      expect(
        find.text('Valid digital signature · public news'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Publishing rejects oversized UTF-8 text before calling controller',
    (tester) async {
      final app = await showApp(tester);
      await app.createChannel('Owned', '');
      await tab(tester, 'News');
      await tester.tap(find.byKey(const ValueKey('compose-news')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('news-text')),
        List.filled(600, 'ش').join(),
      );
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(
        find.text('Text too long. Shorten it before continuing.'),
        findsWidgets,
      );
      expect(app.newsPublications, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Foreign channels begin not assessed and cannot be published to',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [
          <String, dynamic>{
            'id': _otherId,
            'name': 'Other source',
            'description': '',
            'ownerId': _otherOwner,
            'owned': false,
          },
        ],
      });
      await tab(tester, 'Channels');
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Other source'));
      expect(find.text('Other source'), findsOneWidget);
      expect(find.text('Not assessed'), findsOneWidget);
      expect(find.text('Write news'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Advanced pairing stays behind diagnostics and exports require disclosure',
    (tester) async {
      final app = await showApp(tester);
      await tester.tap(find.byKey(const ValueKey('advanced-diagnostics')));
      await tester.pumpAndSettle();
      expect(find.text('Advanced diagnostics'), findsOneWidget);
      await tab(tester, 'Peers');
      expect(
        find.text('Import a peer card or starting-peer list'),
        findsOneWidget,
      );
      await tab(tester, 'Results');
      final export = find.widgetWithText(OutlinedButton, 'Export trial report');
      await reveal(tester, export);
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(find.textContaining('public peer fingerprints'), findsOneWidget);
      expect(app.exportCount, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Export report'));
      await tester.pumpAndSettle();
      expect(app.exportCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Reader navigation includes Temporary log without Results', (
    tester,
  ) async {
    await showApp(tester);
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    expect(find.text('Results'), findsNothing);
    expect(find.text('Export trial report'), findsNothing);
  });

  testWidgets('Foreign news is opt-in and unfollow removes it from the feed', (
    tester,
  ) async {
    final app = await showApp(tester);
    app.update({
      'channels': [
        _foreignChannel(_otherId, 'Community'),
        _foreignChannel(_anotherId, 'Weather'),
      ],
      'bulletins': [
        _newsItem(_otherId, 'Community update'),
        _newsItem(_anotherId, 'Weather update'),
        {
          'id': 'legacy',
          'text': 'Legacy pilot message',
          'createdAtMs': 1770000000000,
        },
      ],
    });
    await tab(tester, 'News');
    expect(find.text('Community update'), findsNothing);
    expect(find.text('Weather update'), findsNothing);
    expect(find.text('Legacy pilot message'), findsNothing);
    await tab(tester, 'Channels');
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    final follow = find.byKey(ValueKey('follow-$_otherId'));
    await reveal(tester, follow);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    expect(app.isChannelFollowed(_otherId), isTrue);
    await tab(tester, 'News');
    await reveal(tester, find.text('Community update'));
    expect(find.text('Community update'), findsOneWidget);
    expect(find.text('Weather update'), findsNothing);
    expect(find.text('Legacy pilot message'), findsNothing);
    expect(find.text('Received via local Wi-Fi'), findsOneWidget);
    await tab(tester, 'Channels');
    await reveal(tester, follow);
    await tester.tap(follow);
    await tester.pumpAndSettle();
    await tab(tester, 'News');
    expect(find.text('Community update'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Block hides a channel and unblock does not silently follow it', (
    tester,
  ) async {
    final app = await showApp(tester);
    app.update({
      'channels': [_foreignChannel(_otherId, 'Community')],
    });
    await app.followChannel(_otherId);
    await tab(tester, 'Channels');
    final menu = find.byKey(ValueKey('channel-menu-$_otherId'));
    await reveal(tester, menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block channel'));
    await tester.pumpAndSettle();
    expect(find.text('Block this channel?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();
    expect(app.isChannelBlocked(_otherId), isTrue);
    expect(app.isChannelFollowed(_otherId), isFalse);
    await reveal(tester, find.text('Discover'));
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('channel-card-$_otherId')), findsNothing);
    final manage = find.byKey(const ValueKey('manage-blocked-channels'));
    await reveal(tester, manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('unblock-$_otherId')));
    await tester.pumpAndSettle();
    expect(app.isChannelBlocked(_otherId), isFalse);
    expect(app.isChannelFollowed(_otherId), isFalse);
    expect(find.text('No blocked channels.'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Search accepts a real channel ID and reveals the full key only in details',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [
          _foreignChannel(_otherId, 'Community'),
          _foreignChannel(_anotherId, 'Weather'),
        ],
      });
      await tab(tester, 'Channels');
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('channel-search'));
      await tester.enterText(search, _otherId);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Community'));
      expect(find.text('Weather'), findsNothing);
      expect(find.text(_otherOwner), findsNothing);
      expect(find.text('aaaaaaaaaa…aaaaaaaa'), findsNothing);
      await tester.tap(find.byKey(ValueKey('channel-menu-$_otherId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channel ID & publisher key'));
      await tester.pumpAndSettle();
      expect(find.text(List.filled(8, 'aaaaaaaa').join(' ')), findsOneWidget);
      expect(find.text(List.filled(8, '22222222').join(' ')), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('clear-channel-search')));
      await tester.tap(find.byKey(const ValueKey('clear-channel-search')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      await tester.enterText(search, 'nothing matches');
      await tester.pumpAndSettle();
      await reveal(tester, find.text('No matching channels'));
      expect(find.text('No matching channels'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Create validates, stays open on failure and waits for persistence',
    (tester) async {
      final app = await showApp(tester);
      await tab(tester, 'Channels');
      await tester.tap(find.byKey(const ValueKey('create-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
      await tester.pumpAndSettle();
      expect(find.text('Give your channel a name.'), findsOneWidget);
      expect(app.channelCreations, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('channel-name')),
        'Community',
      );
      app.failNextCreate = true;
      await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-channel-page')), findsOneWidget);
      expect(app.channelCreations, isEmpty);
      expect(find.text('Channel created on this device.'), findsNothing);
      app.creationGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
      await tester.pump();
      expect(find.byKey(const ValueKey('create-channel-page')), findsOneWidget);
      expect(app.channelCreations, isEmpty);
      app.creationGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('create-channel-page')), findsNothing);
      expect(app.channelCreations, [('Community', '')]);
      expect(app.isChannelFollowed(_ownedId), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Compose reviews the selected channel, keeps edits and survives save failure',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [
          {
            'id': _ownedId,
            'name': 'First channel',
            'description': '',
            'ownerId': identity.id,
            'owned': true,
          },
          {
            'id': _secondOwnedId,
            'name': 'Second channel',
            'description': '',
            'ownerId': identity.id,
            'owned': true,
          },
        ],
      });
      await tab(tester, 'News');
      await tester.tap(find.byKey(const ValueKey('compose-news')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(find.text('Write your news before reviewing it.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('compose-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second channel').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('news-text')),
        'A specific channel update',
      );
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(find.text('Second channel'), findsOneWidget);
      expect(app.newsPublications, isEmpty);
      final edit = find.byKey(const ValueKey('edit-news'));
      await reveal(tester, edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('news-text')))
            .controller!
            .text,
        'A specific channel update',
      );
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      app.failNextPublish = true;
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('compose-news-page')), findsOneWidget);
      expect(app.newsPublications, isEmpty);
      expect(
        find.text(
          'Signed and saved on this device. Delivery needs a connection.',
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      expect(app.newsPublications, [
        (_secondOwnedId, 'A specific channel update'),
      ]);
      expect(find.byKey(const ValueKey('compose-news-page')), findsNothing);
      expect(find.text('A specific channel update'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Private trust waits for saving and keeps the prior choice on errors',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [_foreignChannel(_otherId, 'Community')],
      });
      await tab(tester, 'Channels');
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      final menu = find.byKey(ValueKey('channel-menu-$_otherId'));
      await reveal(tester, menu);
      expect(find.text('Not assessed'), findsOneWidget);
      app.trustGate = Completer<void>();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('trust-channel-$_otherId')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(ValueKey('trust-pending-$_otherId')), findsOneWidget);
      expect(app.isChannelTrusted(_otherId), isFalse);
      expect(find.text('Not assessed'), findsOneWidget);
      app.trustGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Trusted by you'), findsOneWidget);
      expect(app.isChannelFollowed(_otherId), isFalse);
      expect(app.newsPublications, isEmpty);
      app.failNextUntrust = true;
      await reveal(tester, menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('untrust-channel-$_otherId')));
      await tester.pumpAndSettle();
      expect(find.text('Trusted by you'), findsOneWidget);
      expect(app.isChannelTrusted(_otherId), isTrue);
      await reveal(tester, find.byKey(ValueKey('trust-error-$_otherId')));
      expect(
        find.text('Your choice was not saved. Try again.'),
        findsOneWidget,
      );
      app.untrustGate = Completer<void>();
      await reveal(tester, menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('untrust-channel-$_otherId')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(app.isChannelTrusted(_otherId), isTrue);
      expect(find.byKey(ValueKey('trust-pending-$_otherId')), findsOneWidget);
      app.untrustGate!.complete();
      await tester.pumpAndSettle();
      expect(app.isChannelTrusted(_otherId), isFalse);
      expect(find.text('Not assessed'), findsOneWidget);
      app.failNextTrust = true;
      await reveal(tester, menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('trust-channel-$_otherId')));
      await tester.pumpAndSettle();
      expect(app.isChannelTrusted(_otherId), isFalse);
      expect(find.text('Not assessed'), findsOneWidget);
      expect(app.newsPublications, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Trust stays separate from following, hiding, signatures and publication',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [_foreignChannel(_otherId, 'Community')],
        'bulletins': [_newsItem(_otherId, 'Community update')],
      });
      await app.trustChannel(_otherId);
      await tab(tester, 'News');
      expect(find.text('Community update'), findsNothing);
      await app.followChannel(_otherId);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Community update'));
      expect(find.text('Trusted by you'), findsOneWidget);
      expect(
        find.text('Valid digital signature · public news'),
        findsOneWidget,
      );
      await tab(tester, 'Channels');
      final follow = find.byKey(ValueKey('follow-$_otherId'));
      await reveal(tester, follow);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(app.isChannelFollowed(_otherId), isFalse);
      expect(app.isChannelTrusted(_otherId), isTrue);
      expect(app.newsPublications, isEmpty);
      expect(app.channelCreations, isEmpty);
      await app.blockChannel(_otherId);
      await app.unblockChannel(_otherId);
      expect(app.isChannelTrusted(_otherId), isFalse);
      expect(app.isChannelFollowed(_otherId), isFalse);
      await app.followChannel(_otherId);
      await tab(tester, 'News');
      await reveal(tester, find.text('Community update'));
      expect(find.text('Not assessed'), findsOneWidget);
      expect(
        find.text('Valid digital signature · public news'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Farsi private trust controls remain clear on a narrow screen', (
    tester,
  ) async {
    final app = await showApp(
      tester,
      language: 'fa',
      size: const Size(360, 800),
      scale: 1.4,
    );
    app.update({
      'channels': [_foreignChannel(_otherId, 'اطلاعیه‌های عمومی')],
    });
    await tab(tester, 'کانال‌ها');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('channel-sections')),
        matching: find.text('کشف کانال‌ها'),
      ),
    );
    await tester.pumpAndSettle();
    final menu = find.byKey(ValueKey('channel-menu-$_otherId'));
    await reveal(tester, menu);
    expect(find.text('هنوز ارزیابی نکرده‌اید'), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('trust-channel-$_otherId')));
    await tester.pumpAndSettle();
    expect(find.text('مورد اعتماد شما'), findsOneWidget);
    await reveal(tester, menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('برداشتن اعتماد'), findsOneWidget);
    expect(find.text('مسدودکردن کانال'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blocked owned channels stay out of every publish chooser', (
    tester,
  ) async {
    final app = await showApp(tester);
    app.update({
      'channels': [
        {
          'id': _ownedId,
          'name': 'Blocked channel',
          'description': '',
          'ownerId': identity.id,
          'owned': true,
        },
        {
          'id': _secondOwnedId,
          'name': 'Available channel',
          'description': '',
          'ownerId': identity.id,
          'owned': true,
        },
      ],
    });
    await app.blockChannel(_ownedId);
    await tab(tester, 'Channels');
    final write = find.byKey(ValueKey('channel-compose-$_secondOwnedId'));
    await reveal(tester, write);
    await tester.tap(write);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('compose-channel')),
          )
          .initialValue,
      _secondOwnedId,
    );
    await tester.tap(find.byKey(const ValueKey('compose-channel')));
    await tester.pumpAndSettle();
    expect(find.text('Blocked channel'), findsNothing);
    await tester.tap(find.text('Available channel').last);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tab(tester, 'News');
    await tester.tap(find.byKey(const ValueKey('compose-news')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('compose-channel')),
          )
          .initialValue,
      _secondOwnedId,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await app.blockChannel(_secondOwnedId);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compose-news')), findsNothing);
    await tab(tester, 'Channels');
    expect(find.byKey(const ValueKey('create-channel')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('create-channel')))
          .onPressed,
      isNotNull,
    );
    expect(app.newsPublications, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Channel list shows four sources without scrolling', (
    tester,
  ) async {
    final app = await showApp(tester);
    final ids = [_otherId, _anotherId, _ownedId, _secondOwnedId];
    app.update({
      'channels': [
        for (var i = 0; i < ids.length; i++)
          _foreignChannel(ids[i], 'News source ${i + 1}'),
      ],
      'bulletins': [
        for (var i = 0; i < ids.length; i++)
          _newsItem(ids[i], 'Latest headline ${i + 1}'),
      ],
    });
    for (final id in ids) {
      await app.followChannel(id);
    }
    await tab(tester, 'Channels');
    final bottom = tester.getTopLeft(find.byType(NavigationBar)).dy;
    for (final id in ids) {
      expect(
        tester.getBottomLeft(find.byKey(ValueKey('channel-card-$id'))).dy,
        lessThan(bottom),
      );
    }
    expect(find.text('Publisher key fingerprint'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Channel previews use signed sequence and update activity order',
    (tester) async {
      final app = await showApp(tester);
      final old = {
        ..._newsItem(_otherId, 'Old replay'),
        'id': 'old',
        'sequence': 1,
        'createdAtMs': 1770000009000,
      };
      final current = {
        ..._newsItem(_otherId, 'Current headline'),
        'id': 'current',
        'sequence': 2,
        'createdAtMs': 1770000000000,
      };
      app.update({
        'channels': [
          _foreignChannel(_otherId, 'Community'),
          _foreignChannel(_anotherId, 'Weather'),
        ],
        'bulletins': [
          old,
          current,
          {
            ..._newsItem(_anotherId, 'Weather headline'),
            'createdAtMs': 1770000001000,
            'sequence': 1,
          },
        ],
      });
      await app.followChannel(_otherId);
      await app.followChannel(_anotherId);
      await tab(tester, 'Channels');
      expect(find.text('Current headline'), findsOneWidget);
      expect(find.text('Old replay'), findsNothing);
      double rowY(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('channel-card-$id'))).dy;
      expect(rowY(_anotherId), lessThan(rowY(_otherId)));
      app.update({
        'bulletins': [
          old,
          current,
          {
            ...current,
            'id': 'new',
            'sequence': 3,
            'text': 'Fresh headline',
            'createdAtMs': 1770000020000,
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('Fresh headline'), findsOneWidget);
      expect(find.text('Current headline'), findsNothing);
      expect(rowY(_otherId), lessThan(rowY(_anotherId)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Opening a discovered channel previews only its news without following',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [
          _foreignChannel(_otherId, 'Community'),
          _foreignChannel(_anotherId, 'Weather'),
        ],
        'bulletins': [
          _newsItem(_otherId, 'Community bulletin'),
          _newsItem(_anotherId, 'Weather bulletin'),
        ],
      });
      await tab(tester, 'Channels');
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('open-channel-$_otherId')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('channel-page-$_otherId')), findsOneWidget);
      expect(find.text('Community bulletin'), findsOneWidget);
      expect(find.text('Weather bulletin'), findsNothing);
      expect(app.isChannelFollowed(_otherId), isFalse);
      expect(app.isChannelTrusted(_otherId), isFalse);
      expect(find.byKey(const ValueKey('channel-compose-news')), findsNothing);
      await tester.tap(find.byKey(ValueKey('channel-follow-$_otherId')));
      await tester.pumpAndSettle();
      expect(app.isChannelFollowed(_otherId), isTrue);
      expect(app.isChannelTrusted(_otherId), isFalse);
      await tester.tap(find.byKey(ValueKey('channel-follow-$_otherId')));
      await tester.pumpAndSettle();
      expect(app.isChannelFollowed(_otherId), isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('channel-search')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Channel view publishes and stays in its channel', (
    tester,
  ) async {
    final app = await showApp(tester);
    app.update({
      'channels': [
        {
          'id': _ownedId,
          'name': 'My updates',
          'ownerId': identity.id,
          'owned': true,
          'description': '',
        },
      ],
    });
    await tab(tester, 'Channels');
    await tester.tap(find.byKey(ValueKey('open-channel-$_ownedId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('channel-compose-news')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('news-text')),
      'Fresh channel bulletin',
    );
    await tester.tap(find.byKey(const ValueKey('submit-news')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign & publish'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('channel-page-$_ownedId')), findsOneWidget);
    expect(find.text('Fresh channel bulletin'), findsOneWidget);
    expect(app.newsPublications, [(_ownedId, 'Fresh channel bulletin')]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('channel-search')), findsOneWidget);
    expect(find.text('Fresh channel bulletin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Channel view keeps trust private, reports save failure and closes after hiding',
    (tester) async {
      final app = await showApp(tester);
      app.update({
        'channels': [_foreignChannel(_otherId, 'Community')],
      });
      await tab(tester, 'Channels');
      await tester.tap(find.text('Discover'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('open-channel-$_otherId')));
      await tester.pumpAndSettle();
      Future<void> choose(String key) async {
        await tester.tap(find.byKey(ValueKey('channel-menu-$_otherId')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('$key-channel-$_otherId')));
        await tester.pumpAndSettle();
      }

      await choose('trust');
      expect(app.isChannelTrusted(_otherId), isTrue);
      expect(app.isChannelFollowed(_otherId), isFalse);
      app.failNextUntrust = true;
      await choose('untrust');
      expect(app.isChannelTrusted(_otherId), isTrue);
      expect(
        find.text('Your choice was not saved. Try again.'),
        findsOneWidget,
      );
      await choose('untrust');
      expect(app.isChannelTrusted(_otherId), isFalse);
      await tester.tap(find.byKey(ValueKey('channel-menu-$_otherId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Block channel'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Block'));
      await tester.pumpAndSettle();
      expect(app.isChannelBlocked(_otherId), isTrue);
      expect(find.byKey(ValueKey('channel-page-$_otherId')), findsNothing);
      expect(find.byKey(ValueKey('channel-card-$_otherId')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['fa', 'en']) {
    testWidgets('$language channel list and news fit larger text', (
      tester,
    ) async {
      final app = await showApp(
        tester,
        language: language,
        size: const Size(360, 800),
        scale: 1.6,
      );
      app.update({
        'channels': [
          _foreignChannel(
            _otherId,
            language == 'fa'
                ? 'اطلاعیه‌های عمومی محله'
                : 'Neighbourhood public notices',
          ),
        ],
        'bulletins': [
          _newsItem(
            _otherId,
            language == 'fa' ? 'خبر عمومی آزمایشی' : 'Public test bulletin',
          ),
        ],
      });
      await app.followChannel(_otherId);
      await tab(tester, language == 'fa' ? 'کانال‌ها' : 'Channels');
      await tester.tap(find.byKey(ValueKey('open-channel-$_otherId')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('channel-page-$_otherId')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'ui-channel-news-large-$language', wholeApp: true);
    });

    testWidgets('Render $language channel and publishing screens', (
      tester,
    ) async {
      final app = await showApp(tester, language: language);
      final farsi = language == 'fa';
      await tab(tester, farsi ? 'کانال‌ها' : 'Channels');
      await tester.tap(find.byKey(const ValueKey('create-channel')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('channel-name')),
        farsi ? 'خبرهای محله' : 'Community updates',
      );
      await tester.enterText(
        find.byKey(const ValueKey('channel-description')),
        farsi
            ? 'خبرهای عمومی برای همسایه‌ها؛ روشن، کوتاه و قابل بررسی.'
            : 'Clear, short public updates for our neighbours.',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await capture(tester, 'ui-create-channel-$language', wholeApp: true);
      await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
      await tester.pumpAndSettle();
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).last))
          .clearSnackBars();
      await tester.pumpAndSettle();
      await app.followChannel(_otherId);
      app.update({
        'channels': [
          ...(app.snapshot['channels'] as List),
          _foreignChannel(
            _otherId,
            farsi ? 'اطلاعیه‌های عمومی' : 'Public notices',
          ),
        ],
      });
      await tester.pumpAndSettle();
      final sections = tester.widget<SegmentedButton<bool>>(
        find.byKey(const ValueKey('channel-sections')),
      );
      expect(
        sections.style!.textStyle!.resolve({})!.fontFamily,
        farsi ? 'Vazirmatn' : 'Manrope',
      );
      await capture(tester, 'ui-channels-$language', wholeApp: true);
      await tab(tester, farsi ? 'خبرها' : 'News');
      await tester.tap(find.byKey(const ValueKey('compose-news')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('news-text')),
        farsi
            ? 'این یک خبر آزمایشی عمومی است. لطفاً منبع خبر را مستقل بررسی کنید.'
            : 'This is a public test update. Please check the source independently.',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await capture(tester, 'ui-compose-news-$language', wholeApp: true);
      await tester.tap(find.byKey(const ValueKey('submit-news')));
      await tester.pumpAndSettle();
      await capture(tester, 'ui-review-news-$language', wholeApp: true);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '$language create and compose fit a narrow screen with larger text',
      (tester) async {
        final app = await showApp(
          tester,
          language: language,
          size: const Size(360, 800),
          scale: 1.4,
        );
        await tab(tester, language == 'fa' ? 'کانال‌ها' : 'Channels');
        await tester.tap(find.byKey(const ValueKey('create-channel')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('channel-name')),
          language == 'fa' ? 'خبرهای محله' : 'Community updates',
        );
        await tester.enterText(
          find.byKey(const ValueKey('channel-description')),
          language == 'fa'
              ? 'خبرهای عمومی برای همسایه‌ها'
              : 'Public updates for our neighbours',
        );
        for (var i = 0; i < 3; i++) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -250));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
        await tester.pumpAndSettle();
        await tab(tester, language == 'fa' ? 'خبرها' : 'News');
        await tester.tap(find.byKey(const ValueKey('compose-news')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.enterText(
          find.byKey(const ValueKey('news-text')),
          language == 'fa'
              ? 'این یک خبر آزمایشی عمومی است.'
              : 'This is a public test update.',
        );
        await tester.tap(find.byKey(const ValueKey('submit-news')));
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -200));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(app.newsPublications, isEmpty);
      },
    );
  }

  for (final language in ['fa', 'en']) {
    for (final size in [const Size(390, 844), const Size(360, 800)]) {
      for (final scale in [1.0, 1.4]) {
        testWidgets('$language tabs fit $size at $scale text scale', (
          tester,
        ) async {
          await showApp(tester, language: language, size: size, scale: scale);
          final names = language == 'fa'
              ? ['اتصال', 'کانال‌ها', 'خبرها']
              : ['Connection', 'Channels', 'News'];
          for (final name in names) {
            await tab(tester, name);
            expect(tester.takeException(), isNull, reason: '$name initially');
            for (var i = 0; i < 5; i++) {
              await tester.drag(
                find.byType(ListView).first,
                const Offset(0, -350),
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$name after scrolling',
              );
            }
          }
        });
      }
    }
  }

  for (final language in ['fa', 'en']) {
    testWidgets('Render $language connection preview with actual assets', (
      tester,
    ) async {
      await showApp(tester, language: language);
      expect(tester.takeException(), isNull);
      await capture(
        tester,
        language == 'fa' ? 'ui-overview-fa' : 'ui-overview',
      );
    });
  }
}

Map<String, dynamic> _foreignChannel(String id, String name) => {
  'id': id,
  'name': name,
  'description': 'Public updates',
  'ownerId': _otherOwner,
  'owned': false,
  'trust': 'unverified',
};
Map<String, dynamic> _newsItem(String channelId, String text) => {
  'id': 'news-$channelId',
  'channelId': channelId,
  'text': text,
  'sourceId': _otherOwner,
  'createdAtMs': 1770000000000,
  'receivedVia': 'lan',
};

/// Exercises presentation only: native services and discovery are engine tests.
class _PreviewController extends AppController {
  final channelCreations = <(String, String)>[];
  final newsPublications = <(String, String)>[];
  final _followed = <String>{};
  final _blocked = <String>{};
  final _trusted = <String>{};
  bool failNextCreate = false;
  bool failNextPublish = false;
  bool failNextTrust = false;
  bool failNextUntrust = false;
  Completer<void>? creationGate;
  Completer<void>? trustGate;
  Completer<void>? untrustGate;
  int exportCount = 0;
  _PreviewController(Identity generated) {
    identity = generated;
    loading = false;
    running = true;
    activeMode = true;
    label = 'Test phone';
    device = {
      'platform': 'android',
      'batteryPercent': 86,
      'lockStateKnown': true,
      'isLocked': false,
    };
    snapshot = {
      'running': true,
      'activeMode': true,
      'connectedCount': 0,
      'discoveredCount': 0,
      'bootstrapConfiguredCount': 0,
      'discoveryState': 'searching',
      'channels': <Map<String, dynamic>>[],
      'peers': <Map<String, dynamic>>[],
      'bulletins': <Map<String, dynamic>>[],
      'trials': <Map<String, dynamic>>[],
      'events': <Map<String, dynamic>>[],
    };
  }
  void update(Map<String, dynamic> value) {
    snapshot = {...snapshot, ...value};
    notifyListeners();
  }

  @override
  Set<String> get followedChannelIds => {
    ..._followed,
    for (final c in (snapshot['channels'] as List).cast<Map<String, dynamic>>())
      if (c['ownerId'] == identity?.id) c['id'] as String,
  }..removeAll(_blocked);
  @override
  Set<String> get blockedChannelIds => Set.unmodifiable(_blocked);
  @override
  bool isChannelFollowed(String id) => followedChannelIds.contains(id);
  @override
  bool isChannelBlocked(String id) => _blocked.contains(id);
  @override
  bool isChannelTrusted(String id) =>
      _trusted.contains(id) && !_blocked.contains(id);
  @override
  Future<void> trustChannel(String id) async {
    await trustGate?.future;
    if (failNextTrust) {
      failNextTrust = false;
      throw StateError('Could not save your private trust choice.');
    }
    _trusted.add(id);
    notifyListeners();
  }

  @override
  Future<void> untrustChannel(String id) async {
    await untrustGate?.future;
    if (failNextUntrust) {
      failNextUntrust = false;
      throw StateError('Could not remove your private trust choice.');
    }
    _trusted.remove(id);
    notifyListeners();
  }

  @override
  Future<void> followChannel(String id) async {
    _blocked.remove(id);
    _followed.add(id);
    notifyListeners();
  }

  @override
  Future<void> unfollowChannel(String id) async {
    _followed.remove(id);
    notifyListeners();
  }

  @override
  Future<void> blockChannel(String id) async {
    _followed.remove(id);
    _trusted.remove(id);
    _blocked.add(id);
    notifyListeners();
  }

  @override
  Future<void> unblockChannel(String id) async {
    _blocked.remove(id);
    notifyListeners();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> refresh() async => notifyListeners();
  @override
  Future<void> setLanguageCode(String value) async {
    languageCode = value;
    notifyListeners();
  }

  @override
  Future<void> start({required bool active}) async {
    running = true;
    activeMode = active;
    update({'running': true, 'activeMode': active});
  }

  @override
  Future<void> stop() async {
    running = false;
    update({'running': false});
  }

  @override
  Future<void> createChannel(String name, String description) async {
    await creationGate?.future;
    if (failNextCreate) {
      failNextCreate = false;
      throw StateError('Could not save this channel.');
    }
    channelCreations.add((name, description));
    update({
      'channels': [
        ...(snapshot['channels'] as List),
        <String, dynamic>{
          'id': _ownedId,
          'name': name,
          'description': description,
          'ownerId': identity!.id,
          'owned': true,
        },
      ],
    });
  }

  @override
  Future<void> publishToChannel(String channelId, String text) async {
    if (failNextPublish) {
      failNextPublish = false;
      throw StateError('Could not save this news.');
    }
    newsPublications.add((channelId, text));
    update({
      'bulletins': [
        <String, dynamic>{
          'id': 'b'.padLeft(64, 'b'),
          'channelId': channelId,
          'sourceId': identity!.id,
          'channelName': (snapshot['channels'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere((c) => c['id'] == channelId)['name'],
          'text': text,
          'createdAtMs': 1770000000000,
          'receivedVia': 'local',
        },
      ],
    });
  }

  @override
  Future<void> export() async {
    exportCount++;
  }
}
