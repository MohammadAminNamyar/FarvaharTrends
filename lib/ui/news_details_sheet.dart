import 'package:flutter/material.dart';

import 'localization.dart';
import 'news_components.dart';
import 'theme.dart';

class NewsDetailsSheet extends StatelessWidget with Localized {
  const NewsDetailsSheet({
    super.key,
    required this.news,
    required this.channel,
    required this.fa,
    this.route,
    this.onRemove,
  });
  final Map<String, dynamic> news, channel;
  @override
  final bool fa;
  final String? route;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: fa ? TextDirection.rtl : TextDirection.ltr,
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .88,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: RepaintBoundary(
            key: const ValueKey('news-details-preview'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    ChannelAvatar(channel: channel, size: 42),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('جزئیات خبر', 'News details'),
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: inkColor,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            channel['name'] as String? ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: mutedColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t('بستن', 'Close'),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        size: 22,
                        color: mutedColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: lineColor),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NewsTimes(news: news, fa: fa, compact: true),
                      if (route != null) ...[
                        const Divider(height: 1, indent: 16, endIndent: 16),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.alt_route_rounded,
                                color: tealTextColor,
                                size: 20,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t('مسیر دریافت', 'Delivery route'),
                                      style: const TextStyle(
                                        color: mutedColor,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      route!,
                                      style: const TextStyle(
                                        color: inkColor,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        height: 1.6,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 18),
                  child: Text(
                    t(
                      'زمان‌ها به وقت این گوشی‌اند؛ اختلاف ساعت‌ها معیار دقیق سرعت انتقال نیست.',
                      'Times use this phone’s timezone; clock differences do not measure delivery speed.',
                    ),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.7,
                      color: mutedColor,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: softSurfaceColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.verified_outlined,
                        color: tealTextColor,
                        size: 23,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t(
                                'امضای دیجیتال معتبر',
                                'Valid digital signature',
                              ),
                              style: const TextStyle(
                                color: tealTextColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              t(
                                'امضا کلید ناشر را تأیید می‌کند؛ درستی خبر را مستقل بررسی کنید.',
                                'The signature verifies the publishing key. Check factual accuracy independently.',
                              ),
                              style: const TextStyle(
                                color: mutedColor,
                                fontSize: 12,
                                height: 1.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (onRemove != null) ...[
                  const SizedBox(height: 16),
                  TextButton.icon(
                    key: ValueKey('remove-news-${news['id']}'),
                    onPressed: () {
                      Navigator.pop(context);
                      onRemove!();
                    },
                    style: TextButton.styleFrom(foregroundColor: errorColor),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: Text(t('حذف خبر', 'Remove news')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
