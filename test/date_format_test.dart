import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/jalali.dart';
import 'package:persian_trend/ui/date_format.dart';
import 'package:persian_trend/ui/news_components.dart';

// ---------------------------------------------------------------------------
// Snapshot of the formatters the widgets used before lib/ui/date_format.dart
// existed (NewsTimes._stamp/_clock in news_components.dart and the event time
// in temporary_log.dart). English output must stay byte-for-byte identical.
// ---------------------------------------------------------------------------
String _previousDigits(String text, bool fa) => fa
    ? text.replaceAllMapped(
        RegExp('[0-9]'),
        (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)],
      )
    : text;

String _previousStamp(dynamic value, bool fa) {
  if (value is! int || value < 0 || value > 253402300799999) {
    return fa ? 'ثبت نشده' : 'Unavailable';
  }
  final date = DateTime.fromMillisecondsSinceEpoch(
    value,
    isUtc: true,
  ).toLocal();
  final zone = date.timeZoneOffset;
  String two(int n) => n.toString().padLeft(2, '0');
  return _previousDigits(
    '${date.year}/${two(date.month)}/${two(date.day)} '
    '${two(date.hour)}:${two(date.minute)}:${two(date.second)} '
    'UTC${zone.isNegative ? '-' : '+'}${two(zone.inMinutes.abs() ~/ 60)}:'
    '${two(zone.inMinutes.abs() % 60)}',
    fa,
  );
}

String _previousClock(dynamic value, bool fa) {
  if (value is! int || value < 0 || value > 253402300799999) {
    return fa ? 'ثبت نشده' : 'Unavailable';
  }
  final date = DateTime.fromMillisecondsSinceEpoch(
    value,
    isUtc: true,
  ).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return _previousDigits(
    '${two(date.hour)}:${two(date.minute)}:${two(date.second)}',
    fa,
  );
}

String _previousLogTime(int value, bool fa) {
  final at = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String pad(int value) => '$value'.padLeft(2, '0');
  return _previousDigits(
    '${at.year}/${pad(at.month)}/${pad(at.day)} · ${pad(at.hour)}:${pad(at.minute)}:${pad(at.second)}',
    fa,
  );
}

const _iso = '\u2066';
const _pop = '\u2069';
const _tehran = Duration(hours: 3, minutes: 30);

