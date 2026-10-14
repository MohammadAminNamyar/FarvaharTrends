import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/jalali.dart';
import 'package:persian_trend/core/news_timeline.dart';
import 'package:persian_trend/ui/channel_views.dart';
import 'package:persian_trend/ui/date_format.dart';

Map<String, dynamic> post(String id, String writer, int seq, int time) => {
  'id': id,
  'channelId': 'channel',
  'sourceId': writer,
  'sequence': seq,
  'createdAtMs': time,
};

void main() {
  test(
    'multiple writers, rollback, equal timestamps and arrival permutations',
    () {
      final items = [
        post('a1', 'a', 1, 3000),
        post('a2', 'a', 2, 1000),
        post('b1', 'b', 1, 2000),
        post('b2', 'b', 2, 4000),
        post('c1', 'c', 1, 3000),
        post('c2', 'c', 2, 3000),
      ];
      final expected = ['b2', 'a2', 'a1', 'c2', 'c1', 'b1'];
      for (var seed = 0; seed < 200; seed++) {
        final shuffled = jsonDecode(
          jsonEncode(items),
        ).cast<Map<String, dynamic>>()..shuffle(Random(seed));
        expect(orderNews(shuffled).map((n) => n['id']), expected);
      }
      // Sorting never changes the original signed time or the input snapshot.
      expect(items[1]['createdAtMs'], 1000);
      expect(items.first['id'], 'a1');
    },
  );

  test(
    'received times, timezones and missing observation do not affect order',
    () {
      final old = {...post('old', 'a', 1, 1000), 'receivedAtWallMs': 90000};
      final recent = {...post('new', 'b', 1, 2000), 'receivedAtWallMs': 1};
      expect(orderNews([old, recent]).map((n) => n['id']), ['new', 'old']);
      old.remove('receivedAtWallMs');
      expect(orderNews([recent, old]).map((n) => n['id']), ['new', 'old']);
    },
  );

  for (final fa in [false, true]) {
    testWidgets('local timezone, send/receive labels and unknown receipt: $fa', (
      tester,
    ) async {
      final news = {
        ...post('example', 'a', 1, 1770000000000),
        'receivedAtWallMs': 1770000065000,
        'receivedVia': 'overlay',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsTimes(news: news, fa: fa),
          ),
        ),
      );
      Text label(String key) =>
          tester.widget<Text>(find.byKey(ValueKey('$key-example')));
      expect(label('sent-time').data, startsWith(fa ? 'ارسال:' : 'Sent:'));
      expect(
        label('received-time').data,
        startsWith(fa ? 'دریافت در این گوشی:' : 'Received on this phone:'),
      );
      expect(label('sent-time').data, contains('UTC'));
      expect(label('sent-time').data, isNot(label('received-time').data));
      // English keeps the Gregorian stamp; Farsi renders a Jalali date with
      // Persian month names and digits, and isolates the offset run.
      expect(
        label('sent-time').data,
        fa
            ? allOf(
                contains(
                  RegExp(
                    '^ارسال: [۰-۹]{1,2} (${JalaliDate.monthNamesFa.join('|')}) '
                    '[۰-۹]{4} [۰-۹]{2}:[۰-۹]{2}:[۰-۹]{2} '
                    '${ltrIsolateStart}UTC[+-][۰-۹]{2}:[۰-۹]{2}$ltrIsolateEnd\$',
                  ),
                ),
                isNot(contains(RegExp('[0-9]'))),
              )
            : matches(
                RegExp(
                  r'^Sent: \d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} UTC[+-]\d{2}:\d{2}$',
                ),
              ),
      );
      news.remove('receivedAtWallMs');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsTimes(news: news, fa: fa),
          ),
        ),
      );
      expect(
        label('received-time').data,
        contains(fa ? 'ثبت نشده' : 'Unavailable'),
      );
      news['receivedVia'] = 'local';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsTimes(news: news, fa: fa),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('received-time-example')), findsNothing);
    });
  }
}
