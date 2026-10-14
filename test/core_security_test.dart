import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/channels.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';

void main() {
  late Identity source;
  late Identity receiver;
  late PeerCard sourceCard;
  late PeerCard receiverCard;

  setUpAll(() {
    source = Identity.generate();
    receiver = Identity.generate();
    sourceCard = PeerCard(name: 'Source', certificatePem: source.certPem);
    receiverCard = PeerCard(name: 'Receiver', certificatePem: receiver.certPem);
  });

  group('identity and certificate pins', () {
    test('persisted identity signs with its pinned TLS certificate', () {
      final restored = Identity.fromJson(source.toJson());
      final bytes = Uint8List.fromList(utf8.encode('signed public news'));
      expect(restored.id, source.id);
      expect(restored.certPem, source.certPem);
      expect(
        Identity.verify(restored.certPem, bytes, restored.sign(bytes)),
        isTrue,
      );
      expect(
        Identity.verify(receiver.certPem, bytes, restored.sign(bytes)),
        isFalse,
      );
      expect(
        Identity.verify(
          restored.certPem,
          Uint8List.fromList([1]),
          restored.sign(bytes),
        ),
        isFalse,
      );
      expect(Identity.verify(restored.certPem, bytes, 'invalid'), isFalse);
    });

    test('fingerprint depends on DER rather than PEM line endings', () {
      final crlf = source.certPem
          .replaceAll('\r\n', '\n')
          .replaceAll('\n', '\r\n');
      expect(Identity.certificateId('\n$crlf\n'), source.id);
      expect(
        Identity.certificateDer(crlf),
        Identity.certificateDer(source.certPem),
      );
      expect(source.id, isNot(receiver.id));
    });

    test(
      'rejects a mismatched key, stored fingerprint, or certificate bundle',
      () {
        expect(
          () => Identity.fromJson({
            ...source.toJson(),
            'keyPem': receiver.keyPem,
          }),
          throwsFormatException,
        );
        expect(
          () => Identity.fromJson({...source.toJson(), 'id': receiver.id}),
          throwsFormatException,
        );
        expect(
          () => Identity.fromJson({...source.toJson(), 'version': 1.0}),
          throwsFormatException,
        );
        expect(
          () => Identity.publicKeyFromCertificate(
            '${source.certPem}\n${receiver.certPem}',
          ),
          throwsFormatException,
        );
        expect(
          () => Identity.publicKeyFromCertificate('bad certificate'),
          throwsFormatException,
        );
      },
    );
  });

  group('pairing cards', () {
    test(
      'trust-only and numeric IPv4/IPv6 cards round-trip without a private key',
      () {
        final parsed = PeerCard.fromText(sourceCard.toText());
        expect(parsed.id, source.id);
        expect(parsed.host, isEmpty);
        expect(parsed.port, defaultPeerPort);
        expect(parsed.toJson().containsKey('keyPem'), isFalse);
        for (final host in [
          '127.0.0.1',
          '192.168.1.21',
          '::1',
          'fd12:3456::7',
        ]) {
          final card = PeerCard(
            name: 'Test',
            host: host,
            certificatePem: source.certPem,
          );
          expect(PeerCard.fromJson(card.toJson()).host, card.host);
        }
      },
    );

    test(
      'rejects DNS, invalid or multicast addresses, bad ports, and spoofed IDs',
      () {
        for (final host in [
          'example.com',
          'https://192.168.1.1',
          '192.168.1.1:1234',
          '0.0.0.0',
          '::',
          '224.0.0.1',
          'ff02::1',
          '255.255.255.255',
        ]) {
          expect(
            () => PeerCard(
              name: 'Test',
              host: host,
              certificatePem: source.certPem,
            ),
            throwsFormatException,
            reason: host,
          );
        }
        for (final port in [0, -1, 65536]) {
          expect(
            () => PeerCard(
              name: 'Test',
              port: port,
              certificatePem: source.certPem,
            ),
            throwsFormatException,
          );
        }
        expect(
          () => PeerCard.fromJson({...sourceCard.toJson(), 'id': receiver.id}),
          throwsFormatException,
        );
        for (final name in ['', ' ', 'a' * 81, 'Device\nInjected']) {
          expect(
            () => PeerCard(name: name, certificatePem: source.certPem),
            throwsFormatException,
          );
        }
      },
    );

    test('rejects malformed and oversized pairing tokens', () {
      for (final token in [
        '',
        'farvahartrends:pair:v1:!',
        'other:${sourceCard.toText()}',
        'x' * 17000,
      ]) {
        expect(() => PeerCard.fromText(token), throwsFormatException);
      }
    });
  });

  group('signed bulletins', () {
    late SignedBulletin bulletin;

    setUp(() {
      bulletin = SignedBulletin.create(
        source,
        runId: 'pilot-1',
        text: 'خبر عمومی',
        sequence: 1,
      );
    });

    test(
      'trusted source or self verifies; unknown and misbound identities fail',
      () {
        final parsed = SignedBulletin.fromJson(bulletin.toJson());
        expect(parsed.verifyAgainst({source.id: sourceCard}, receiver), isTrue);
        expect(parsed.verifyAgainst({}, source), isTrue);
        expect(parsed.verifyAgainst({}, receiver), isFalse);
        expect(
          parsed.verifyAgainst({source.id: receiverCard}, receiver),
          isFalse,
        );
        expect(parsed.text, bulletin.text);
        expect(parsed.sequence, 1);
        expect(parsed.runId, 'pilot-1');
      },
    );

    test('payload alteration fails either its hash or its signature', () {
      final alteredBody = {..._body(bulletin.toJson()), 'text': 'Forged news'};
      final alteredBytes = Uint8List.fromList(
        utf8.encode(jsonEncode(alteredBody)),
      );
      expect(
        () => SignedBulletin.fromJson({
          ...bulletin.toJson(),
          'payloadBase64': base64Encode(alteredBytes),
        }),
        throwsFormatException,
      );
      final rehashed = SignedBulletin.fromJson({
        ...bulletin.toJson(),
        'payloadBase64': base64Encode(alteredBytes),
        'id': sha256.convert(alteredBytes).toString(),
      });
      expect(
        rehashed.verifyAgainst({source.id: sourceCard}, receiver),
        isFalse,
      );

      final signatureBytes = base64Decode(bulletin.signature);
      signatureBytes[0] ^= 1;
      final changedSignature = SignedBulletin.fromJson({
        ...bulletin.toJson(),
        'signature': base64Encode(signatureBytes),
      });
      expect(
        changedSignature.verifyAgainst({source.id: sourceCard}, receiver),
        isFalse,
      );
    });

    test(
      'replay keeps its ID; a fresh publication has a distinct random nonce',
      () {
        final replay = SignedBulletin.fromJson(bulletin.toJson());
        final fresh = SignedBulletin.create(
          source,
          runId: 'pilot-1',
          text: bulletin.text,
          sequence: 1,
        );
        expect(replay.id, bulletin.id);
        expect(replay.nonce, bulletin.nonce);
        expect(fresh.id, isNot(bulletin.id));
        expect(fresh.nonce, isNot(bulletin.nonce));
      },
    );

    test('bounds use UTF-8 bytes and sequence/run IDs require valid types', () {
      expect(
        SignedBulletin.create(
          source,
          runId: 'run',
          text: 'ا' * 512,
          sequence: 1,
        ).text,
        'ا' * 512,
      );
      for (final text in [' ', 'x' * 1025, 'ا' * 513]) {
        expect(
          () => SignedBulletin.create(
            source,
            runId: 'run',
            text: text,
            sequence: 1,
          ),
          throwsFormatException,
        );
      }
      for (final run in ['', ' ', 'x' * 65, 'run\n1']) {
        expect(
          () => SignedBulletin.create(
            source,
            runId: run,
            text: 'news',
            sequence: 1,
          ),
          throwsFormatException,
        );
      }
      for (final seq in [0, -1, 9007199254740992]) {
        expect(
          () => SignedBulletin.create(
            source,
            runId: 'run',
            text: 'news',
            sequence: seq,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects signed objects with wrong schema, type, or noncanonical encoding', () {
      final original = _body(bulletin.toJson());
      for (final updates in <Map<String, dynamic>>[
        {'version': 2},
        {'version': 1.0},
        {'kind': 'receipt'},
        {'seq': 1.0},
        {'sourceId': 'not-a-fingerprint'},
        {'createdAtMs': -1},
        {'nonce': 'invalid'},
        {'unexpected': true},
      ]) {
        expect(
          () => SignedBulletin.fromJson(
            _signed(source, {...original, ...updates}),
          ),
          throwsFormatException,
          reason: updates.toString(),
        );
      }
      final missing = {...original}..remove('text');
      expect(
        () => SignedBulletin.fromJson(_signed(source, missing)),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson({...bulletin.toJson(), 'extra': true}),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson({
          ...bulletin.toJson(),
          'signature': 'A' * 344,
        }),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson({
          ...bulletin.toJson(),
          'payloadBase64': '${bulletin.payloadBase64}\n',
        }),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson({
          ...bulletin.toJson(),
          'payloadBase64': 'A' * 17000,
        }),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson(_signed(source, [])),
        throwsFormatException,
      );
      expect(
        () => SignedBulletin.fromJson(
          _signedBytes(source, Uint8List.fromList([0xff])),
        ),
        throwsFormatException,
      );
    });
  });

  group('signed receipts', () {
    late SignedBulletin bulletin;
    late SignedReceipt receipt;

    setUp(() {
      bulletin = SignedBulletin.create(
        source,
        runId: 'pilot-2',
        text: 'news',
        sequence: 2,
      );
      receipt = SignedReceipt.create(
        receiver,
        bulletinId: bulletin.id,
        sourceId: source.id,
        runId: bulletin.runId,
        locked: true,
        elapsedRealtimeMs: 12345,
      );
    });

    test('receiver signs the exact bulletin binding and retransmission keeps its ID', () {
      final parsed = SignedReceipt.fromJson(receipt.toJson());
      expect(parsed.verifyAgainst({receiver.id: receiverCard}, source), isTrue);
      expect(parsed.verifyAgainst({}, receiver), isTrue);
      expect(parsed.verifyAgainst({source.id: sourceCard}, source), isFalse);
      expect(parsed.verifyAgainst({receiver.id: sourceCard}, source), isFalse);
      expect(parsed.id, receipt.id);
      expect(parsed.bulletinId, bulletin.id);
      expect(parsed.sourceId, source.id);
      expect(parsed.receiverId, receiver.id);
      expect(parsed.runId, bulletin.runId);
      expect(parsed.locked, isTrue);
      expect(parsed.lockStateKnown, isTrue);
      expect(parsed.elapsedRealtimeMs, 12345);
    });

    test('elapsed time can be absent; lock state and elapsed time are strictly typed', () {
      final noElapsed = SignedReceipt.create(
        receiver,
        bulletinId: bulletin.id,
        sourceId: source.id,
        runId: bulletin.runId,
        locked: false,
      );
      expect(
        SignedReceipt.fromJson(noElapsed.toJson()).elapsedRealtimeMs,
        isNull,
      );
      final original = _body(receipt.toJson());
      for (final updates in <Map<String, dynamic>>[
        {'kind': 'bulletin'},
        {'locked': 1},
        {'lockStateKnown': 1},
        {'elapsedRealtimeMs': -1},
        {'elapsedRealtimeMs': 1.5},
        {'verifiedAtWallMs': -1},
        {'receiverId': 'x'},
      ]) {
        expect(
          () => SignedReceipt.fromJson(
            _signed(receiver, {...original, ...updates}),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => SignedBulletin.fromJson(receipt.toJson()),
        throwsFormatException,
      );
      expect(
        () => SignedReceipt.fromJson(bulletin.toJson()),
        throwsFormatException,
      );
    });

    test('unknown lock state remains distinct from verified unlocked', () {
      final unknown = SignedReceipt.create(
        receiver,
        bulletinId: bulletin.id,
        sourceId: source.id,
        runId: bulletin.runId,
        locked: false,
        lockStateKnown: false,
      );
      final parsed = SignedReceipt.fromJson(unknown.toJson());
      expect(parsed.lockStateKnown, isFalse);
      expect(parsed.locked, isFalse);
      expect(parsed.verifyAgainst({receiver.id: receiverCard}, source), isTrue);
    });

    test('changing receipt evidence invalidates its receiver signature', () {
      final body = {..._body(receipt.toJson()), 'locked': false};
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
      final altered = SignedReceipt.fromJson({
        ...receipt.toJson(),
        'id': sha256.convert(bytes).toString(),
        'payloadBase64': base64Encode(bytes),
      });
      expect(
        altered.verifyAgainst({receiver.id: receiverCard}, source),
        isFalse,
      );
    });
  });

  test(
    'signed wall timestamps are representable while sequences stay wider',
    () {
      final bulletin = SignedBulletin.create(
        source,
        runId: 'time-bounds',
        text: 'Harmless timestamp test',
        sequence: 9007199254740991,
      );
      final receipt = SignedReceipt.create(
        receiver,
        bulletinId: bulletin.id,
        sourceId: source.id,
        runId: bulletin.runId,
        locked: false,
      );
      final channel = SignedChannel.create(source, name: 'Time bounds');
      final valid = SignedBulletin.fromJson(
        _signed(source, {
          ..._body(bulletin.toJson()),
          'createdAtMs': maxSignedWallTimeMs,
        }),
      );
      expect(valid.sequence, 9007199254740991);
      expect(valid.verifyAgainst({}, source), isTrue);
      expect(
        DateTime.fromMillisecondsSinceEpoch(valid.createdAtMs)
            .millisecondsSinceEpoch,
        maxSignedWallTimeMs,
      );
      for (final invalid in [maxSignedWallTimeMs + 1, 9007199254740991]) {
        expect(
          () => DateTime.fromMillisecondsSinceEpoch(invalid),
          throwsArgumentError,
        );
        expect(
          () => SignedBulletin.fromJson(
            _signed(source, {
              ..._body(bulletin.toJson()),
              'createdAtMs': invalid,
            }),
          ),
          throwsFormatException,
        );
        expect(
          () => SignedReceipt.fromJson(
            _signed(receiver, {
              ..._body(receipt.toJson()),
              'verifiedAtWallMs': invalid,
            }),
          ),
          throwsFormatException,
        );
        final bytes = Uint8List.fromList(
          utf8.encode(
            jsonEncode({..._body(channel.toJson()), 'createdAtMs': invalid}),
          ),
        );
        expect(
          () => SignedChannel.fromJson({
            'id': sha256.convert(bytes).toString(),
            'payloadBase64': base64Encode(bytes),
            'signature': source.sign(
              Uint8List.fromList([
                ...utf8.encode('$channelSigningDomain\n'),
                ...bytes,
              ]),
            ),
            'ownerCertificatePem': source.certPem,
          }),
          throwsFormatException,
        );
      }
    },
  );
}

Map<String, dynamic> _body(Map<String, dynamic> envelope) =>
    jsonDecode(utf8.decode(base64Decode(envelope['payloadBase64'] as String)))
        as Map<String, dynamic>;

Map<String, dynamic> _signed(Identity identity, Object body) =>
    _signedBytes(identity, Uint8List.fromList(utf8.encode(jsonEncode(body))));

Map<String, dynamic> _signedBytes(Identity identity, Uint8List bytes) => {
  'id': sha256.convert(bytes).toString(),
  'payloadBase64': base64Encode(bytes),
  'signature': identity.sign(bytes),
};
