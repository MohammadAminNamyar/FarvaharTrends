import 'package:flutter/material.dart';

import '../app_controller.dart';

const _ink = Color(0xFF183F51);
const _muted = Color(0xFF5A717C);
const _teal = Color(0xFF267E7B);

/// Sequence is authoritative within a channel, even after out-of-order catch-up.
int compareChannelNews(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aSequence = a['sequence'];
  final bSequence = b['sequence'];
  if (aSequence is int && bSequence is int && aSequence != bSequence) {
    return bSequence.compareTo(aSequence);
  }
  final time = (b['createdAtMs'] as int? ?? 0).compareTo(
    a['createdAtMs'] as int? ?? 0,
  );
  return time != 0 ? time : '${a['id']}'.compareTo('${b['id']}');
}

String channelActivityTime(BuildContext context, dynamic value, bool fa) {
  if (value is! int || value.abs() > 8640000000000000) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final text = day == today
      ? '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'
      : day == DateTime(today.year, today.month, today.day - 1)
      ? (fa ? 'دیروز' : 'Yesterday')
      : MaterialLocalizations.of(context).formatShortDate(date);
  return fa
      ? text.replaceAllMapped(
          RegExp('[0-9]'),
          (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)],
        )
      : text;
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

class ChannelOptions extends StatelessWidget {
  const ChannelOptions({
    super.key,
    required this.channel,
    required this.fa,
    required this.trusted,
    required this.busy,
    required this.onSelected,
  });
  final Map<String, dynamic> channel;
  final bool fa, trusted, busy;
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

class _ChannelNewsPageState extends State<ChannelNewsPage> {
  bool savingTrust = false;
  String? trustError;
  AppController get app => widget.app;
  bool get fa => app.languageCode != 'en';
  String t(String f, String e) => fa ? f : e;

  Future<void> _action(String action, Map<String, dynamic> channel) async {
    if (app.busy || savingTrust) return;
    if (action == 'identity') {
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
      final followed = app.isChannelFollowed(widget.channelId);
      final trusted = app.isChannelTrusted(widget.channelId);
      final news =
          (app.snapshot['bulletins'] as List? ?? const [])
              .cast<Map<String, dynamic>>()
              .where((b) => b['channelId'] == widget.channelId)
              .toList()
            ..sort(compareChannelNews);
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
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.all(17),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SelectableText(
                                    b['text'] as String? ?? '',
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 15,
                                      height: 1.8,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    channelActivityTime(
                                      context,
                                      b['createdAtMs'],
                                      fa,
                                    ),
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    t(
                                      'امضای دیجیتال معتبر · خبر عمومی',
                                      'Valid digital signature · public news',
                                    ),
                                    style: const TextStyle(
                                      color: _teal,
                                      fontSize: 10,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _arrival(b['receivedVia']),
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
            child: owned
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

  String _arrival(dynamic route) => switch (route) {
    'ip' => t(
      'دریافت از مسیر اینترنت / شبکهٔ داخلی',
      'Received via Internet / domestic IP',
    ),
    'lan' => t('دریافت از وای‌فای محلی', 'Received via local Wi-Fi'),
    'wifiDirect' => t('دریافت از وای‌فای مستقیم', 'Received via Wi-Fi Direct'),
    'bluetooth' => t('دریافت از بلوتوث', 'Received via Bluetooth'),
    'local' => t('منتشرشده در همین دستگاه', 'Published on this device'),
    _ => t(
      'مسیر دریافت این خبر قدیمی ثبت نشده است',
      'Arrival path was not recorded for this older item',
    ),
  };
}
