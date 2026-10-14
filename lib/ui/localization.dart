/// Shared Farsi/English helpers for the reader UI.
///
/// Farsi is the default language; English is opt-in via `languageCode == 'en'`.
/// These replace the private `t()` / digit helpers that were copied per widget.
library;

/// Persian-Indic digits, indexed by the ASCII digit value.
const persianDigitChars = '۰۱۲۳۴۵۶۷۸۹';

/// True unless the stored language code selects English.
bool isFarsiLanguage(String? languageCode) => languageCode != 'en';

/// Maps ASCII digits 0-9 to Persian-Indic digits. Other characters, including
/// '.', ':', '/' and '-', pass through unchanged, exactly as the former
/// per-widget helpers did, so clock and offset separators stay stable.
String persianDigits(String text) => text.replaceAllMapped(
  RegExp('[0-9]'),
  (m) => persianDigitChars[m[0]!.codeUnitAt(0) - 0x30],
);

/// `value` rendered with Persian digits in Farsi, unchanged otherwise.
String localizedDigits(Object? value, {required bool fa}) =>
    fa ? persianDigits('$value') : '$value';

/// Picks the Farsi or English copy.
String tr(bool fa, String faText, String enText) => fa ? faText : enText;

/// Mix into widgets or states that expose `bool get fa` (a `final bool fa`
/// field satisfies it) to keep the familiar `t(...)` / `n(...)` call sites.
mixin Localized {
  bool get fa;

  String t(String faText, String enText) => fa ? faText : enText;

  String n(Object? value) => localizedDigits(value, fa: fa);
}
