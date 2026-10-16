/// The animated peer radar on the connection tab.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'native_radar_motion.dart';

class LiveRadar extends StatefulWidget {
  const LiveRadar({
    super.key,
    required this.active,
    required this.searching,
    required this.contacts,
    required this.animate,
    required this.number,
    required this.caption,
  });
  final bool active, searching, animate;
  final int contacts;
  final String number, caption;
  @override
  State<LiveRadar> createState() => _LiveRadarState();
}

class _LiveRadarState extends State<LiveRadar> with WidgetsBindingObserver {
  // This slow sweep needs only 30 paints per second, even on a 120 Hz phone.
  // A timer avoids scheduling an otherwise idle Flutter frame at every vsync.
  static const _frame = Duration(microseconds: 33333);
  static const _cycleMicros = 5000000;
  final motion = ValueNotifier<double>(0);
  Timer? _timer;
  bool _motionAllowed = false;
  bool _visible = true;
  bool _nativeFailed = false;
  bool get _native =>
      Platform.isAndroid &&
      !_nativeFailed &&
      const bool.fromEnvironment('FT_NATIVE_RADAR', defaultValue: true);
  bool get _animate =>
      widget.active && widget.animate && _motionAllowed && _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _visible = state == null || state == AppLifecycleState.resumed;
  }

  void updateMotion() {
    if (_animate && !_native) {
      if (_timer != null) return;
      final start = motion.value;
      _timer = Timer.periodic(_frame, (timer) {
        // tick includes missed intervals: delayed frames do not slow the sweep.
        motion.value =
            (start + timer.tick * _frame.inMicroseconds / _cycleMicros) % 1;
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    updateMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    updateMotion();
    if (_native && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LiveRadar oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateMotion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.number} ${widget.caption}',
    child: SizedBox(
      height: 160,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_native)
            LayoutBuilder(
              builder: (context, constraints) => Center(
                child: SizedBox.square(
                  dimension: math.min(constraints.maxWidth * .45 / .44, 160),
                  child: NativeRadarMotion(
                    backgroundColor: inkColor,
                    active: widget.active,
                    searching: widget.searching,
                    animate: _animate,
                    onUnavailable: () {
                      if (!mounted) return;
                      setState(() => _nativeFailed = true);
                      updateMotion();
                    },
                  ),
                ),
              ),
            ),
          RepaintBoundary(
            child: CustomPaint(
              painter: _RadarBackgroundPainter(contacts: widget.contacts),
            ),
          ),
          if (!_native)
            RepaintBoundary(
              child: CustomPaint(
                painter: _RadarMotionPainter(
                  progress: motion,
                  active: widget.active,
                  searching: widget.searching,
                ),
              ),
            ),
          Center(
            child: Text(
              widget.number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 38,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          ),
          // Center the count itself on the crosshair; the caption must not
          // shift it upward. Keep their gap when the text scale changes.
          Positioned(
            top: 80 + MediaQuery.textScalerOf(context).scale(38) * .6 + 4,
            left: 0,
            right: 0,
            child: Text(
              widget.caption,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFB8D5DC), fontSize: 10),
            ),
          ),
        ],
      ),
    ),
  );
}

// Static rings, peer dots and text stay outside the animated paint layer.
// Animation ticks repaint the sweep directly; they never rebuild widgets.
class _RadarBackgroundPainter extends CustomPainter {
  const _RadarBackgroundPainter({required this.contacts});
  final int contacts;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width * .45, size.height * .44);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .12);
    for (final scale in [.35, .65, 1.0]) {
      canvas.drawCircle(center, radius * scale, line);
    }
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      line,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      line,
    );
    for (var i = 0; i < math.min(contacts, 6); i++) {
      final angle = i * 2.399 + .5;
      final r = radius * (.55 + (i % 3) * .15);
      canvas.drawCircle(
        center + Offset(math.cos(angle) * r, math.sin(angle) * r),
        3.5,
        Paint()..color = i == 0 ? goldColor : tealColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarBackgroundPainter oldDelegate) =>
      contacts != oldDelegate.contacts;
}

class _RadarMotionPainter extends CustomPainter {
  _RadarMotionPainter({
    required this.progress,
    required this.active,
    required this.searching,
  }) : super(repaint: progress);

  final ValueListenable<double> progress;
  final bool active, searching;
  final _ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final _sweep = Paint();
  double? _shaderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width * .45, size.height * .44);
    final phase = progress.value;
    _ring.color = tealColor.withValues(alpha: (1 - phase) * .4);
    canvas.drawCircle(center, radius * (.3 + .7 * phase), _ring);
    if (!searching) return;
    final bounds = Rect.fromCircle(center: Offset.zero, radius: radius);
    if (_shaderRadius != radius) {
      _shaderRadius = radius;
      _sweep.shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2,
        colors: [
          tealColor.withValues(alpha: 0),
          tealColor.withValues(alpha: .22),
        ],
      ).createShader(bounds);
    }
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(phase * math.pi * 2);
    canvas.drawArc(bounds, 0, math.pi / 2, true, _sweep);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RadarMotionPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      active != oldDelegate.active ||
      searching != oldDelegate.searching;
}
