/// The "Channels" tab: followed and discovered channels, search, trust and
/// block actions, plus the identity and blocked-channel sheets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/snapshot_dto.dart';
import 'channel_tools.dart';
import 'channel_views.dart';
import 'localization.dart';
import 'reader_widgets.dart';
import 'shared_widgets.dart';
import 'theme.dart';

/// Builds the Channels tab's list items. List state (search text, the
/// Following/Discover switch, pending trust saves) stays on the shell so it
/// survives tab changes; this class only reads it and reports changes back.
class ChannelsView with Localized {
  const ChannelsView({
    required this.app,
    required this.snapshot,
    required this.fa,
    required this.discoverChannels,
    required this.channelSearch,
    required this.trustPendingChannelId,
    required this.trustErrorChannelId,
    required this.onSearchChanged,
    required this.onDiscoverChanged,
    required this.onCreateChannel,
    required this.onManageBlocked,
    required this.onOpenChannel,
    required this.onPublish,
    required this.onIdentity,
    required this.onBlock,
    required this.onSetTrust,
  });
  final AppController app;
  final Snapshot snapshot;
  @override
  final bool fa;
  final bool discoverChannels;
  final TextEditingController channelSearch;
  final String? trustPendingChannelId, trustErrorChannelId;
  final VoidCallback onSearchChanged, onCreateChannel, onManageBlocked;
  final ValueChanged<bool> onDiscoverChanged;
  final ValueChanged<ChannelItem> onOpenChannel, onPublish, onIdentity, onBlock;
  final void Function(String id, bool trusted) onSetTrust;