void main() {
  final instants = <int>[
    0,
    1,
    DateTime.utc(2026, 10, 13, 8, 8, 6).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 20, 20, 29, 59).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 20, 20, 30).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 29, 0, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 29, 1).millisecondsSinceEpoch,
    DateTime.utc(2026, 10, 25, 0, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(2026, 10, 25, 1).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 8, 9, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(2026, 3, 8, 10).millisecondsSinceEpoch,
    DateTime.utc(2026, 11, 1, 8, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(2026, 11, 1, 9).millisecondsSinceEpoch,
    DateTime.utc(2025, 3, 20, 23, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(1999, 12, 31, 23, 59, 59).millisecondsSinceEpoch,
    DateTime.utc(2038, 1, 19, 3, 14, 8).millisecondsSinceEpoch,
    maxTimestampMs,
  ];
  final invalid = <dynamic>[
    null,
    -1,
    maxTimestampMs + 1,
    '1770000000000',
    1770000000000.0,
    true,
  ];

  test('English output is unchanged versus the previous formatter', () {
    const format = NewsDateFormat(fa: false);
    for (final ms in instants) {
      expect(format.full(ms), _previousStamp(ms, false), reason: '$ms');
      expect(format.clock(ms), _previousClock(ms, false), reason: '$ms');
      expect(
        format.dateAndTime(ms),
        _previousLogTime(ms, false),
        reason: '$ms',
      );
    }
    for (final value in invalid) {
      expect(format.full(value), _previousStamp(value, false));
      expect(format.clock(value), _previousClock(value, false));
      expect(format.dateAndTime(value), 'Unavailable');
    }
  });

  test('Farsi clock keeps the previous HH:MM:SS with Persian digits', () {
    const format = NewsDateFormat(fa: true);
    for (final ms in instants) {
      expect(format.clock(ms), _previousClock(ms, true), reason: '$ms');
    }
    for (final value in invalid) {
      expect(format.clock(value), 'ثبت نشده');
      expect(format.full(value), 'ثبت نشده');
      expect(format.dateAndTime(value), 'ثبت نشده');
    }
  });

  test('fixed zones: Tehran, Nowruz boundary and DST steps', () {
    final tehranEn = NewsDateFormat(fa: false, zone: fixedZone(_tehran));
    final tehranFa = NewsDateFormat(fa: true, zone: fixedZone(_tehran));
    final mehr = DateTime.utc(2026, 10, 13, 8, 8, 6).millisecondsSinceEpoch;
    expect(tehranEn.full(mehr), '2026/10/13 11:38:06 UTC+03:30');
    expect(tehranEn.clock(mehr), '11:38:06');
    expect(tehranEn.dateAndTime(mehr), '2026/10/13 · 11:38:06');
    expect(tehranFa.full(mehr), '۲۱ مهر ۱۴۰۵ ۱۱:۳۸:۰۶ ${_iso}UTC+۰۳:۳۰$_pop');
    expect(tehranFa.clock(mehr), '۱۱:۳۸:۰۶');
    expect(tehranFa.dateAndTime(mehr), '۲۱ مهر ۱۴۰۵ · ۱۱:۳۸:۰۶');

    // The same instant is 29 Esfand 1404 in UTC and 1 Farvardin 1405 in Tehran.
    final nowruz = DateTime.utc(2026, 3, 20, 20, 30).millisecondsSinceEpoch;
    final utcFa = NewsDateFormat(fa: true, zone: fixedZone(Duration.zero));
    expect(
      tehranFa.full(nowruz),
      '۱ فروردین ۱۴۰۵ ۰۰:۰۰:۰۰ ${_iso}UTC+۰۳:۳۰$_pop',
    );
    expect(utcFa.full(nowruz), '۲۹ اسفند ۱۴۰۴ ۲۰:۳۰:۰۰ ${_iso}UTC+۰۰:۰۰$_pop');
    expect(
      tehranFa.full(nowruz - 1000),
      '۲۹ اسفند ۱۴۰۴ ۲۳:۵۹:۵۹ ${_iso}UTC+۰۳:۳۰$_pop',
    );
    expect(tehranEn.full(nowruz - 1000), '2026/03/20 23:59:59 UTC+03:30');
    expect(tehranEn.full(nowruz), '2026/03/21 00:00:00 UTC+03:30');

    // A zone that observes DST reports the offset in force at each instant.
    final before = DateTime.utc(2026, 3, 29, 0, 59, 59).millisecondsSinceEpoch;
    final after = DateTime.utc(2026, 3, 29, 1).millisecondsSinceEpoch;
    final winter = NewsDateFormat(
      fa: false,
      zone: fixedZone(const Duration(hours: 1)),
    );
    final summer = NewsDateFormat(
      fa: false,
      zone: fixedZone(const Duration(hours: 2)),
    );
    expect(winter.full(before), '2026/03/29 01:59:59 UTC+01:00');
    expect(summer.full(after), '2026/03/29 03:00:00 UTC+02:00');
    final summerFa = NewsDateFormat(
      fa: true,
      zone: fixedZone(const Duration(hours: 2)),
    );
    expect(
      summerFa.full(after),
      '۹ فروردین ۱۴۰۵ ۰۳:۰۰:۰۰ ${_iso}UTC+۰۲:۰۰$_pop',
    );

    // Negative offsets, including a half-hour one, keep the sign and padding.
    final newfoundland = NewsDateFormat(
      fa: false,
      zone: fixedZone(const Duration(hours: -2, minutes: -30)),
    );
    expect(newfoundland.full(mehr), '2026/10/13 05:38:06 UTC-02:30');
    final pacific = NewsDateFormat(
      fa: true,
      zone: fixedZone(const Duration(hours: -7)),
    );
    expect(pacific.full(mehr), '۲۱ مهر ۱۴۰۵ ۰۱:۰۸:۰۶ ${_iso}UTC-۰۷:۰۰$_pop');
    // A date shift across the UTC day line also shifts the Jalali day.
    final late = DateTime.utc(2026, 10, 13, 22).millisecondsSinceEpoch;
    expect(tehranFa.dateAndTime(late), '۲۲ مهر ۱۴۰۵ · ۰۱:۳۰:۰۰');
    expect(pacific.dateAndTime(late), '۲۱ مهر ۱۴۰۵ · ۱۵:۰۰:۰۰');
  });

  test('device zone resolves through DateTime.toLocal', () {
    final utc = DateTime.utc(2026, 10, 13, 8, 8, 6);
    final at = deviceZone(utc);
    final local = utc.toLocal();
    expect(at.wall, local);
    expect(at.offset, local.timeZoneOffset);
    expect(const NewsDateFormat(fa: false).resolve(null), isNull);
    expect(
      const NewsDateFormat(fa: false).resolve(0)!.wall.year,
      greaterThan(1968),
    );
  });

  test('Farsi full labels use every Jalali month name', () {
    final format = NewsDateFormat(fa: true, zone: fixedZone(_tehran));
    final seen = <String>{};
    var day = DateTime.utc(2026, 3, 21, 6);
    for (var i = 0; i < 365; i++) {
      final label = format.full(day.millisecondsSinceEpoch);
      final month = JalaliDate.monthNamesFa.firstWhere(label.contains);
      seen.add(month);
      expect(label, isNot(contains(RegExp('[0-9]'))));
      expect(label, contains('۱۴۰۵'));
      day = day.add(const Duration(days: 1));
    }
    expect(seen, JalaliDate.monthNamesFa.toSet());
  });

  test('relativeDay: today, yesterday, otherwise a date', () {
    final now = DateTime(2026, 10, 13, 18);
    String short(DateTime d) => 'short:${d.year}-${d.month}-${d.day}';
    const en = NewsDateFormat(fa: false);
    const fa = NewsDateFormat(fa: true);
    final today = DateTime(2026, 10, 13, 11, 38);
    final yesterday = DateTime(2026, 10, 12, 23, 59);
    final older = DateTime(2026, 10, 11, 0, 1);
    expect(en.relativeDay(today, now: now, shortDate: short), '11:38');
    expect(fa.relativeDay(today, now: now, shortDate: short), '۱۱:۳۸');
    expect(en.relativeDay(yesterday, now: now, shortDate: short), 'Yesterday');
    expect(fa.relativeDay(yesterday, now: now, shortDate: short), 'دیروز');
    expect(
      en.relativeDay(older, now: now, shortDate: short),
      'short:2026-10-11',
    );
    expect(fa.relativeDay(older, now: now, shortDate: short), '۱۹ مهر ۱۴۰۵');
    // Month and year boundaries for "yesterday".
    final newYear = DateTime(2027, 1, 1, 9);
    expect(
      en.relativeDay(DateTime(2026, 12, 31, 9), now: newYear, shortDate: short),
      'Yesterday',
    );
    final afterNowruz = DateTime(2026, 3, 22, 9);
    expect(
      fa.relativeDay(
        DateTime(2026, 3, 20, 9),
        now: afterNowruz,
        shortDate: short,
      ),
      '۲۹ اسفند ۱۴۰۴',
    );
  });

  testWidgets('channelActivityTime keeps the Material short date in English', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 13, 18);
    final older = DateTime(2026, 10, 1, 9).millisecondsSinceEpoch;
    final todayMs = DateTime(2026, 10, 13, 9, 5).millisecondsSinceEpoch;
    late String en, fa, enToday, faToday, enInvalid;
    late String expected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            expected = MaterialLocalizations.of(context)
                .formatShortDate(DateTime.fromMillisecondsSinceEpoch(older));
            en = channelActivityTime(context, older, false, now: now);
            fa = channelActivityTime(context, older, true, now: now);
            enToday = channelActivityTime(context, todayMs, false, now: now);
            faToday = channelActivityTime(context, todayMs, true, now: now);
            enInvalid = channelActivityTime(context, 'x', false, now: now);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(en, expected);
    expect(fa, '۹ مهر ۱۴۰۵');
    expect(enToday, '09:05');
    expect(faToday, '۰۹:۰۵');
    expect(enInvalid, '');
  });
}
