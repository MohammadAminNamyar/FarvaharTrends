import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/news_timeline.dart';
import 'channel_tools.dart';
import 'news_components.dart';
import 'news_card.dart';
export 'news_components.dart';

const _muted = Color(0xFF5A717C);
const _teal = Color(0xFF267E7B);

class ChannelOptions extends StatelessWidget {
  const ChannelOptions({
    super.key,
    required this.channel,
    required this.fa,
    required this.trusted,
    required this.busy,
    this.muted = false,
    required this.onSelected,
  });
  final Map<String, dynamic> channel;
  final bool fa, trusted, busy, muted;
  final ValueChanged<String> onSelected;
  String t(String f, String e) => fa ? f : e;

  @override
  Widget build(BuildContext context) {
    final id = channel['id'] as String;
    return IconButton(
      key: ValueKey('channel-menu-$id'),
      tooltip: t('گزینه‌های کانال', 'Channel options'),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 48),
      icon: const Icon(Icons.more_vert_rounded, color: _muted, size: 21),
      onPressed: busy
          ? null
          : () async {
              final anchor = context.findRenderObject()! as RenderBox;
              final overlay =
                  Navigator.of(context).overlay!.context.findRenderObject()!
                      as RenderBox;
              // Capture the position before async saves can reflow the channel list.
              final position = RelativeRect.fromRect(
                Rect.fromPoints(
                  anchor.localToGlobal(Offset.zero, ancestor: overlay),
                  anchor.localToGlobal(
                    anchor.size.bottomRight(Offset.zero),
                    ancestor: overlay,
                  ),
                ),
                Offset.zero & overlay.size,
              );
              final selected = await showMenu<String>(
                context: context,
                position: position,
                items: [
                  if (channel['owned'] == true)
                    PopupMenuItem(
                      value: 'manage',
                      child: Text(
                        t('مدیریت و بازیابی کانال', 'Manage & recover channel'),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'mute',
                    child: Text(
                      muted
                          ? t('فعال‌کردن اعلان کانال', 'Unmute channel')
                          : t('بی‌صدا کردن کانال', 'Mute channel'),
                    ),
                  ),
                  if (channel['owned'] != true)
                    PopupMenuItem(
                      key: ValueKey(
                        '${trusted ? 'untrust' : 'trust'}-channel-$id',
                      ),
                      value: trusted ? 'untrust' : 'trust',
                      child: Text(
                        trusted
                            ? t('برداشتن اعتماد', 'Remove trust')
                            : t(
                                'علامت‌گذاری به‌عنوان مورد اعتماد',
                                'Mark as trusted',
                              ),
                      ),
                    ),
                  PopupMenuItem(
                    value: 'identity',
                    child: Text(
                      t('شناسه و کلید ناشر', 'Channel ID & publisher key'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'block',
                    child: Text(t('مسدودکردن کانال', 'Block channel')),
                  ),
                ],
              );
              if (context.mounted && selected != null) onSelected(selected);
            },
    );
  }
}

class ChannelNewsPage extends StatefulWidget {
  const ChannelNewsPage({
    super.key,
    required this.app,
    required this.channelId,
    required this.onPublish,
    required this.onIdentity,
    required this.onBlock,
  });
  final AppController app;
  final String channelId;
  final Future<void> Function(Map<String, dynamic>) onPublish,
      onIdentity,
      onBlock;

  @override
  State<ChannelNewsPage> createState() => _ChannelNewsPageState();
}

class _ChannelNewsPageState extends State<ChannelNewsPage>
    with WidgetsBindingObserver {
  String _readStamp = '';
  bool _marking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _readStamp = '';
      setState(() {});
    }
  }

