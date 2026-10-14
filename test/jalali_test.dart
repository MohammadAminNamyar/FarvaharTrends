import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/jalali.dart';

/// (Gregorian y, m, d) -> (Jalali y, m, d), from official calendar tables.
const knownPairs = <((int, int, int), (int, int, int))>[
  // 1 Farvardin boundaries, 2000-2026 (March 20 in Gregorian leap years).
  ((2000, 3, 20), (1379, 1, 1)),
  ((2004, 3, 20), (1383, 1, 1)),
  ((2008, 3, 20), (1387, 1, 1)),
  ((2012, 3, 20), (1391, 1, 1)),
  ((2016, 3, 20), (1395, 1, 1)),
  ((2020, 3, 20), (1399, 1, 1)),
  ((2021, 3, 21), (1400, 1, 1)),
  ((2022, 3, 21), (1401, 1, 1)),
  ((2023, 3, 21), (1402, 1, 1)),
  ((2024, 3, 20), (1403, 1, 1)),
  ((2024, 3, 21), (1403, 1, 2)),
  ((2025, 3, 21), (1404, 1, 1)),
  ((2026, 3, 21), (1405, 1, 1)),
  // Last day of the year: 30 Esfand in leap years, 29 Esfand otherwise.
  ((2021, 3, 20), (1399, 12, 30)),
  ((2024, 3, 19), (1402, 12, 29)),
  ((2025, 3, 20), (1403, 12, 30)),
  ((2026, 3, 20), (1404, 12, 29)),
  // Mid-year month boundaries (31-day and 30-day months).
  ((2026, 9, 22), (1405, 6, 31)),
  ((2026, 9, 23), (1405, 7, 1)),
  ((2026, 10, 13), (1405, 7, 21)),
  ((1999, 12, 31), (1378, 10, 10)),
  ((2000, 1, 1), (1378, 10, 11)),
  // Historical anchors.
  ((1969, 12, 22), (1348, 10, 1)),
  ((1970, 1, 1), (1348, 10, 11)),
  ((1979, 2, 11), (1357, 11, 22)),
  ((1989, 6, 3), (1368, 3, 13)),
];

void main() {
  test('known Gregorian/Jalali pairs convert both ways', () {
    expect(knownPairs.length, greaterThanOrEqualTo(20));
    for (final (gregorian, jalali) in knownPairs) {
      final date = DateTime(gregorian.$1, gregorian.$2, gregorian.$3);
      final converted = JalaliDate.fromDateTime(date);
      expect(
        (converted.year, converted.month, converted.day),
        jalali,
        reason: 'from $date',
      );
      final back = JalaliDate(jalali.$1, jalali.$2, jalali.$3).toDateTime();
      expect(back, date, reason: 'to $jalali');
    }
  });

  test('leap years follow the official 33-year cycle', () {
    for (final leap in [
      1366,
      1370,
      1375,
      1379,
      1383,
      1387,
      1391,
      1395,
      1399,
      1403,
      1408,
    ]) {
      expect(JalaliDate.isLeapYear(leap), isTrue, reason: '$leap');
      expect(JalaliDate.monthLength(leap, 12), 30);
      expect(JalaliDate(leap, 12, 30).isLeap, isTrue);
    }
    for (final plain in [1400, 1401, 1402, 1404, 1405, 1406, 1407]) {
      expect(JalaliDate.isLeapYear(plain), isFalse, reason: '$plain');
      expect(JalaliDate.monthLength(plain, 12), 29);
      expect(() => JalaliDate(plain, 12, 30), throwsArgumentError);
    }
  });

  test('time of day and zone flag do not change the calendar date', () {
    final utc = DateTime.utc(2026, 3, 20, 23, 59, 59);
    final local = DateTime(2026, 3, 20, 0, 0, 1);
    for (final value in [utc, local]) {
      final date = JalaliDate.fromDateTime(value);
      expect((date.year, date.month, date.day), (1404, 12, 29));
    }
  });

  test('Persian month and weekday names', () {
    final nowruz = JalaliDate(1405, 1, 1);
    expect(nowruz.monthNameFa, 'فروردین');
    expect(nowruz.toDateTime().weekday, DateTime.saturday);
    expect(nowruz.weekdayNameFa, 'شنبه');
    final mehr = JalaliDate.fromDateTime(DateTime(2026, 10, 13));
    expect(mehr.monthNameFa, 'مهر');
    expect(mehr.weekdayNameFa, 'سه‌شنبه');
    expect(JalaliDate(1403, 12, 30).weekdayNameFa, 'پنجشنبه');
    expect(JalaliDate(1403, 12, 30).toString(), '1403/12/30');
    expect(JalaliDate.monthNamesFa, hasLength(12));
    expect(JalaliDate.monthNamesFa.last, 'اسفند');
  });

  test('round trip over every day from 1970 to 2100', () {
    var day = DateTime.utc(1970, 1, 1);
    final end = DateTime.utc(2101, 1, 1);
    JalaliDate? previous;
    var count = 0;
    while (day.isBefore(end)) {
      final jalali = JalaliDate.fromDateTime(day);
      expect(jalali.month, inInclusiveRange(1, 12));
      expect(
        jalali.day,
        inInclusiveRange(1, JalaliDate.monthLength(jalali.year, jalali.month)),
      );
      final back = jalali.toDateTime();
      expect((back.year, back.month, back.day), (day.year, day.month, day.day));
      if (previous != null) {
        // Consecutive days advance by exactly one Jalali day.
        expect(jalali.julianDay - previous.julianDay, 1, reason: '$day');
        final rolled =
            previous.day ==
            JalaliDate.monthLength(previous.year, previous.month);
        if (rolled) {
          expect(jalali.day, 1);
          expect(
            (jalali.year, jalali.month),
            previous.month == 12
                ? (previous.year + 1, 1)
                : (previous.year, previous.month + 1),
          );
        } else {
          expect(
            (jalali.year, jalali.month, jalali.day),
            (previous.year, previous.month, previous.day + 1),
          );
        }
      }
      previous = jalali;
      day = day.add(const Duration(days: 1));
      count++;
    }
    expect(count, 47847);
  });

  test('invalid fields and unsupported years are rejected', () {
    expect(() => JalaliDate(1405, 0, 1), throwsArgumentError);
    expect(() => JalaliDate(1405, 13, 1), throwsArgumentError);
    expect(() => JalaliDate(1405, 7, 31), throwsArgumentError);
    expect(() => JalaliDate(JalaliDate.maxYear + 1, 1, 1), throwsArgumentError);
    expect(() => JalaliDate(JalaliDate.minYear - 1, 1, 1), throwsArgumentError);
    expect(JalaliDate(1405, 7, 21), JalaliDate(1405, 7, 21));
    expect(JalaliDate(1405, 7, 21).compareTo(JalaliDate(1405, 7, 22)), -1);
  });
}
