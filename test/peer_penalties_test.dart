import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/peer_penalties.dart';

void main() {
  test('penalties outlive contact eviction, expire and stay bounded', () {
    var now = 0;
    final penalties = PeerPenalties(nowMs: () => now, cooldownMs: 30000);
    final contacts = <String>{'offender'};
    expect(penalties.strike('offender'), false);
    contacts.remove('offender');
    contacts.add('offender');
    expect(penalties.strike('offender'), false);
    expect(penalties.strike('offender'), true);
    expect(penalties.cooling('offender'), true);
    for (var i = 0; i < 128; i++) {
      penalties.strike('stranger-$i');
    }
    expect(penalties.length, PeerPenalties.maxEntries);
    expect(penalties.cooling('offender'), true);
    now = 30000;
    expect(penalties.cooling('offender'), false);
    now = PeerPenalties.strikeLifetimeMs;
    expect(penalties.length, 0);
  });
  test('IPv6 /64 shares a bucket without conflating other networks', () {
    String bucket(String address) =>
        PeerPenalties.addressBucket(InternetAddress(address));
    expect(bucket('2001:db8:1:2::1'), bucket('2001:db8:1:2:ffff::99'));
    expect(bucket('2001:db8:1:2::1'), isNot(bucket('2001:db8:1:3::1')));
    expect(bucket('::ffff:192.0.2.1'), bucket('192.0.2.1'));
    expect(bucket('192.0.2.1'), isNot(bucket('192.0.2.2')));
  });
}
