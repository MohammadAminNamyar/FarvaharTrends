/// The one timestamp formatter for the reader UI.
///
/// Contract (docs/SCALE-AND-SECURITY-AUDIT.md, "Time and ordering contract"):
/// `createdAtMs` is the writer's signed UTC send time; `receivedAtWallMs` is
/// this phone's private first-receive wall time. Both are shown in the viewer's
/// current time zone. Nothing here measures a duration, invents a clock, or
/// alters a signed value: a missing or out-of-range value renders as
/// "Unavailable" / "ثبت نشده".
///
/// English output is byte-for-byte the Gregorian text the widgets produced
/// before this module existed. Farsi output uses the Jalali calendar with
/// Persian month names and Persian-Indic digits.
library;

import '../core/jalali.dart';
import 'localization.dart';

/// Latest accepted epoch millisecond: 9999-12-31T23:59:59.999Z.
const maxTimestampMs = 253402300799999;

/// U+2066 LEFT-TO-RIGHT ISOLATE: starts an LTR run inside RTL text.
const ltrIsolateStart = '\u2066';

/// U+2069 POP DIRECTIONAL ISOLATE: ends the run opened by [ltrIsolateStart].
const ltrIsolateEnd = '\u2069';

/// A wall-clock reading in the viewer's zone and the zone offset at that
/// instant. Only the calendar/time fields of [wall] are read, so a UTC-flagged
/// value whose fields already hold the wall time is acceptable (see
/// [fixedZone]).
class ZonedTime {
  const ZonedTime(this.wall, this.offset);
  final DateTime wall;
  final Duration offset;
}

/// Maps a UTC instant to the viewer's wall clock.
typedef ZoneResolver = ZonedTime Function(DateTime utc);

/// The device's current zone, including its DST rules.
ZonedTime deviceZone(DateTime utc) {
  final local = utc.toLocal();
  return ZonedTime(local, local.timeZoneOffset);
}

/// A constant offset, for tests and previews that must not depend on the
/// host zone.
ZoneResolver fixedZone(Duration offset) =>
    (utc) => ZonedTime(utc.add(offset), offset);

/// Formats signed/observed epoch-millisecond values for one language.
class NewsDateFormat {
  const NewsDateFormat({required this.fa, this.zone = deviceZone});

  final bool fa;
  final ZoneResolver zone;

  /// Shown when a timestamp is absent, not an int, negative or beyond
  /// [maxTimestampMs].
  String get unavailable => fa ? 'ثبت نشده' : 'Unavailable';

  /// Wall-clock reading of `epochMs`, or null when it is not a usable value.
  ZonedTime? resolve(dynamic epochMs) {
    if (epochMs is! int || epochMs < 0 || epochMs > maxTimestampMs) return null;
    return zone(DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true));
  }

  /// Compact label: `HH:MM:SS` on the viewer's clock. Callers render it in an
  /// LTR run (`textDirection: TextDirection.ltr`) so digits never reorder.
  String clock(dynamic epochMs) {
    final at = resolve(epochMs);
    return at == null ? unavailable : _digits(_clock(at.wall));
  }

  /// Calendar date in the viewer's timezone, without repeating the clock.
  String date(dynamic epochMs) {
    final at = resolve(epochMs);
    return at == null
        ? unavailable
        : fa
        ? _jalaliDate(at.wall)
        : _gregorianDate(at.wall);
  }

  /// Full label: date, `HH:MM:SS` and the UTC offset in force at that instant.
  /// English: `2026/10/13 11:38:06 UTC+03:30`.
  /// Farsi: `۲۱ مهر ۱۴۰۵ ۱۱:۳۸:۰۶ UTC+۰۳:۳۰`, with the offset token wrapped in
  /// a left-to-right isolate (U+2066..U+2069) so it reads correctly inside
  /// right-to-left text.
  String full(dynamic epochMs) {
    final at = resolve(epochMs);
    if (at == null) return unavailable;
    final offset = 'UTC${_offset(at.offset)}';
    return fa
        ? '${_jalaliDate(at.wall)} ${_digits(_clock(at.wall))} '
              '$ltrIsolateStart${_digits(offset)}$ltrIsolateEnd'
        : '${_gregorianDate(at.wall)} ${_clock(at.wall)} $offset';
  }

  /// Date and time without the offset, for local-only logs:
  /// English `2026/10/13 · 11:38:06`, Farsi `۲۱ مهر ۱۴۰۵ · ۱۱:۳۸:۰۶`.
  String dateAndTime(dynamic epochMs) {
    final at = resolve(epochMs);
    if (at == null) return unavailable;
    return fa
        ? '${_jalaliDate(at.wall)} · ${_digits(_clock(at.wall))}'
        : '${_gregorianDate(at.wall)} · ${_clock(at.wall)}';
  }

  /// Day-relative label for list headers: `HH:MM` today, "Yesterday" for the
  /// previous calendar day, otherwise the short date. English short dates are
  /// produced by `shortDate` (the Material localization today); Farsi short
  /// dates are Jalali, e.g. `۲۱ مهر ۱۴۰۵`.
  String relativeDay(
    DateTime wall, {
    required DateTime now,
    required String Function(DateTime wall) shortDate,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(wall.year, wall.month, wall.day);
    if (day == today) {
      return _digits('${_two(wall.hour)}:${_two(wall.minute)}');
    }
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return fa ? 'دیروز' : 'Yesterday';
    }
    return fa ? _jalaliDate(wall) : shortDate(wall);
  }

  String _digits(String text) => fa ? persianDigits(text) : text;

  String _jalaliDate(DateTime wall) {
    final date = JalaliDate.fromDateTime(wall);
    return '${_digits('${date.day}')} ${date.monthNameFa} '
        '${_digits('${date.year}')}';
  }

  static String _gregorianDate(DateTime wall) =>
      '${wall.year}/${_two(wall.month)}/${_two(wall.day)}';

  static String _clock(DateTime wall) =>
      '${_two(wall.hour)}:${_two(wall.minute)}:${_two(wall.second)}';

  static String _offset(Duration zone) {
    final minutes = zone.inMinutes.abs();
    return '${zone.isNegative ? '-' : '+'}${_two(minutes ~/ 60)}:'
        '${_two(minutes % 60)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
