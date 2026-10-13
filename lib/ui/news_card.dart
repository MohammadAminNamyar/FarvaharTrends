import 'package:flutter/material.dart';

import 'news_components.dart';

const _ink = Color(0xFF183F51);
const _muted = Color(0xFF5A717C);
const _teal = Color(0xFF267E7B);
const _line = Color(0xFFDFE9EC);

/// The same article presentation in the channel timeline and followed feed.
class NewsCard extends StatelessWidget {
  const NewsCard({
    super.key,
    required this.news,
    required this.channel,
    required this.fa,
    required this.assessment,
    this.onOpenChannel,
    this.onRemove,
  });
  final Map<String, dynamic> news, channel;
  final bool fa;
  final String assessment;
  final VoidCallback? onOpenChannel, onRemove;
  String t(String f, String e) => fa ? f : e;

  @override
  Widget build(BuildContext context) {
    final byline = news['byline'];
    final route = _arrival(news['receivedVia']);
    return Container(
      key: ValueKey('news-card-${news['id']}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(
            color: _ink.withValues(alpha: .035),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: const Color(0xFFF7FAFB),
              child: InkWell(
                onTap: onOpenChannel,
                child: Container(
                  key: ValueKey('news-header-${news['id']}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: _line)),
                  ),
                  child: Row(
                    children: [
                      ChannelAvatar(channel: channel, size: 34),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              channel['name'] as String? ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              assessment,
                              key: ValueKey('news-trust-${news['id']}'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 10.5,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        channelActivityTime(context, news['createdAtMs'], fa),
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 19, 18, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (news['image'] is Map)
                    NewsImageView(
                      image: Map<String, dynamic>.from(news['image'] as Map),
                      fa: fa,
                    ),
                  SelectableText(
                    news['text'] as String? ?? '',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 16,
                      height: 1.9,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              key: ValueKey('news-footer-${news['id']}'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              decoration: const BoxDecoration(
                color: Color(0xFFEDF5F5),
                border: Border(top: BorderSide(color: _line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (byline is String && byline.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(
                          Icons.edit_note_rounded,
                          size: 17,
                          color: _teal,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            t('نویسنده: $byline', 'By $byline'),
                            key: ValueKey('news-byline-${news['id']}'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: NewsTimes(news: news, fa: fa, compact: true),
                      ),
                      if (onRemove != null)
                        IconButton(
                          key: ValueKey('remove-news-${news['id']}'),
                          tooltip: t('حذف خبر', 'Remove news'),
                          onPressed: onRemove,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 19,
                            color: _muted,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Tooltip(
                    message: t(
                      'امضا کلید ناشر را تأیید می‌کند؛ درستی خبر را مستقل بررسی کنید.',
                      'The signature verifies the publishing key. Check factual accuracy independently.',
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.verified_user_outlined,
                          color: _teal,
                          size: 13,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            t(
                              'امضای دیجیتال معتبر · خبر عمومی',
                              'Valid digital signature · public news',
                            ),
                            style: const TextStyle(
                              color: _teal,
                              fontSize: 10,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (route != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      route,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 10,
                        height: 1.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _arrival(dynamic route) => switch (route) {
    'overlay' => t(
      'دریافت از شبکهٔ همتاها',
      'Received through the peer network',
    ),
    'ip' => t(
      'دریافت از مسیر اینترنت / شبکهٔ داخلی',
      'Received via Internet / domestic IP',
    ),
    'lan' => t('دریافت از وای‌فای محلی', 'Received via local Wi-Fi'),
    'wifiDirect' => t('دریافت از وای‌فای مستقیم', 'Received via Wi-Fi Direct'),
    'bluetooth' => t('دریافت از بلوتوث', 'Received via Bluetooth'),
    'local' => t('منتشرشده در همین دستگاه', 'Published on this device'),
    _ => null,
  };
}
