import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:pointycastle/asn1.dart';

void main() {
  test(
    'new certificates cover reset clocks and encode year 9999 correctly',
    () {
      final identity = Identity.generate();
      final cert = X509Utils.x509CertificateFromPem(identity.certPem);
      final validity = cert.tbsCertificate!.validity;
      expect(validity.notBefore.toUtc(), DateTime.utc(2000));
      expect(validity.notAfter.toUtc(), DateTime.utc(9999, 12, 31, 23, 59, 59));
      // A certificate generated today remains valid at a peer's reset date.
      for (final peerClock in [
        DateTime.utc(2001),
        DateTime.utc(2020),
        DateTime.utc(2051),
      ]) {
        expect(validity.notBefore.isAfter(peerClock), false);
        expect(validity.notAfter.isBefore(peerClock), false);
      }
      expect(X509Utils.checkX509Signature(identity.certPem), true);
      final message = Uint8List.fromList([1, 2, 3]);
      expect(
        Identity.verify(identity.certPem, message, identity.sign(message)),
        true,
      );
      expect(Identity.fromJson(identity.toJson()).id, identity.id);
    },
  );
  test(
    'real mTLS accepts a newly generated client at a reset server clock',
    () async {
      final client = Identity.generate(), server = Identity.generate();
      final privateDer = base64Decode(
        server.keyPem
            .split('\n')
            .where((line) => !line.startsWith('-----'))
            .join()
            .replaceAll(RegExp(r'\s'), ''),
      );
      final pkcs8 = ASN1Sequence(
        elements: [
          ASN1Integer(BigInt.zero),
          ASN1Sequence(
            elements: [
              ASN1ObjectIdentifier.fromIdentifierString('1.2.840.113549.1.1.1'),
              ASN1Null(),
            ],
          ),
          ASN1OctetString(octets: privateDer),
        ],
      ).encode();
      final javaHome = Platform.environment['JAVA_HOME'];
      final java = javaHome == null
          ? 'java'
          : '$javaHome/bin/java${Platform.isWindows ? '.exe' : ''}';
      final process = await Process.start(java, [
        '--source',
        '17',
        'test/support/ClockSkewTlsServer.java',
      ]);
      final stderr = process.stderr.transform(utf8.decoder).join();
      SecureSocket? socket;
      try {
        process.stdin.writeln(
          base64Encode(Identity.certificateDer(server.certPem)),
        );
        process.stdin.writeln(base64Encode(pkcs8));
        process.stdin.writeln(
          base64Encode(Identity.certificateDer(client.certPem)),
        );
        process.stdin.writeln(DateTime.utc(2001).millisecondsSinceEpoch);
        await process.stdin.close();
        privateDer.fillRange(0, privateDer.length, 0);
        pkcs8.fillRange(0, pkcs8.length, 0);
        final port = int.parse(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 20)),
        );
        final context = SecurityContext(withTrustedRoots: false)
          ..useCertificateChainBytes(utf8.encode(client.certPem))
          ..usePrivateKeyBytes(utf8.encode(client.keyPem))
          ..setTrustedCertificatesBytes(utf8.encode(server.certPem))
          ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3;
        socket = await SecureSocket.connect(
          'localhost',
          port,
          context: context,
          onBadCertificate: (cert) =>
              Identity.certificateId(cert.pem) == server.id,
          timeout: const Duration(seconds: 10),
        );
        expect(
          await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
          'CLOCK_SKEW_ACCEPTED',
        );
        // Finish the client side before waiting for the JVM to exit. Otherwise
        // JSSE may wait for our TLS close while we wait for its process exit.
        await socket.close();
        expect(
          await process.exitCode.timeout(const Duration(seconds: 10)),
          0,
          reason: await stderr,
        );
      } finally {
        socket?.destroy();
        process.kill();
        await process.exitCode;
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
