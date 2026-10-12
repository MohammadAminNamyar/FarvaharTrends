import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:persian_trend/core/service_lifecycle.dart';

import 'package:flutter_background_service_android/flutter_background_service_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('void service sends tolerate a detached Android messenger', () async {
    const channel = MethodChannel(
      'id.flutter/background_service/android/method',
      JSONMethodCodec(),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var calls = 0;
    for (final error in [
      PlatformException(code: 'detached'),
      MissingPluginException(),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        throw error;
      });
      FlutterBackgroundServiceAndroid().invoke('snapshot', {
        'requestId': 'test',
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls, 2);
  });
  test(
    'native teardown barrier waits beyond a Dart stop acknowledgment',
    () async {
      var queries = 0;
      await waitForServiceStop(
        () async => ++queries < 4,
        pollInterval: const Duration(milliseconds: 1),
      );
      expect(queries, 4);
    },
  );

  test(
    'a stuck native service prevents a competing engine from starting',
    () async {
      var startedReplacement = false;
      Future<void> replace() async {
        await waitForServiceStop(() async => true, timeout: Duration.zero);
        startedReplacement = true;
      }

      await expectLater(replace(), throwsA(isA<TimeoutException>()));
      expect(startedReplacement, isFalse);
    },
  );

  test('an already stopped native service needs no polling delay', () async {
    await waitForServiceStop(() async => false, timeout: Duration.zero);
  });
}
