import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/bootstrap_config.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';

void main() {
  late Identity a, b;
  setUpAll(() {
    a = Identity.generate();
    b = Identity.generate();
  });

  Map<String, dynamic> card(
    Identity identity, {
    String host = '11.0.113.9',
    int port = 7411,
    bool enrollment = false,
    String name = 'Seed',
  }) => PeerCard(
    name: name,
    host: host,
    port: port,
    certificatePem: identity.certPem,
    tcpEnrollment: enrollment,
  ).toJson();

  test('version 1 documents still parse with peers only', () {
    final config = parseBootstrapConfig(
      jsonEncode({
        'version': 1,
        'peers': [card(a), card(b, host: '11.51.100.2')],
      }),
    );
    expect(config.peers.map((p) => p.id), [a.id, b.id]);
    expect(config.dhtBootstrap, isEmpty);
  });

  test('version 1 documents reject extra keys such as dhtBootstrap', () {
    expect(
      () => parseBootstrapConfig(
        jsonEncode({
          'version': 1,
          'peers': [],
          'dhtBootstrap': ['11.0.113.1:49737'],
        }),
      ),
      throwsFormatException,
    );
  });

  test('version 2 documents carry normalized DHT bootstrap entries', () {
    final config = parseBootstrapConfig(
      jsonEncode({
        'version': 2,
        'peers': [card(a)],
        'dhtBootstrap': [
          '11.0.113.1:49737',
          '11.0.114.1:49737',
          '11.0.115.2:443',
        ],
      }),
    );
    expect(config.peers.single.id, a.id);
    expect(config.dhtBootstrap, [
      '11.0.113.1:49737',
      '11.0.114.1:49737',
      '11.0.115.2:443',
    ]);
    expect(config.toJson()['version'], 2);
    expect(
      parseBootstrapConfig(jsonEncode(config.toJson())).dhtBootstrap,
      config.dhtBootstrap,
    );
  });

  test('version 2 dhtBootstrap is optional and unknown keys are rejected', () {
    expect(
      parseBootstrapConfig(jsonEncode({'version': 2, 'peers': []})).isEmpty,
      isTrue,
    );
    expect(
      () => parseBootstrapConfig(
        jsonEncode({'version': 2, 'peers': [], 'relay': 'x'}),
      ),
      throwsFormatException,
    );
    expect(
      () => parseBootstrapConfig(jsonEncode({'version': 3, 'peers': []})),
      throwsFormatException,
    );
  });

  for (final bad in [
    '203.0.113.1:49737',
    '[2606:4700:4700::1111]:49737',
    '[2001:db8::1]:49737',
    '10.1.2.3:49737',
    '100.64.0.1:49737',
    'seed.example.org:49737', // DNS names cannot be redirected by a resolver.
    'localhost:49737',
    '127.0.0.1:49737',
    '[::1]:49737',
    '0.0.0.0:49737',
    '[::]:49737',
    '224.0.0.1:49737',
    '[ff02::1]:49737',
    '169.254.1.1:49737',
    '255.255.255.255:49737',
    '11.0.113.1:0',
    '11.0.113.1:65536',
    '11.0.113.1:0443',
    '11.0.113.1',
    '11.0.113.1:',
    ':49737',
    '2001:db8::1:49737', // IPv6 needs brackets.
    '[11.0.113.1]:49737',
    '[fe80::1%wlan0]:49737',
    ' 11.0.113.1:49737',
    '11.0.113.1:49737 ',
  ]) {
    test('rejects DHT bootstrap entry "$bad"', () {
      expect(
        () => parseBootstrapConfig(
          jsonEncode({
            'version': 2,
            'peers': [],
            'dhtBootstrap': [bad],
          }),
        ),
        throwsFormatException,
      );
    });
  }

  test('rejects duplicate, non-string and too many DHT entries', () {
    expect(
      () => parseDhtBootstrapEntries(['11.0.113.1:1', '11.0.113.1:1']),
      throwsFormatException,
    );
    expect(
      () => parseDhtBootstrapEntries(['[2001:db8::1]:1', '[2001:0db8::1]:1']),
      throwsFormatException,
    );
    expect(() => parseDhtBootstrapEntries([42]), throwsFormatException);
    expect(
      () => parseDhtBootstrapEntries([
        for (var i = 1; i <= maxDhtBootstrapEntries + 1; i++)
          '11.0.113.$i:49737',
      ]),
      throwsFormatException,
    );
    expect(
      parseDhtBootstrapEntries([
        for (var i = 1; i <= maxDhtBootstrapEntries; i++) '11.0.113.$i:49737',
      ]).length,
      maxDhtBootstrapEntries,
    );
  });

  test('the 128 KiB cap still applies', () {
    final padded = jsonEncode({
      'version': 2,
      'peers': [],
      'dhtBootstrap': [],
      'pad': 'x' * maxBootstrapConfigBytes,
    });
    expect(() => parseBootstrapConfig(padded), throwsFormatException);
    expect(() => parseBootstrapInput(padded), throwsFormatException);
  });

  test('parseBootstrapInput accepts a token, a card object or a document', () {
    final token = PeerCard(name: 'Phone', certificatePem: a.certPem).toText();
    expect(parseBootstrapInput(token).peers.single.id, a.id);
    expect(parseBootstrapInput(token).peers.single.host, '');
    expect(parseBootstrapInput(jsonEncode(card(b))).peers.single.id, b.id);
    final document = parseBootstrapInput(
      jsonEncode({
        'version': 2,
        'peers': [card(a)],
        'dhtBootstrap': ['11.0.113.1:49737'],
      }),
    );
    expect(document.peers.single.id, a.id);
    expect(document.dhtBootstrap, ['11.0.113.1:49737']);
    expect(() => parseBootstrapInput(''), throwsFormatException);
    expect(() => parseBootstrapInput('[1,2]'), throwsFormatException);
    expect(() => parseBootstrapInput('not a token'), throwsFormatException);
    expect(
      () => parseBootstrapInput(jsonEncode({...card(b), 'privateKey': 'x'})),
      throwsFormatException,
    );
  });

  test('combineBootstrapConfigs prefers imported entries and keeps caps', () {
    final imported = BootstrapConfig(
      peers: [
        PeerCard(
          name: 'Imported',
          host: '11.0.113.9',
          port: 7411,
          certificatePem: a.certPem,
          tcpEnrollment: true,
        ),
      ],
      dhtBootstrap: const ['11.0.113.1:1'],
    );
    final asset = BootstrapConfig(
      peers: [
        PeerCard(
          name: 'Asset',
          host: '11.0.113.9',
          port: 7411,
          certificatePem: a.certPem,
        ),
        PeerCard(
          name: 'Conflict',
          host: '11.0.113.9',
          port: 7411,
          certificatePem: b.certPem,
        ),
        PeerCard(name: 'Other', host: '11.51.100.7', certificatePem: b.certPem),
      ],
      dhtBootstrap: const ['11.0.113.1:1', '11.0.113.2:1'],
    );
    final merged = combineBootstrapConfigs(imported, asset);
    expect(merged.peers.map((p) => p.name), ['Imported', 'Other']);
    expect(merged.peers.first.tcpEnrollment, isTrue);
    expect(merged.dhtBootstrap, ['11.0.113.1:1', '11.0.113.2:1']);

    final many = BootstrapConfig(
      peers: [
        for (var i = 1; i <= 20; i++)
          PeerCard(
            name: 'Peer $i',
            host: '11.0.113.$i',
            certificatePem: (i.isEven ? a : b).certPem,
          ),
      ],
    );
    expect(
      combineBootstrapConfigs(BootstrapConfig.empty, many).peers.length,
      maxBootstrapPeers,
    );
  });
}
