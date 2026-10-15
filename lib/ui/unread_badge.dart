import 'package:flutter/material.dart';

import 'localization.dart';
import 'theme.dart';

/// Local unread news, with a bounded visual label and an exact spoken count.
class UnreadBadge extends StatelessWidget with Localized {
  const UnreadBadge({
    super.key,
    required this.count,
    required this.fa,
    this.muted = false,
  });
  final int count;
  @override
  final bool fa;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '${n(99)}+' : n(count);
    return Semantics(
      label: t(
        '${n(count)} خبر خوانده‌نشده در این گوشی',
        '$count unread news on this phone',
      ),
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: muted ? mutedColor : tealTextColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            textDirection: TextDirection.ltr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}
