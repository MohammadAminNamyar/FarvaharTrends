/// The reader's main screen: header, tab bar and the per-tab list views.
///
/// Tab-level state (selected tab, news filter, channel search and switch,
/// pending trust saves) lives here so it survives switching tabs; each tab's
/// items come from `ConnectionView`, `ChannelsView` and `NewsFeedView`.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/snapshot_dto.dart';
import 'channel_tools.dart';
import 'channel_views.dart';
import 'channels_view.dart';
import 'compose_news_page.dart';
import 'connection_view.dart';
import 'create_channel_page.dart';
import 'legacy_diagnostics.dart';
import 'localization.dart';
import 'news_channel_picker.dart';
import 'news_feed_view.dart';
import 'reader_widgets.dart';
import 'temporary_log.dart';
import 'theme.dart';

class ReaderHome extends StatefulWidget {
  const ReaderHome({super.key, required this.app, required this.animateRadar});
  final AppController app;
  final bool animateRadar;
  @override
  State<ReaderHome> createState() => _ReaderState();
}

class _ReaderState extends State<ReaderHome>
    with WidgetsBindingObserver, Localized {
  int tab = 0;
  String? filter;
  String? trustPendingChannelId;
  String? trustErrorChannelId;
  bool discoverChannels = false;
  final channelSearch = TextEditingController();
  AppController get app => widget.app;
  @override
  bool get fa => isFarsiLanguage(app.languageCode);
  Snapshot get snapshot => Snapshot.fromJson(app.snapshot);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_reconcileNewsSelection);
  }

  @override
  void didUpdateWidget(covariant ReaderHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != app) {
      oldWidget.app.removeListener(_reconcileNewsSelection);
      app.addListener(_reconcileNewsSelection);
      _reconcileNewsSelection();
    }
  }

  void _reconcileNewsSelection() {
    if (filter != null &&
        !followedChannels(app, snapshot).any((c) => c.id == filter)) {
      setState(() => filter = null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_reconcileNewsSelection);
    channelSearch.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !app.loading &&
        app.identity != null) {
      app.perform(app.refresh);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 17, 16, 18),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/brand/logo.jpg',
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: fa
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Text(
                          t('پرشین‌ترند', 'PersianTrend'),
                          maxLines: 1,
                          style: const TextStyle(
                            color: inkColor,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t('خبر، از مردم به مردم', 'INDEPENDENT BY DESIGN'),
                        style: TextStyle(
                          color: mutedColor,
                          fontSize: fa ? 10 : 7.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: fa ? 0 : 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  key: const ValueKey('language-switch'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(36, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  onPressed: app.busy
                      ? null
                      : () => app.perform(
                          () => app.setLanguageCode(fa ? 'en' : 'fa'),
                        ),
                  child: Text(
                    fa ? 'EN' : 'فارسی',
                    style: const TextStyle(
                      fontFamily: 'Vazirmatn',
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('reader-settings'),
                  tooltip: t('تنظیمات خبرخوان', 'Reader settings'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    useSafeArea: true,
                    isScrollControlled: true,
                    builder: (context) => AnimatedBuilder(
                      animation: app,
                      builder: (context, _) => SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        child: ReaderSettingsCard(app: app),
                      ),
                    ),
                  ),
                  icon: const Icon(
                    Icons.notifications_none_rounded,
                    color: mutedColor,
                    size: 21,
                  ),
                ),
                IconButton(
                  key: const ValueKey('advanced-diagnostics'),
                  tooltip: t('ابزارهای پیشرفته', 'Advanced diagnostics'),
                  onPressed: _advanced,
                  icon: const Icon(
                    Icons.tune_rounded,
                    color: mutedColor,
                    size: 21,
                  ),
                ),
              ],
            ),
          ),
          if (app.loading)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tealColor,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      t(
                        'در حال آماده‌سازی اتصال…',
                        'Preparing your connection…',
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                color: tealColor,
                onRefresh: () => app.perform(app.refresh),
                child: Builder(
                  builder: (context) {
                    if (tab == 3) return TemporaryLogView(app: app);
                    final snapshot = this.snapshot;
                    final items = <Widget>[
                      if (app.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 15),
                          child: ReaderNote(
                            Icons.error_outline_rounded,
                            t('این کار کامل نشد', 'That action did not finish'),
                            app.error!,
                          ),
                        ),
                      ...switch (tab) {
                        0 => ConnectionView(
                          app: app,
                          snapshot: snapshot,
                          fa: fa,
                          animateRadar: widget.animateRadar,
                          onExploreNews: () => setState(() => tab = 2),
                        ).build(context),
                        1 => ChannelsView(
                          app: app,
                          snapshot: snapshot,
                          fa: fa,
                          discoverChannels: discoverChannels,
                          channelSearch: channelSearch,
                          trustPendingChannelId: trustPendingChannelId,
                          trustErrorChannelId: trustErrorChannelId,
                          onSearchChanged: () => setState(() {}),
                          onDiscoverChanged: (value) =>
                              setState(() => discoverChannels = value),
                          onCreateChannel: _createChannel,
                          onManageBlocked: _manageBlocked,
                          onOpenChannel: _openChannel,
                          onPublish: _publish,
                          onIdentity: _channelIdentity,
                          onBlock: _blockChannel,
                          onSetTrust: _setChannelTrust,
                        ).build(context),
                        _ => NewsFeedView(
                          app: app,
                          snapshot: snapshot,
                          fa: fa,
                          filter: filter,
                          onChooseChannel: _chooseNewsChannel,
                          onCompose: _chooseChannel,
                          onDiscoverChannels: () => setState(() {
                            tab = 1;
                            discoverChannels = true;
                          }),
                          onOpenChannel: _openChannel,
                        ).build(context),
                      },
                    ];
                    return ListView.builder(
                      key: ValueKey('reader-$tab'),
                      padding: EdgeInsets.fromLTRB(
                        tab == 1 ? 12 : 22,
                        4,
                        tab == 1 ? 12 : 22,
                        28,
                      ),
                      itemCount: items.length,
                      itemBuilder: (context, index) => items[index],
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    ),
    bottomNavigationBar: DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: lineColor)),
      ),
      child: NavigationBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        height: 74,
        selectedIndex: tab,
        indicatorColor: tealColor.withValues(alpha: .12),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: fa ? 'Vazirmatn' : 'Manrope',
            fontSize: 11,
            color: s.contains(WidgetState.selected) ? inkColor : mutedColor,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w800
                : FontWeight.w500,
          ),
        ),
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.radar_rounded, size: 22),
            label: t('اتصال', 'Connection'),
          ),
          NavigationDestination(
            icon: Badge(
              label: Text(n(app.unreadCount)),
              isLabelVisible: app.unreadCount > 0,
              child: const Icon(Icons.forum_outlined, size: 21),
            ),
            label: t('کانال‌ها', 'Channels'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.article_outlined, size: 22),
            label: t('خبرها', 'News'),
          ),
          NavigationDestination(
            key: const ValueKey('temporary-log-tab'),
            icon: const Icon(Icons.history_rounded, size: 22),
            label: t('گزارش موقت', 'Temporary log'),
          ),
        ],
      ),
    ),
  );

  Future<void> _setChannelTrust(String id, bool trusted) async {
    if (app.busy) return;
    setState(() {
      trustPendingChannelId = id;
      trustErrorChannelId = null;
    });
    await app.perform(
      () => trusted ? app.trustChannel(id) : app.untrustChannel(id),
    );
    if (!mounted) return;
    setState(() {
      trustPendingChannelId = null;
      trustErrorChannelId = app.error == null ? null : id;
    });
  }

  Future<void> _channelIdentity(ChannelItem channel) =>
      showChannelIdentity(context, fa: fa, channel: channel);

  Future<void> _blockChannel(ChannelItem channel) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(t('مسدودکردن این کانال؟', 'Block this channel?')),
        content: Text(
          t(
            'کانال و خبرهای آن در این دستگاه پنهان می‌شوند و دیگر دنبال نمی‌شوند. علامت اعتماد خصوصی شما هم پاک می‌شود. خبرهای عمومیِ ذخیره‌شده ممکن است همچنان بازنشر شوند.',
            'Hide this channel and its news on this device, stop following it and clear your private trust mark. Cached public news may still be relayed.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(t('انصراف', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(t('مسدودکردن', 'Block')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    final id = channel.id;
    await app.perform(() => app.blockChannel(id));
    if (mounted && app.error == null) {
      setState(() {
        if (filter == id) filter = null;
        if (trustErrorChannelId == id) trustErrorChannelId = null;
      });
    }
  }

  Future<void> _manageBlocked() =>
      showBlockedChannels(context, app: app, fa: fa);

  Future<void> _chooseNewsChannel() async {
    final result = await showModalBottomSheet<NewsChannelSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(sheet).height * .82, 720),
          child: NewsChannelPicker(app: app, selection: () => filter),
        ),
      ),
    );
    if (!mounted || result == null) return;
    final id = result.channelId;
    setState(() {
      filter =
          id != null && followedChannels(app, snapshot).any((c) => c.id == id)
          ? id
          : null;
    });
  }

  Future<void> _createChannel() async {
    final before = snapshot.channels.map((c) => c.id).toSet();
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CreateChannelPage(app: app)),
    );
    if (created == true && mounted) {
      setState(() {
        tab = 1;
        discoverChannels = false;
        channelSearch.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 12),
          action: SnackBarAction(
            label: t('ذخیرهٔ بازیابی', 'Save recovery'),
            onPressed: () {
              final added = snapshot.channels
                  .where((c) => !before.contains(c.id))
                  .firstOrNull;
              if (added != null) {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChannelToolsPage(app: app, channelId: added.id),
                  ),
                );
              }
            },
          ),
          content: Text(
            t(
              'کانال روی این دستگاه ساخته شد.',
              'Channel created on this device.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _chooseChannel(List<ChannelItem> owned) async {
    if (owned.isEmpty) return;
    await _openComposer(owned, owned.first.id);
  }

  Future<void> _publish(ChannelItem channel) async {
    final owned = publishableChannels(app, snapshot);
    await _openComposer(owned, channel.id);
  }

  Future<void> _openChannel(ChannelItem channel) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ChannelNewsPage(
            app: app,
            channelId: channel.id,
            onIdentity: _channelIdentity,
            onBlock: _blockChannel,
            onPublish: (selected) => _openComposer(
              publishableChannels(app, snapshot),
              selected.id,
              returnToFeed: false,
            ),
          ),
        ),
      );

  Future<void> _openComposer(
    List<ChannelItem> owned,
    String selectedId, {
    bool returnToFeed = true,
  }) async {
    final published = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            ComposeNewsPage(app: app, channels: owned, selectedId: selectedId),
      ),
    );
    if (published != null && mounted) {
      if (returnToFeed) {
        setState(() {
          tab = 2;
          filter = published;
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'خبر امضا و روی این دستگاه ذخیره شد؛ دریافت دیگران به اتصال نیاز دارد.',
              'Signed and saved on this device. Delivery needs a connection.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _advanced() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (page) => Scaffold(
        appBar: AppBar(
          title: Text(t('ابزارهای پیشرفته', 'Advanced diagnostics')),
          backgroundColor: canvasColor,
        ),
        body: LegacyDiagnosticsPage(app: app),
      ),
    ),
  );
}
