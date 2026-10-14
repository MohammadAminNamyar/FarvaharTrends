/// Small building blocks and snapshot queries shared by the reader tabs.
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/news_timeline.dart';
import '../core/snapshot_dto.dart';
import 'shared_widgets.dart';
import 'theme.dart';

/// Lower-cased, trimmed search text with Arabic yeh/kaf folded to Persian.
String normalizeSearchText(String value) =>
    value.trim().toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک');

/// Channels this phone follows and has not blocked.
List<ChannelItem> followedChannels(AppController app, Snapshot snapshot) =>
    snapshot.channels
        .where(
          (c) => app.isChannelFollowed(c.id) && !app.isChannelBlocked(c.id),
        )
        .toList();

/// Channels this phone can write to (owned or editor) and has not blocked.
List<ChannelItem> publishableChannels(AppController app, Snapshot snapshot) =>
    snapshot.channels
        .where((c) => (c.owned || c.canPublish) && !app.isChannelBlocked(c.id))
        .toList();

/// Newest first, keeping the typed view over each item.
List<NewsItem> orderNewsItems(Iterable<NewsItem> items) =>
    orderNews(items.map((item) => item.raw)).map(NewsItem.fromJson).toList();

/// The private trust label shown under a channel name and on news cards.
String channelAssessment(
  AppController app,
  Snapshot snapshot,
  String id, {
  required bool fa,
}) {
  if (snapshot.channels.any(
    (channel) => channel.id == id && (channel.owned || channel.canPublish),
  )) {
    return fa ? 'کانال شما' : 'Your channel';
  }
  return app.isChannelTrusted(id)
      ? (fa ? 'مورد اعتماد شما' : 'Trusted by you')
      : (fa ? 'هنوز ارزیابی نکرده‌اید' : 'Not assessed');
}

/// Tab headline and lede.
class ReaderIntro extends StatelessWidget {
  const ReaderIntro(this.title, this.body, {super.key});
  final String title, body;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(height: 1.5),
      ),
      const SizedBox(height: 8),
      Text(
        body,
        style: const TextStyle(color: mutedColor, fontSize: 12, height: 1.9),
      ),
    ],
  );
}

/// Empty-state card with an icon, title and explanation.
class ReaderEmpty extends StatelessWidget {
  const ReaderEmpty(this.icon, this.title, this.body, {super.key});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => AppCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 19),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: canvasColor,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Icon(icon, color: tealColor, size: 28),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: inkColor,
              fontWeight: FontWeight.w800,
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: mutedColor,
              fontSize: 11,
              height: 1.9,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Teal-tinted callout with an icon, title and body.
class ReaderNote extends StatelessWidget {
  const ReaderNote(
    this.icon,
    this.title,
    this.body, {
    super.key,
    this.onDismiss,
    this.dismissLabel,
  });
  final IconData icon;
  final String title, body;

  /// When set, a close button hides the note; [dismissLabel] is its tooltip.
  final VoidCallback? onDismiss;
  final String? dismissLabel;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: tealColor.withValues(alpha: .065),
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: tealColor.withValues(alpha: .17)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: tealTextColor, size: 19),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: inkColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                  height: 1.8,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: const TextStyle(
                  color: mutedColor,
                  fontSize: 10.5,
                  height: 1.9,
                ),
              ),
            ],
          ),
        ),
        if (onDismiss != null)
          IconButton(
            key: const ValueKey('dismiss-note'),
            tooltip: dismissLabel,
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.close_rounded, color: mutedColor, size: 18),
          ),
      ],
    ),
  );
}
