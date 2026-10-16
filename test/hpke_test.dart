import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/hpke.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  // RFC 9180 Appendix A.2.1: DHKEM(X25519)/HKDF-SHA256/ChaCha20Poly1305.
  final skR = hex(
    '8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb',
  );
  final pkR = hex(
    '4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a',
  );
  final skE = hex(
    'f4ec9b33b792c372c1d2c2063507b684ef925b8c75a42dbcbf57d63ccd381600',
  );
  final enc = hex(
    '1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a',
  );
  final info = hex('4f6465206f6e2061204772656369616e2055726e');
  final pt = hex('4265617574792069732074727574682c20747275746820626561757479');
  final aad = hex('436f756e742d30');
  final ct = hex(
    '1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28',
  );
  test('RFC 9180 A.2.1 public keys, ciphertext and decryption', () async {
    expect(await Hpke.publicKey(skR), pkR);
    final sealed = await Hpke.seal(
      recipient: pkR,
      plaintext: pt,
      info: info,
      aad: aad,
      ephemeralPrivateKey: skE,
    );
    expect(sealed, [...enc, ...ct]);
    expect(
      await Hpke.open(privateKey: skR, sealed: sealed, info: info, aad: aad),
      pt,
    );
  });
  test(
    'wrong key, altered content, wrong domain and AAD fail closed',
    () async {
      final sealed = Uint8List.fromList([...enc, ...ct]);
      for (final offset in [0, 32, sealed.length - 1]) {
        final bad = Uint8List.fromList(sealed)..[offset] ^= 1;
        await expectLater(
          Hpke.open(privateKey: skR, sealed: bad, info: info, aad: aad),
          throwsA(isA<FormatException>()),
        );
      }
      await expectLater(
        Hpke.open(privateKey: skE, sealed: sealed, info: info, aad: aad),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        Hpke.open(
          privateKey: skR,
          sealed: sealed,
          info: utf8.encode('wrong'),
          aad: aad,
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        Hpke.open(privateKey: skR, sealed: sealed, info: info),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        Hpke.seal(recipient: Uint8List(32), plaintext: pt, info: info),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        Hpke.open(privateKey: skR, sealed: Uint8List(47), info: info),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test('single-shot encryptions have independent ephemeral keys', () async {
    final a = await Hpke.seal(recipient: pkR, plaintext: pt, info: info);
    final b = await Hpke.seal(recipient: pkR, plaintext: pt, info: info);
    expect(a, isNot(orderedEquals(b)));
    expect(await Hpke.open(privateKey: skR, sealed: b, info: info), pt);
  });
}
