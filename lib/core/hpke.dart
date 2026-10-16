import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// RFC 9180 base mode, suite (0x0020, 0x0001, 0x0003).
/// Single-shot contexts only: every seal has a fresh ephemeral key and sequence
/// zero. Callers must authenticate recipient keys and supply replay protection.
class Hpke {
  static final _kem = [...ascii.encode('KEM'), 0, 32];
  static final _suite = [...ascii.encode('HPKE'), 0, 32, 0, 1, 0, 3];
  static final _dh = X25519();
  static final _aead = Chacha20.poly1305Aead();

  static Future<Uint8List> publicKey(List<int> privateKey) async =>
      Uint8List.fromList(
        (await (await _dh.newKeyPairFromSeed(
          privateKey,
        )).extractPublicKey()).bytes,
      );

  static Uint8List _extract(List<int> salt, List<int> ikm) =>
      Uint8List.fromList(
        hashes.Hmac(
          hashes.sha256,
          salt.isEmpty ? Uint8List(32) : salt,
        ).convert(ikm).bytes,
      );

  static Uint8List _expand(List<int> prk, List<int> info, int length) {
    if (length < 0 || length > 255 * 32) throw ArgumentError('HKDF length');
    final result = BytesBuilder(copy: false);
    var previous = <int>[];
    for (var i = 1; result.length < length; i++) {
      previous = hashes.Hmac(
        hashes.sha256,
        prk,
      ).convert([...previous, ...info, i]).bytes;
      result.add(previous);
    }
    return Uint8List.sublistView(result.takeBytes(), 0, length);
  }

  static Uint8List _labeledExtract(
    List<int> suite,
    List<int> salt,
    String label,
    List<int> ikm,
  ) => _extract(salt, [
    ...ascii.encode('HPKE-v1'),
    ...suite,
    ...ascii.encode(label),
    ...ikm,
  ]);

  static Uint8List _labeledExpand(
    List<int> suite,
    List<int> prk,
    String label,
    List<int> info,
    int length,
  ) => _expand(prk, [
    length >> 8,
    length & 255,
    ...ascii.encode('HPKE-v1'),
    ...suite,
    ...ascii.encode(label),
    ...info,
  ], length);

  static Future<Uint8List> _secret(
    List<int> privateKey,
    List<int> remote,
    List<int> enc,
    List<int> recipient,
  ) async {
    if (privateKey.length != 32 || remote.length != 32) {
      throw const FormatException('Invalid HPKE key size');
    }
    final pair = await _dh.newKeyPairFromSeed(privateKey);
    final secret = await (await _dh.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(remote, type: KeyPairType.x25519),
    )).extractBytes();
    var nonzero = 0;
    for (final byte in secret) {
      nonzero |= byte;
    }
    if (nonzero == 0) {
      throw const FormatException('Invalid X25519 shared secret');
    }
    final prk = _labeledExtract(_kem, const [], 'eae_prk', secret);
    return _labeledExpand(_kem, prk, 'shared_secret', [
      ...enc,
      ...recipient,
    ], 32);
  }

  static (Uint8List, Uint8List) _schedule(List<int> shared, List<int> info) {
    final context = [
      0,
      ..._labeledExtract(_suite, const [], 'psk_id_hash', const []),
      ..._labeledExtract(_suite, const [], 'info_hash', info),
    ];
    final secret = _labeledExtract(_suite, shared, 'secret', const []);
    return (
      _labeledExpand(_suite, secret, 'key', context, 32),
      _labeledExpand(_suite, secret, 'base_nonce', context, 12),
    );
  }

  /// The deterministic ephemeral key parameter exists only for RFC vectors.
  static Future<Uint8List> seal({
    required List<int> recipient,
    required List<int> plaintext,
    required List<int> info,
    List<int> aad = const [],
    List<int>? ephemeralPrivateKey,
  }) async {
    final pair = ephemeralPrivateKey == null
        ? await _dh.newKeyPair()
        : await _dh.newKeyPairFromSeed(ephemeralPrivateKey);
    final seed = await pair.extractPrivateKeyBytes();
    final enc = (await pair.extractPublicKey()).bytes;
    final shared = await _secret(seed, recipient, enc, recipient);
    final (key, nonce) = _schedule(shared, info);
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    return Uint8List.fromList([...enc, ...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> open({
    required List<int> privateKey,
    required List<int> sealed,
    required List<int> info,
    List<int> aad = const [],
  }) async {
    if (sealed.length < 48) throw const FormatException('Truncated HPKE box');
    final recipient = await publicKey(privateKey);
    final enc = sealed.sublist(0, 32);
    final shared = await _secret(privateKey, enc, enc, recipient);
    final (key, nonce) = _schedule(shared, info);
    try {
      return Uint8List.fromList(
        await _aead.decrypt(
          SecretBox(
            sealed.sublist(32, sealed.length - 16),
            nonce: nonce,
            mac: Mac(sealed.sublist(sealed.length - 16)),
          ),
          secretKey: SecretKey(key),
          aad: aad,
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('HPKE authentication failed');
    }
  }
}
