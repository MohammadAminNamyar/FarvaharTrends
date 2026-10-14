import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/network_epoch.dart';

void main() {
  test(
    'network loss, Wi-Fi address replacement, cellular switch and repeats',
    () {
      final epoch = NetworkEpoch();
      expect(epoch.observe('wifi-100'), isFalse);
      expect(epoch.observe('wifi-100'), isFalse);
      expect(epoch.observe('none'), isTrue);
      expect(epoch.observe('none'), isFalse);
      expect(epoch.observe('wifi-108'), isTrue);
      expect(epoch.observe('wifi-108'), isFalse);
      expect(epoch.observe('cellular-200'), isTrue);
      expect(epoch.observe('cellular-200'), isFalse);
    },
  );
  test('unavailable sampling cannot fabricate a network change', () {
    final epoch = NetworkEpoch();
    expect(epoch.observe(null), isFalse);
    expect(epoch.observe('wifi-1'), isFalse);
    expect(epoch.observe(null), isFalse);
    expect(epoch.observe('wifi-1'), isFalse);
    expect(epoch.observe('wifi-2'), isTrue);
  });
}
