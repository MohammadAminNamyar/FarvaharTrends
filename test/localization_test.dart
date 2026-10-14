import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/ui/localization.dart';

class _Widget with Localized {
  _Widget(this.fa);
  @override
  final bool fa;
}

void main() {
  test('persianDigits maps ASCII digits only and keeps separators', () {
    expect(persianDigits('0123456789'), '۰۱۲۳۴۵۶۷۸۹');
    expect(persianDigits('11:38:06'), '۱۱:۳۸:۰۶');
    expect(persianDigits('2026/10/13 UTC+03:30'), '۲۰۲۶/۱۰/۱۳ UTC+۰۳:۳۰');
    expect(persianDigits('3.5 -2'), '۳.۵ -۲');
    expect(persianDigits('۱۲ مهر'), '۱۲ مهر');
    expect(persianDigits(''), '');
    expect(persianDigitChars, hasLength(10));
  });

  test('localizedDigits and tr follow the language flag', () {
    expect(localizedDigits(200, fa: true), '۲۰۰');
    expect(localizedDigits(200, fa: false), '200');
    expect(localizedDigits(null, fa: true), 'null');
    expect(tr(true, 'فارسی', 'English'), 'فارسی');
    expect(tr(false, 'فارسی', 'English'), 'English');
  });

  test('isFarsiLanguage defaults to Farsi', () {
    expect(isFarsiLanguage('fa'), isTrue);
    expect(isFarsiLanguage(null), isTrue);
    expect(isFarsiLanguage(''), isTrue);
    expect(isFarsiLanguage('en'), isFalse);
  });

  test('Localized mixin keeps the t()/n() call sites', () {
    final fa = _Widget(true), en = _Widget(false);
    expect(fa.t('الف', 'a'), 'الف');
    expect(en.t('الف', 'a'), 'a');
    expect(fa.n(42), '۴۲');
    expect(en.n(42), '42');
  });
}
