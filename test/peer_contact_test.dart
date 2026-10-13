import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/peer_contact.dart';
import 'package:persian_trend/core/peer_contact_store.dart';

void main() {
  late Identity connection;
  setUpAll(() => connection = Identity.generate());
  PeerContact contact({int? now, int lifetime = 60000}) => PeerContact.create(
    connection,
    host: '8.8.8.8',
    port: 45871,
    lifetimeMs: lifetime,
    nowMs: now,
  );

  test('A contact binds endpoint and expiry to its connection certificate', () {
    final original = contact();
    final parsed = PeerContact.parse(original.toJson());
    expect(parsed.id, connection.id);
    expect(parsed.peer.tcpEnrollment, isTrue);
    for (final mutation in <String, dynamic>{
      'host': '1.1.1.1',
      'port': 45872,
      'expiresAtMs': original.expiresAtMs + 1,
      'nonce': 'AAAAAAAAAAAAAAAAAAAAAA==',
      'certificatePem': Identity.generate().certPem,
    }.entries) {
      expect(
        () => PeerContact.parse({
          ...original.toJson(),
          mutation.key: mutation.value,
        }),
        throwsFormatException,
      );
    }
  });

  test('Expiry, future issuance and excessive leases are rejected', () {
    const now = 1800000000000;
    final original = contact(now: now);
    expect(
      () => PeerContact.parse(original.toJson(), nowMs: now + 60000),
      throwsFormatException,
    );
    expect(
      () => PeerContact.parse(original.toJson(), nowMs: now - 31000),
      throwsFormatException,
    );
    for (final lifetime in [0, -1, PeerContact.maxLifetimeMs + 1]) {
      expect(
        () => contact(now: now, lifetime: lifetime),
        throwsFormatException,
      );
    }
    expect(
      () => PeerContact.parse({
        ...original.toJson(),
        'publisherId': connection.id,
      }),
      throwsFormatException,
    );
    expect(
      () => PeerContact.parse({...original.toJson(), 'nonce': 'A' * 8000}),
      throwsFormatException,
    );
  });

  test('Public endpoint filtering excludes local and special-use ranges', () {
    for (final value in [
      '0.0.0.1',
      '10.1.2.3',
      '100.64.0.1',
      '100.127.255.254',
      '127.0.0.1',
      '169.254.0.2',
      '172.16.0.1',
      '172.31.255.254',
      '192.168.0.1',
      '192.0.0.8',
      '192.0.2.1',
      '198.18.0.1',
      '198.19.255.254',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
      '255.255.255.255',
      '::',
      '::1',
      'fc00::1',
      'fe80::1',
      'ff02::1',
      '::ffff:192.168.1.1',
      '2001:db8::1',
      '2002:a01:203::1',
      '3fff::1',
    ]) {
      expect(
        PeerContact.isPublicAddress(InternetAddress(value)),
        isFalse,
        reason: value,
      );
    }
    for (final value in [
      '8.8.8.8',
      '1.1.1.1',
      '100.63.255.254',
      '100.128.0.1',
      '172.15.255.254',
      '172.32.0.1',
      '2606:4700:4700::1111',
      '2001:4860:4860::8888',
    ]) {
      expect(
        PeerContact.isPublicAddress(InternetAddress(value)),
        isTrue,
        reason: value,
      );
    }
    expect(
      () => PeerContact.create(
        connection,
        host: '127.0.0.1',
        port: 45871,
        lifetimeMs: 60000,
      ),
      throwsFormatException,
    );
  });

  test('Expired hints are usable only for private pinned reconnection', () {
    const now = 1800000000000;
    final original = contact(now: now);
    expect(
      () => PeerContact.parse(original.toJson(), nowMs: now + 60001),
      throwsFormatException,
    );
    final cached = PeerContact.readCached(
      original.toJson(),
      nowMs: now + 60001,
    );
    expect(cached.id, connection.id);
    expect(
      () => PeerContact.readCached(
        original.toJson(),
        nowMs: original.expiresAtMs + PeerContact.maxReconnectAgeMs + 1,
      ),
      throwsFormatException,
    );
    expect(
      () => PeerContact.readCached(original.toJson(), nowMs: now - 31000),
      throwsFormatException,
    );
  });

  test(
    'Cache survives restart and tolerates expired, damaged or oversized data',
    () async {
      final parent = Directory('${Directory.current.path}/.tooling/test-tmp');
      await parent.create(recursive: true);
      final scratch = await parent.createTemp('contact-cache-');
      addTearDown(() => scratch.delete(recursive: true));
      final store = PeerContactStore(scratch);
      final original = contact();
      await store.save([original]);
      expect(
        (await PeerContactStore(scratch).load()).single.toJson(),
        original.toJson(),
      );
      await store.save([]);
      expect(await store.load(), isEmpty);
      final file = File('${scratch.path}/helper-contacts.json');
      await file.writeAsString('{partial');
      expect(await store.load(), isEmpty);
      await file.writeAsString('x' * (PeerContactStore.maxBytes + 1));
      expect(await store.load(), isEmpty);
    },
  );
}
