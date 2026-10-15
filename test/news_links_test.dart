import 'package:farvahar_trends/ui/news_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'web links preserve queries, fragments and balanced URL parentheses',
    () {
      const text =
          'ببینید: (https://example.org/a_(b)?q=1&x=2#part). '
          'www.example.org/news، https://example.net/خبر؟';
      final links = newsLinks(text);
      expect(links.map((v) => text.substring(v.start, v.end)), [
        'https://example.org/a_(b)?q=1&x=2#part',
        'www.example.org/news',
        'https://example.net/خبر',
      ]);
      expect(links[1].uri.scheme, 'https');
      expect(Uri.decodeComponent(links[2].uri.path), '/خبر');
    },
  );

  test(
    'non-web, malformed, credential and hidden-control addresses stay text',
    () {
      expect(
        newsLinks(
          'javascript:alert(1) file:///etc/test intent://foo '
          'https://name:pass@example.org https:// https://[broken '
          'https://example.org/abc\u202Edef https://example.org\\evil '
          'me@www.example.org foohttps://example.org',
        ),
        isEmpty,
      );
    },
  );

  test('address and gesture count are bounded for hostile posts', () {
    expect(newsLinks('https://example.org/${'a' * 3000}'), isEmpty);
    final text = List.filled(1000, 'https://example.org').join(' ');
    expect(newsLinks(text), hasLength(64));
  });

  for (final fa in [true, false]) {
    testWidgets('tap web link opens externally, preserves copy text: $fa', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      const platform = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(platform, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          platform,
          null,
        ),
      );
      final text = fa
          ? 'خبر تازه: https://example.org/news?q=1&b=2 پایان خبر'
          : 'Latest: https://example.org/news?q=1&b=2 end of news';
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: fa ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              body: NewsText(text: text, fa: fa),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty); // No preview fetch/open while merely reading.
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(selectable.textSpan!.toPlainText(), text);
      final RenderEditable editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final start = text.indexOf('https://');
      final box = editable
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 5),
          )
          .first;
      await tester.tapAt(editable.localToGlobal(box.toRect().center));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'launch');
      expect(calls.single.arguments['url'], 'https://example.org/news?q=1&b=2');
      expect(calls.single.arguments['useWebView'], false);
      expect(calls.single.arguments['useSafariVC'], false);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'failed link opening has localized feedback and recovers: $fa',
      (tester) async {
        const platform = MethodChannel('plugins.flutter.io/url_launcher');
        var calls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          platform,
          (call) async {
            calls++;
            throw PlatformException(code: 'no_browser');
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            platform,
            null,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NewsText(text: 'https://example.org', fa: fa),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          final RenderEditable editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final box = editable
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 5),
              )
              .first;
          await tester.tapAt(editable.localToGlobal(box.toRect().center));
          await tester.pumpAndSettle();
        }
        expect(calls, 2);
        expect(
          find.text(
            fa
                ? 'بازکردن پیوند ممکن نشد. می‌توانید نشانی را کپی کنید.'
                : 'Could not open this link. You can copy the address instead.',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