  void _markVisible(List<Map<String, dynamic>> news) {
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true || _marking) return;
    final stamp = news.map((v) => v['id']).join(',');
    if (stamp == _readStamp) return;
    _readStamp = stamp;
    _marking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          await app.markChannelRead(widget.channelId);
        }
      } finally {
        _marking = false;
      }
    });
  }

  Future<void> _remove(String id) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('حذف خبر از کانال؟', 'Remove this news?')),
        content: Text(
          t(
            'دستگاه‌های به‌روز پس از دریافت دستور امضاشده، خبر را پنهان می‌کنند و دیگر نمی‌فرستند. نسخه‌های ذخیره‌شده یا تصویربرداری‌شده پاک نمی‌شوند.',
            'Updated devices will hide this post and stop forwarding it when they receive the signed removal. Saved copies and screenshots cannot be erased.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('انصراف', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('حذف خبر', 'Remove news')),
          ),
        ],
      ),
    );
    if (approved == true) {
      await app.perform(
        () => app.channelAction('removePublishedNews', {
          'channelId': widget.channelId,
          'newsId': id,
        }),
      );
    }
  }

  bool savingTrust = false;
  String? trustError;
  AppController get app => widget.app;
  bool get fa => app.languageCode != 'en';
  String t(String f, String e) => fa ? f : e;

  Future<void> _action(String action, Map<String, dynamic> channel) async {
    if (app.busy || savingTrust) return;
    if (action == 'manage') {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              ChannelToolsPage(app: app, channelId: widget.channelId),
        ),
      );
    } else if (action == 'mute') {
      await app.perform(
        () => app.setChannelMuted(
          widget.channelId,
          !app.isChannelMuted(widget.channelId),
        ),
      );
    } else if (action == 'identity') {
      await widget.onIdentity(channel);
    } else if (action == 'block') {
      await widget.onBlock(channel);
      if (mounted && app.isChannelBlocked(widget.channelId)) {
        Navigator.of(context).pop();
      }
    } else if (action == 'trust' || action == 'untrust') {
      setState(() {
        savingTrust = true;
        trustError = null;
      });
      await app.perform(
        () => action == 'trust'
            ? app.trustChannel(widget.channelId)
            : app.untrustChannel(widget.channelId),
      );
      if (!mounted) return;
      setState(() {
        savingTrust = false;
        trustError = app.error == null
            ? null
            : t(
                'انتخاب شما ذخیره نشد؛ دوباره امتحان کنید.',
                'Your choice was not saved. Try again.',
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      final channel = (app.snapshot['channels'] as List? ?? const [])
          .cast<Map<String, dynamic>>()
          .where((c) => c['id'] == widget.channelId)
          .firstOrNull;
      if (channel == null || app.isChannelBlocked(widget.channelId)) {
        return Scaffold(
          appBar: AppBar(),
          body: Center(
            child: Text(t('کانال در دسترس نیست', 'Channel unavailable')),
          ),
        );
      }
      final owned = channel['owned'] == true;
      final canPublish = owned || channel['canPublish'] == true;
      final followed = app.isChannelFollowed(widget.channelId);
      final trusted = app.isChannelTrusted(widget.channelId);
      final news = orderNews(
        (app.snapshot['bulletins'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .where((b) => b['channelId'] == widget.channelId),
      );
      _markVisible(news);
      final assessment = owned
          ? t('کانال شما', 'Your channel')
          : trusted
          ? t('مورد اعتماد شما', 'Trusted by you')
          : t('هنوز ارزیابی نکرده‌اید', 'Not assessed');
      return Scaffold(
        key: ValueKey('channel-page-${widget.channelId}'),
        backgroundColor: const Color(0xFFEDF3F4),
        appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          titleSpacing: 0,
          title: InkWell(
            onTap: () => widget.onIdentity(channel),
            child: Row(
              children: [
                ChannelAvatar(channel: channel, size: 38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        channel['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        assessment,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: _muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            ChannelOptions(
              channel: channel,
              fa: fa,
              trusted: trusted,
              muted: app.isChannelMuted(widget.channelId),
              busy: app.busy || savingTrust,
              onSelected: (v) => _action(v, channel),
            ),
          ],
        ),
        body: Column(
          children: [
            if (savingTrust) const LinearProgressIndicator(minHeight: 2),
            if (trustError != null || app.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  trustError ?? app.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: news.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.campaign_outlined,
                              color: _teal,
                              size: 42,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              t('هنوز خبری منتشر نشده', 'No news here yet'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 17,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              t(
                                'خبرهای ذخیره‌شدهٔ این کانال اینجا نمایش داده می‌شوند.',
                                'Saved news from this channel will appear here.',
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: _muted,
                                height: 1.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('channel-news-list'),
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(14, 20, 14, 14),
                      itemCount: news.length,
                      itemBuilder: (context, index) {
                        final b = news[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: NewsCard(
                            news: b,
                            channel: channel,
                            fa: fa,
                            assessment: assessment,
                            onRemove: owned && !app.busy
                                ? () => _remove(b['id'] as String)
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: canPublish
                ? FilledButton.icon(
                    key: const ValueKey('channel-compose-news'),
                    onPressed: app.busy
                        ? null
                        : () => widget.onPublish(channel),
                    icon: const Icon(Icons.edit_note_rounded),
                    label: Text(t('نوشتن خبر', 'Write news')),
                  )
                : followed
                ? Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(
                            'انتخاب و اعتماد شما خصوصی است.',
                            'Following and trust are private.',
                          ),
                          style: const TextStyle(color: _muted, fontSize: 10),
                        ),
                      ),
                      TextButton(
                        key: ValueKey('channel-follow-${widget.channelId}'),
                        onPressed: app.busy
                            ? null
                            : () => app.perform(
                                () => app.unfollowChannel(widget.channelId),
                              ),
                        child: Text(t('دنبال نکردن', 'Unfollow')),
                      ),
                    ],
                  )
                : FilledButton.icon(
                    key: ValueKey('channel-follow-${widget.channelId}'),
                    onPressed: app.busy
                        ? null
                        : () => app.perform(
                            () => app.followChannel(widget.channelId),
                          ),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('دنبال‌کردن کانال', 'Follow channel')),
                  ),
          ),
        ),
      );
    },
  );
}
