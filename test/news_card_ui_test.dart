import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/ui/news_card.dart';

void main() {
  testWidgets(
    'channel timeline hides duplicate identity, preserves distinct writers',
    (tester) async {
      Future<void> showCard({
        required bool showHeader,
        required String writer,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NewsCard(
                news: {
                  'id': 'one',
                  'text': 'A public update',
                  'byline': writer,
                },
                channel: {'id': 'a' * 64, 'name': 'Community'},
                fa: false,
                assessment: 'Not assessed',
                showChannelHeader: showHeader,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await showCard(showHeader: false, writer: 'Community');
      expect(find.text('Community'), findsNothing);
      expect(find.text('By Community'), findsNothing);
      expect(find.byKey(const ValueKey('news-header-one')), findsNothing);
      await showCard(showHeader: false, writer: 'Elias');
      expect(find.text('By Elias'), findsOneWidget);
      await showCard(showHeader: true, writer: 'Community');
      expect(find.text('Community'), findsOneWidget);
      expect(find.text('By Community'), findsNothing);
    },
  );
  setUpAll(() async {
    for (final font in {
      'Manrope': 'assets/fonts/Manrope.ttf',
      'Vazirmatn': 'assets/fonts/Vazirmatn.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });
  for (final fa in [true, false]) {
    testWidgets('article keeps local time details and readable metadata: $fa', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final sent = DateTime(2026, 10, 13, 11, 38, 6).millisecondsSinceEpoch;
      final news = <String, dynamic>{
        'id': 'article',
        'createdAtMs': sent,
        'receivedAtWallMs': sent + 4000,
        'receivedVia': 'overlay',
        'byline': fa ? 'الیاس' : 'Elias',
        'text': fa
            ? 'اطلاعیهٔ تازه برای همراهان فروهر ترندز\n\nخبرها را از کانال‌هایی که انتخاب کرده‌اید دنبال کنید. هر خبر با نام نویسنده و زمان دریافت روی همین گوشی نمایش داده می‌شود.'
            : 'A fresh update for FarvaharTrends readers\n\nFollow the channels you choose. Each article shows its writer and the time it reached this phone.',
      };
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: fa ? 'Vazirmatn' : 'Manrope',
            useMaterial3: true,
          ),
          home: Directionality(
            textDirection: fa ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: const Color(0xFFF4F7F8),
              body: RepaintBoundary(
                key: const ValueKey('article-preview'),
                child: ColoredBox(
                  color: const Color(0xFFF4F7F8),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 40, 18, 24),
                    child: NewsCard(
                      news: news,
                      fa: fa,
                      channel: {
                        'id': 'a' * 64,
                        'name': fa ? 'فروهر ترندز' : 'FarvaharTrends',
                      },
                      assessment: fa ? 'مورد اعتماد شما' : 'Trusted by you',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sent-time-article')), findsNothing);
      expect(find.text(fa ? 'نویسنده: الیاس' : 'By Elias'), findsOneWidget);
      expect(find.text(news['text'] as String), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('article-preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('artifacts').create(recursive: true);
          await File('artifacts/ui-article-${fa ? 'fa' : 'en'}.png')
              .writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      await tester.tap(find.byKey(const ValueKey('news-details-article')));
      await tester.pumpAndSettle();
      final sentLabel = tester.widget<Text>(
        find.byKey(const ValueKey('sent-time-article')),
      );
      final receivedLabel = tester.widget<Text>(
        find.byKey(const ValueKey('received-time-article')),
      );
      final detailsBoundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('news-details-preview')),
      );
      await tester.runAsync(() async {
        final image = await detailsBoundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('artifacts/ui-news-details-${fa ? 'fa' : 'en'}.png')
              .writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(sentLabel.data, fa ? '۱۱:۳۸:۰۶' : '11:38:06');
      expect(receivedLabel.data, fa ? '۱۱:۳۸:۱۰' : '11:38:10');
      expect(sentLabel.textDirection, TextDirection.ltr);
      await tester.tap(find.byKey(const ValueKey('sent-time-article')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('UTC'), findsOneWidget);
      // The full stamp is Jalali with Persian digits in Farsi and the
      // unchanged Gregorian text in English; the clock is this phone's zone.
      final tooltip = tester.widget<Text>(find.textContaining('UTC'));
      expect(
        tooltip.data ?? tooltip.textSpan?.toPlainText(),
        fa
            ? allOf(
                contains('۲۱ مهر ۱۴۰۵ ۱۱:۳۸:۰۶'),
                isNot(contains(RegExp('[0-9]'))),
              )
            : startsWith('2026/10/13 11:38:06 UTC'),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
