import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/app_controller.dart';
import 'package:farvahar_trends/ui/channel_views.dart';
import 'package:farvahar_trends/ui/channel_tools.dart';

class _Reader extends AppController {
  _Reader(String language) {
    languageCode = language;
    loading = false;
    snapshot = {
      'channels': [
        {
          'id': 'a' * 64,
          'name': 'Example channel',
          'owned': true,
          'writerNickname': 'Roozbeh',
        },
      ],
      'bulletins': [
        {
          'id': 'b' * 64,
          'channelId': 'a' * 64,
          'text': 'A public article',
          'byline': 'Roozbeh',
          'sequence': 1,
          'receivedVia': 'unknown',
        },
      ],
    };
  }
  @override
  bool isChannelFollowed(String id) => true;
}

void main() {
  for (final language in ['fa', 'en']) {
    testWidgets(
      '$language shows the signed writer below news without an old-route warning',
      (tester) async {
        final app = _Reader(language);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ChannelNewsPage(
              app: app,
              channelId: 'a' * 64,
              onPublish: (_) async {},
              onIdentity: (_) async {},
              onBlock: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'fa' ? 'نویسنده: Roozbeh' : 'By Roozbeh'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Arrival path was not recorded'),
          findsNothing,
        );
        expect(find.textContaining('مسیر دریافت این خبر قدیمی'), findsNothing);
        expect(find.byKey(ValueKey('remove-news-${'b' * 64}')), findsOneWidget);
        (app.snapshot['bulletins'] as List).single['receivedVia'] = 'overlay';
        app.notifyListeners();
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'fa'
                ? 'دریافت از شبکهٔ همتاها'
                : 'Received through the peer network',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      '$language owner management exposes channel removal with a confirmation',
      (tester) async {
        final app = _Reader(language);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: ChannelToolsPage(app: app, channelId: 'a' * 64),
          ),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('remove-channel')),
        );
        await tester.tap(find.byKey(const ValueKey('remove-channel')));
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'fa' ? 'حذف کانال؟' : 'Remove this channel?'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            language == 'fa'
                ? 'نسخه‌های ذخیره‌شده'
                : 'Saved copies cannot be erased',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text(language == 'fa' ? 'انصراف' : 'Cancel'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
