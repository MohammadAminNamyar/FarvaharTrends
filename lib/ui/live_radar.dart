/// The animated peer radar on the connection tab.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

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

class _LiveRadarState extends State<LiveRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );
  void updateMotion() {
    if (widget.active &&
        widget.animate &&
        !MediaQuery.disableAnimationsOf(context)) {
      motion.repeat();
    } else {
      motion.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateMotion();
  }

  @override
  void didUpdateWidget(covariant LiveRadar oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateMotion();
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.number} ${widget.caption}',
    child: SizedBox(
      height: 160,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: motion,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(
            progress: motion.value,
            contacts: widget.contacts,
            active: widget.active,
            searching: widget.searching,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.caption,
                  style: const TextStyle(
                    color: Color(0xFFB8D5DC),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.progress,
    required this.contacts,
    required this.active,
    required this.searching,
  });
  final double progress;
  final int contacts;
  final bool active, searching;
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
    if (active) {
      canvas.drawCircle(
        center,
        radius * (.3 + .7 * progress),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = tealColor.withValues(alpha: (1 - progress) * .4),
      );
      if (searching) {
        final sweep = Paint()
          ..shader = SweepGradient(
            startAngle: 0,
            endAngle: math.pi / 2,
            colors: [
              tealColor.withValues(alpha: 0),
              tealColor.withValues(alpha: .22),
            ],
            transform: GradientRotation(progress * math.pi * 2),
          ).createShader(Rect.fromCircle(center: center, radius: radius));
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          progress * math.pi * 2,
          math.pi / 2,
          true,
          sweep,
        );
      }
    }
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
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      contacts != oldDelegate.contacts ||
      active != oldDelegate.active ||
      searching != oldDelegate.searching;
}
