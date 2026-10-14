import 'dart:io';

import 'package:flutter/material.dart';

import 'theme.dart';

import 'date_format.dart';

const _ink = inkColor;
const _muted = mutedColor;

/// Day-relative label for a signed send time in the channel/feed header.
/// `now` is injectable for tests; it is the viewer's clock, never a measure.
String channelActivityTime(
  BuildContext context,
  dynamic value,
  bool fa, {
  DateTime? now,
}) {
  if (value is! int || value.abs() > 8640000000000000) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  return NewsDateFormat(fa: fa).relativeDay(
    date,
    now: now ?? DateTime.now(),
    shortDate: MaterialLocalizations.of(context).formatShortDate,
  );
}

class ChannelAvatar extends StatelessWidget {
  const ChannelAvatar({super.key, required this.channel, this.size = 48});
  final Map<String, dynamic> channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    const colors = [
      Color(0xFF247E86),
      Color(0xFF5275A7),
      Color(0xFF9770AA),
      Color(0xFFB77861),
      Color(0xFF4A8B70),
    ];
    final id = channel['id'] as String;
    final hash = id.codeUnits.fold<int>(0, (sum, c) => (sum * 31 + c) & 0xffff);
    final name = (channel['name'] as String? ?? '').trim();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: colors[hash % colors.length],
        child: Text(
          name.isEmpty ? '•' : name.characters.first.toUpperCase(),
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * .43,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class NewsImageView extends StatelessWidget {
  const NewsImageView({super.key, required this.image, required this.fa});
  final Map<String, dynamic> image;
  final bool fa;
  @override
  Widget build(BuildContext context) {
    final path = image['path'];
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: path is String
              ? Image.file(
                  File(path),
                  width: double.infinity,
                  fit: BoxFit.contain,
                  cacheWidth: 1280,
                  errorBuilder: (_, _, _) =>
                      Text(fa ? 'تصویر در دسترس نیست' : 'Image unavailable'),
                )
              : Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  color: const Color(0xFFECF5F3),
                  child: Row(
                    children: [
                      const Icon(Icons.image_outlined, color: _muted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          fa ? 'تصویر اختیاری · با اتصال مناسب دریافت می‌شود' : 'Optional image · downloads on an allowed connection',
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Send time is signed by the writer; receive time stays on this phone.
class NewsTimes extends StatelessWidget {
  const NewsTimes({
    super.key,
    required this.news,
    required this.fa,
    this.compact = false,
  });
  final Map<String, dynamic> news;
  final bool fa;
  final bool compact;

  NewsDateFormat get _format => NewsDateFormat(fa: fa);
  String _stamp(dynamic value) => _format.full(value);
  String _clock(dynamic value) => _format.clock(value);

  Widget _compactTime(String label, dynamic value, String key) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 7,
    children: [
      Text(
        '$label:',
        style: const TextStyle(color: _muted, fontSize: 10.5, height: 1.8),
      ),
      Tooltip(
        message: _stamp(value),
        triggerMode: TooltipTriggerMode.tap,
        child: Text(
          _clock(value),
          key: ValueKey('$key-${news['id']}'),
          textDirection: TextDirection.ltr,
          style: const TextStyle(
            color: _ink,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            height: 1.8,
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final local = news['receivedVia'] == 'local';
    return Tooltip(
      message: fa
          ? 'زمان‌ها در منطقهٔ زمانی همین گوشی نمایش داده می‌شوند. ارسال از ساعت نویسنده و دریافت از ساعت این گوشی است؛ اختلافشان زمان قطعی انتقال نیست.'
          : 'Both times use this phone’s timezone. Sent uses the writer’s clock; received uses this phone’s clock. Their difference is not a measured delivery duration.',
      child: Semantics(
        container: true,
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _compactTime(
                    fa ? 'ارسال' : 'Sent',
                    news['createdAtMs'],
                    'sent-time',
                  ),
                  if (!local)
                    _compactTime(
                      fa ? 'دریافت در این گوشی' : 'Received here',
                      news['receivedAtWallMs'],
                      'received-time',
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${fa ? 'ارسال' : 'Sent'}: ${_stamp(news['createdAtMs'])}',
                    key: ValueKey('sent-time-${news['id']}'),
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      height: 1.7,
                    ),
                  ),
                  if (!local)
                    Text(
                      '${fa ? 'دریافت در این گوشی' : 'Received on this phone'}: '
                      '${_stamp(news['receivedAtWallMs'])}',
                      key: ValueKey('received-time-${news['id']}'),
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 10,
                        height: 1.7,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
