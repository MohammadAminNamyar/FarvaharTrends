import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_platform/pilot_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('farvahartrends/device');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('overlapping stores wait for native release before acquiring', () async {
    var acquires = 0;
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'acquireIdentityLease') return 'lease-${++acquires}';
      if (call.arguments['token'] == 'lease-1') await release.future;
      return null;
    });
    final first = await PilotPlatform.acquireIdentityLease();
    final second = PilotPlatform.acquireIdentityLease();
    await Future<void>.delayed(Duration.zero);
    expect(acquires, 1);
    final releasing = PilotPlatform.releaseIdentityLease(first);
    await Future<void>.delayed(Duration.zero);
    expect(acquires, 1);
    release.complete();
    await releasing;
    expect(await second, 'lease-2');
    await PilotPlatform.releaseIdentityLease('lease-2');
  });

  test('failed acquire does not strand the next store', () async {
    var acquires = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'acquireIdentityLease') return null;
      if (++acquires == 1) {
        throw PlatformException(code: 'identity_lease_timeout');
      }
      return 'recovered';
    });
    final failed = expectLater(
      PilotPlatform.acquireIdentityLease(),
      throwsA(isA<PlatformException>()),
    );
    final next = PilotPlatform.acquireIdentityLease();
    await failed;
    expect(await next, 'recovered');
    await PilotPlatform.releaseIdentityLease('recovered');
  });

  test('a foreign release cannot advance the queue', () async {
    var acquires = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          call.method == 'acquireIdentityLease' ? 'lease-${++acquires}' : null,
    );
    final first = await PilotPlatform.acquireIdentityLease();
    final second = PilotPlatform.acquireIdentityLease();
    await expectLater(
      PilotPlatform.releaseIdentityLease('foreign'),
      throwsStateError,
    );
    expect(acquires, 1);
    await PilotPlatform.releaseIdentityLease(first);
    await PilotPlatform.releaseIdentityLease(await second);
  });

  test('same-engine waiting requests are bounded', () async {
    var acquires = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          call.method == 'acquireIdentityLease' ? 'lease-${++acquires}' : null,
    );
    final pending = List.generate(
      16,
      (_) => PilotPlatform.acquireIdentityLease(),
    );
    await expectLater(PilotPlatform.acquireIdentityLease(), throwsStateError);
    for (final request in pending) {
      await PilotPlatform.releaseIdentityLease(await request);
    }
    expect(acquires, 16);
  });
}
