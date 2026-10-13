import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/identity.dart';
import 'package:persian_trend/core/models.dart';

void main() {
  late Identity identity;
  setUpAll(() => identity = Identity.generate());

  test('Existing cards retain strict TLS admission without enrollment', () {
    final card = PeerCard(name: 'Known peer', certificatePem: identity.certPem);
    expect(card.tcpEnrollment, isFalse);
    expect(card.toJson().containsKey('tcpEnrollment'), isFalse);
    expect(PeerCard.fromText(card.toText()).tcpEnrollment, isFalse);
  });

  test('Explicit relay enrollment capability survives pairing and persistence', () {
    final card = PeerCard(
      name: 'Volunteer relay',
      host: '203.0.113.10',
      certificatePem: identity.certPem,
      tcpEnrollment: true,
    );
    for (final parsed in [
      PeerCard.fromJson(card.toJson()),
      PeerCard.fromText(card.toText()),
    ]) {
      expect(parsed.tcpEnrollment, isTrue);
      expect(parsed.id, identity.id);
      expect(parsed.host, card.host);
      expect(parsed.toJson().containsKey('keyPem'), isFalse);
    }
  });

  test('Enrollment capability cannot replace certificate pin validation', () {
    final card = PeerCard(name: 'Relay', certificatePem: identity.certPem);
    expect(
      () => PeerCard.fromJson({
        ...card.toJson(),
        'tcpEnrollment': true,
        'id': '0' * 64,
      }),
      throwsFormatException,
    );
    for (final invalid in [null, 1, 'true', [], {}]) {
      expect(
        () => PeerCard.fromJson({...card.toJson(), 'tcpEnrollment': invalid}),
        throwsFormatException,
      );
    }
  });
}
