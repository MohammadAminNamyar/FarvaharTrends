/// Dependency-free Gregorian <-> Jalali (Solar Hijri) calendar conversion.
///
/// This is the arithmetic from jalaali-js (Behrang Noruzi Niya), itself an
/// implementation of Kazimierz M. Borkowski's "The Persian calendar for 3000
/// years" (Earth, Moon and Planets 74, 1996): 1 Farvardin is placed by the
/// 33-year leap cycle with the published break years, so it agrees with the
/// official Iranian calendar for years 475..3177 (Gregorian 1096..3797).
/// Known reference: 1403 is a leap year and 1404 is not.
///
/// Presentation only. Signed UTC timestamps, time zones and ordering are not
/// touched here; callers convert an instant to the viewer's wall clock first.
library;

/// A calendar date in the Solar Hijri calendar.
class JalaliDate implements Comparable<JalaliDate> {
  JalaliDate(this.year, this.month, this.day) {
    if (year < minYear || year > maxYear) {
      throw ArgumentError.value(year, 'year', 'Outside $minYear..$maxYear');
    }
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', 'Must be 1..12');
    }
    final length = monthLength(year, month);
    if (day < 1 || day > length) {
      throw ArgumentError.value(day, 'day', 'Must be 1..$length');
    }
  }

  /// Converts the calendar fields (year, month, day) of `local`; the time of
  /// day and the zone of the value are ignored. Pass a wall-clock value.
  factory JalaliDate.fromDateTime(DateTime local) => JalaliDate.fromJulianDay(
    gregorianToJulianDay(local.year, local.month, local.day),
  );

  /// Converts a Julian Day Number.
  factory JalaliDate.fromJulianDay(int julianDay) {
    final gregorianYear = _julianDayToGregorian(julianDay).$1;
    var jalaliYear = gregorianYear - 621;
    final calc = _calc(jalaliYear);
    final firstDay = gregorianToJulianDay(gregorianYear, 3, calc.march);
    var k = julianDay - firstDay;
    if (k >= 0) {
      if (k <= 185) {
        return JalaliDate(jalaliYear, 1 + _div(k, 31), _mod(k, 31) + 1);
      }
      k -= 186;
    } else {
      jalaliYear -= 1;
      k += 179;
      if (calc.leap == 1) k += 1;
    }
    return JalaliDate(jalaliYear, 7 + _div(k, 30), _mod(k, 30) + 1);
  }

  /// First supported year (jalaali-js break table).
  static const minYear = -61;

  /// Last supported year (jalaali-js break table).
  static const maxYear = 3177;

  final int year;
  final int month;
  final int day;

  static const monthNamesFa = [
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند',
  ];

  /// Indexed by [DateTime.weekday] (Monday = 1 .. Sunday = 7); index 0 unused.
  static const weekdayNamesFa = [
    '',
    'دوشنبه',
    'سه‌شنبه',
    'چهارشنبه',
    'پنجشنبه',
    'جمعه',
    'شنبه',
    'یکشنبه',
  ];

  /// True when Esfand has 30 days in `year`.
  static bool isLeapYear(int year) => _calc(year).leap == 0;

  /// Days in `month` of `year`.
  static int monthLength(int year, int month) => month <= 6
      ? 31
      : month <= 11
      ? 30
      : isLeapYear(year)
      ? 30
      : 29;

  bool get isLeap => isLeapYear(year);
  String get monthNameFa => monthNamesFa[month - 1];

  /// Weekday in [DateTime.weekday] numbering (Monday = 1 .. Sunday = 7).
  int get weekday => toDateTime().weekday;
  String get weekdayNameFa => weekdayNamesFa[weekday];

  /// Julian Day Number of this date.
  int get julianDay {
    final calc = _calc(year);
    return gregorianToJulianDay(calc.gregorianYear, 3, calc.march) +
        (month - 1) * 31 -
        _div(month, 7) * (month - 7) +
        day -
        1;
  }

  /// Local midnight of the equivalent Gregorian date.
  DateTime toDateTime() {
    final (y, m, d) = _julianDayToGregorian(julianDay);
    return DateTime(y, m, d);
  }

  @override
  int compareTo(JalaliDate other) => julianDay.compareTo(other.julianDay);

  @override
  bool operator ==(Object other) =>
      other is JalaliDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      '$year/${month.toString().padLeft(2, '0')}/${day.toString().padLeft(2, '0')}';
}

/// Julian Day Number of a proleptic Gregorian date.
int gregorianToJulianDay(int year, int month, int day) {
  var d =
      _div((year + _div(month - 8, 6) + 100100) * 1461, 4) +
      _div(153 * _mod(month + 9, 12) + 2, 5) +
      day -
      34840408;
  d = d - _div(_div(year + 100100 + _div(month - 8, 6), 100) * 3, 4) + 752;
  return d;
}

(int, int, int) _julianDayToGregorian(int julianDay) {
  var j = 4 * julianDay + 139361631;
  j = j + _div(_div(4 * julianDay + 183187720, 146097) * 3, 4) * 4 - 3908;
  final i = _div(_mod(j, 1461), 4) * 5 + 308;
  final day = _div(_mod(i, 153), 5) + 1;
  final month = _mod(_div(i, 153), 12) + 1;
  final year = _div(j, 1461) - 100100 + _div(8 - month, 6);
  return (year, month, day);
}

const _breaks = [
  -61,
  9,
  38,
  199,
  426,
  686,
  756,
  818,
  1111,
  1181,
  1210,
  1635,
  2060,
  2097,
  2192,
  2262,
  2324,
  2394,
  2456,
  3178,
];

/// `leap`: days to the next leap year (0 means `year` is leap); `march`: the
/// Gregorian March day of 1 Farvardin in `gregorianYear`.
({int leap, int gregorianYear, int march}) _calc(int year) {
  if (year < _breaks.first || year >= _breaks.last) {
    throw ArgumentError.value(year, 'year', 'Outside the supported range');
  }
  final gregorianYear = year + 621;
  var leapJ = -14;
  var jp = _breaks.first;
  var jump = 0;
  for (var i = 1; i < _breaks.length; i++) {
    final jm = _breaks[i];
    jump = jm - jp;
    if (year < jm) break;
    leapJ = leapJ + _div(jump, 33) * 8 + _div(_mod(jump, 33), 4);
    jp = jm;
  }
  var n = year - jp;
  leapJ = leapJ + _div(n, 33) * 8 + _div(_mod(n, 33) + 3, 4);
  if (_mod(jump, 33) == 4 && jump - n == 4) leapJ += 1;
  final leapG =
      _div(gregorianYear, 4) -
      _div((_div(gregorianYear, 100) + 1) * 3, 4) -
      150;
  final march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + _div(jump + 4, 33) * 33;
  var leap = _mod(_mod(n + 1, 33) - 1, 4);
  if (leap == -1) leap = 4;
  return (leap: leap, gregorianYear: gregorianYear, march: march);
}

// Truncating division and remainder, as in the JavaScript reference.
int _div(int a, int b) => a ~/ b;
int _mod(int a, int b) => a - (a ~/ b) * b;
