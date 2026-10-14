import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/helper_contact_policy.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/peer_contact.dart';

void main() {
  late List<Identity> keys;
  setUpAll(() => keys = List.generate(6, (_) => Identity.generate()));
  const now = 1800000000000;
  PeerContact claim(int i, {String? host, int port = 45871, int at = now}) =>
      PeerContact.create(
        keys[i],
        host: host ?? '11.2.$i.1',
        port: port,
        lifetimeMs: 120000,
        nowMs: at,
      );

  test(
    'one introducer cannot occupy the pool even with valid live identities',
    () {
      final policy = HelperContactPolicy();
      for (var i = 0; i < 4; i++) {
        final c = claim(i);
        expect(policy.canAccept(c, 'first'), isTrue);
        policy.record(c, 'first', 0);
        policy.confirm(c.id, c.peer.host, c.peer.port);
      }
      expect(policy.canAccept(claim(4), 'first'), isFalse);
      expect(policy.canAccept(claim(4), 'second'), isTrue);
    },
  );

  test(
    'unconfirmed identities and a single address range have independent limits',
    () {
      final policy = HelperContactPolicy();
      for (var i = 0; i < 4; i++) {
        final c = claim(i, host: '11.2.3.${i + 1}');
        expect(policy.canAccept(c, '$i'), isTrue);
        policy.record(c, '$i', 0);
      }
      expect(policy.canAccept(claim(4), 'new'), isFalse);
      final c = claim(0, host: '11.2.3.1');
      expect(policy.confirm(c.id, '11.2.3.2', c.peer.port), isFalse);
      expect(policy.confirm(c.id, c.peer.host, c.peer.port + 1), isFalse);
      expect(policy.confirm(c.id, c.peer.host, c.peer.port), isTrue);
      expect(policy.canAccept(claim(4, host: '11.2.3.99'), 'new'), isFalse);
      expect(policy.canAccept(claim(4), 'new'), isTrue);
    },
  );

  test('lease replay cannot keep dead claims alive or inherit proof for a new address', () {
    final policy = HelperContactPolicy();
    final original = claim(0);
    policy.record(original, 'first', 0);
    expect(policy.canAccept(original, 'second'), isFalse);
    policy.record(claim(0, at: now + 1000), 'second', 59000);
    expect(policy.expirePending(60000), [original.id]);
    policy.record(original, 'first', 60000);
    policy.confirm(original.id, original.peer.host, original.peer.port);
    policy.record(claim(0, at: now + 2000), 'first', 61000);
    expect(policy.isVerified(original.id), isTrue);
    policy.record(claim(0, port: 12345, at: now + 3000), 'first', 62000);
    expect(policy.isVerified(original.id), isFalse);
    expect(policy.isDurable(original.id), isFalse);
  });

  test('restored contacts remain available but need a new connection before forwarding', () {
    final policy = HelperContactPolicy();
    final c = claim(0);
    policy.restore(c, 0);
    expect(policy.isDurable(c.id), isTrue);
    expect(policy.isVerified(c.id), isFalse);
    expect(policy.expirePending(60001), isEmpty);
    policy.confirm(c.id, c.peer.host, c.peer.port);
    expect(policy.isVerified(c.id), isTrue);
  });
}