  List<Widget> build(BuildContext context) {
    final available = snapshot.channels
        .where((c) => !app.isChannelBlocked(c.id))
        .toList();
    final latest = <String, NewsItem>{};
    for (final bulletin in orderNewsItems(snapshot.bulletins)) {
      final id = bulletin.raw['channelId'] as String?;
      if (id == null) continue;
      latest.putIfAbsent(id, () => bulletin);
    }
    final source = discoverChannels
        ? available
        : followedChannels(app, snapshot);
    final query = normalizeSearchText(channelSearch.text);
    final visible =
        source
            .where(
              (c) =>
                  query.isEmpty ||
                  normalizeSearchText('${c.name} ${c.id} ${c.ownerId}')
                      .contains(query),
            )
            .toList()
          ..sort((a, b) {
            final aTime = latest[a.id]?.createdAtMs ?? 0;
            final bTime = latest[b.id]?.createdAtMs ?? 0;
            final order = bTime.compareTo(aTime);
            return order != 0
                ? order
                : normalizeSearchText('${a.name} ${a.id}')
                      .compareTo(normalizeSearchText('${b.name} ${b.id}'));
          });
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                t('کانال‌ها', 'Channels'),
                style: const TextStyle(
                  color: inkColor,
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('create-channel'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: TextStyle(
                  fontFamily: fa ? 'Vazirmatn' : 'Manrope',
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: app.busy || app.identity == null
                  ? null
                  : onCreateChannel,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(t('ساخت کانال', 'Create a channel')),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: TextButton.icon(
          key: const ValueKey('channel-tools'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => ChannelToolsPage(app: app)),
          ),
          icon: const Icon(Icons.key_rounded, size: 17),
          label: Text(t('بازیابی و همکاری', 'Recovery & collaboration')),
        ),
      ),
      TextField(
        key: const ValueKey('channel-search'),
        controller: channelSearch,
        onChanged: (_) => onSearchChanged(),
        decoration: InputDecoration(
          isDense: true,
          hintText: t(
            'جست‌وجو با نام یا شناسهٔ کانال',
            'Search by name or channel ID',
          ),
          hintStyle: const TextStyle(fontSize: 12),
          prefixIcon: const Icon(Icons.search_rounded, size: 21),
          suffixIcon: channelSearch.text.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('clear-channel-search'),
                  tooltip: t('پاک‌کردن جست‌وجو', 'Clear search'),
                  onPressed: () {
                    channelSearch.clear();
                    onSearchChanged();
                  },
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
        ),
      ),
      const SizedBox(height: 12),
      SegmentedButton<bool>(
        key: const ValueKey('channel-sections'),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: TextStyle(
            fontFamily: fa ? 'Vazirmatn' : 'Manrope',
            fontFamilyFallback: const ['Vazirmatn', 'Manrope'],
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        segments: [
          ButtonSegment(
            value: false,
            label: Text(t('دنبال‌شده‌ها', 'Following')),
          ),
          ButtonSegment(
            value: true,
            label: Text(t('کشف کانال‌ها', 'Discover')),
          ),
        ],
        selected: {discoverChannels},
        onSelectionChanged: (value) => onDiscoverChanged(value.first),
      ),
      if (app.blockedChannelIds.isNotEmpty)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const ValueKey('manage-blocked-channels'),
            onPressed: onManageBlocked,
            icon: const Icon(Icons.block_rounded, size: 16),
            label: Text(t('کانال‌های مسدودشده', 'Manage blocked')),
          ),
        ),
      const SizedBox(height: 14),
      if (visible.isEmpty) ...[
        ReaderEmpty(
          Icons.campaign_outlined,
          query.isNotEmpty
              ? t('کانالی پیدا نشد', 'No matching channels')
              : discoverChannels
              ? t('هنوز کانالی پیدا نشده', 'No channels discovered yet')
              : t('خبرخوانتان را انتخاب کنید', 'Make this feed yours'),
          query.isNotEmpty
              ? t(
                  'نام یا شناسهٔ دیگری را امتحان کنید.',
                  'Try another name or ID.',
                )
              : discoverChannels
              ? t(
                  'کانال‌ها پس از اتصال به همتاها ظاهر می‌شوند. می‌توانید کانال خودتان را بسازید.',
                  'Channels appear when peers connect. You can also create your own.',
                )
              : t(
                  'از بخش کشف، کانال دلخواهتان را دنبال کنید. کانال‌های خودتان خودکار دنبال می‌شوند.',
                  'Follow a channel from Discover. Your own channels are followed automatically.',
                ),
        ),
        if (!discoverChannels && query.isEmpty)
          TextButton.icon(
            key: const ValueKey('discover-from-empty'),
            onPressed: () => onDiscoverChanged(true),
            icon: const Icon(Icons.explore_outlined),
            label: Text(t('کشف کانال‌ها', 'Discover channels')),
          ),
      ] else
        ...visible.map((c) => _channelCard(context, c, latest[c.id])),
    ];
  }

  Widget _channelCard(
    BuildContext context,
    ChannelItem channel,
    NewsItem? latest,
  ) {
    final id = channel.id;
    final owned = channel.owned;
    final followed = app.isChannelFollowed(id);
    final trusted = app.isChannelTrusted(id);
    final description = channel.description;
    final preview =
        latest?.text ??
        (description.isEmpty
            ? t('هنوز خبری منتشر نشده', 'No news here yet')
            : description);
    return Material(
      key: ValueKey('channel-card-$id'),
      color: Colors.white,
      child: InkWell(
        key: ValueKey('open-channel-$id'),
        onTap: () => onOpenChannel(channel),
        child: Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: lineColor)),
          ),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 13, 0, 13),
          child: Row(
            children: [
              ChannelAvatar(channel: channel.raw),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: inkColor,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (app.unreadFor(id) > 0) ...[
                          const SizedBox(width: 6),
                          Badge(
                            key: ValueKey('unread-$id'),
                            label: Text(n(app.unreadFor(id))),
                          ),
                        ],
                        if (latest != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            channelActivityTime(
                              context,
                              latest.createdAtMs,
                              fa,
                            ),
                            style: const TextStyle(
                              color: mutedColor,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview.replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: mutedColor, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: t(
                        'انتخاب خصوصی شماست؛ تأیید درستی خبر نیست.',
                        'Your private choice; not proof that news is true.',
                      ),
                      child: Text(
                        channelAssessment(app, snapshot, id, fa: fa),
                        key: ValueKey('channel-trust-$id'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: owned || trusted ? tealTextColor : mutedColor,
                        ),
                      ),
                    ),
                    if (trustPendingChannelId == id)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          key: ValueKey('trust-pending-$id'),
                          children: [
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                t(
                                  'در حال ذخیرهٔ انتخاب شما…',
                                  'Saving your choice…',
                                ),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: mutedColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (trustErrorChannelId == id)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          t(
                            'انتخاب شما ذخیره نشد؛ دوباره امتحان کنید.',
                            'Your choice was not saved. Try again.',
                          ),
                          key: ValueKey('trust-error-$id'),
                          style: const TextStyle(
                            fontSize: 10,
                            color: pinkColor,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (owned || channel.canPublish)
                IconButton(
                  key: ValueKey('channel-compose-$id'),
                  tooltip: t('نوشتن خبر', 'Write news'),
                  onPressed: app.busy ? null : () => onPublish(channel),
                  icon: const Icon(
                    Icons.edit_note_rounded,
                    color: tealTextColor,
                    size: 22,
                  ),
                )
              else
                IconButton(
                  key: ValueKey('follow-$id'),
                  tooltip: followed
                      ? t('دنبال نکردن', 'Unfollow')
                      : t('دنبال‌کردن', 'Follow'),
                  onPressed: app.busy
                      ? null
                      : () => app.perform(
                          () => followed
                              ? app.unfollowChannel(id)
                              : app.followChannel(id),
                        ),
                  icon: Icon(
                    followed
                        ? Icons.check_circle_outline_rounded
                        : Icons.add_circle_outline_rounded,
                    color: tealTextColor,
                    size: 22,
                  ),
                ),
              ChannelOptions(
                channel: channel.raw,
                fa: fa,
                trusted: trusted,
                muted: app.isChannelMuted(id),
                busy: app.busy,
                onSelected: (value) {
                  if (value == 'manage') {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChannelToolsPage(app: app, channelId: id),
                      ),
                    );
                  }
                  if (value == 'mute') {
                    app.perform(
                      () => app.setChannelMuted(id, !app.isChannelMuted(id)),
                    );
                  }
                  if (value == 'identity') onIdentity(channel);
                  if (value == 'block') onBlock(channel);
                  if (value == 'trust') onSetTrust(id, true);
                  if (value == 'untrust') onSetTrust(id, false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet with the full publisher fingerprint and channel ID.
Future<void> showChannelIdentity(
  BuildContext context, {
  required bool fa,
  required ChannelItem channel,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(channel.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            tr(
              fa,
              'امضا مالکیت کلید را نشان می‌دهد، نه هویت واقعی یا درستی خبر را.',
              'A signature proves key possession, not human identity or factual accuracy.',
            ),
          ),
          const SizedBox(height: 18),
          Text(tr(fa, 'اثر انگشت کامل ناشر', 'Full publisher fingerprint')),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Fingerprint(channel.ownerId),
          ),
          const SizedBox(height: 16),
          Text(tr(fa, 'شناسهٔ کامل کانال', 'Full channel ID')),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Fingerprint(channel.id),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: channel.id));
              if (sheet.mounted) {
                ScaffoldMessenger.of(sheet).showSnackBar(
                  SnackBar(
                    content: Text(
                      tr(fa, 'شناسهٔ کانال کپی شد', 'Channel ID copied'),
                    ),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: Text(tr(fa, 'کپی شناسهٔ کانال', 'Copy channel ID')),
          ),
        ],
      ),
    ),
  ),
);

/// Bottom sheet listing blocked channels with an unblock action per row.
Future<void> showBlockedChannels(
  BuildContext context, {
  required AppController app,
  required bool fa,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) => AnimatedBuilder(
    animation: app,
    builder: (_, _) {
      final ids = app.blockedChannelIds.toList()..sort();
      final snapshot = Snapshot.fromJson(app.snapshot);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(fa, 'کانال‌های مسدودشده', 'Blocked channels'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                tr(
                  fa,
                  'رفع مسدودی، کانال دیگران را خودکار دنبال نمی‌کند.',
                  'Unblocking does not automatically follow someone else’s channel.',
                ),
              ),
              const SizedBox(height: 16),
              if (ids.isEmpty)
                Text(
                  tr(fa, 'کانال مسدودشده‌ای ندارید.', 'No blocked channels.'),
                ),
              for (final id in ids) ...[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snapshot.channelById(id)?.name ?? _idPreview(id),
                        style: const TextStyle(
                          color: inkColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        _idPreview(id),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 10),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        key: ValueKey('unblock-$id'),
                        onPressed: app.busy
                            ? null
                            : () => app.perform(() => app.unblockChannel(id)),
                        child: Text(tr(fa, 'رفع مسدودی', 'Unblock')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      );
    },
  ),
);

String _idPreview(String id) => id.length > 20
    ? '${id.substring(0, 10)}…${id.substring(id.length - 8)}'
    : id;
