import 'dart:math';

import 'package:farvahar_trends/core/connection_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final (resource, limit, reserve) in [
    (TrafficResource.ingressFrames, 2400, 150),
    (TrafficResource.ingressBytes, 4 * 1024 * 1024, 256 * 1024),
    (TrafficResource.egressBytes, 4 * 1024 * 1024, 256 * 1024),
    (TrafficResource.requests, 2048, 128),
    (TrafficResource.channels, 32, 2),
    (TrafficResource.policies, 128, 8),
    (TrafficResource.contacts, 64, 4),
    (TrafficResource.envelopeDecryptions, 256, 16),
    (TrafficResource.relayAdmissions, 64, 4),
  ]) {
    test(
      'seven busy links cannot consume the eighth $resource reservation',
      () {
        final pool = ConnectionBudget(capacity: 8, limits: {resource: limit});
        final honest = pool.acquire()!;
        final busy = List.generate(7, (_) => pool.acquire()!);
        expect(pool.acquire(), isNull);
        expect(pool.spend(busy.first, resource, limit - 7 * reserve), isTrue);
        for (final link in busy.skip(1)) {
          expect(pool.spend(link, resource, reserve), isTrue);
        }
        for (final link in busy) {
          expect(pool.spend(link, resource, 1), isFalse);
        }
        expect(pool.spend(honest, resource, reserve), isTrue);
        expect(pool.spend(honest, resource, 1), isFalse);
      },
    );
  }

  test(
    'connection churn cannot mint work or consume a live neighbor reservation',
    () {
      final pool = ConnectionBudget(
        capacity: 2,
        limits: {TrafficResource.ingressFrames: 100},
      );
      final honest = pool.acquire()!;
      var attacker = pool.acquire()!;
      expect(pool.spend(attacker, TrafficResource.ingressFrames, 75), isTrue);
      for (var i = 0; i < 100; i++) {
        pool.release(attacker);
        expect(pool.spend(attacker, TrafficResource.ingressFrames, 1), isFalse);
        final stale = attacker;
        attacker = pool.acquire()!;
        pool.release(stale);
        expect(pool.spend(attacker, TrafficResource.ingressFrames, 1), isFalse);
        expect(pool.acquire(), isNull);
      }
      expect(pool.spend(honest, TrafficResource.ingressFrames, 25), isTrue);
    },
  );

  test('failed work is atomic and only a new window restores spending', () {
    final pool = ConnectionBudget(
      capacity: 2,
      limits: {TrafficResource.ingressFrames: 100},
    );
    final first = pool.acquire()!;
    final second = pool.acquire()!;
    expect(pool.spend(first, TrafficResource.ingressFrames, 76), isFalse);
    expect(pool.spend(first, TrafficResource.ingressFrames, 75), isTrue);
    expect(pool.spend(second, TrafficResource.ingressFrames, 25), isTrue);
    pool.refreshWindow(0);
    expect(pool.spend(first, TrafficResource.ingressFrames, 1), isFalse);
    pool.refreshWindow(60000);
    expect(pool.spend(first, TrafficResource.ingressFrames, 75), isTrue);
    pool.refreshWindow(1);
    expect(pool.spend(first, TrafficResource.ingressFrames, 1), isFalse);
    expect(pool.spend(second, TrafficResource.ingressFrames, 25), isTrue);
  });

  test(
    'a lease from another engine cannot spend or release local capacity',
    () {
      ConnectionBudget make() =>
          ConnectionBudget(capacity: 1, limits: {TrafficResource.channels: 32});
      final a = make();
      final b = make();
      final aLease = a.acquire()!;
      final bLease = b.acquire()!;
      a.release(bLease);
      expect(a.acquire(), isNull);
      expect(a.spend(bLease, TrafficResource.channels, 1), isFalse);
      expect(a.spend(aLease, TrafficResource.channels, 32), isTrue);
    },
  );

  test(
    'random admission, release and reconnect never exceed aggregate bounds',
    () {
      final pool = ConnectionBudget(
        capacity: 4,
        limits: {
          TrafficResource.ingressFrames: 101,
          TrafficResource.channels: 33,
        },
      );
      final random = Random(7531);
      final leases = <ConnectionAllowance>[];
      final used = <TrafficResource, int>{};
      for (var step = 0; step < 10000; step++) {
        if (step % 500 == 0) {
          pool.refreshWindow(step + 1);
          used.clear();
        }
        if (leases.isEmpty || random.nextInt(4) == 0) {
          final lease = pool.acquire();
          if (lease != null) leases.add(lease);
        } else if (random.nextInt(4) == 0) {
          pool.release(leases.removeAt(random.nextInt(leases.length)));
        } else {
          final resource = random.nextBool()
              ? TrafficResource.ingressFrames
              : TrafficResource.channels;
          final count = random.nextInt(20) + 1;
          if (pool.spend(
            leases[random.nextInt(leases.length)],
            resource,
            count,
          )) {
            used[resource] = (used[resource] ?? 0) + count;
          }
          expect(
            used[resource] ?? 0,
            lessThanOrEqualTo(pool.limits[resource]!),
          );
        }
      }
    },
  );
}
