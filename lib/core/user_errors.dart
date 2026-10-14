import 'dart:async';
import 'dart:io';

/// Stable presentation codes; exception text never becomes interface copy.
class UserError {
  const UserError(this.code, this.fa, this.en);
  final String code, fa, en;
  String text(String language) => language == 'en' ? en : fa;
}

const _errors = {
  'connection_choice': UserError(
    'connection_choice',
    'انتخاب روش اتصال ذخیره نشد. لطفاً دوباره تلاش کنید.',
    'Could not save your connection choice.',
  ),
  'timeout': UserError(
    'timeout',
    'زمان انتظار تمام شد. لطفاً دوباره تلاش کنید.',
    'The request timed out. Please try again.',
  ),
  'network': UserError(
    'network',
    'ارتباط برقرار نشد. اتصال را بررسی کنید و دوباره تلاش کنید.',
    'Could not connect. Check your connection and try again.',
  ),
  'storage': UserError(
    'storage',
    'ذخیره‌سازی کامل نشد. فضای خالی گوشی را بررسی کنید.',
    'Could not save. Check the free space on your phone.',
  ),
  'invalid': UserError(
    'invalid',
    'اطلاعات یا فایل معتبر نیست. لطفاً آن را بررسی کنید.',
    'The information or file is invalid. Please check it.',
  ),
  'channel_capacity': UserError(
    'channel_capacity',
    'ظرفیت کانال‌های ذخیره‌شده پر است. کانال‌های غیرضروری را بررسی کنید.',
    'The saved channel limit has been reached. Review unused channels.',
  ),
  'channel_publisher_capacity': UserError(
    'channel_publisher_capacity',
    'ظرفیت کانال‌های این ناشر پر شده است.',
    'This publisher has reached the channel limit.',
  ),
  'reader_recovery': UserError(
    'reader_recovery',
    'تنظیمات خواندن بازیابی نشد؛ اعلان‌ها و دریافت تصویر خاموش است. لطفاً تنظیمات را دوباره بررسی کنید.',
    'Reading settings could not be recovered; alerts and image downloads are off. Please review your settings.',
  ),
  'channel_recovery': UserError(
    'channel_recovery',
    'انتخاب‌های ذخیره‌شدهٔ کانال‌ها قابل خواندن نبود. لطفاً انتخاب‌های دنبال‌کردن، پنهان‌کردن و اعتماد را دوباره تنظیم کنید.',
    'Saved channel choices could not be read. Please set your follow, hide and trust choices again.',
  ),
  'generic': UserError(
    'generic',
    'این کار کامل نشد. لطفاً دوباره تلاش کنید.',
    'That action did not finish. Please try again.',
  ),
};

UserError userError(Object error, {String? code}) {
  if (code != null && _errors.containsKey(code)) return _errors[code]!;
  if (error is TimeoutException) return _errors['timeout']!;
  if (error is SocketException || error is HandshakeException) {
    return _errors['network']!;
  }
  if (error is FileSystemException) return _errors['storage']!;
  if (error is FormatException || error is ArgumentError) {
    return _errors['invalid']!;
  }
  if (error is StateError && _errors.containsKey(error.message)) {
    return _errors[error.message]!;
  }
  if (error is StateError &&
      error.message == 'Could not save your connection choice.') {
    return _errors['connection_choice']!;
  }
  return _errors['generic']!;
}
