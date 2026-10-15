import 'package:flutter/material.dart';

import 'theme.dart';
import 'localization.dart';
import 'news_components.dart';
import 'news_text.dart';
import 'news_details_sheet.dart';

/// A reading-first card shared by the channel timeline and followed feed.
class NewsCard extends StatelessWidget with Localized {
  const NewsCard({
    super.key,
    required this.news,
    required this.channel,
    required this.fa,
    required this.assessment,
    this.showChannelHeader = true,
    this.onOpenChannel,
    this.onRemove,
  });
  final Map<String, dynamic> news, channel;
  @override
  final bool fa;
  final String assessment;
  final bool showChannelHeader;
  final VoidCallback? onOpenChannel, onRemove;

  @override
  Widget build(BuildContext context) {
    final byline = news['byline'];
    final showByline =
        byline is String &&
        byline.trim().isNotEmpty &&
        byline.trim() != (channel['name'] as String? ?? '').trim();
    return Container(
      key: ValueKey('news-card-${news['id']}'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lineColor),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showChannelHeader)
              Material(
                color: Colors.white,
                child: InkWell(
                  onTap: onOpenChannel,
                  child: Padding(
                    key: ValueKey('news-header-${news['id']}'),
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Row(
                      children: [
                        ChannelAvatar(channel: channel, size: 36),
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
                                  color: inkColor,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                assessment,
                                key: ValueKey('news-trust-${news['id']}'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: mutedColor,
                                  fontSize: 11,
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
                            color: mutedColor,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                showChannelHeader ? 8 : 16,
                16,
                18,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (news['image'] is Map)
                    NewsImageView(
                      image: Map<String, dynamic>.from(news['image'] as Map),
                      fa: fa,
                    ),
                  NewsText(text: news['text'] as String? ?? '', fa: fa),
                ],
              ),
            ),
            Container(
              key: ValueKey('news-footer-${news['id']}'),
              padding: const EdgeInsetsDirectional.fromSTEB(16, 2, 6, 2),
              decoration: const BoxDecoration(
                color: softSurfaceColor,
                border: Border(top: BorderSide(color: lineColor)),
              ),
              child: Row(
                children: [
                  if (showByline)
                    Expanded(
                      child: Text(
                        t('نویسنده: $byline', 'By $byline'),
                        key: ValueKey('news-byline-${news['id']}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: mutedColor,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  if (!showByline) const Spacer(),
                  if (!showChannelHeader)
                    Text(
                      channelActivityTime(context, news['createdAtMs'], fa),
                      style: const TextStyle(color: mutedColor, fontSize: 11),
                    ),
                  IconButton(
                    key: ValueKey('news-details-${news['id']}'),
                    tooltip: t('جزئیات خبر', 'News details'),
                    onPressed: () => _details(context),
                    icon: const Icon(
                      Icons.info_outline_rounded,
                      color: tealTextColor,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _details(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: canvasColor,
    builder: (_) => NewsDetailsSheet(
      news: news,
      channel: channel,
      fa: fa,
      route: _arrival(news['receivedVia']),
      onRemove: onRemove,
    ),
  );
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
