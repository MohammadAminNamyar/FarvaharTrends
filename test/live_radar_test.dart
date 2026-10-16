import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farvahar_trends/ui/live_radar.dart';

void main() {
  testWidgets('count stays on the radar center independently of its caption', (
    tester,
  ) async {
    for (final scale in [1.0, 1.5]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: LiveRadar(
                    active: false,
                    searching: false,
                    contacts: 12,
                    animate: false,
                    number: '۱۲',
                    caption: 'دستگاه متصل',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final radar = tester.getRect(find.byType(LiveRadar));
      final count = tester.getRect(find.text('۱۲'));
      final caption = tester.getRect(find.text('دستگاه متصل'));
      expect(count.center, radar.center);
      expect(caption.center.dx, radar.center.dx);
      // Font line heights round to logical pixels on the rendering backend.
      expect(caption.top - count.bottom, closeTo(4, .5));
    }
  });

  testWidgets('radar keeps animating without rebuilding widgets each frame', (
    tester,
  ) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: capture,
              child: const SizedBox(
                width: 320,
                child: LiveRadar(
                  active: true,
                  searching: true,
                  contacts: 2,
                  animate: true,
                  number: '۲',
                  caption: 'دستگاه متصل',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final owner = tester.binding.buildOwner!;
    final original = owner.onBuildScheduled;
    var widgetBuilds = 0;
    owner.onBuildScheduled = () {
      widgetBuilds++;
      original?.call();
    };
    addTearDown(() => owner.onBuildScheduled = original);

    Future<Uint8List> pixels() async => (await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
      } finally {
        image.dispose();
      }
    }))!;

    await tester.pump(const Duration(milliseconds: 500));
    final first = await pixels();
    await tester.pump(const Duration(milliseconds: 500));
    final second = await pixels();
    expect(
      second,
      isNot(orderedEquals(first)),
      reason: 'The sweep must still move.',
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(await pixels(), isNot(orderedEquals(second)));
    expect(
      widgetBuilds,
      0,
      reason: 'Animation should paint without rebuilding labels or layout.',
    );
    expect(find.text('۲'), findsOneWidget);
    expect(find.text('دستگاه متصل'), findsOneWidget);
    owner.onBuildScheduled = original;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('radar pauses while hidden or backgrounded and then resumes', (
    tester,
  ) async {
    var paints = 0;
    void countPaints() => paints++;
    final enabled = ValueNotifier<bool>(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (context, value, child) =>
              TickerMode(enabled: value, child: child!),
          child: const LiveRadar(
            active: true,
            searching: true,
            contacts: 1,
            animate: true,
            number: '۱',
            caption: 'دستگاه متصل',
          ),
        ),
      ),
    );
    final painters = tester.widgetList<CustomPaint>(
      find.descendant(
        of: find.byType(LiveRadar),
        matching: find.byType(CustomPaint),
      ),
    );
    final motion = painters.last.painter!;
    motion.addListener(countPaints);
    addTearDown(() => motion.removeListener(countPaints));
    await tester.pump(const Duration(seconds: 1));
    expect(paints, inInclusiveRange(29, 31));

    enabled.value = false;
    await tester.pump();
    final hidden = paints;
    await tester.pump(const Duration(seconds: 1));
    expect(paints, hidden);

    enabled.value = true;
    await tester.pump();
    // Rebuilding can replace the painter; use its shared motion notifier.
    final current = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(LiveRadar),
            matching: find.byType(CustomPaint),
          ),
        )
        .last
        .painter!;
    motion.removeListener(countPaints);
    current.addListener(countPaints);
    addTearDown(() => current.removeListener(countPaints));
    await tester.pump(const Duration(seconds: 1));
    expect(paints, greaterThan(hidden));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final background = paints;
    await tester.pump(const Duration(seconds: 1));
    expect(paints, background);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    expect(paints, greaterThan(background));
    current.removeListener(countPaints);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
