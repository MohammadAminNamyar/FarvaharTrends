import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/app_controller.dart';
import 'package:farvahar_trends/core/bootstrap_config.dart';
import 'package:farvahar_trends/core/identity.dart';
import 'package:farvahar_trends/core/models.dart';
import 'package:farvahar_trends/main.dart';
import 'package:farvahar_trends/ui/pilot_app.dart' show maxQrBytes;
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Identity identity;
  late Identity other;

  setUpAll(() async {
    identity = Identity.generate();
    other = Identity.generate();
    for (final entry in {
      'Manrope': 'assets/fonts/Manrope.ttf',
      'Vazirmatn': 'assets/fonts/Vazirmatn.ttf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
  });

  Future<_BootstrapController> showPeers(
    WidgetTester tester, {
    String language = 'en',
    String? export,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final app = _BootstrapController(identity)
      ..languageCode = language
      ..exported = export;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      FarvaharTrendsApp(
        controller: app,
        initialize: false,
        animateRadar: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('advanced-diagnostics')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(NavigationBar),
            matching: find.text(language == 'fa' ? 'اعتماد دستی' : 'Peers'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('The pairing card sheet shows a scannable QR of the card', (
    tester,
  ) async {
    final app = await showPeers(tester);
    await tester.tap(find.text('Show pairing card'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('qr-own-card')), findsOneWidget);
    expect(find.byKey(const ValueKey('qr-own-card-too-large')), findsNothing);
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.errorCorrectionLevel, QrErrorCorrectLevel.M);
    expect(find.text('Copy card'), findsOneWidget);
    final card = jsonEncode(app.ownCard().toJson());
    expect(utf8.encode(card).length, lessThanOrEqualTo(maxQrBytes));
    expect(tester.takeException(), isNull);
  });

  testWidgets('An oversized starting-peer list shows a message, not a QR', (
    tester,
  ) async {
    final big = jsonEncode({
      'version': 2,
      'peers': [
        for (var i = 1; i <= 4; i++)
          PeerCard(
            name: 'Helper $i',
            host: '11.0.113.$i',
            certificatePem: other.certPem,
          ).toJson(),
      ],
      'dhtBootstrap': const <String>[],
    });
    expect(utf8.encode(big).length, greaterThan(maxQrBytes));
    await showPeers(tester, language: 'fa', export: big);
    await tester.tap(find.byKey(const ValueKey('share-starting-peers')));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    expect(
      find.byKey(const ValueKey('qr-starting-peers-too-large')),
      findsOneWidget,
    );
    expect(find.textContaining('کد QR'), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-starting-peers')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A small starting-peer list renders a QR with its summary', (
    tester,
  ) async {
    final small = jsonEncode({
      'version': 2,
      'peers': [
        PeerCard(
          name: 'Helper',
          host: '11.0.113.1',
          certificatePem: other.certPem,
        ).toJson(),
      ],
      'dhtBootstrap': ['11.0.113.2:49737'],
    });
    await showPeers(tester, export: small);
    await tester.tap(find.byKey(const ValueKey('share-starting-peers')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('qr-starting-peers')), findsOneWidget);
    expect(find.text('1 starting peers · 1 discovery nodes'), findsOneWidget);
    expect(find.byKey(const ValueKey('starting-peers-text')), findsNothing);
    expect(find.text(small), findsNothing);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('copy-starting-peers')));
    await tester.pumpAndSettle();
    expect(copied, small);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['fa', 'en']) {
    testWidgets('$language empty starting-peer list has no QR or copy action', (
      tester,
    ) async {
      await showPeers(tester, language: language);
      await tester.tap(find.byKey(const ValueKey('share-starting-peers')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('starting-peers-empty')),
        findsOneWidget,
      );
      expect(find.byType(QrImageView), findsNothing);
      expect(find.byKey(const ValueKey('copy-starting-peers')), findsNothing);
      expect(find.byKey(const ValueKey('starting-peers-text')), findsNothing);
      expect(
        find.textContaining(
          language == 'fa'
              ? 'هنوز همتای شروعی برای اشتراک ندارید'
              : 'No starting peers to share yet',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> importText(WidgetTester tester, String text) async {
    await tester.tap(find.text('Import a peer card or starting-peer list'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('import-peer-text')),
      text,
    );
    await tester.tap(find.byKey(const ValueKey('review-import')));
    await tester.pumpAndSettle();
  }

  testWidgets('Importing a pairing token reviews one fingerprint', (
    tester,
  ) async {
    final app = await showPeers(tester);
    final token = PeerCard(
      name: 'Other',
      certificatePem: other.certPem,
    ).toText();
    await importText(tester, token);
    expect(find.text('Trust Other?'), findsOneWidget);
    expect(find.text('Trust only · no dialing address'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('approve-import')));
    await tester.pumpAndSettle();
    expect(app.imports, [token]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Importing a version 2 document lists every card once', (
    tester,
  ) async {
    final app = await showPeers(tester);
    final third = Identity.generate();
    final document = jsonEncode({
      'version': 2,
      'peers': [
        PeerCard(
          name: 'Seed A',
          host: '11.0.113.1',
          certificatePem: other.certPem,
        ).toJson(),
        PeerCard(
          name: 'Seed B',
          host: '11.0.113.2',
          certificatePem: third.certPem,
        ).toJson(),
      ],
      'dhtBootstrap': ['11.0.113.3:49737'],
    });
    await importText(tester, document);
    expect(find.text('Trust 2 starting peers?'), findsOneWidget);
    expect(find.text('Seed A'), findsOneWidget);
    expect(find.text('Seed B'), findsOneWidget);
    expect(find.text('Address: 11.0.113.1:$defaultPeerPort'), findsOneWidget);
    expect(find.textContaining('11.0.113.3:49737'), findsOneWidget);
    expect(app.imports, isEmpty);
    await tester.tap(find.byKey(const ValueKey('approve-import')));
    await tester.pumpAndSettle();
    expect(app.imports, [document]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Invalid text and the phone’s own card stay in the dialog', (
    tester,
  ) async {
    final app = await showPeers(tester);
    await importText(tester, 'nonsense');
    expect(find.byKey(const ValueKey('review-import')), findsOneWidget);
    expect(app.imports, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('import-peer-text')),
      app.ownCard().toText(),
    );
    await tester.tap(find.byKey(const ValueKey('review-import')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('approve-import')), findsNothing);
    expect(find.byKey(const ValueKey('review-import')), findsOneWidget);
    expect(app.error, isNotNull);
    expect(app.imports, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _BootstrapController extends AppController {
  _BootstrapController(Identity generated) {
    identity = generated;
    loading = false;
    running = true;
    activeMode = true;
    label = 'Test phone';
    device = {'platform': 'android', 'batteryPercent': 86};
    snapshot = {
      'running': true,
      'activeMode': true,
      'connectedCount': 0,
      'discoveredCount': 0,
      'discoveryState': 'searching',
      'channels': <Map<String, dynamic>>[],
      'peers': <Map<String, dynamic>>[],
      'bulletins': <Map<String, dynamic>>[],
      'trials': <Map<String, dynamic>>[],
      'events': <Map<String, dynamic>>[],
    };
  }

  final imports = <String>[];
  String? exported;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> refresh() async => notifyListeners();

  @override
  Future<BootstrapConfig> importBootstrapDocument(String text) async {
    final document = parseBootstrapDocument(text);
    imports.add(text);
    return document;
  }

  @override
  Future<String> exportBootstrapDocument() async =>
      exported ?? jsonEncode(const BootstrapConfig().toJson());
}
