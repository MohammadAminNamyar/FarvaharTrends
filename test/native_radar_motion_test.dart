import 'package:farvahar_trends/ui/native_radar_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('native radar sends state changes, not a per-frame Dart stream', (
    tester,
  ) async {
    final platformCalls = <MethodCall>[];
    final updates = <MethodCall>[];
    int? viewId;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      platformCalls.add(call);
      if (call.method == 'create') {
        final args = call.arguments as Map;
        viewId = args['id'] as int;
        expect(args['hybrid'], true);
        messenger.setMockMethodCallHandler(
          MethodChannel('farvahartrends/radar/$viewId'),
          (call) async {
            updates.add(call);
            return null;
          },
        );
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (viewId != null) {
        messenger.setMockMethodCallHandler(
          MethodChannel('farvahartrends/radar/$viewId'),
          null,
        );
      }
    });
    Future<void> show(bool animate, {bool active = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 160,
              child: NativeRadarMotion(
                active: active,
                searching: true,
                animate: animate,
                backgroundColor: const Color(0xFF102E42),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await show(true);
    expect(viewId, isNotNull);
    expect(updates.last.arguments, {
      'active': true,
      'searching': true,
      'animate': true,
      'backgroundColor': 0xFF102E42,
    });
    final initial = updates.length;
    await tester.pump(const Duration(seconds: 5));
    expect(updates.length, initial, reason: 'The native renderer owns motion.');
    await show(false);
    expect(updates.last.arguments['animate'], false);
    await show(true);
    expect(updates.last.arguments['animate'], true);
    await show(false, active: false);
    expect(updates.last.arguments['active'], false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(platformCalls.where((c) => c.method == 'dispose'), hasLength(1));
  });
}
