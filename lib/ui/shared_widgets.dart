/// Cards, tags and tiles shared by the reader screens and the legacy
/// diagnostics page.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'legacy_text.dart';
import 'localization.dart';
import 'theme.dart';

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: lineColor),
    ),
    child: child,
  );
}

class AppTag extends StatelessWidget {
  const AppTag(
    this.text, {
    super.key,
    required this.color,
    this.onDark = false,
  });
  final String text;
  final Color color;
  final bool onDark;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(6),
    ),
    child: LegacyText(
      text,
      style: TextStyle(
        fontSize: 7.5,
        fontWeight: FontWeight.w800,
        color: onDark
            ? color
            : color == tealColor
            ? tealTextColor
            : color == goldColor
            ? goldTextColor
            : errorColor,
        letterSpacing: .6,
      ),
    ),
  );
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, required this.color});
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 41,
    height: 41,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .085),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, size: 21, color: color),
  );
}

class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });
  final String value, label;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const Spacer(),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .4),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LegacyText(
          value,
          style: const TextStyle(
            color: inkColor,
            fontSize: 31,
            fontWeight: FontWeight.w800,
            height: 1,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 9),
        LegacyText(
          label,
          style: const TextStyle(
            color: mutedColor,
            fontSize: 7.5,
            fontWeight: FontWeight.w800,
            letterSpacing: .5,
          ),
        ),
      ],
    ),
  );
}

class Fingerprint extends StatelessWidget {
  const Fingerprint(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: canvasColor,
      borderRadius: BorderRadius.circular(11),
    ),
    child: SelectableText(
      [
        for (var i = 0; i < id.length; i += 8)
          id.substring(i, math.min(i + 8, id.length)),
      ].join(' '),
      style: TextStyle(
        fontFamily: LanguageScope.isFarsi(context) ? 'Vazirmatn' : 'Manrope',
        fontWeight: FontWeight.w600,
        fontSize: 10,
        height: 1.8,
        letterSpacing: .1,
        color: inkColor,
      ),
    ),
  );
}

class SubmissionError extends StatelessWidget {
  const SubmissionError(this.message, {super.key, required this.farsi});
  final String message;
  final bool farsi;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            farsi ? 'این کار کامل نشد' : 'That action did not finish',
            style: const TextStyle(
              color: errorColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: const TextStyle(color: errorColor, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
