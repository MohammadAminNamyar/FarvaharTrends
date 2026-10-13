import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/app_controller.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/main.dart';

void main() {
  late Identity identity;
  setUpAll(() async {
    identity = Identity.generate();
    for (final font in {
      'Manrope': 'assets/fonts/Manrope.ttf',
      'Vazirmatn': 'assets/fonts/Vazirmatn.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  for (final fa in [true, false]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'temporary log renders and clears locally: fa=$fa scale=$scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(360, 800);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          String? copiedText;
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(SystemChannels.platform, (
            call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              copiedText = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            ),
          );
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final app = _LogController(identity)..languageCode = fa ? 'fa' : 'en';
          addTearDown(app.dispose);
          await tester.pumpWidget(
            RepaintBoundary(
              key: const ValueKey('log-preview'),
              child: PersianTrendApp(
                controller: app,
                initialize: false,
                animateRadar: false,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => precacheImage(
              const AssetImage('assets/brand/logo.jpg'),
              tester.element(find.byType(Scaffold)),
            ),
          );
          await tester.tap(find.byKey(const ValueKey('temporary-log-tab')));
          await tester.pumpAndSettle();
          expect(
            find.text(fa ? 'گزارش موقت' : 'Temporary log'),
            findsNWidgets(2),
          );
          expect(tester.takeException(), isNull);
          final own = tester.widget<Text>(
            find.byKey(const ValueKey('temporary-log-own-id')),
          );
          expect(
            own.semanticsLabel,
            contains(fa ? 'شناسهٔ اتصال این گوشی' : 'This phone’s connection'),
          );
          await tester.tap(find.byKey(const ValueKey('temporary-log-copy-id')));
          await tester.pumpAndSettle();
          expect(copiedText, identity.id.substring(0, 12));
          await tester.ensureVisible(
            find.byKey(const ValueKey('temporary-log-copy-report')),
          );
          await tester.tap(
            find.byKey(const ValueKey('temporary-log-copy-report')),
          );
          await tester.pumpAndSettle();
          final report = jsonDecode(copiedText!) as Map;
          expect(report['reportVersion'], 1);
          expect(report['connectionId'], identity.id.substring(0, 12));
          expect(copiedText, isNot(contains('203.0.113.22')));
          expect(copiedText, isNot(contains('Private news text')));
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('temporary-log-connected-count')),
                )
                .data,
            fa ? '۱' : '1',
          );
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('temporary-log-seen-count')),
                )
                .data,
            fa ? '۲' : '2',
          );
          expect(find.textContaining('203.0.113.22'), findsNothing);
          expect(find.textContaining('Private peer name'), findsNothing);
          expect(find.textContaining('Private news text'), findsNothing);
          final list = find
              .descendant(
                of: find.byKey(const ValueKey('temporary-log-list')),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('temporary-log-event-0')),
            180,
            scrollable: list,
          );
          expect(
            find.text(
              fa ? 'خبر با امضای معتبر دریافت شد' : 'Signed news received',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (scale == 1) {
            tester.state<ScrollableState>(list).position.jumpTo(0);
            await tester.pumpAndSettle();
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('log-preview')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              try {
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await File(
                  '${Directory.current.path}/artifacts/ui-temporary-log-${fa ? 'fa' : 'en'}.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          await tester.ensureVisible(
            find.byKey(const ValueKey('temporary-log-clear')),
          );
          await tester.tap(find.byKey(const ValueKey('temporary-log-clear')));
          await tester.pumpAndSettle();
          expect(app.clearCalls, 1);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('temporary-log-empty')),
            120,
            scrollable: list,
          );
          expect(
            find.byKey(const ValueKey('temporary-log-empty')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('temporary-log-clear')),
                )
                .onPressed,
            isNull,
          );
          // Clearing history must not hide or disconnect a live peer.
          tester.state<ScrollableState>(list).position.jumpTo(0);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('temporary-log-connected-count')),
                )
                .data,
            fa ? '۱' : '1',
          );
          expect(app.snapshot['peers'], hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

class _LogController extends AppController {
  _LogController(Identity own) {
    identity = own;
    publisherIdentity = own;
    loading = false;
    running = true;
    final at = DateTime(2026, 10, 13, 11, 38, 6).millisecondsSinceEpoch;
    snapshot = {
      'connectedCount': 1,
      'channels': <Map<String, dynamic>>[],
      'bulletins': <Map<String, dynamic>>[],
      'peers': [
        {
          'id': 'a' * 64,
          'connected': true,
          'transport': 'overlay',
          'host': '203.0.113.22',
          'name': 'Private peer name',
        },
      ],
      'temporaryPeerActivity': [
        {
          'kind': 'bulletin_verified',
          'peerId': 'a' * 64,
          'transport': 'overlay',
          'atWallMs': at + 4000,
          'text': 'Private news text',
        },
        {
          'kind': 'connected',
          'peerId': 'a' * 64,
          'transport': 'overlay',
          'atWallMs': at,
        },
        {
          'kind': 'disconnected',
          'peerId': 'b' * 64,
          'transport': 'bluetooth',
          'atWallMs': at - 1000,
        },
      ],
    };
  }
  int clearCalls = 0;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> clearTemporaryLog() async {
    clearCalls++;
    snapshot = {...snapshot, 'temporaryPeerActivity': <Map<String, dynamic>>[]};
    notifyListeners();
  }
}
