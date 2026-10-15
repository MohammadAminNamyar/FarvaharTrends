import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/app_controller.dart';
import 'package:farvahar_trends/ui/create_channel_page.dart';

class _OwnerController extends AppController {
  _OwnerController(String language) {
    languageCode = language;
    loading = false;
    snapshot = {'channelKeyManagement': true, 'channels': [], 'bulletins': []};
  }
  final actions = <String>[];
  @override
  Future<String?> channelAction(
    String action,
    Map<String, dynamic> args,
  ) async {
    actions.add(action);
    if (action == 'prepareProtectedChannel') {
      return jsonEncode({
        'token': 'pending',
        'file': 'encrypted-test-fixture',
        'channelId': 'a' * 64,
      });
    }
    return action == 'commitProtectedChannel' ? 'a' * 64 : null;
  }
}

void main() {
  const platform = MethodChannel('farvahartrends/device');
  for (final language in ['fa', 'en']) {
    for (final saved in [false, true]) {
      testWidgets(
        '$language protected creation requires a successful file save: $saved',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(430, 900);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetPhysicalSize);
          final app = _OwnerController(language);
          addTearDown(app.dispose);
          var saves = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(platform, (call) async {
                expect(call.method, 'saveChannelDocument');
                saves++;
                expect(app.actions, ['prepareProtectedChannel']);
                return saved;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(platform, null),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Directionality(
                          textDirection: language == 'fa'
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          child: CreateChannelPage(app: app),
                        ),
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('channel-name')),
            'آزمایش کانال',
          );
          await tester.tap(find.byKey(const ValueKey('submit-create-channel')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.enterText(
            find.byKey(const ValueKey('recovery-password')),
            'violet canoe orbit pepper 5728',
          );
          await tester.enterText(
            find.byKey(const ValueKey('recovery-password-confirm')),
            'violet canoe orbit pepper 5728',
          );
          await tester.tap(find.text(language == 'fa' ? 'ادامه' : 'Continue'));
          await tester.pumpAndSettle();
          expect(saves, 1);
          expect(app.actions, [
            'prepareProtectedChannel',
            saved ? 'commitProtectedChannel' : 'cancelProtectedChannel',
          ]);
          expect(tester.takeException(), isNull);
          if (saved) expect(find.text('Open'), findsOneWidget);
        },
      );
    }
  }
}
