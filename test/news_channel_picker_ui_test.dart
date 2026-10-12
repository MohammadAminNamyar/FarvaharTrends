import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/app_controller.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/main.dart';

String channelId(int index) => (index + 1).toRadixString(16).padLeft(64, '0');

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

  Future<_NewsController> showNews(
    WidgetTester tester, {
    String language = 'en',
    double scale = 1,
    int count = 120,
    String? targetName,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final app = _NewsController(identity, count: count, targetName: targetName)
      ..languageCode = language;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('news-test-preview'),
        child: PersianTrendApp(
          controller: app,
          initialize: false,
          animateRadar: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(language == 'fa' ? 'خبرها' : 'News'),
      ),
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

  final picker = find.byKey(const ValueKey('news-channel-picker'));
  final search = find.byKey(const ValueKey('news-channel-search'));
  Finder option(String id) => find.byKey(ValueKey('news-channel-option-$id'));

  Future<void> openPicker(WidgetTester tester) async {
    await reveal(tester, picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
  }

  Future<void> selectTarget(WidgetTester tester) async {
    await openPicker(tester);
    await tester.enterText(search, channelId(119));
    await tester.pumpAndSettle();
    await tester.tap(option(channelId(119)));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final finder = find.byKey(const ValueKey('news-test-preview'));
    final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${Directory.current.path}/artifacts/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('120 followed channels use one compact picker and a lazy list', (
    tester,
  ) async {
    await showNews(tester);
    expect(picker, findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('All followed channels'), findsOneWidget);
    await openPicker(tester);
    expect(
      find.byKey(const ValueKey('news-channel-picker-sheet')),
      findsOneWidget,
    );
    expect(find.byType(ListTile).evaluate().length, lessThan(25));
    expect(option(channelId(119)), findsNothing);
    await tester.enterText(search, channelId(119));
    await tester.pumpAndSettle();
    expect(option(channelId(119)), findsOneWidget);
    expect(option(channelId(118)), findsNothing);
    expect(option('all'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search by name or ID selects one feed; All restores the feed', (
    tester,
  ) async {
    await showNews(tester);
    await openPicker(tester);
    await tester.enterText(search, 'target source');
    await tester.pumpAndSettle();
    expect(option(channelId(119)), findsOneWidget);
    await tester.tap(option(channelId(119)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('news-channel-picker-sheet')),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('news-channel-selection')))
          .data,
      'Target source',
    );
    expect(find.text('Target news'), findsOneWidget);
    expect(find.text('Other news'), findsNothing);
    await openPicker(tester);
    await tester.tap(option('all'));
    await tester.pumpAndSettle();
    expect(find.text('All followed channels'), findsOneWidget);
    await reveal(tester, find.text('Other news'));
    expect(find.text('Other news'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final hide in [false, true]) {
    testWidgets(
      'Selected channel resets after ${hide ? 'hiding' : 'unfollowing'}',
      (tester) async {
        final app = await showNews(tester);
        await selectTarget(tester);
        if (hide) {
          await app.blockChannel(channelId(119));
        } else {
          await app.unfollowChannel(channelId(119));
        }
        await tester.pumpAndSettle();
        expect(find.text('All followed channels'), findsOneWidget);
        expect(find.text('Target news'), findsNothing);
        await app.followChannel(channelId(119));
        await tester.pumpAndSettle();
        expect(find.text('All followed channels'), findsOneWidget);
        await reveal(tester, find.text('Other news'));
        expect(find.text('Other news'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Picker excludes hidden and unfollowed sources and updates live',
    (tester) async {
      final app = await showNews(tester);
      await app.blockChannel(channelId(0));
      await app.unfollowChannel(channelId(1));
      await openPicker(tester);
      for (final id in [channelId(0), channelId(1)]) {
        await tester.enterText(search, id);
        await tester.pumpAndSettle();
        expect(option(id), findsNothing);
        expect(
          find.byKey(const ValueKey('news-channel-search-empty')),
          findsOneWidget,
        );
      }
      await tester.enterText(search, channelId(119));
      await tester.pumpAndSettle();
      expect(option(channelId(119)), findsOneWidget);
      await app.unfollowChannel(channelId(119));
      await tester.pumpAndSettle();
      expect(option(channelId(119)), findsNothing);
      expect(
        find.byKey(const ValueKey('news-channel-search-empty')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('clear-news-channel-search')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(
        find.byKey(const ValueKey('news-channel-search-empty')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Closing the picker preserves its previous channel selection', (
    tester,
  ) async {
    await showNews(tester);
    await selectTarget(tester);
    await openPicker(tester);
    await tester.enterText(search, 'no matching channel');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-news-channel-picker')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('news-channel-selection')))
          .data,
      'Target source',
    );
    expect(find.text('Other news'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A removed selection cannot reappear while the picker is open', (
    tester,
  ) async {
    final app = await showNews(tester);
    await selectTarget(tester);
    await openPicker(tester);
    await app.unfollowChannel(channelId(119));
    await tester.pumpAndSettle();
    await app.followChannel(channelId(119));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(option('all')).selected, isTrue);
    await tester.enterText(search, channelId(119));
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(option(channelId(119))).selected, isFalse);
    await tester.tap(find.byKey(const ValueKey('close-news-channel-picker')));
    await tester.pumpAndSettle();
    expect(find.text('All followed channels'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('No followed channels has no empty picker control', (
    tester,
  ) async {
    final app = await showNews(tester);
    app.followed.clear();
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(picker, findsNothing);
    expect(find.text('A feed you choose'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['fa', 'en']) {
    testWidgets('$language picker fits long names, large text and a keyboard', (
      tester,
    ) async {
      final longName = language == 'fa'
          ? 'خبرهای محله و جامعه، گزارش‌های روزانه از زندگی مردم در شهرهای مختلف'
          : 'Community and neighbourhood updates from our local correspondents';
      await showNews(
        tester,
        language: language,
        scale: 1.8,
        targetName: longName,
      );
      await openPicker(tester);
      expect(
        Directionality.of(tester.element(search)),
        language == 'fa' ? TextDirection.rtl : TextDirection.ltr,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(search, channelId(119));
      await tester.pumpAndSettle();
      await tester.ensureVisible(option(channelId(119)));
      await tester.tap(option(channelId(119)));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('news-channel-selection')))
            .data,
        longName,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Render $language news-channel picker', (tester) async {
      await showNews(
        tester,
        language: language,
        targetName: language == 'fa' ? 'خبرهای تهران' : 'Tehran updates',
      );
      await openPicker(tester);
      await tester.enterText(search, language == 'fa' ? 'تهران' : 'Tehran');
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await capture(tester, 'ui-news-picker-$language');
      await tester.tap(option(channelId(119)));
      await tester.pumpAndSettle();
      await capture(tester, 'ui-news-selected-$language');
      expect(tester.takeException(), isNull);
    });
  }
}

class _NewsController extends AppController {
  _NewsController(
    Identity generated, {
    required int count,
    String? targetName,
  }) {
    identity = generated;
    publisherIdentity = generated;
    loading = false;
    running = false;
    snapshot = {
      'channels': [
        for (var index = 0; index < count; index++)
          {
            'id': channelId(index),
            'name': index == 119
                ? targetName ?? 'Target source'
                : 'Channel ${index.toString().padLeft(3, '0')}',
            'description': 'Public updates',
            'ownerId': 'a' * 64,
            'owned': false,
          },
      ],
      'bulletins': [
        for (final index in [119, 2])
          {
            'id': 'news-$index',
            'channelId': channelId(index),
            'text': index == 119 ? 'Target news' : 'Other news',
            'sourceId': 'a' * 64,
            'createdAtMs': 1770000000000,
            'receivedVia': 'lan',
          },
      ],
    };
    followed.addAll(List.generate(count, channelId));
  }
  final followed = <String>{};
  final blocked = <String>{};
  @override
  bool isChannelFollowed(String id) =>
      followed.contains(id) && !blocked.contains(id);
  @override
  bool isChannelBlocked(String id) => blocked.contains(id);
  @override
  Future<void> followChannel(String id) async {
    blocked.remove(id);
    followed.add(id);
    notifyListeners();
  }

  @override
  Future<void> unfollowChannel(String id) async {
    followed.remove(id);
    notifyListeners();
  }

  @override
  Future<void> blockChannel(String id) async {
    followed.remove(id);
    blocked.add(id);
    notifyListeners();
  }
}
