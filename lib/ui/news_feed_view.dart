/// The "News" tab: the followed feed, its channel filter and the composer
/// entry point.
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/snapshot_dto.dart';
import 'localization.dart';
import 'news_card.dart';
import 'reader_widgets.dart';
import 'theme.dart';

/// Builds the News tab's list items. The channel filter lives on the shell
/// so the composer and channel actions can update it.
class NewsFeedView with Localized {
  const NewsFeedView({
    required this.app,
    required this.snapshot,
    required this.fa,
    required this.filter,
    required this.onChooseChannel,
    required this.onCompose,
    required this.onDiscoverChannels,
    required this.onOpenChannel,
  });
  final AppController app;
  final Snapshot snapshot;
  @override
  final bool fa;

  /// Channel id the feed is narrowed to, or null for every followed channel.
  final String? filter;
  final VoidCallback onChooseChannel, onDiscoverChannels;
  final ValueChanged<List<ChannelItem>> onCompose;
  final ValueChanged<ChannelItem> onOpenChannel;

  List<Widget> build(BuildContext context) {
    final following = followedChannels(app, snapshot);
    final selected = following.any((c) => c.id == filter) ? filter : null;
    final feed = snapshot.bulletins.where(
      (b) =>
          b.raw['channelId'] is String &&
          app.isChannelFollowed(b.channelId) &&
          !app.isChannelBlocked(b.channelId),
    );
    final visible = orderNewsItems(
      feed.where((b) => selected == null || b.channelId == selected),
    );
    final owned = publishableChannels(app, snapshot);
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              t('خبرهای شما', 'Your news'),
              style: const TextStyle(
                color: inkColor,
                fontSize: 23,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (owned.isNotEmpty) ...[
            const SizedBox(width: 10),
            FilledButton.icon(
              key: const ValueKey('compose-news'),
              onPressed: app.busy ? null : () => onCompose(owned),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: const Icon(Icons.edit_note_rounded, size: 19),
              label: Text(t('نوشتن خبر', 'Write news')),
            ),
          ],
        ],
      ),
      const SizedBox(height: 8),
      Text(
        t(
          'فقط از کانال‌هایی که دنبال می‌کنید.',
          'Only from the channels you follow.',
        ),
        style: const TextStyle(color: mutedColor, fontSize: 12, height: 1.7),
      ),
      const SizedBox(height: 17),
      if (following.isNotEmpty) ...[
        OutlinedButton(
          key: const ValueKey('news-channel-picker'),
          onPressed: onChooseChannel,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            alignment: AlignmentDirectional.centerStart,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.filter_list_rounded,
                size: 21,
                color: tealTextColor,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected == null
                          ? t(
                              'همهٔ کانال‌های دنبال‌شده',
                              'All followed channels',
                            )
                          : following.firstWhere((c) => c.id == selected).name,
                      key: const ValueKey('news-channel-selection'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: inkColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              const Icon(
                Icons.expand_more_rounded,
                size: 23,
                color: mutedColor,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
      if (visible.isEmpty) ...[
        ReaderEmpty(
          Icons.article_outlined,
          following.isEmpty
              ? t('خبرخوانی به انتخاب شما', 'A feed you choose')
              : t(
                  'هنوز خبری از این کانال‌ها نرسیده',
                  'No news from these channels yet',
                ),
          t(
            'برای دیدن خبر، کانالی را دنبال کنید. دریافت خبرهای تازه به مسیر ارتباطی نیاز دارد.',
            'Follow a channel to see its news. New arrivals need an available connection.',
          ),
        ),
        TextButton.icon(
          key: const ValueKey('news-discover-channels'),
          onPressed: onDiscoverChannels,
          icon: const Icon(Icons.explore_outlined),
          label: Text(t('کشف کانال‌ها', 'Discover channels')),
        ),
      ] else
        ...visible.map((b) {
          final channel =
              snapshot.channelById(b.channelId) ??
              ChannelItem.fromJson({
                'id': b.raw['channelId'] ?? b.raw['id'],
                'name': _bulletinChannelName(b),
              });
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: NewsCard(
              news: b.raw,
              channel: channel.raw,
              fa: fa,
              assessment: channelAssessment(app, snapshot, b.channelId, fa: fa),
              onOpenChannel: () => onOpenChannel(channel),
            ),
          );
        }),
      const SizedBox(height: 17),
      ReaderNote(
        Icons.info_outline_rounded,
        t('منبع را مستقل بررسی کنید.', 'Check the source independently.'),
        t(
          'امضای معتبر، درستی خبر یا هویت واقعی ناشر را تضمین نمی‌کند.',
          'A valid signature does not establish factual accuracy or the publisher’s real-world identity.',
        ),
      ),
    ];
  }

  String _bulletinChannelName(NewsItem bulletin) =>
      snapshot.channelById(bulletin.channelId)?.name ??
      bulletin.raw['channelName'] as String? ??
      t('خبر عمومی', 'Public bulletin');
}
