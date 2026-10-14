import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/user_errors.dart';

void main() {
  test('known errors map to stable codes and unknown text stays private', () {
    for (final error in [
      TimeoutException('raw'),
      const SocketException('raw'),
      const FileSystemException('raw'),
      const FormatException('raw'),
      StateError('raw'),
    ]) {
      final mapped = userError(error);
      expect(mapped.text('fa'), isNot(contains('raw')));
      expect(mapped.text('fa'), isNot(matches(RegExp(r'[A-Za-z]'))));
      expect(mapped.text('en'), isNotEmpty);
    }
    expect(userError('private', code: 'timeout').code, 'timeout');
    expect(userError('private', code: 'unknown').code, 'generic');
    expect(userError(StateError('channel_capacity')).code, 'channel_capacity');
    expect(
      userError('', code: 'reader_recovery').text('fa'),
      contains('خاموش'),
    );
  });
}
