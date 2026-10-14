import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';

/// One cryptographic identity. Production uses independent instances for
/// publisher signatures and connection authentication. A connection identity
/// does not confer publisher authority or reveal which channels a peer owns.
class Identity {
  Identity._(this.certPem, this.keyPem, this._privateKey)
    : id = certificateId(certPem);

  final String certPem;
  final String keyPem;
  final String id;
  final RSAPrivateKey _privateKey;

  /// CPU-intensive. Run in an isolate when called from a UI.
  static Identity generate() {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;
    final subjectId = sha256
        .convert(utf8.encode(CryptoUtils.encodeRSAPublicKeyToPem(publicKey)))
        .toString();
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': subjectId, 'O': 'PersianTrend'},
      privateKey,
      publicKey,
      signingAlgorithm: 'SHA-256',
    );
    final random = Random.secure();
    var serial = BigInt.one;
    for (var i = 0; i < 16; i++) {
      serial = (serial << 8) | BigInt.from(random.nextInt(256));
    }
    final certificate = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3651,
      serialNumber: serial.toString(),
      notBefore: DateTime.utc(2000),
      cA: false,
      extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH, ExtendedKeyUsage.CLIENT_AUTH],
    );
    return Identity._(
      _withClockIndependentValidity(certificate, privateKey),
      CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(privateKey),
      privateKey,
    );
  }

  // basic_utils 5.8.2 only emits UTCTime (two-digit years). X.509 requires
  // GeneralizedTime after 2049. Rebuild and re-sign rather than encoding 9999
  // as 1999. Validity is not channel revocation: authority stays fingerprint
  // pinned, with signed policies controlling publisher/editor permissions.
  static String _withClockIndependentValidity(String pem, RSAPrivateKey key) {
    final certificate =
        ASN1Parser(certificateDer(pem)).nextObject() as ASN1Sequence;
    final original = certificate.elements!.first as ASN1Sequence;
    final fields = [...original.elements!];
    fields[4] = ASN1Sequence(
      elements: [
        ASN1UtcTime(DateTime.utc(2000)),
        ASN1GeneralizedTime(DateTime.utc(9999, 12, 31, 23, 59, 59)),
      ],
    );
    final tbs = ASN1Sequence(elements: fields);
    final signed = ASN1Sequence(
      elements: [
        tbs,
        certificate.elements![1],
        ASN1BitString(
          stringValues: CryptoUtils.rsaSign(
            key,
            tbs.encode(),
            algorithmName: 'SHA-256/RSA',
          ),
        ),
      ],
    );
    final encoded = base64Encode(signed.encode());
    final lines = [
      for (var i = 0; i < encoded.length; i += 64)
        encoded.substring(i, min(i + 64, encoded.length)),
    ];
    return '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----';
  }

  factory Identity.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] is! int ||
          json['version'] != 1 ||
          json['certPem'] is! String ||
          json['keyPem'] is! String) {
        throw const FormatException('Invalid stored identity.');
      }
      final certificate = json['certPem'] as String;
      final keyPem = json['keyPem'] as String;
      if (keyPem.length > 8192) {
        throw const FormatException('Private key is too large.');
      }
      final publicKey = publicKeyFromCertificate(certificate);
      final privateKey = CryptoUtils.rsaPrivateKeyFromPemPkcs1(keyPem);
      if (privateKey.modulus != publicKey.modulus ||
          privateKey.modulus?.bitLength != 2048) {
        throw const FormatException('Certificate and private key disagree.');
      }
      final identity = Identity._(certificate, keyPem, privateKey);
      if (json['id'] != identity.id) {
        throw const FormatException('Stored identity fingerprint disagrees.');
      }
      final challenge = Uint8List.fromList(
        utf8.encode('PersianTrend identity v1'),
      );
      if (!verify(certificate, challenge, identity.sign(challenge))) {
        throw const FormatException('Private key cannot sign for certificate.');
      }
      return identity;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid stored identity.');
    }
  }

  /// Contains the private key. Store through the application's protected store.
  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'certPem': certPem,
    'keyPem': keyPem,
  };

  String sign(Uint8List bytes) => base64Encode(
    CryptoUtils.rsaSign(_privateKey, bytes, algorithmName: 'SHA-256/RSA'),
  );

  static bool verify(String certPem, Uint8List bytes, String signature) {
    try {
      if (signature.length != 344) return false;
      final decoded = base64Decode(signature);
      if (decoded.length != 256 || base64Encode(decoded) != signature) {
        return false;
      }
      return CryptoUtils.rsaVerify(
        publicKeyFromCertificate(certPem),
        bytes,
        decoded,
        algorithm: 'SHA-256/RSA',
      );
    } catch (_) {
      return false;
    }
  }

  /// Hash of the exact DER certificate, not of PEM whitespace or a display name.
  static String certificateId(String certPem) =>
      sha256.convert(certificateDer(certPem)).toString();

  static Uint8List certificateDer(String certPem) {
    if (certPem.length > 8192) {
      throw const FormatException('Certificate is too large.');
    }
    final match = RegExp(
      r'^\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+)\s*-----END CERTIFICATE-----\s*$',
    ).firstMatch(certPem);
    if (match == null) {
      throw const FormatException('Expected exactly one PEM certificate.');
    }
    try {
      final encoded = match.group(1)!.replaceAll(RegExp(r'\s'), '');
      final der = base64Decode(encoded);
      if (der.isEmpty || der.length > 4096 || base64Encode(der) != encoded) {
        throw const FormatException('Invalid certificate encoding.');
      }
      return der;
    } on FormatException {
      throw const FormatException('Invalid certificate encoding.');
    }
  }

  /// Validates the v1 RSA certificate profile without any network/CA lookup.
  static RSAPublicKey publicKeyFromCertificate(String certPem) {
    certificateDer(certPem);
    try {
      final certificate = X509Utils.x509CertificateFromPem(certPem);
      final info = certificate.tbsCertificate?.subjectPublicKeyInfo;
      if (info?.algorithm != '1.2.840.113549.1.1.1' ||
          info?.exponent != 65537) {
        throw const FormatException('Expected an RSA-2048 pilot certificate.');
      }
      final modulus = X509Utils.getModulusFromRSAX509Pem(certPem);
      if (modulus.bitLength != 2048 || !X509Utils.checkX509Signature(certPem)) {
        throw const FormatException('Invalid self-signed pilot certificate.');
      }
      return RSAPublicKey(modulus, BigInt.from(info!.exponent!));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid pilot certificate.');
    }
  }
}
