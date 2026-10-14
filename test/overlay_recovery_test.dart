import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/core/overlay_recovery.dart';

void main() {
  test('isolated remembered peers recover without an app restart', () {
    var elapsed = 0;
    final policy = OverlayRecovery(nowMs: () => elapsed);
    bool sample() => policy.shouldRestart(
      connected: false,
      offline: false,
      rememberedPeers: true,
    );
    expect(sample(), false);
    elapsed = 89999;
    expect(sample(), false);
    elapsed++;
    expect(sample(), true);
    expect(sample(), false, reason: 'Repeated samples must not restart twice');
    elapsed += 179999;
    expect(sample(), false);
    elapsed++;
    expect(sample(), true);
    elapsed += 360000;
    expect(sample(), true);
    for (var i = 0; i < 20; i++) {
      elapsed += 899999;
      expect(sample(), false);
      elapsed++;
      expect(sample(), true);
    }
  });

  test(
    'cold discovery gets longer; offline time cannot consume its budget',
    () {
      var elapsed = 0;
      final policy = OverlayRecovery(nowMs: () => elapsed);
      bool sample(bool offline) => policy.shouldRestart(
        connected: false,
        offline: offline,
        rememberedPeers: false,
      );
      expect(sample(false), false);
      elapsed = 90000;
      expect(sample(false), false);
      expect(sample(true), false);
      elapsed += 86400000;
      expect(sample(true), false);
      expect(sample(false), false);
      elapsed += 179999;
      expect(sample(false), false);
      elapsed++;
      expect(sample(false), true);
    },
  );

  test('brief connections do not reset backoff; sustained recovery does', () {
    var elapsed = 0;
    final policy = OverlayRecovery(nowMs: () => elapsed);
    bool sample(bool linked) => policy.shouldRestart(
      connected: linked,
      offline: false,
      rememberedPeers: true,
    );
    sample(false);
    elapsed = 90000;
    expect(sample(false), true);
    sample(true);
    elapsed += 1000;
    sample(false);
    elapsed += 90000;
    expect(sample(false), false);
    sample(true);
    elapsed += 90000;
    expect(sample(true), false);
    expect(policy.attempts, 0);
    sample(false);
    elapsed += 90000;
    expect(sample(false), true);
  });

  test('a changed network gets a fresh recovery opportunity', () {
    var elapsed = 0;
    final policy = OverlayRecovery(nowMs: () => elapsed);
    bool sample() => policy.shouldRestart(
      connected: false,
      offline: false,
      rememberedPeers: true,
    );
    sample();
    elapsed += 90000;
    sample();
    expect(policy.attempts, 1);
    policy.networkChanged();
    expect(sample(), false);
    elapsed += 90000;
    expect(sample(), true);
  });
}
