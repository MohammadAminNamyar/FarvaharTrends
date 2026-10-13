import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/news_timeline.dart';
import 'channel_tools.dart';

const _ink = Color(0xFF183F51);
const _muted = Color(0xFF5A717C);
const _teal = Color(0xFF267E7B);

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
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.all(17),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (b['image'] is Map)
                                    NewsImageView(
                                      image: Map<String, dynamic>.from(
                                        b['image'] as Map,
                                      ),
                                      fa: fa,
                                    ),
                                  SelectableText(
                                    b['text'] as String? ?? '',
                                    style: const TextStyle(
                                      color: _ink,
                                      fontSize: 15,
                                      height: 1.8,
                                    ),
                                  ),
                                  if (b['byline'] is String &&
                                      (b['byline'] as String).isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 14),
                                      child: Text(
                                        t(
                                          'نویسنده: ${b['byline']}',
                                          'By ${b['byline']}',
                                        ),
                                        key: ValueKey('news-byline-${b['id']}'),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: _muted,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: NewsTimes(news: b, fa: fa),
                                      ),
                                      if (owned)
                                        IconButton(
                                          key: ValueKey(
                                            'remove-news-${b['id']}',
                                          ),
                                          tooltip: t('حذف خبر', 'Remove news'),
                                          onPressed: app.busy
                                              ? null
                                              : () =>
                                                    _remove(b['id'] as String),
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                            size: 19,
                                            color: _muted,
                                          ),
                                        ),
                                    ],
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
                                  if (const {
                                    'ip',
                                    'overlay',
                                    'wifiDirect',
                                    'bluetooth',
                                    'lan',
                                    'local',
                                  }.contains(b['receivedVia']))
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

  String _arrival(dynamic route) => switch (route) {
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
    _ => t('خبر ذخیره‌شده', 'Saved news'),
  };
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
                  color: const Color(0xFFF0F5F5),
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
  const NewsTimes({super.key, required this.news, required this.fa});
  final Map<String, dynamic> news;
  final bool fa;

  String _digits(String text) => fa
      ? text.replaceAllMapped(
          RegExp('[0-9]'),
          (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)],
        )
      : text;

  String _stamp(dynamic value) {
    if (value is! int || value < 0 || value > 253402300799999) {
      return fa ? 'ثبت نشده' : 'Unavailable';
    }
    final date = DateTime.fromMillisecondsSinceEpoch(
      value,
      isUtc: true,
    ).toLocal();
    final zone = date.timeZoneOffset;
    String two(int n) => n.toString().padLeft(2, '0');
    return _digits(
      '${date.year}/${two(date.month)}/${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)} '
      'UTC${zone.isNegative ? '-' : '+'}${two(zone.inMinutes.abs() ~/ 60)}:'
      '${two(zone.inMinutes.abs() % 60)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final local = news['receivedVia'] == 'local';
    return Tooltip(
      message: fa
          ? 'زمان‌ها در منطقهٔ زمانی همین گوشی نمایش داده می‌شوند. ارسال از ساعت نویسنده و دریافت از ساعت این گوشی است؛ اختلافشان زمان قطعی انتقال نیست.'
          : 'Both times use this phone’s timezone. Sent uses the writer’s clock; received uses this phone’s clock. Their difference is not a measured delivery duration.',
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${fa ? 'ارسال' : 'Sent'}: ${_stamp(news['createdAtMs'])}',
              key: ValueKey('sent-time-${news['id']}'),
              style: const TextStyle(color: _muted, fontSize: 10, height: 1.7),
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
