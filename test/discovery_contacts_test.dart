import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/discovery_contacts.dart';
import 'package:farvahar_trends/core/identity.dart';

void main() {
  late Identity identity;
  setUpAll(() => identity = Identity.generate());

  test(
    'contact authenticates its endpoint and cannot outlive its signed lease',
    () {
      final contact = DiscoveryContact.create(identity, '11.1.2.3', 49737);
      expect(DiscoveryContact.parse(contact.value).id, identity.id);
      expect(
        () => DiscoveryContact.parse({...contact.value, 'port': 1234}),
        throwsFormatException,
      );
      expect(
        () => DiscoveryContact.parse({
          ...contact.value,
          'kind': 'farvahartrends/helper-contact/v1',
        }),
        throwsFormatException,
      );
      expect(
        () => DiscoveryContact.parse(contact.value, nowMs: contact.expiresAtMs),
        throwsFormatException,
      );
      expect(
        DiscoveryContact.parse(
          contact.value,
          nowMs: contact.expiresAtMs,
          forReconnect: true,
        ).host,
        '11.1.2.3',
      );
      expect(
        () => DiscoveryContact.parse(
          contact.value,
          nowMs: contact.expiresAtMs + DiscoveryContact.reconnectMs,
          forReconnect: true,
        ),
        throwsFormatException,
      );
      for (final host in [
        '10.1.2.3',
        '127.0.0.1',
        '100.64.0.1',
        '203.0.113.1',
        '2606:4700:4700::1111',
      ]) {
        expect(
          () => DiscoveryContact.create(identity, host, 49737),
          throwsFormatException,
        );
      }
    },
  );

  test('unverified hints cannot fill storage from one identity and survive restart', () async {
    final root = Directory(
      '${Directory.current.path}/artifacts/discovery-contact-tests',
    );
    await root.create(recursive: true);
    final directory = await root.createTemp('case-');
    addTearDown(() => directory.delete(recursive: true));
    final contacts = DiscoveryContacts(directory);
    final introducer = 'a' * 64;
    for (var i = 1; i <= 20; i++) {
      contacts.add(
        DiscoveryContact.create(identity, '11.1.2.$i', 49737),
        introducer,
      );
    }
    expect(contacts.contacts.length, 2);
    await contacts.save();
    final restored = DiscoveryContacts(directory);
    await restored.load();
    expect(restored.fresh.length, 2);
    expect(
      await File('${directory.path}/discovery-contacts.json').readAsString(),
      isNot(contains('PRIVATE KEY')),
    );
    restored.remove(introducer);
    expect(restored.contacts, isEmpty);
  });
}
