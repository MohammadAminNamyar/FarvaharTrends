import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pilot_platform/pilot_platform.dart';

import '../app_controller.dart';
import 'channel_views.dart';
import 'news_card.dart';
import 'channel_tools.dart';
import '../core/media_store.dart';
import '../core/delivery_mode.dart';
import '../core/models.dart';
import '../core/news_timeline.dart';

const _canvas = Color(0xFFF4F7F8);
const _ink = Color(0xFF183F51);
const _teal = Color(0xFF3DBAB6);
const _pink = Color(0xFFE80E7C);
const _muted = Color(0xFF5A717C);
const _tealText = Color(0xFF267E7B);
const _line = Color(0xFFE2E9EC);

class PersianTrendApp extends StatefulWidget {
  const PersianTrendApp({
    super.key,
    this.controller,
    this.initialize = true,
    this.animateRadar = true,
  });
  final AppController? controller;
  final bool initialize;
  final bool animateRadar;
  @override
  State<PersianTrendApp> createState() => _AppState();
}

class _AppState extends State<PersianTrendApp> {
  late final AppController app = widget.controller ?? AppController();
  @override
  void initState() {
    super.initState();
    if (widget.initialize) app.initialize();
  }

  @override
  void dispose() {
    if (widget.controller == null) app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => MaterialApp(
      title: 'PersianTrend',
      debugShowCheckedModeBanner: false,
      locale: Locale(app.languageCode),
      supportedLocales: const [Locale('fa'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => _Language(
        fa: app.languageCode != 'en',
        child: Directionality(
          textDirection: app.languageCode == 'en'
              ? TextDirection.ltr
              : TextDirection.rtl,
          child: child!,
        ),
      ),
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
        fontFamilyFallback: const ['Vazirmatn', 'Manrope'],
        scaffoldBackgroundColor: _canvas,
        colorScheme: ColorScheme.fromSeed(seedColor: _ink).copyWith(
          primary: _ink,
          secondary: _teal,
          surface: Colors.white,
          error: _pink,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            fontSize: 27,
            fontWeight: FontWeight.w800,
            color: _ink,
            height: 1.22,
            letterSpacing: -.8,
          ),
          titleLarge: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
          titleMedium: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
          bodyMedium: TextStyle(fontSize: 13, color: _muted, height: 1.65),
          bodySmall: TextStyle(fontSize: 11, color: _muted, height: 1.6),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: TextStyle(
              fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            side: const BorderSide(color: _line),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            textStyle: TextStyle(
              fontFamily: app.languageCode == 'en' ? 'Manrope' : 'Vazirmatn',
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _teal, width: 1.5),
          ),
          labelStyle: const TextStyle(color: _muted, fontSize: 13),
        ),
        dividerColor: _line,
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: _ink,
        ),
      ),
      home: RepaintBoundary(
        key: const ValueKey('pilot-preview'),
        child: _ReaderHome(app: app, animateRadar: widget.animateRadar),
      ),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.app});
  final AppController app;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with WidgetsBindingObserver {
  int tab = 0;
  AppController get app => widget.app;
  List<Map<String, dynamic>> get peers => _maps(app.snapshot['peers']);
  List<Map<String, dynamic>> get trials => _maps(app.snapshot['trials']);
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
    if (state == AppLifecycleState.resumed &&
        !app.loading &&
        app.identity != null) {
      app.perform(app.refresh);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 21, 16, 23),
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
                  const SizedBox(width: 11),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Localized(
                          'PersianTrend',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: _ink,
                            letterSpacing: -.7,
                          ),
                        ),
                        SizedBox(height: 3),
                        _Localized(
                          'INDEPENDENT BY DESIGN',
                          style: TextStyle(
                            fontSize: 7.5,
                            fontWeight: FontWeight.w800,
                            color: _muted,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const _Tag('PILOT', color: _pink),
                  IconButton(
                    tooltip: 'Pilot guide',
                    onPressed: _guide,
                    icon: const Icon(
                      Icons.help_outline_rounded,
                      size: 21,
                      color: _muted,
                    ),
                  ),
                ],
              ),
            ),
            if (app.loading)
              const Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: _teal, strokeWidth: 2),
                      SizedBox(height: 20),
                      _Localized('Preparing your device identity…'),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: RefreshIndicator(
                  color: _teal,
                  onRefresh: () => app.perform(app.refresh),
                  child: ListView(
                    key: ValueKey('tab-$tab'),
                    padding: const EdgeInsets.fromLTRB(22, 6, 22, 28),
                    children: [
                      if (app.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _error(app.error!),
                        ),
                      ...switch (tab) {
                        0 => _overview(),
                        1 => _peerPage(),
                        2 => _bulletinPage(),
                        _ => _resultsPage(),
                      },
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: _line)),
        ),
        child: NavigationBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          height: 74,
          selectedIndex: tab,
          indicatorColor: _teal.withValues(alpha: .12),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontFamily: _Language.isFarsi(context) ? 'Vazirmatn' : 'Manrope',
              fontSize: 10,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: states.contains(WidgetState.selected) ? _ink : _muted,
            ),
          ),
          onDestinationSelected: (value) => setState(() => tab = value),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.space_dashboard_outlined, size: 21),
              selectedIcon: Icon(
                Icons.space_dashboard_rounded,
                size: 21,
                color: _ink,
              ),
              label: _diagnostic(context, 'Overview'),
            ),
            NavigationDestination(
              icon: Icon(Icons.hub_outlined, size: 22),
              selectedIcon: Icon(Icons.hub_rounded, size: 22, color: _ink),
              label: _diagnostic(context, 'Peers'),
            ),
            NavigationDestination(
              icon: Icon(Icons.article_outlined, size: 22),
              selectedIcon: Icon(Icons.article_rounded, size: 22, color: _ink),
              label: _diagnostic(context, 'Bulletins'),
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_rounded, size: 23),
              selectedIcon: Icon(
                Icons.bar_chart_rounded,
                size: 23,
                color: _ink,
              ),
              label: _diagnostic(context, 'Results'),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _overview() {
    final connected = _number(app.snapshot['connectedCount']);
    final confirmed = trials.fold<int>(
      0,
      (n, item) => n + _number(item['confirmed']),
    );
    return [
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _ink,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Stack(
          children: [
            const Positioned(
              right: -78,
              top: -65,
              bottom: -60,
              width: 290,
              child: CustomPaint(painter: _NetworkPainter()),
            ),
            Padding(
              padding: const EdgeInsets.all(25),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.circle, color: _teal, size: 6),
                      SizedBox(width: 7),
                      Expanded(
                        child: _Localized(
                          'A SMALL SIGNAL. A SHARED CONNECTION.',
                          style: TextStyle(
                            fontSize: 7.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.05,
                            color: Color(0xFFB8D5DC),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const SizedBox(
                    width: 260,
                    child: _Localized(
                      'News worth keeping connected.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 29,
                        height: 1.18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.9,
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  const _Localized(
                    'From peer to peer.\nVerified at every stop.',
                    style: TextStyle(
                      color: Color(0xFFB8D5DC),
                      fontSize: 12,
                      height: 1.65,
                    ),
                  ),
                  const SizedBox(height: 25),
                  Row(
                    children: [
                      Container(width: 21, height: 2, color: _teal),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: _Localized(
                          'NO REQUIRED CENTRAL SERVER',
                          style: TextStyle(
                            color: Color(0xFFB8D5DC),
                            fontSize: 7.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconTile(
                  app.running
                      ? Icons.sensors_rounded
                      : Icons.sensors_off_rounded,
                  color: app.running ? _teal : _muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Localized(
                        app.running ? 'Receiving is on' : 'Receiving is off',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      _Localized(
                        app.running
                            ? (app.activeMode
                                  ? 'Active Android mode'
                                  : 'Standard comparison mode')
                            : 'Your phone is ready when you are.',
                        style: const TextStyle(fontSize: 10.5, color: _muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: app.running ? _teal : const Color(0xFFC3CFD5),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: app.busy || app.identity == null
                    ? null
                    : () => app.perform(
                        app.running
                            ? app.stop
                            : () => app.start(active: Platform.isAndroid),
                      ),
                icon: app.busy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        app.running
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded,
                        size: 19,
                      ),
                label: _Localized(
                  app.running ? 'Stop receiving' : 'Start receiving',
                ),
              ),
            ),
            if (!app.running)
              Center(
                child: TextButton(
                  onPressed: app.busy || app.identity == null
                      ? null
                      : () => app.perform(() => app.start(active: false)),
                  child: const _Localized(
                    'Try standard mode for comparison',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: _muted),
                  ),
                ),
              ),
            if (app.running)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: _Localized(
                  'Stay connected to a reachable paired peer. Android active mode shows a persistent receiving notification.',
                  style: TextStyle(fontSize: 10.5, color: _muted, height: 1.6),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: _Metric(
              value: '$connected',
              label: 'CONNECTED PEERS',
              icon: Icons.hub_outlined,
              color: _teal,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Metric(
              value: '$confirmed',
              label: 'LOCKED + ≤ 5 MIN',
              icon: Icons.verified_outlined,
              color: _pink,
            ),
          ),
        ],
      ),
      const SizedBox(height: 26),
      const _Section('Your device', 'A few conditions shape every connection.'),
      const SizedBox(height: 13),
      _Card(
        child: Column(
          children: [
            _condition(Icons.wifi_rounded, 'Network', _deviceText('network')),
            const Divider(height: 25),
            _condition(
              Icons.battery_5_bar_rounded,
              'Battery',
              app.device['batteryPercent'] is num
                  ? '${app.device['batteryPercent']}%'
                  : 'Not available',
            ),
            const Divider(height: 25),
            _condition(
              Icons.bolt_rounded,
              'Charging',
              _boolText(
                app.device['charging'],
                yes: 'Connected',
                no: 'Unplugged',
              ),
            ),
            const Divider(height: 25),
            _condition(
              Icons.energy_savings_leaf_outlined,
              'Power saving',
              _boolText(app.device['powerSave'], yes: 'On', no: 'Off'),
            ),
            const Divider(height: 25),
            _condition(
              Icons.shield_outlined,
              'Battery exemption',
              _boolText(
                app.device['batteryExempt'],
                yes: 'Allowed',
                no: 'Not exempt',
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: Platform.isAndroid
                    ? () => app.perform(PilotPlatform.batterySettings)
                    : null,
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: const _Localized('Battery settings'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _callout(
        Icons.route_outlined,
        'A trusted peer still needs a route.',
        'Pairing confirms identity. It cannot make two phones reachable through a provider’s NAT or a blocked network.',
      ),
      const SizedBox(height: 18),
      InkWell(
        onTap: _guide,
        borderRadius: BorderRadius.circular(19),
        child: const _Card(
          child: Row(
            children: [
              _IconTile(Icons.science_outlined, color: _pink),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Localized(
                      'Make your first connection',
                      style: TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    SizedBox(height: 4),
                    _Localized(
                      'A five-step guide to a meaningful trial.',
                      style: TextStyle(color: _muted, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: _ink, size: 19),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _condition(IconData icon, String name, String value) => Row(
    children: [
      Icon(icon, size: 18, color: _muted),
      const SizedBox(width: 10),
      Expanded(
        child: _Localized(
          name,
          style: const TextStyle(
            fontSize: 11.5,
            color: _ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      Flexible(
        child: _Localized(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
      ),
    ],
  );

  List<Widget> _peerPage() => [
    const _PageIntro(
      'People make the network.',
      'Pair trusted test phones before you begin. Each phone imports the other’s card.',
    ),
    const SizedBox(height: 23),
    _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconTile(Icons.badge_outlined, color: _teal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Localized(
                      'Your pairing card',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _Localized(
                      app.label,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit your card',
                onPressed: app.identity == null ? null : _editOwn,
                icon: const Icon(Icons.edit_outlined, size: 19, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Localized(
            app.advertisedHost.isEmpty
                ? 'Trust only · no dialing address'
                : '${app.advertisedHost}:$defaultPeerPort',
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          const SizedBox(height: 9),
          if (app.identity != null) _Fingerprint(app.identity!.id),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: app.identity == null ? null : _showOwn,
              icon: const Icon(Icons.ios_share_rounded, size: 17),
              label: const _Localized('Show pairing card'),
            ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 23),
    Row(
      children: [
        const Expanded(
          child: _Section(
            'Paired peers',
            'Only explicitly trusted identities.',
          ),
        ),
        _Tag('${peers.length}', color: _teal),
      ],
    ),
    const SizedBox(height: 14),
    SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: app.busy || app.identity == null ? null : _importPeer,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const _Localized('Import a peer card'),
      ),
    ),
    const SizedBox(height: 14),
    if (peers.isEmpty)
      const _Empty(
        icon: Icons.hub_outlined,
        title: 'Pair your first peer',
        body: 'Exchange cards with another test phone. Check the full fingerprint together before trusting it.',
      )
    else
      ...peers.map(
        (peer) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _peerCard(peer),
        ),
      ),
    const SizedBox(height: 18),
    _callout(
      Icons.link_rounded,
      'Keep trust and reachability separate.',
      'Manual addresses are optional. Automatic peer discovery also works across networks.',
    ),
  ];

  Widget _peerCard(Map<String, dynamic> peer) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _IconTile(Icons.person_outline_rounded, color: _teal),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Localized(
                    peer['name']?.toString() ?? 'Peer',
                    style: const TextStyle(
                      color: _ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _Localized(
                    peer['connected'] == true
                        ? 'Connected'
                        : 'Waiting for a route',
                    style: TextStyle(
                      color: peer['connected'] == true ? _tealText : _muted,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded, color: _muted),
              onSelected: (value) =>
                  value == 'edit' ? _editPeer(peer) : _removePeer(peer),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'edit',
                  child: _Localized('Update address'),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: _Localized('Remove trust'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 13),
        _Localized(
          (peer['host'] as String? ?? '').isEmpty
              ? 'Trust only · no dialing address'
              : '${peer['host']}:${peer['port']}',
          style: const TextStyle(fontSize: 11, color: _muted),
        ),
        const SizedBox(height: 9),
        _Fingerprint(peer['id'] as String),
      ],
    ),
  );

  List<Widget> _bulletinPage() {
    final bulletins = _maps(app.snapshot['bulletins']);
    return [
      const _PageIntro(
        'A signal you can verify.',
        'Small, signed test bulletins move between reachable paired phones.',
      ),
      const SizedBox(height: 22),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: app.running && peers.isNotEmpty && !app.busy
              ? _compose
              : null,
          icon: const Icon(Icons.edit_note_rounded, size: 22),
          label: const _Localized('Publish a test bulletin'),
        ),
      ),
      if (!app.running || peers.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: _Localized(
            'Start receiving and pair a peer to publish.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: _muted),
          ),
        ),
      const SizedBox(height: 26),
      Row(
        children: [
          const Expanded(
            child: _Section(
              'Verified feed',
              'Stored locally. Ready to pass along.',
            ),
          ),
          _Tag('${bulletins.length}', color: _teal),
        ],
      ),
      const SizedBox(height: 14),
      if (bulletins.isEmpty)
        const _Empty(
          icon: Icons.article_outlined,
          title: 'Your first bulletin starts here.',
          body: 'Publish harmless test text or receive a signed bulletin from a paired source.',
        )
      else
        ...bulletins.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        color: _teal,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: _Localized(
                          'SIGNATURE VERIFIED',
                          style: TextStyle(
                            fontSize: 8,
                            color: _tealText,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8,
                          ),
                        ),
                      ),
                      _Localized(
                        _time(item['createdAtMs']),
                        style: const TextStyle(fontSize: 9, color: _muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  _Localized(
                    item['text']?.toString() ?? '',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 15,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 17),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 9,
                    runSpacing: 5,
                    children: [
                      _Localized(
                        'Run ${item['runId']}',
                        style: const TextStyle(color: _muted, fontSize: 9),
                      ),
                      _Localized(
                        '№ ${item['sequence']}',
                        style: const TextStyle(color: _muted, fontSize: 9),
                      ),
                      _Localized(
                        'Source ${_short(item['sourceId'])}',
                        style: const TextStyle(color: _muted, fontSize: 9),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 18),
      _callout(
        Icons.lock_outline_rounded,
        'Signed at the source. Pinned between peers.',
        'A valid signature confirms the trusted signer and protects the message from alteration. This pilot is for public, harmless test content.',
      ),
    ];
  }

  List<Widget> _resultsPage() {
    final enrolled = trials.fold<int>(0, (n, r) => n + _number(r['enrolled']));
    final confirmed = trials.fold<int>(
      0,
      (n, r) => n + _number(r['confirmed']),
    );
    final unlocked = trials.fold<int>(
      0,
      (n, r) => n + _number(r['timelyUnlocked']),
    );
    final unknown = trials.fold<int>(0, (n, r) => n + _number(r['unknown']));
    return [
      const _PageIntro(
        'Measure the connection.',
        'Evidence from your own trials. Every paired recipient stays in the count.',
      ),
      const SizedBox(height: 23),
      _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Tag('LOCKED DELIVERY · ≤ 5 MIN', color: _teal),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Localized(
                  '$confirmed',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 48,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -2,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: _Localized(
                      '/ $enrolled recipients',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: enrolled == 0 ? 0 : confirmed / enrolled,
                color: _teal,
                backgroundColor: _canvas,
              ),
            ),
            const SizedBox(height: 17),
            const _Localized(
              'Confirmed only when a signed receipt returns to the source within five minutes and the receiver reports a known locked state.',
              style: TextStyle(fontSize: 11, color: _muted, height: 1.65),
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _resultMini('$unlocked', 'Timely · unlocked', _pink),
                ),
                Expanded(
                  child: _resultMini('$unknown', 'Unproven / missing', _muted),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _callout(
        Icons.info_outline_rounded,
        'Unknown is a limit of the evidence.',
        'A late or missing receipt, unknown lock state, or unavailable clock does not prove delivery failed. Locked state is sampled at receipt, not throughout the wait.',
      ),
      const SizedBox(height: 26),
      const _Section(
        'Trial history',
        'Fresh messages make a useful comparison.',
      ),
      const SizedBox(height: 14),
      if (trials.isEmpty)
        const _Empty(
          icon: Icons.bar_chart_rounded,
          title: 'A clear result starts with a real trial.',
          body: 'Pair phones, establish a route, then publish a fresh bulletin while a receiving phone is locked.',
        )
      else
        ...trials.reversed.map(
          (trial) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _Localized(
                          trial['runId']?.toString() ?? 'Trial',
                          style: const TextStyle(
                            color: _ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      _Localized(
                        _time(trial['createdAtMs']),
                        style: const TextStyle(color: _muted, fontSize: 9),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Wrap(
                    spacing: 13,
                    runSpacing: 8,
                    children: [
                      _Localized(
                        '${trial['confirmed']} locked ≤ 5 min',
                        style: const TextStyle(
                          color: _tealText,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      _Localized(
                        '${trial['timelyUnlocked']} timely unlocked',
                        style: const TextStyle(color: _muted, fontSize: 10),
                      ),
                      _Localized(
                        '${trial['unknown']} unproven',
                        style: const TextStyle(color: _muted, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      const SizedBox(height: 18),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: app.busy || app.identity == null ? null : _export,
          icon: const Icon(Icons.file_download_outlined, size: 18),
          label: const _Localized('Export trial report'),
        ),
      ),
      const SizedBox(height: 13),
      Center(
        child: TextButton.icon(
          onPressed: _guide,
          icon: const Icon(Icons.science_outlined, size: 16),
          label: const _Localized(
            'How to run a useful trial',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ),
    ];
  }

  Widget _resultMini(String value, String label, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Localized(
        value,
        style: TextStyle(
          color: color,
          fontSize: 24,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 4),
      _Localized(label, style: const TextStyle(color: _muted, fontSize: 9.5)),
    ],
  );
  Widget _error(String error) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFFFEDF4),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded, color: _pink, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: _Localized(
            error,
            style: const TextStyle(
              color: Color(0xFF9B315D),
              fontSize: 11,
              height: 1.6,
            ),
          ),
        ),
      ],
    ),
  );
  Widget _callout(IconData icon, String title, String body) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: _teal.withValues(alpha: .065),
      border: Border.all(color: _teal.withValues(alpha: .17)),
      borderRadius: BorderRadius.circular(17),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: const Color(0xFF2D9798), size: 19),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Localized(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              _Localized(
                body,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 10.5,
                  height: 1.7,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  String _deviceText(String key) {
    final value = app.device[key];
    if (value == null || value.toString().isEmpty) return 'Not available';
    final text = value.toString();
    return '${text[0].toUpperCase()}${text.substring(1)}';
  }

  Future<void> _editOwn() async {
    final result = await _addressDialog(
      title: 'Your pairing card',
      name: app.label,
      host: app.advertisedHost,
      editableName: true,
    );
    if (result != null) {
      await app.perform(() => app.saveDisplay(result.$1, result.$2));
    }
  }

  Future<void> _showOwn() async {
    final token = app.ownCard().toText();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const _Localized('Your pairing card'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const _Localized(
                  'Copy this card to the other phone. Compare the complete fingerprint together. Import their card here too.',
                ),
                const SizedBox(height: 18),
                _Fingerprint(app.identity!.id),
                const SizedBox(height: 18),
                SelectableText(
                  token,
                  style: const TextStyle(fontSize: 9, color: _muted),
                  maxLines: 8,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const _Localized('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
                _toast('Pairing card copied');
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const _Localized('Copy card'),
          ),
        ],
      ),
    );
  }

  Future<void> _importPeer() async {
    final token = TextEditingController();
    String? error;
    final card = await _inputDialog<PeerCard>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const _Localized('Import a peer card'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Localized(
                    'Paste the card shared by the other test phone.',
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: token,
                    maxLines: 5,
                    maxLength: maxEnvelopeBytes,
                    decoration: const InputDecoration(
                      labelText: 'Pairing token',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (error != null)
                    _Localized(
                      error!,
                      style: const TextStyle(color: _pink, fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const _Localized('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final card = PeerCard.fromText(token.text.trim());
                  if (card.id == app.identity?.id) {
                    throw const FormatException(
                      'This is your own card. Use the other phone’s card.',
                    );
                  }
                  Navigator.pop(dialogContext, card);
                } catch (ex) {
                  update(() => error = ex.toString());
                }
              },
              child: const _Localized('Review identity'),
            ),
          ],
        ),
      ),
    );
    token.dispose();
    if (card == null || !mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: _Localized('Trust ${card.name}?'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Localized(
                  'Compare every group below with the fingerprint shown on the other phone, using a channel you trust.',
                ),
                const SizedBox(height: 18),
                _Fingerprint(card.id),
                const SizedBox(height: 18),
                _Localized(
                  card.host.isEmpty
                      ? 'Trust only · no dialing address'
                      : 'Address: ${card.host}:${card.port}',
                ),
                const SizedBox(height: 10),
                const _Localized(
                  'This peer can send signed test bulletins and receive yours. A matching fingerprint confirms identity, not network reachability.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const _Localized('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const _Localized('Fingerprint matches · trust'),
          ),
        ],
      ),
    );
    if (approved == true) await app.perform(() => app.addPeer(card));
  }

  Future<void> _editPeer(Map<String, dynamic> raw) async {
    final peer = PeerCard.fromJson(raw);
    final result = await _addressDialog(
      title: 'Update peer address',
      name: peer.name,
      host: peer.host,
      port: peer.port,
    );
    if (result != null) {
      await app.perform(
        () => app.addPeer(
          PeerCard(
            name: peer.name,
            host: result.$2,
            port: result.$3,
            certificatePem: peer.certificatePem,
          ),
        ),
      );
    }
  }

  Future<(String, String, int)?> _addressDialog({
    required String title,
    required String name,
    required String host,
    int port = defaultPeerPort,
    bool editableName = false,
  }) async {
    final nameInput = TextEditingController(text: name),
        hostInput = TextEditingController(text: host),
        portInput = TextEditingController(text: '$port');
    String? error;
    final result = await _inputDialog<(String, String, int)>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: _Localized(title),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (editableName) ...[
                    TextField(
                      controller: nameInput,
                      maxLength: 80,
                      decoration: const InputDecoration(
                        labelText: 'Phone label',
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: hostInput,
                    decoration: const InputDecoration(
                      labelText: 'Numeric IP address',
                      hintText: 'Blank for trust only',
                    ),
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                  ),
                  const SizedBox(height: 14),
                  if (!editableName)
                    TextField(
                      controller: portInput,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                    ),
                  const SizedBox(height: 13),
                  const _Localized(
                    'Use an address the other phone can reach. Wi-Fi addresses usually work only on the same local network.',
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _Localized(
                        error!,
                        style: const TextStyle(color: _pink, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const _Localized('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final parsedPort = int.tryParse(portInput.text) ?? -1;
                  PeerCard(
                    name: nameInput.text,
                    host: hostInput.text,
                    port: parsedPort,
                    certificatePem: app.identity!.certPem,
                  );
                  Navigator.pop(dialogContext, (
                    nameInput.text.trim(),
                    hostInput.text.trim(),
                    parsedPort,
                  ));
                } catch (ex) {
                  update(() => error = ex.toString());
                }
              },
              child: const _Localized('Save address'),
            ),
          ],
        ),
      ),
    );
    nameInput.dispose();
    hostInput.dispose();
    portInput.dispose();
    return result;
  }

  Future<void> _removePeer(Map<String, dynamic> peer) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const _Localized('Remove this peer’s trust?'),
        content: _Localized(
          '${peer['name']} will no longer be a trusted source or connection. Earlier trial enrollment remains in your results.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const _Localized('Keep peer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const _Localized('Remove peer'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await app.perform(() => app.removePeer(peer['id'] as String));
    }
  }

  Future<void> _compose() async {
    final run = TextEditingController(
          text: 'test-${DateTime.now().millisecondsSinceEpoch}',
        ),
        text = TextEditingController(
          text: 'PersianTrend connection test. This is harmless public test content.',
        );
    String? error;
    final message = await _inputDialog<(String, String)>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const _Localized('Publish a test bulletin'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Localized(
                    'Use fresh, harmless text for each trial. Paired phones can store and relay it.',
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: run,
                    maxLength: maxRunIdLength,
                    decoration: const InputDecoration(
                      labelText: 'Trial / run ID',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: text,
                    maxLines: 5,
                    onChanged: (_) => update(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Public test message',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Localized(
                    '${utf8.encode(text.text).length} / $maxBulletinTextBytes UTF-8 bytes',
                    style: TextStyle(
                      fontSize: 10,
                      color:
                          utf8.encode(text.text).length > maxBulletinTextBytes
                          ? _pink
                          : _muted,
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _Localized(
                        error!,
                        style: const TextStyle(color: _pink, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const _Localized('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (run.text.trim().isEmpty ||
                    text.text.trim().isEmpty ||
                    utf8.encode(text.text).length > maxBulletinTextBytes) {
                  update(
                    () => error =
                        'Add a run ID and a message within the byte limit.',
                  );
                  return;
                }
                Navigator.pop(dialogContext, (run.text.trim(), text.text));
              },
              child: const _Localized('Sign & publish'),
            ),
          ],
        ),
      ),
    );
    run.dispose();
    text.dispose();
    if (message != null) {
      await app.perform(() => app.publish(message.$1, message.$2));
    }
  }

  // DialogRoute.completed also waits for the closing transition to unmount its
  // fields. A plain showDialog future completes before controllers can be freed.
  Future<T?> _inputDialog<T>({required WidgetBuilder builder}) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    final result = await Navigator.of(context).push(route);
    await route.completed;
    return result;
  }

  Future<void> _export() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const _Localized('Export a trial report?'),
        content: const _Localized(
          'The report contains public peer fingerprints, test labels, signed receipts, timing, device conditions, and trial outcomes. It excludes raw IP addresses, names, private keys, certificates, and message content. Identifiers and timing may link activity. Share it only with people you trust.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const _Localized('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const _Localized('Export report'),
          ),
        ],
      ),
    );
    if (approved == true) await app.perform(app.export);
  }

  Future<void> _guide() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .82,
        minChildSize: .4,
        maxChildSize: .94,
        builder: (sheetContext, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(25, 8, 25, 28),
          children: [
            const _Tag('THE FIRST REAL TRIAL', color: _pink),
            const SizedBox(height: 17),
            const _PageIntro(
              'Start small.\nLearn from the signal.',
              'Use test phones and harmless messages. This pilot measures what your current route can deliver.',
            ),
            const SizedBox(height: 25),
            ...const [
              (
                '01',
                'Choose your phones',
                'Use Android phones on different providers for the cross-provider trial. A same-Wi-Fi trial is a useful first check, but does not establish provider-to-provider reachability.',
              ),
              (
                '02',
                'Pair in both directions',
                'Exchange cards, compare the complete fingerprints, and add reachable numeric addresses. Pairing establishes trust; it does not bypass CGNAT or a blocked route.',
              ),
              (
                '03',
                'Establish a foreground route',
                'Start receiving on both phones. Confirm the peer is connected and exchange a fresh test bulletin while both screens are on.',
              ),
              (
                '04',
                'Lock, unplug, and wait',
                'Leave the receiving phone locked and unplugged for 30 minutes. Repeat after two hours and overnight. Keep active and standard mode trials separate.',
              ),
              (
                '05',
                'Send a fresh source message',
                'From the source phone, publish a new bulletin after the wait. Do not unlock the receiver to check. Review the returned receipt on the source; export after the trial.',
              ),
            ].map(
              (step) => Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Localized(
                      step.$1,
                      style: const TextStyle(
                        color: _tealText,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Localized(
                            step.$2,
                            style: const TextStyle(
                              color: _ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 7),
                          _Localized(
                            step.$3,
                            style: const TextStyle(
                              color: _muted,
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
            ),
            _callout(
              Icons.radar_rounded,
              'A receipt is evidence with a boundary.',
              'A timely signed return proves a receiver verified by that deadline. It does not prove physical domestic routing, or that the phone stayed locked throughout the wait.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: const _Localized('Ready to begin'),
            ),
          ],
        ),
      ),
    ),
  );
  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: _Localized(message)));
    }
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(19),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _line),
    ),
    child: child,
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(6),
    ),
    child: _Localized(
      text,
      style: TextStyle(
        fontSize: 7.5,
        fontWeight: FontWeight.w800,
        color: color == _teal ? _tealText : const Color(0xFFB40C65),
        letterSpacing: .6,
      ),
    ),
  );
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon, {required this.color});
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 41,
    height: 41,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .085),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, size: 21, color: color),
  );
}

class _Metric extends StatelessWidget {
  const _Metric({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });
  final String value, label;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const Spacer(),
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .4),
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _Localized(
          value,
          style: const TextStyle(
            color: _ink,
            fontSize: 31,
            fontWeight: FontWeight.w800,
            height: 1,
            letterSpacing: -.7,
          ),
        ),
        const SizedBox(height: 9),
        _Localized(
          label,
          style: const TextStyle(
            color: _muted,
            fontSize: 7.5,
            fontWeight: FontWeight.w800,
            letterSpacing: .5,
          ),
        ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.subtitle);
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Localized(
        title,
        style: const TextStyle(
          color: _ink,
          fontWeight: FontWeight.w800,
          fontSize: 17,
          letterSpacing: -.3,
        ),
      ),
      const SizedBox(height: 5),
      _Localized(
        subtitle,
        style: const TextStyle(color: _muted, fontSize: 10.5, height: 1.6),
      ),
    ],
  );
}

class _PageIntro extends StatelessWidget {
  const _PageIntro(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Localized(title, style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 12),
      _Localized(
        body,
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.8),
      ),
    ],
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => _Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 19),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: _canvas,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Icon(icon, color: _teal, size: 28),
          ),
          const SizedBox(height: 19),
          _Localized(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: _ink,
              fontWeight: FontWeight.w800,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          _Localized(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: _muted, height: 1.8),
          ),
        ],
      ),
    ),
  );
}

class _Fingerprint extends StatelessWidget {
  const _Fingerprint(this.id);
  final String id;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _canvas,
      borderRadius: BorderRadius.circular(11),
    ),
    child: SelectableText(
      [
        for (var i = 0; i < id.length; i += 8)
          id.substring(i, math.min(i + 8, id.length)),
      ].join(' '),
      style: TextStyle(
        fontFamily: _Language.isFarsi(context) ? 'Vazirmatn' : 'Manrope',
        fontWeight: FontWeight.w600,
        fontSize: 10,
        height: 1.8,
        letterSpacing: .1,
        color: _ink,
      ),
    ),
  );
}

class _NetworkPainter extends CustomPainter {
  const _NetworkPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .77, size.height * .45);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .075);
    for (var radius = 42.0; radius <= 250; radius += 38) {
      canvas.drawCircle(center, radius, paint);
    }
    final points = [
      Offset(center.dx - 112, center.dy - 18),
      Offset(center.dx - 30, center.dy + 109),
      Offset(center.dx - 153, center.dy + 122),
      Offset(center.dx + 13, center.dy - 78),
    ];
    final edge = Paint()
      ..strokeWidth = .8
      ..color = _teal.withValues(alpha: .13);
    canvas.drawLine(points[0], points[1], edge);
    canvas.drawLine(points[1], points[2], edge);
    canvas.drawLine(points[0], points[3], edge);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        points[i],
        i == 2 ? 4 : 3,
        Paint()..color = (i == 2 ? _pink : _teal).withValues(alpha: .75),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

List<Map<String, dynamic>> _maps(dynamic raw) => raw is List
    ? raw
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : [];
int _number(dynamic value) => value is num && value.isFinite && value >= 0
    ? value.toInt().clamp(0, 9007199254740991)
    : 0;
String _boolText(dynamic value, {required String yes, required String no}) =>
    value is bool ? (value ? yes : no) : 'Not available';
String _short(dynamic value) {
  final text = value?.toString() ?? '';
  return text.length > 10 ? text.substring(0, 10) : text;
}

String _time(dynamic millis) {
  if (millis is! int ||
      millis < -8640000000000000 ||
      millis > 8640000000000000) {
    return '';
  }
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class _Language extends InheritedWidget {
  const _Language({required this.fa, required super.child});
  final bool fa;
  static bool isFarsi(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Language>()?.fa ?? true;
  @override
  bool updateShouldNotify(_Language oldWidget) => fa != oldWidget.fa;
}

// Advanced diagnostics retain the same controls as the earlier paired pilot.
// Localization is applied at render time so switching language preserves state.
class _Localized extends StatelessWidget {
  const _Localized(this.data, {this.style, this.textAlign});
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) {
    final fa = _Language.isFarsi(context);
    return Text(
      fa ? (_diagnosticFa[data] ?? data) : data,
      textAlign: textAlign,
      style: fa
          ? style?.copyWith(
              fontFamily: 'Vazirmatn',
              letterSpacing: 0,
              height: (style?.height ?? 1.5).clamp(1.5, 2),
            )
          : style,
    );
  }
}

String _diagnostic(BuildContext context, String text) =>
    _Language.isFarsi(context) ? (_diagnosticFa[text] ?? text) : text;
const _diagnosticFa = <String, String>{
  'PersianTrend': 'پرشین‌ترند',
  'INDEPENDENT BY DESIGN': 'خبر، از مردم به مردم',
  'PILOT': 'آزمایشی',
  'Overview': 'دستگاه',
  'Peers': 'اعتماد دستی',
  'Bulletins': 'پیام آزمایش',
  'Results': 'نتایج',
  'News worth keeping connected.': 'آزمایش یک اتصال واقعی.',
  'A SMALL SIGNAL. A SHARED CONNECTION.': 'یک اتصال کوچک، یک جریان مشترک',
  'From peer to peer.\nVerified at every stop.':
      'از همتا به همتا.\nامضای هر پیام بررسی می‌شود.',
  'NO REQUIRED CENTRAL SERVER': 'بدون سرور مرکزی اجباری',
  'Preparing your device identity…': 'در حال آماده‌سازی هویت دستگاه…',
  'Receiving is on': 'دریافت فعال است',
  'Receiving is off': 'دریافت غیرفعال است',
  'Active Android mode': 'حالت فعال اندروید',
  'Standard comparison mode': 'حالت استاندارد مقایسه',
  'Your phone is ready when you are.': 'دستگاه برای دریافت آماده است.',
  'Start receiving': 'شروع دریافت',
  'Stop receiving': 'توقف دریافت',
  'Try standard mode for comparison': 'حالت استاندارد برای مقایسه',
  'CONNECTED PEERS': 'همتاهای متصل',
  'LOCKED + ≤ 5 MIN': 'قفل + حداکثر ۵ دقیقه',
  'Your device': 'وضعیت دستگاه',
  'A few conditions shape every connection.':
      'شرایط دستگاه بر اتصال اثر می‌گذارد.',
  'Network': 'شبکه',
  'Battery': 'باتری',
  'Charging': 'در حال شارژ',
  'Power saving': 'ذخیرهٔ انرژی',
  'Battery exemption': 'معافیت باتری',
  'Battery settings': 'تنظیمات باتری',
  'Not available': 'نامشخص',
  'On': 'فعال',
  'Off': 'غیرفعال',
  'Allowed': 'مجاز',
  'Not exempt': 'معاف نیست',
  'Unplugged': 'جدا از شارژ',
  'A trusted peer still needs a route.':
      'همتای مورد اعتماد هم به مسیر واقعی نیاز دارد.',
  'Pairing confirms identity. It cannot make two phones reachable through a provider’s NAT or a blocked network.': 'تبادل کارت، اعتماد به کلید را مشخص می‌کند؛ NAT اپراتور یا مسیر مسدود را برطرف نمی‌کند.',
  'Make your first connection': 'اولین اتصال آزمایشی',
  'A five-step guide to a meaningful trial.':
      'راهنمای پنج‌مرحله‌ای برای آزمایشی قابل بررسی.',
  'People make the network.': 'اعتماد دستی به همتاها',
  'Pair trusted test phones before you begin. Each phone imports the other’s card.':
      'برای آزمون کنترل‌شده، هر دستگاه کارت دستگاه دیگر را وارد کند.',
  'Your pairing card': 'کارت این دستگاه',
  'Trust only · no dialing address': 'فقط اعتماد · بدون نشانی اتصال',
  'Show pairing card': 'نمایش کارت من',
  'Paired peers': 'همتاهای مورد اعتماد',
  'Only explicitly trusted identities.':
      'کلیدهایی که دستی به آن‌ها اعتماد کرده‌اید.',
  'Import a peer card': 'وارد کردن کارت همتا',
  'Pair your first peer': 'اولین همتای آزمایشی را اضافه کنید',
  'Exchange cards with another test phone. Check the full fingerprint together before trusting it.': 'کارت‌ها را مبادله کنید و پیش از اعتماد، همهٔ بخش‌های اثر انگشت را مقایسه کنید.',
  'Keep trust and reachability separate.': 'اعتماد و دسترسی دو چیز جدا هستند.',
  'Manual addresses are optional. Automatic peer discovery also works across networks.': 'واردکردن نشانی دستی اختیاری است. برنامه همتاها را میان شبکه‌های مختلف هم به‌طور خودکار پیدا می‌کند.',
  'Connected': 'متصل',
  'Waiting for a route': 'منتظر مسیر اتصال',
  'Update address': 'ویرایش نشانی',
  'Remove trust': 'حذف اعتماد',
  'A signal you can verify.': 'پیام آزمایش امضاشده',
  'Small, signed test bulletins move between reachable paired phones.': 'پیام‌های کوچک آزمایش میان دستگاه‌های مورد اعتماد و قابل دسترس منتقل می‌شوند.',
  'Publish a test bulletin': 'ارسال پیام آزمایش',
  'Start receiving and pair a peer to publish.':
      'برای آزمایش، دریافت را فعال و یک همتا را اضافه کنید.',
  'Verified feed': 'پیام‌های با امضای معتبر',
  'Stored locally. Ready to pass along.':
      'ذخیره‌شده روی این دستگاه و آمادهٔ بازنشر.',
  'Your first bulletin starts here.': 'هنوز پیام آزمایشی دریافت نشده است.',
  'Publish harmless test text or receive a signed bulletin from a paired source.': 'متن بی‌خطر آزمایش را بفرستید یا پیام امضاشده از یک همتای مورد اعتماد دریافت کنید.',
  'SIGNATURE VERIFIED': 'امضای دیجیتال معتبر',
  'Signed at the source. Pinned between peers.':
      'امضاشده در مبدأ، اتصال به کلید مشخص.',
  'A valid signature confirms the trusted signer and protects the message from alteration. This pilot is for public, harmless test content.': 'امضا از تغییر پیام جلوگیری می‌کند؛ درستی خبر یا هویت انسانی ناشر را تضمین نمی‌کند. برای آزمایش از متن عمومی بی‌خطر استفاده کنید.',
  'Measure the connection.': 'اتصال را بسنجیم.',
  'Evidence from your own trials. Every paired recipient stays in the count.':
      'هر دریافت‌کنندهٔ ثبت‌شده در شمار آزمایش باقی می‌ماند.',
  'LOCKED DELIVERY · ≤ 5 MIN': 'دریافت قفل · حداکثر ۵ دقیقه',
  'Timely · unlocked': 'به‌موقع، بدون قفل',
  'Unproven / missing': 'اثبات‌نشده / ناموجود',
  'Confirmed only when a signed receipt returns to the source within five minutes and the receiver reports a known locked state.': 'تأیید فقط با بازگشت رسید امضاشده در مهلت پنج‌دقیقه‌ای و وضعیت قفل مشخص انجام می‌شود.',
  'Unknown is a limit of the evidence.': 'نامشخص، محدودیت شواهد است.',
  'A late or missing receipt, unknown lock state, or unavailable clock does not prove delivery failed. Locked state is sampled at receipt, not throughout the wait.': 'رسید دیرهنگام یا ناموجود، ساعت نامعتبر و وضعیت قفل نامشخص، شکست دریافت را ثابت نمی‌کنند. حالت قفل فقط هنگام دریافت ثبت می‌شود.',
  'Trial history': 'آزمایش‌های ثبت‌شده',
  'Fresh messages make a useful comparison.':
      'برای هر مقایسه، پیام تازه بفرستید.',
  'A clear result starts with a real trial.': 'هنوز آزمایشی ثبت نشده است.',
  'Pair phones, establish a route, then publish a fresh bulletin while a receiving phone is locked.':
      'مسیر اتصال را برقرار کنید و وقتی گیرنده قفل است، یک پیام تازه بفرستید.',
  'Export trial report': 'خروجی گزارش',
  'How to run a useful trial': 'راهنمای آزمایش قابل بررسی',
  'Close': 'بستن',
  'Copy card': 'کپی کارت',
  'Cancel': 'انصراف',
  'Review identity': 'بررسی هویت',
  'Fingerprint matches · trust': 'اثر انگشت مطابقت دارد',
  'Update peer address': 'ویرایش نشانی همتا',
  'Save address': 'ذخیرهٔ نشانی',
  'Remove this peer’s trust?': 'اعتماد به این همتا حذف شود؟',
  'Keep peer': 'نگه داشتن همتا',
  'Remove peer': 'حذف همتا',
  'Sign & publish': 'امضا و ارسال',
  'Export a trial report?': 'خروجی گزارش آزمایش؟',
  'Export report': 'خروجی گزارش',
  'Copy this card to the other phone. Compare the complete fingerprint together. Import their card here too.': 'این کارت را به دستگاه دیگر بدهید و همهٔ بخش‌های اثر انگشت را مقایسه کنید. کارت آن دستگاه را نیز اینجا وارد کنید.',
  'Paste the card shared by the other test phone.':
      'کارت دستگاه آزمایشی دیگر را اینجا وارد کنید.',
  'Compare every group below with the fingerprint shown on the other phone, using a channel you trust.': 'همهٔ گروه‌های زیر را از یک مسیر مورد اعتماد با اثر انگشت دستگاه دیگر مقایسه کنید.',
  'This peer can send signed test bulletins and receive yours. A matching fingerprint confirms identity, not network reachability.': 'این همتا می‌تواند پیام امضاشده بفرستد و دریافت کند. تطابق اثر انگشت، دسترسی شبکه یا هویت انسانی را تضمین نمی‌کند.',
  'Use an address the other phone can reach. Wi-Fi addresses usually work only on the same local network.': 'نشانی باید از دستگاه مقابل قابل دسترس باشد. IP وای‌فای معمولاً فقط در همان شبکهٔ محلی کار می‌کند.',
  'Use fresh, harmless text for each trial. Paired phones can store and relay it.': 'برای هر آزمایش متن تازه و بی‌خطر بنویسید. همتاها می‌توانند آن را ذخیره و بازنشر کنند.',
  'Add a run ID and a message within the byte limit.':
      'شناسهٔ آزمایش و متن در محدودهٔ مجاز وارد کنید.',
  'The report contains public peer fingerprints, test labels, signed receipts, timing, device conditions, and trial outcomes. It excludes raw IP addresses, names, private keys, certificates, and message content. Identifiers and timing may link activity. Share it only with people you trust.': 'گزارش شامل اثر انگشت عمومی همتاها، برچسب آزمایش، رسیدها، زمان‌ها و شرایط دستگاه است. IP، نام، کلید خصوصی، گواهی و متن خبر در آن نیست. شناسه و زمان ممکن است فعالیت را به هم مرتبط کنند. فقط با افراد مورد اعتماد به اشتراک بگذارید.',
  'THE FIRST REAL TRIAL': 'اولین آزمایش واقعی',
  'Ready to begin': 'متوجه شدم',
};

class _ReaderHome extends StatefulWidget {
  const _ReaderHome({required this.app, required this.animateRadar});
  final AppController app;
  final bool animateRadar;
  @override
  State<_ReaderHome> createState() => _ReaderState();
}

class _ReaderState extends State<_ReaderHome> with WidgetsBindingObserver {
  int tab = 0;
  String? filter;
  String? trustPendingChannelId;
  String? trustErrorChannelId;
  bool discoverChannels = false;
  final channelSearch = TextEditingController();
  AppController get app => widget.app;
  bool get fa => app.languageCode != 'en';
  String t(String farsi, String english) => fa ? farsi : english;
  String n(int value) => fa ? _persianDigits('$value') : '$value';
  List<Map<String, dynamic>> get channels => _maps(app.snapshot['channels']);
  List<Map<String, dynamic>> get bulletins => _maps(app.snapshot['bulletins']);
  List<Map<String, dynamic>> get followedChannels => channels
      .where(
        (c) =>
            app.isChannelFollowed(c['id'] as String) &&
            !app.isChannelBlocked(c['id'] as String),
      )
      .toList();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_reconcileNewsSelection);
  }

  @override
  void didUpdateWidget(covariant _ReaderHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != app) {
      oldWidget.app.removeListener(_reconcileNewsSelection);
      app.addListener(_reconcileNewsSelection);
      _reconcileNewsSelection();
    }
  }

  void _reconcileNewsSelection() {
    if (filter != null && !followedChannels.any((c) => c['id'] == filter)) {
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
                      Text(
                        t('پرشین‌ترند', 'PersianTrend'),
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t('خبر، از مردم به مردم', 'INDEPENDENT BY DESIGN'),
                        style: TextStyle(
                          color: _muted,
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
                    color: _muted,
                    size: 21,
                  ),
                ),
                IconButton(
                  key: const ValueKey('advanced-diagnostics'),
                  tooltip: t('ابزارهای پیشرفته', 'Advanced diagnostics'),
                  onPressed: _advanced,
                  icon: const Icon(Icons.tune_rounded, color: _muted, size: 21),
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
                      color: _teal,
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
                color: _teal,
                onRefresh: () => app.perform(app.refresh),
                child: Builder(
                  builder: (context) {
                    final items = <Widget>[
                      if (app.error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 15),
                          child: _note(
                            Icons.error_outline_rounded,
                            t('این کار کامل نشد', 'That action did not finish'),
                            app.error!,
                          ),
                        ),
                      ...switch (tab) {
                        0 => _connection(),
                        1 => _channels(),
                        _ => _news(),
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
        border: Border(top: BorderSide(color: _line)),
      ),
      child: NavigationBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        height: 74,
        selectedIndex: tab,
        indicatorColor: _teal.withValues(alpha: .12),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: fa ? 'Vazirmatn' : 'Manrope',
            fontSize: 11,
            color: s.contains(WidgetState.selected) ? _ink : _muted,
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
        ],
      ),
    ),
  );
  String get state {
    if (!app.running) return 'paused';
    if (_number(app.snapshot['connectedCount']) > 0) return 'connected';
    if (app.deliveryMode == DeliveryMode.allNetworks &&
        app.snapshot['overlay'] is Map &&
        (app.snapshot['overlay'] as Map)['state'] != 'unavailable') {
      return 'searching';
    }
    return app.snapshot['discoveryState'] as String? ?? 'waitingForBootstrap';
  }

  String get status => switch (state) {
    'connected' => t('به شبکه وصل هستید', 'You are connected'),
    'searching' => t('در جست‌وجوی همتاها', 'Searching for peers'),
    'waitingForBootstrap' => t(
      'در انتظار همتای شروع',
      'Waiting for a starting peer',
    ),
    _ => t('دریافت متوقف است', 'Receiving is paused'),
  };
  String get statusBody => switch (state) {
    'connected' => t(
      'خبرهای عمومی میان دستگاه‌های متصل جابه‌جا می‌شوند.',
      'Public news can move between connected devices.',
    ),
    'searching' => t(
      'جست‌وجوی همتاها در مسیرهای در دسترس و همگام‌سازی خودکار خبرها.',
      'Finding peers over available paths and syncing news automatically.',
    ),
    'waitingForBootstrap' => t(
      'جست‌وجو در مسیرهای در دسترس ادامه دارد. اتصال به دستگاه‌های دیگر به وضعیت شبکه بستگی دارد.',
      'Discovery continues over available paths. Connecting to other devices depends on network conditions.',
    ),
    _ => t(
      'برای ادامهٔ پیدا کردن همتاها، دریافت را از سر بگیرید.',
      'Resume receiving to continue discovering peers.',
    ),
  };
  List<Widget> _connection() {
    final connected = _number(app.snapshot['connectedCount']);
    return [
      _intro(
        t('خبر، زنده می‌ماند.', 'Keep the news moving.'),
        t(
          'یک اتصال کوچک. یک جریان مشترک.',
          'A small connection. A shared flow.',
        ),
      ),
      const SizedBox(height: 20),
      Container(
        key: const ValueKey('discovery-card'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: _ink,
          borderRadius: BorderRadius.circular(25),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 19, 22, 23),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: app.running ? _teal : Colors.white38,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      t(
                        app.deliveryMode == DeliveryMode.nearbyOnly
                            ? 'فقط نزدیک · بلوتوث و وای‌فای محلی'
                            : 'اتصال خودکار · همهٔ شبکه‌ها',
                        app.deliveryMode == DeliveryMode.nearbyOnly
                            ? 'NEARBY ONLY · BLUETOOTH + LOCAL WI-FI'
                            : 'AUTOMATIC CONNECTION · ALL NETWORKS',
                      ),
                      style: const TextStyle(
                        color: Color(0xFFB8D5DC),
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const _Tag('PILOT', color: _pink),
                ],
              ),
              _LiveRadar(
                key: const ValueKey('peer-radar'),
                active: app.running,
                searching: state == 'searching',
                contacts: connected,
                animate: widget.animateRadar,
                number: n(connected),
                caption: t('دستگاه متصل', 'connected peers'),
              ),
              Text(
                status,
                key: const ValueKey('discovery-status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fa ? 19 : 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 9),
              Text(
                statusBody,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFB8D5DC),
                  fontSize: 11,
                  height: 1.9,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          Expanded(
            child: _Metric(
              key: const ValueKey('active-connections-metric'),
              value: n(connected),
              label: t('اتصال‌های فعال', 'ACTIVE CONNECTIONS'),
              icon: Icons.hub_outlined,
              color: _teal,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Metric(
              value: n(channels.length),
              label: t('کانال ذخیره‌شده', 'SAVED CHANNELS'),
              icon: Icons.grid_view_rounded,
              color: _pink,
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _deliveryModeCard(),
      const SizedBox(height: 18),
      _Card(
        child: Row(
          children: [
            const _IconTile(Icons.auto_awesome_outlined, color: _teal),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('اتصال خودکار', 'Automatic connection'),
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    t(
                      'برای کشف محلی، نیازی به وارد کردن IP ندارید.',
                      'No IP entry is needed for local discovery.',
                    ),
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: _muted,
                      height: 1.8,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('toggle-receiving'),
              tooltip: app.running
                  ? t('توقف دریافت', 'Pause receiving')
                  : t('ادامهٔ دریافت', 'Resume receiving'),
              onPressed: app.busy || app.identity == null
                  ? null
                  : () => app.perform(
                      () => app.running
                          ? app.stop()
                          : app.start(active: Platform.isAndroid),
                    ),
              icon: Icon(
                app.running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: _tealText,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      _transportCard(),
      const SizedBox(height: 16),
      ReaderSettingsCard(app: app),
      const SizedBox(height: 20),
      _note(
        Icons.privacy_tip_outlined,
        t('حریم خصوصی از ابتدا', 'Privacy by design'),
        t(
          'بدون حساب کاربری و سرور مرکزی اجباری. خبرهای عمومیِ امضاشده میان دستگاه‌ها جابه‌جا می‌شوند. دنبال‌کردن و اعتماد، انتخاب‌های خصوصی این گوشی‌اند. موقعیت GPS را نمی‌خوانیم.',
          'No account or required central server. Signed public news moves between devices. Follow and trust choices stay on this phone. We do not read GPS.',
        ),
      ),
      const SizedBox(height: 12),
      _privacyDetails(),
      const SizedBox(height: 20),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () => setState(() => tab = 2),
          icon: const Icon(Icons.article_outlined, size: 18),
          label: Text(t('مرور خبرها', 'Explore the news')),
        ),
      ),
    ];
  }

  Widget _privacyDetails() => _Card(
    child: ExpansionTile(
      key: const ValueKey('privacy-details'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(Icons.info_outline_rounded, color: _tealText),
      title: Text(
        t('جزئیات حریم خصوصی', 'Privacy details'),
        style: const TextStyle(
          color: _ink,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
      children: [
        _note(
          Icons.location_off_outlined,
          t('حریم خصوصی در شبکه', 'Connection privacy'),
          t(
            'سرور مرکزی اجباری برای جمع‌آوری خبر یا انتخاب‌های شما نداریم. خبرهای عمومی میان همتاها جابه‌جا می‌شوند؛ انتخاب دنبال‌کردن و اعتماد روی این گوشی می‌ماند. در حالت همهٔ شبکه‌ها، شبکهٔ کشف عمومی به یافتن همتاها کمک می‌کند و همتاهای آن می‌توانند اطلاعات اتصال را ببینند. کلید انتشار از کلید اتصال جداست. موقعیت GPS را نمی‌خوانیم.',
            'There is no required central server collecting your news or choices. Public news moves between peers; follow and trust choices stay on this phone. In All networks mode, a public discovery network helps find peers and its peers can observe connection metadata. Publishing and connections use separate keys. We do not read your GPS location.',
          ),
        ),
        const SizedBox(height: 12),
        _note(
          Icons.shield_outlined,
          t('مرزهای حفاظت', 'Protection limits'),
          t(
            'خواندن یا بازنشر خبر به‌معنای نویسنده‌بودن شما نیست. حتی دریافت خبر از خارج ایران، امنیت یا ناشناس‌ماندن شما را تضمین نمی‌کند.\n\nهمتای نزدیک و زمان ارسال ممکن است شما را مشخص کند. در حالت همهٔ شبکه‌ها، همتاها و اپراتور IP اتصال شما را می‌بینند. ارتباط‌های هویتی نسخه‌های قبلی پاک نمی‌شوند.',
            'Reading or forwarding news does not mean you originally published it. Receiving news from outside Iran does not guarantee safety or anonymity.\n\nNearby peers and timing may identify you. In All networks mode, peers and your provider can see your connection IP. Earlier identity links cannot be erased.',
          ),
        ),
        const SizedBox(height: 12),
        _note(
          Icons.public_rounded,
          t(
            'امضا، تأیید هویت انسانی نیست.',
            'A signature is not a verified human publisher.',
          ),
          t(
            'امضای دیجیتال از تغییر خبر جلوگیری می‌کند و کلید فرستنده را مشخص می‌کند. نام کانال، نشانهٔ اعتبار سردبیری نیست. همهٔ خبرها عمومی هستند.',
            'A digital signature protects integrity and identifies a signing key. A channel name is not editorial endorsement. All news is public.',
          ),
        ),
      ],
    ),
  );

  Widget _deliveryModeCard() {
    final nearbyOnly = app.deliveryMode == DeliveryMode.nearbyOnly;
    return _Card(
      key: const ValueKey('delivery-mode-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('خبر از چه مسیرهایی برسد؟', 'How should news reach you?'),
            style: const TextStyle(
              color: _ink,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          _deliveryModeOption(
            DeliveryMode.allNetworks,
            Icons.public_rounded,
            t('همهٔ شبکه‌ها', 'All networks'),
            t(
              'خودکار: اینترنت و شبکهٔ داخلی با وای‌فای محلی و بلوتوث. همتاها IP اتصال را می‌بینند.',
              'Automatic: Internet and domestic routes, plus local Wi-Fi and Bluetooth. Peers can see your connection IP.',
            ),
          ),
          const SizedBox(height: 9),
          _deliveryModeOption(
            DeliveryMode.nearbyOnly,
            Icons.near_me_outlined,
            t('فقط نزدیک', 'Nearby only'),
            t('بلوتوث و وای‌فای محلی', 'Bluetooth and local Wi-Fi'),
          ),
          const SizedBox(height: 12),
          Text(
            nearbyOnly
                ? t(
                    'این برنامه از اینترنت یا دیتای موبایل برای اتصال به همتاها استفاده نمی‌کند. دیتای موبایل می‌تواند برای برنامه‌های دیگر روشن بماند.',
                    'This app will not use Internet or mobile data to connect to peers. Mobile data can stay on for other apps.',
                  )
                : t(
                    'با دیتای موبایل یا هر وای‌فای، مسیرهای قابل دسترس به‌طور خودکار بررسی می‌شوند. وای‌فای محلی و بلوتوث هم فعال می‌مانند. دریافت خبر به وجود همتای قابل دسترس بستگی دارد. اتصال مستقیم، IP شما را از همتای متصل و اپراتور پنهان نمی‌کند.',
                    'Reachable routes are checked automatically on mobile data or any Wi-Fi. Local Wi-Fi and Bluetooth stay available. News still needs a reachable peer. Direct connections expose your connection IP to connected peers and your provider.',
                  ),
            key: const ValueKey('delivery-mode-explanation'),
            style: const TextStyle(fontSize: 10.5, height: 1.8, color: _muted),
          ),
          if (app.busy) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('در حال آماده‌سازی اتصال…', 'Preparing your connection…'),
                    style: const TextStyle(fontSize: 10, color: _muted),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _deliveryModeOption(
    DeliveryMode value,
    IconData icon,
    String title,
    String description,
  ) {
    final selected = app.deliveryMode == value;
    final enabled = !app.busy && app.identity != null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: selected ? _teal.withValues(alpha: .08) : _canvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? _teal : _line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('delivery-mode-${value.name}'),
          onTap: enabled && !selected
              ? () => app.perform(() => app.setDeliveryMode(value))
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
            child: Row(
              children: [
                Icon(icon, color: selected ? _tealText : _muted, size: 21),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.7,
                          color: _muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? _tealText : _muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _transportCard() {
    final nearbyOnly = app.deliveryMode == DeliveryMode.nearbyOnly;
    final counts = app.snapshot['activeTransportCounts'] as Map? ?? const {};
    final routes = [
      if (!nearbyOnly)
        (
          'ip',
          Icons.public_rounded,
          t('اینترنت و شبکهٔ داخلی', 'Internet / domestic IP'),
        ),
      ('lan', Icons.wifi_rounded, t('وای‌فای محلی', 'Local Wi-Fi')),
      if (!nearbyOnly)
        (
          'wifiDirect',
          Icons.wifi_tethering_rounded,
          t('وای‌فای مستقیم', 'Wi-Fi Direct'),
        ),
      ('bluetooth', Icons.bluetooth_rounded, t('بلوتوث', 'Bluetooth')),
      if (nearbyOnly)
        (
          'wifiDirect',
          Icons.wifi_tethering_rounded,
          t('وای‌فای مستقیم', 'Wi-Fi Direct'),
        ),
      if (nearbyOnly)
        (
          'ip',
          Icons.public_rounded,
          t('اینترنت و شبکهٔ داخلی', 'Internet / domestic IP'),
        ),
    ];
    String routeStatus(String route) {
      if (nearbyOnly && (route == 'ip' || route == 'wifiDirect')) {
        return t('در این حالت مسدود است', 'Blocked in this mode');
      }
      final count =
          _number(counts[route]) +
          (route == 'ip' ? _number(counts['overlay']) : 0);
      if (count > 0) return t('${n(count)} اتصال فعال', '${n(count)} active');
      if (!app.running) return t('متوقف', 'Paused');
      if (route == 'ip') {
        final stage = (app.snapshot['overlay'] as Map?)?['discoveryStage'];
        return stage == 'bootstrapping'
            ? t('در حال یافتن شبکهٔ همتاها', 'Finding the peer network')
            : stage == 'connecting'
            ? t('در حال برقراری اتصال', 'Establishing a connection')
            : t(
                'جست‌وجوی خودکار همتاهای اینترنتی',
                'Finding Internet peers automatically',
              );
      }
      if (route == 'lan') {
        final diagnostic = app.snapshot['discoveryLastError']?.toString();
        final senderOnly =
            diagnostic != null &&
            (diagnostic.startsWith('discovery_multicast_sender_failed') ||
                diagnostic.startsWith('discovery_unicast_sender_failed') ||
                diagnostic == 'discovery_multicast_sender_closed' ||
                diagnostic == 'discovery_unicast_sender_closed');
        if (senderOnly) {
          return t(
            'کشف محدود؛ جست‌وجو ادامه دارد',
            'Limited discovery; still searching',
          );
        }
        return diagnostic == null
            ? t('در جست‌وجو', 'Searching')
            : t('کشف محلی در دسترس نیست', 'Discovery unavailable');
      }
      if (!Platform.isAndroid &&
          (route == 'wifiDirect' || route == 'bluetooth')) {
        return t('در این دستگاه فعال نیست', 'Not enabled here');
      }
      final state = app.nearbyStates[route]?['state'];
      return switch (state) {
        'unsupported' => t('پشتیبانی نمی‌شود', 'Unsupported'),
        'permissionRequired' ||
        'permission_required' => t('نیاز به اجازه', 'Permission needed'),
        'locationRequired' => t('تنظیمات دستگاه', 'Device settings needed'),
        'wifiDisabled' ||
        'bluetoothDisabled' ||
        'bluetooth_off' ||
        'disabled' => t('خاموش', 'Radio off'),
        'foregroundRequired' => t('برنامه را باز نگه دارید', 'Keep app open'),
        'occupied' => t('در حال استفاده', 'In use'),
        'error' || 'unavailable' || 'scan_failed' || 'advertise_failed' => t(
          'در دسترس نیست؛ تلاش دوباره',
          'Unavailable; retrying',
        ),
        'stopped' => t('متوقف', 'Paused'),
        'connecting' => t('در حال اتصال', 'Connecting'),
        'connected' => t('تأیید اتصال امن', 'Checking secure link'),
        'searching' || 'discovering' => t('در جست‌وجو', 'Searching'),
        _ => t('در حال بررسی', 'Checking availability'),
      };
    }

    return _Card(
      key: const ValueKey('transport-priority-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('بهترین مسیرِ در دسترس', 'Best available path'),
            style: const TextStyle(
              color: _ink,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t(
              nearbyOnly
                  ? 'انتخاب خودکار از میان مسیرهای نزدیک؛ اینترنت و دیتای موبایل برای اتصال به همتاها مسدود هستند.'
                  : 'انتخاب خودکار از اینترنت و شبکهٔ داخلی؛ وای‌فای محلی و بلوتوث هم برای پشتیبانی فعال می‌مانند. اتصال به همتا باید قابل دسترس باشد.',
              nearbyOnly
                  ? 'Nearby paths are selected automatically. Internet and mobile-data peer routes are blocked.'
                  : 'Internet and domestic routes are selected automatically, with local Wi-Fi and Bluetooth available for fallback. A peer must be reachable.',
            ),
            style: const TextStyle(fontSize: 10.5, height: 1.8, color: _muted),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < routes.length; i++) ...[
            if (i > 0) const Divider(height: 20, color: _line),
            Row(
              children: [
                Icon(
                  routes[i].$2,
                  color: _number(counts[routes[i].$1]) > 0 ? _tealText : _muted,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    nearbyOnly &&
                            (routes[i].$1 == 'ip' ||
                                routes[i].$1 == 'wifiDirect')
                        ? routes[i].$3
                        : '${n(i + 1)}. ${routes[i].$3}',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    routeStatus(routes[i].$1),
                    key: ValueKey('transport-status-${routes[i].$1}'),
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 10,
                      color: _number(counts[routes[i].$1]) > 0
                          ? _tealText
                          : _muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (Platform.isAndroid) ...[
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: app.busy ? null : () => app.perform(app.enableNearby),
              icon: const Icon(Icons.settings_input_antenna, size: 17),
              label: Text(
                t(
                  'اجازهٔ اتصال به دستگاه‌های نزدیک',
                  'Enable nearby connections',
                ),
              ),
            ),
            Text(
              t(
                'در اندروید قدیمی، سیستم برای کشف دستگاه‌های نزدیک اجازهٔ موقعیت می‌خواهد؛ برنامه GPS را نمی‌خواند.',
                'Older Android versions require location permission for nearby discovery; the app does not read GPS.',
              ),
              style: const TextStyle(fontSize: 10, height: 1.8, color: _muted),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _channels() {
    final available = channels
        .where((c) => !app.isChannelBlocked(c['id'] as String))
        .toList();
    final latest = <String, Map<String, dynamic>>{};
    for (final bulletin in orderNews(bulletins)) {
      final id = bulletin['channelId'] as String?;
      if (id == null) continue;
      latest.putIfAbsent(id, () => bulletin);
    }
    final source = discoverChannels ? available : followedChannels;
    final query = _searchText(channelSearch.text);
    final visible =
        source
            .where(
              (c) =>
                  query.isEmpty ||
                  _searchText('${c['name']} ${c['id']} ${c['ownerId']}')
                      .contains(query),
            )
            .toList()
          ..sort((a, b) {
            final aTime = latest[a['id']]?['createdAtMs'] as int? ?? 0;
            final bTime = latest[b['id']]?['createdAtMs'] as int? ?? 0;
            final order = bTime.compareTo(aTime);
            return order != 0
                ? order
                : _searchText('${a['name']} ${a['id']}')
                      .compareTo(_searchText('${b['name']} ${b['id']}'));
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
                  color: _ink,
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
                  : _createChannel,
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
        onChanged: (_) => setState(() {}),
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
                  onPressed: () => setState(channelSearch.clear),
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
        onSelectionChanged: (value) =>
            setState(() => discoverChannels = value.first),
      ),
      if (app.blockedChannelIds.isNotEmpty)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const ValueKey('manage-blocked-channels'),
            onPressed: _manageBlocked,
            icon: const Icon(Icons.block_rounded, size: 16),
            label: Text(t('کانال‌های مسدودشده', 'Manage blocked')),
          ),
        ),
      const SizedBox(height: 14),
      if (visible.isEmpty) ...[
        _empty(
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
            onPressed: () => setState(() => discoverChannels = true),
            icon: const Icon(Icons.explore_outlined),
            label: Text(t('کشف کانال‌ها', 'Discover channels')),
          ),
      ] else
        ...visible.map((c) => _channelCard(c, latest[c['id']])),
    ];
  }

  Widget _channelCard(
    Map<String, dynamic> channel,
    Map<String, dynamic>? latest,
  ) {
    final id = channel['id'] as String;
    final owned = channel['owned'] == true;
    final followed = app.isChannelFollowed(id);
    final trusted = app.isChannelTrusted(id);
    final description = channel['description'] as String? ?? '';
    final preview =
        latest?['text'] as String? ??
        (description.isEmpty
            ? t('هنوز خبری منتشر نشده', 'No news here yet')
            : description);
    return Material(
      key: ValueKey('channel-card-$id'),
      color: Colors.white,
      child: InkWell(
        key: ValueKey('open-channel-$id'),
        onTap: () => _openChannel(channel),
        child: Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _line)),
          ),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 13, 0, 13),
          child: Row(
            children: [
              ChannelAvatar(channel: channel),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            channel['name'] as String,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
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
                              latest['createdAtMs'],
                              fa,
                            ),
                            style: const TextStyle(color: _muted, fontSize: 9),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview.replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Tooltip(
                      message: t(
                        'انتخاب خصوصی شماست؛ تأیید درستی خبر نیست.',
                        'Your private choice; not proof that news is true.',
                      ),
                      child: Text(
                        _channelAssessment(id),
                        key: ValueKey('channel-trust-$id'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: owned || trusted ? _tealText : _muted,
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
                                  color: _muted,
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
                          style: const TextStyle(fontSize: 10, color: _pink),
                        ),
                      ),
                  ],
                ),
              ),
              if (owned || channel['canPublish'] == true)
                IconButton(
                  key: ValueKey('channel-compose-$id'),
                  tooltip: t('نوشتن خبر', 'Write news'),
                  onPressed: app.busy ? null : () => _publish(channel),
                  icon: const Icon(
                    Icons.edit_note_rounded,
                    color: _tealText,
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
                    color: _tealText,
                    size: 22,
                  ),
                ),
              ChannelOptions(
                channel: channel,
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
                  if (value == 'identity') _channelIdentity(channel);
                  if (value == 'block') _blockChannel(channel);
                  if (value == 'trust') _setChannelTrust(id, true);
                  if (value == 'untrust') _setChannelTrust(id, false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

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

  Future<void> _channelIdentity(Map<String, dynamic> channel) =>
      showModalBottomSheet<void>(
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
                Text(
                  channel['name'] as String,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  t(
                    'امضا مالکیت کلید را نشان می‌دهد، نه هویت واقعی یا درستی خبر را.',
                    'A signature proves key possession, not human identity or factual accuracy.',
                  ),
                ),
                const SizedBox(height: 18),
                Text(t('اثر انگشت کامل ناشر', 'Full publisher fingerprint')),
                const SizedBox(height: 6),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: _Fingerprint(channel['ownerId'] as String? ?? ''),
                ),
                const SizedBox(height: 16),
                Text(t('شناسهٔ کامل کانال', 'Full channel ID')),
                const SizedBox(height: 6),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: _Fingerprint(channel['id'] as String),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: channel['id'] as String),
                    );
                    if (sheet.mounted) {
                      ScaffoldMessenger.of(sheet).showSnackBar(
                        SnackBar(
                          content: Text(
                            t('شناسهٔ کانال کپی شد', 'Channel ID copied'),
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(t('کپی شناسهٔ کانال', 'Copy channel ID')),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _blockChannel(Map<String, dynamic> channel) async {
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
    final id = channel['id'] as String;
    await app.perform(() => app.blockChannel(id));
    if (mounted && app.error == null) {
      setState(() {
        if (filter == id) filter = null;
        if (trustErrorChannelId == id) trustErrorChannelId = null;
      });
    }
  }

  Future<void> _manageBlocked() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final ids = app.blockedChannelIds.toList()..sort();
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t('کانال‌های مسدودشده', 'Blocked channels'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                Text(
                  t(
                    'رفع مسدودی، کانال دیگران را خودکار دنبال نمی‌کند.',
                    'Unblocking does not automatically follow someone else’s channel.',
                  ),
                ),
                const SizedBox(height: 16),
                if (ids.isEmpty)
                  Text(t('کانال مسدودشده‌ای ندارید.', 'No blocked channels.')),
                for (final id in ids) ...[
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channels
                                      .where((c) => c['id'] == id)
                                      .firstOrNull?['name']
                                  as String? ??
                              _idPreview(id),
                          style: const TextStyle(
                            color: _ink,
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
                          child: Text(t('رفع مسدودی', 'Unblock')),
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

  String _searchText(String value) =>
      value.trim().toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک');
  String _idPreview(String id) => id.length > 20
      ? '${id.substring(0, 10)}…${id.substring(id.length - 8)}'
      : id;
  List<Widget> _news() {
    final following = followedChannels;
    final selected = following.any((c) => c['id'] == filter) ? filter : null;
    final feed = bulletins.where(
      (b) =>
          b['channelId'] is String &&
          app.isChannelFollowed(b['channelId'] as String) &&
          !app.isChannelBlocked(b['channelId'] as String),
    );
    final visible = orderNews(
      feed
          .where((b) => selected == null || b['channelId'] == selected)
          .toList(),
    );
    final owned = channels
        .where(
          (c) =>
              (c['owned'] == true || c['canPublish'] == true) &&
              !app.isChannelBlocked(c['id'] as String),
        )
        .toList();
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              t('خبرهای شما', 'Your news'),
              style: const TextStyle(
                color: _ink,
                fontSize: 23,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (owned.isNotEmpty) ...[
            const SizedBox(width: 10),
            FilledButton.icon(
              key: const ValueKey('compose-news'),
              onPressed: app.busy ? null : () => _chooseChannel(owned),
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
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.7),
      ),
      const SizedBox(height: 17),
      if (following.isNotEmpty) ...[
        OutlinedButton(
          key: const ValueKey('news-channel-picker'),
          onPressed: _chooseNewsChannel,
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            alignment: AlignmentDirectional.centerStart,
          ),
          child: Row(
            children: [
              const Icon(Icons.filter_list_rounded, size: 21, color: _tealText),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('نمایش خبر از', 'Showing news from'),
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      selected == null
                          ? t(
                              'همهٔ کانال‌های دنبال‌شده',
                              'All followed channels',
                            )
                          : following.firstWhere(
                                  (c) => c['id'] == selected,
                                )['name']
                                as String,
                      key: const ValueKey('news-channel-selection'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: _ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              const Icon(Icons.expand_more_rounded, size: 23, color: _muted),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
      if (visible.isEmpty) ...[
        _empty(
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
          onPressed: () => setState(() {
            tab = 1;
            discoverChannels = true;
          }),
          icon: const Icon(Icons.explore_outlined),
          label: Text(t('کشف کانال‌ها', 'Discover channels')),
        ),
      ] else
        ...visible.map((b) {
          final channel = channels.firstWhere(
            (c) => c['id'] == b['channelId'],
            orElse: () => {
              'id': b['channelId'] ?? b['id'],
              'name': _bulletinChannelName(b),
            },
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: NewsCard(
              news: b,
              channel: channel,
              fa: fa,
              assessment: _channelAssessment(b['channelId'] as String),
              onOpenChannel: () => _openChannel(channel),
            ),
          );
        }),
      const SizedBox(height: 17),
      _note(
        Icons.info_outline_rounded,
        t('منبع را مستقل بررسی کنید.', 'Check the source independently.'),
        t(
          'امضای معتبر، درستی خبر یا هویت واقعی ناشر را تضمین نمی‌کند.',
          'A valid signature does not establish factual accuracy or the publisher’s real-world identity.',
        ),
      ),
    ];
  }

  Future<void> _chooseNewsChannel() async {
    final result = await showModalBottomSheet<_NewsChannelSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(sheet).height * .82, 720),
          child: _NewsChannelPicker(app: app, selection: () => filter),
        ),
      ),
    );
    if (!mounted || result == null) return;
    final id = result.channelId;
    setState(() {
      filter = id != null && followedChannels.any((c) => c['id'] == id)
          ? id
          : null;
    });
  }

  String _bulletinChannelName(Map<String, dynamic> bulletin) {
    for (final channel in channels) {
      if (channel['id'] == bulletin['channelId']) {
        return channel['name'] as String;
      }
    }
    return bulletin['channelName'] as String? ??
        t('خبر عمومی', 'Public bulletin');
  }

  String _channelAssessment(String id) {
    if (channels.any(
      (channel) =>
          channel['id'] == id &&
          (channel['owned'] == true || channel['canPublish'] == true),
    )) {
      return t('کانال شما', 'Your channel');
    }
    return app.isChannelTrusted(id)
        ? t('مورد اعتماد شما', 'Trusted by you')
        : t('هنوز ارزیابی نکرده‌اید', 'Not assessed');
  }

  Widget _intro(String title, String body) => Column(
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
        style: const TextStyle(color: _muted, fontSize: 12, height: 1.9),
      ),
    ],
  );
  Widget _empty(IconData icon, String title, String body) => _Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 19),
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: _canvas,
              borderRadius: BorderRadius.circular(19),
            ),
            child: Icon(icon, color: _teal, size: 28),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontWeight: FontWeight.w800,
              fontSize: 16,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _muted, fontSize: 11, height: 1.9),
          ),
        ],
      ),
    ),
  );
  Widget _note(IconData icon, String title, String body) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: _teal.withValues(alpha: .065),
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: _teal.withValues(alpha: .17)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _tealText, size: 19),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                  height: 1.8,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 10.5,
                  height: 1.9,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Future<void> _createChannel() async {
    final before = channels.map((v) => v['id']).toSet();
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _CreateChannelPage(app: app)),
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
              final added = channels
                  .where((v) => !before.contains(v['id']))
                  .firstOrNull;
              if (added != null) {
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => ChannelToolsPage(
                      app: app,
                      channelId: added['id'] as String,
                    ),
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

  Future<void> _chooseChannel(List<Map<String, dynamic>> owned) async {
    if (owned.isEmpty) return;
    await _openComposer(owned, owned.first['id'] as String);
  }

  Future<void> _publish(Map<String, dynamic> channel) async {
    final owned = channels
        .where(
          (c) =>
              (c['owned'] == true || c['canPublish'] == true) &&
              !app.isChannelBlocked(c['id'] as String),
        )
        .toList();
    await _openComposer(owned, channel['id'] as String);
  }

  Future<void> _openChannel(Map<String, dynamic> channel) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ChannelNewsPage(
            app: app,
            channelId: channel['id'] as String,
            onIdentity: _channelIdentity,
            onBlock: _blockChannel,
            onPublish: (selected) => _openComposer(
              channels
                  .where(
                    (c) =>
                        (c['owned'] == true || c['canPublish'] == true) &&
                        !app.isChannelBlocked(c['id'] as String),
                  )
                  .toList(),
              selected['id'] as String,
              returnToFeed: false,
            ),
          ),
        ),
      );

  Future<void> _openComposer(
    List<Map<String, dynamic>> owned,
    String selectedId, {
    bool returnToFeed = true,
  }) async {
    final published = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            _ComposeNewsPage(app: app, channels: owned, selectedId: selectedId),
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
          backgroundColor: _canvas,
        ),
        body: _Home(app: app),
      ),
    ),
  );
}

class _NewsChannelSelection {
  const _NewsChannelSelection(this.channelId);
  final String? channelId;
}

class _NewsChannelPicker extends StatefulWidget {
  const _NewsChannelPicker({required this.app, required this.selection});
  final AppController app;
  final ValueGetter<String?> selection;

  @override
  State<_NewsChannelPicker> createState() => _NewsChannelPickerState();
}

class _NewsChannelPickerState extends State<_NewsChannelPicker> {
  final search = TextEditingController();
  String query = '';
  bool get fa => widget.app.languageCode != 'en';
  String t(String farsi, String english) => fa ? farsi : english;
  String normalized(String value) =>
      value.trim().toLowerCase().replaceAll('ي', 'ی').replaceAll('ك', 'ک');

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      final following =
          _maps(widget.app.snapshot['channels'])
              .where(
                (c) =>
                    widget.app.isChannelFollowed(c['id'] as String) &&
                    !widget.app.isChannelBlocked(c['id'] as String),
              )
              .toList()
            ..sort(
              (a, b) =>
                  normalized(a['name'] as String)
                      .compareTo(normalized(b['name'] as String)),
            );
      final selectedId = widget.selection();
      final selected = following.any((c) => c['id'] == selectedId)
          ? selectedId
          : null;
      final matches = following
          .where(
            (c) =>
                normalized('${c['name']} ${c['id']}')
                    .contains(normalized(query)),
          )
          .toList();
      return SafeArea(
        top: false,
        child: Column(
          key: const ValueKey('news-channel-picker-sheet'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(22, 0, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t('انتخاب کانال', 'Choose a channel'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('close-news-channel-picker'),
                    tooltip: t('بستن', 'Close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: _muted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: TextField(
                key: const ValueKey('news-channel-search'),
                controller: search,
                maxLength: 200,
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => query = value),
                decoration: InputDecoration(
                  hintText: t('نام یا شناسهٔ کانال', 'Channel name or ID'),
                  counterText: '',
                  prefixIcon: const Icon(Icons.search_rounded, size: 21),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          key: const ValueKey('clear-news-channel-search'),
                          tooltip: t('پاک‌کردن جست‌وجو', 'Clear search'),
                          onPressed: () {
                            search.clear();
                            setState(() => query = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 19),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 13),
            Expanded(
              child: ListView.separated(
                key: const ValueKey('news-channel-picker-list'),
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
                itemCount: matches.isEmpty ? 2 : matches.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _option(
                      null,
                      t('همهٔ کانال‌های دنبال‌شده', 'All followed channels'),
                      t(
                        'خبرها از همهٔ منابع انتخابی شما',
                        'News from all the sources you follow',
                      ),
                      selected == null,
                    );
                  }
                  if (matches.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(22),
                      child: Text(
                        t(
                          'کانالی با این جست‌وجو پیدا نشد.',
                          'No matching followed channels.',
                        ),
                        key: const ValueKey('news-channel-search-empty'),
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    );
                  }
                  final channel = matches[index - 1];
                  final id = channel['id'] as String;
                  return _option(
                    id,
                    channel['name'] as String,
                    channel['description'] as String? ?? '',
                    selected == id,
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _option(String? id, String title, String description, bool selected) =>
      ListTile(
        key: ValueKey('news-channel-option-${id ?? 'all'}'),
        selected: selected,
        selectedTileColor: _teal.withValues(alpha: .08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        leading: Icon(
          id == null ? Icons.dynamic_feed_outlined : Icons.campaign_outlined,
          color: selected ? _tealText : _muted,
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: description.isEmpty
            ? null
            : Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 10),
              ),
        trailing: selected
            ? const Icon(Icons.check_circle_rounded, color: _tealText, size: 21)
            : const SizedBox(width: 21),
        onTap: () => Navigator.pop(context, _NewsChannelSelection(id)),
      );
}

class _CreateChannelPage extends StatefulWidget {
  const _CreateChannelPage({required this.app});
  final AppController app;
  @override
  State<_CreateChannelPage> createState() => _CreateChannelPageState();
}

class _CreateChannelPageState extends State<_CreateChannelPage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final description = TextEditingController();
  bool submitting = false;
  String? submissionError;
  bool get fa => widget.app.languageCode != 'en';
  String t(String farsi, String english) => fa ? farsi : english;

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (submitting || widget.app.busy || !form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      submitting = true;
      submissionError = null;
    });
    final before = (widget.app.snapshot['channels'] as List? ?? [])
        .whereType<Map>()
        .map((v) => v['id'])
        .toSet();
    await widget.app.perform(
      () => widget.app.createChannel(name.text.trim(), description.text.trim()),
    );
    if (!mounted) return;
    if (widget.app.error != null) {
      setState(() {
        submitting = false;
        submissionError = widget.app.error;
      });
    } else {
      if (widget.app.snapshot['channelKeyManagement'] == true) {
        final added = (widget.app.snapshot['channels'] as List? ?? [])
            .whereType<Map>()
            .where((v) => !before.contains(v['id']))
            .firstOrNull;
        final save = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t('نسخهٔ بازیابی کانال', 'Channel recovery file')),
            content: Text(
              t(
                'کانال ساخته شد. یک فایل رمزگذاری‌شده ذخیره کنید تا در صورت تعویض یا از دست رفتن گوشی، مالکیت کانال را بازیابی کنید.',
                'Channel created. Save an encrypted file so you can recover ownership if you lose or replace this phone.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(t('بعداً', 'Later')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t('ذخیره با رمز', 'Save with a password')),
              ),
            ],
          ),
        );
        if (save == true && added != null && mounted) {
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => ChannelToolsPage(
                app: widget.app,
                channelId: added['id'] as String,
                startBackup: true,
              ),
            ),
          );
        }
        if (!mounted) return;
      }
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !submitting,
    child: Scaffold(
      key: const ValueKey('create-channel-page'),
      appBar: AppBar(
        title: Text(t('ساخت کانال', 'Create a channel')),
        backgroundColor: _canvas,
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
            children: [
              Text(
                t('یک جای روشن برای خبرهای شما', 'A home for your updates'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                t(
                  'نام و توضیحی انتخاب کنید که مردم بتوانند کانال شما را بشناسند. می‌توانید بدون اتصال هم کانال بسازید.',
                  'Choose a name and description people can recognize. You can create your channel offline.',
                ),
              ),
              const SizedBox(height: 25),
              TextFormField(
                key: const ValueKey('channel-name'),
                controller: name,
                enabled: !submitting,
                textInputAction: TextInputAction.next,
                maxLength: 80,
                maxLengthEnforcement: MaxLengthEnforcement.none,
                onChanged: (_) => setState(() => submissionError = null),
                decoration: InputDecoration(
                  labelText: t('نام کانال', 'Channel name'),
                  hintText: t(
                    'مثلاً: خبرهای محله',
                    'For example: Community updates',
                  ),
                  helperText: t(
                    'کوتاه و مشخص؛ نام، تأیید هویت نیست.',
                    'Keep it clear. A name is not identity verification.',
                  ),
                  helperMaxLines: 3,
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.isEmpty) {
                    return t(
                      'برای کانالتان نامی بنویسید.',
                      'Give your channel a name.',
                    );
                  }
                  if (text.length > 80 || utf8.encode(text).length > 256) {
                    return t(
                      'نام طولانی است؛ نام کوتاه‌تری انتخاب کنید.',
                      'This name is too long. Choose a shorter name.',
                    );
                  }
                  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
                    return t(
                      'نام را در یک خط، بدون نویسهٔ کنترلی بنویسید.',
                      'Use a single line without control characters.',
                    );
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const ValueKey('channel-description'),
                controller: description,
                enabled: !submitting,
                maxLines: 4,
                minLines: 3,
                maxLength: 500,
                maxLengthEnforcement: MaxLengthEnforcement.none,
                onChanged: (_) => setState(() => submissionError = null),
                decoration: InputDecoration(
                  labelText: t(
                    'دربارهٔ کانال · اختیاری',
                    'About this channel · optional',
                  ),
                  alignLabelWithHint: true,
                  hintText: t(
                    'چه خبرهایی منتشر می‌کنید و برای چه کسانی؟',
                    'What will you share, and who is it for?',
                  ),
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final text = (value ?? '').trim();
                  if (text.length > 500 || utf8.encode(text).length > 2048) {
                    return t(
                      'توضیح طولانی است؛ کمی کوتاه‌ترش کنید.',
                      'This description is too long. Shorten it a little.',
                    );
                  }
                  if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')
                      .hasMatch(text)) {
                    return t(
                      'نویسه‌های کنترلی را از توضیح حذف کنید.',
                      'Remove control characters from the description.',
                    );
                  }
                  return null;
                },
              ),
              const SizedBox(height: 23),
              Text(
                t('پیش‌نمایش کانال', 'CHANNEL PREVIEW'),
                style: const TextStyle(
                  fontSize: 10,
                  color: _muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _IconTile(Icons.campaign_outlined, color: _teal),
                    const SizedBox(height: 14),
                    Text(
                      name.text.trim().isEmpty
                          ? t('نام کانال شما', 'Your channel name')
                          : name.text.trim(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (description.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(description.text.trim()),
                    ],
                    const SizedBox(height: 14),
                    Text(
                      t(
                        'کانال شما · خودکار دنبال می‌شود',
                        'Your channel · followed automatically',
                      ),
                      style: const TextStyle(color: _tealText, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                t(
                  'نام، توضیح و خبرها عمومی هستند. کلید این دستگاه مالک کانال است؛ دیگران پس از برقرارشدن مسیر آن را می‌بینند.',
                  'The name, description and news are public. This device’s key owns the channel; others see it when a route connects.',
                ),
                style: const TextStyle(fontSize: 11, height: 1.8),
              ),
              if (submissionError != null) ...[
                const SizedBox(height: 16),
                _SubmissionError(submissionError!, farsi: fa),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
          child: FilledButton.icon(
            key: const ValueKey('submit-create-channel'),
            onPressed: submitting ? null : submit,
            icon: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(
              submitting
                  ? t('در حال ساخت…', 'Creating…')
                  : t('ساخت کانال', 'Create channel'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ComposeNewsPage extends StatefulWidget {
  const _ComposeNewsPage({
    required this.app,
    required this.channels,
    required this.selectedId,
  });
  final AppController app;
  final List<Map<String, dynamic>> channels;
  final String selectedId;
  @override
  State<_ComposeNewsPage> createState() => _ComposeNewsPageState();
}

class _ComposeNewsPageState extends State<_ComposeNewsPage> {
  final form = GlobalKey<FormState>();
  final text = TextEditingController();
  late final nickname = TextEditingController(
    text: channel['writerNickname'] as String? ?? '',
  );
  late String selectedId = widget.selectedId;
  Uint8List? image;
  bool pickingImage = false;
  bool reviewing = false;
  bool submitting = false;
  String? submissionError;
  bool get fa => widget.app.languageCode != 'en';
  String t(String farsi, String english) => fa ? farsi : english;
  int get bytes => utf8.encode(text.text).length;
  Map<String, dynamic> get channel =>
      widget.channels.firstWhere((c) => c['id'] == selectedId);

  @override
  void dispose() {
    text.dispose();
    nickname.dispose();
    super.dispose();
  }

  Future<void> pickImage() async {
    if (pickingImage || submitting) return;
    setState(() => pickingImage = true);
    try {
      final bytes = await PilotPlatform.pickNewsImage();
      if (bytes != null) {
        NewsImage.inspect(bytes);
        if (mounted) setState(() => image = bytes);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => submissionError = t(
            'تصویر انتخاب نشد؛ فایل کوچک‌تری امتحان کنید.',
            'Could not attach this image. Try a smaller file.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => pickingImage = false);
    }
  }

  Future<void> reviewOrPublish() async {
    if (submitting || widget.app.busy || pickingImage) return;
    if (!reviewing) {
      if (!form.currentState!.validate()) return;
      FocusScope.of(context).unfocus();
      setState(() => reviewing = true);
      return;
    }
    setState(() {
      submitting = true;
      submissionError = null;
    });
    await widget.app.perform(() async {
      if (nickname.text.trim() !=
          (channel['writerNickname'] as String? ?? '')) {
        await widget.app.channelAction('setWriterNickname', {
          'channelId': selectedId,
          'nickname': nickname.text,
        });
      }
      await (image == null
          ? widget.app.publishToChannel(selectedId, text.text)
          : widget.app.publishNewsWithImage(selectedId, text.text, image!));
    });
    if (!mounted) return;
    if (widget.app.error != null) {
      setState(() {
        submitting = false;
        submissionError = widget.app.error;
      });
    } else {
      Navigator.of(context).pop(selectedId);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !submitting,
    child: Scaffold(
      key: const ValueKey('compose-news-page'),
      appBar: AppBar(
        title: Text(
          reviewing
              ? t('بازبینی خبر', 'Review news')
              : t('نوشتن خبر', 'Write news'),
        ),
        backgroundColor: _canvas,
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
            children: [
              Text(
                reviewing
                    ? t(
                        'پیش از انتشار، یک بار بخوانید.',
                        'One last look before publishing.',
                      )
                    : t('چه خبری دارید؟', 'What would you like to share?'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 10),
              Text(
                reviewing
                    ? t(
                        'این متن با کلید شما امضا و در کانال انتخاب‌شده منتشر می‌شود.',
                        'This text will be signed with your key and published to the selected channel.',
                      )
                    : t(
                        'کانال را انتخاب کنید، خبر را بنویسید و پیش‌نمایش را ببینید.',
                        'Choose your channel, write your update, then review it.',
                      ),
              ),
              const SizedBox(height: 24),
              if (!reviewing) ...[
                DropdownButtonFormField<String>(
                  key: const ValueKey('compose-channel'),
                  initialValue: selectedId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('انتشار در کانال', 'Publish to channel'),
                  ),
                  items: widget.channels
                      .map(
                        (c) => DropdownMenuItem<String>(
                          value: c['id'] as String,
                          child: Text(
                            c['name'] as String,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: submitting
                      ? null
                      : (value) => setState(() {
                          selectedId = value!;
                          nickname.text =
                              channel['writerNickname'] as String? ?? '';
                        }),
                ),
                const SizedBox(height: 22),
                TextFormField(
                  key: const ValueKey('news-text'),
                  controller: text,
                  minLines: 6,
                  maxLines: 14,
                  enabled: !submitting,
                  keyboardType: TextInputType.multiline,
                  onChanged: (_) => setState(() => submissionError = null),
                  decoration: InputDecoration(
                    labelText: t('متن خبر', 'News text'),
                    alignLabelWithHint: true,
                    hintText: t(
                      'پیامتان را روشن و کوتاه بنویسید…',
                      'Write a clear, short update…',
                    ),
                    errorMaxLines: 3,
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return t(
                        'پیش از بازبینی، متن خبر را بنویسید.',
                        'Write your news before reviewing it.',
                      );
                    }
                    if (utf8.encode(value ?? '').length >
                        maxBulletinTextBytes) {
                      return t(
                        'متن طولانی است؛ کوتاه‌ترش کنید.',
                        'Text too long. Shorten it before continuing.',
                      );
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                if (!reviewing)
                  OutlinedButton.icon(
                    key: const ValueKey('attach-news-image'),
                    onPressed: submitting || pickingImage ? null : pickImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      pickingImage
                          ? t('فشرده‌سازی تصویر…', 'Compressing image…')
                          : t('افزودن تصویر اختیاری', 'Attach optional image'),
                    ),
                  ),
                if (image != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.memory(
                      image!,
                      height: 180,
                      fit: BoxFit.contain,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t(
                            'تصویر فشرده · ${((image!.length) / 1024).ceil()} کیلوبایت',
                            'Compressed image · ${((image!.length) / 1024).ceil()} KB',
                          ),
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                      ),
                      if (!reviewing)
                        IconButton(
                          tooltip: t('حذف تصویر', 'Remove image'),
                          onPressed: () => setState(() => image = null),
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('writer-nickname'),
                  controller: nickname,
                  maxLength: 60,
                  enabled: !submitting,
                  decoration: InputDecoration(
                    labelText: t(
                      'نام مستعار نویسنده (اختیاری)',
                      'Writer nickname (optional)',
                    ),
                    helperText: t(
                      'زیر خبر نمایش داده می‌شود؛ نام واقعی لازم نیست.',
                      'Shown below your news; no real name is required.',
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    try {
                      validateNewsByline(value.trim());
                      return null;
                    } catch (_) {
                      return t(
                        'نام کوتاه و تک‌خطی وارد کنید.',
                        'Enter a short, single-line nickname.',
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
              ] else ...[
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.campaign_outlined,
                            color: _tealText,
                            size: 20,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              channel['name'] as String,
                              style: const TextStyle(
                                color: _ink,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        t(
                          'کانال شما · خبر عمومی',
                          'Your channel · public news',
                        ),
                        style: const TextStyle(fontSize: 10, color: _tealText),
                      ),
                      const Divider(height: 28),
                      if (nickname.text.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            t(
                              'نویسنده: ${nickname.text.trim()}',
                              'By ${nickname.text.trim()}',
                            ),
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ),
                      if (image != null) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            image!,
                            height: 180,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      SelectableText(
                        text.text,
                        key: const ValueKey('news-review-text'),
                        style: const TextStyle(
                          fontSize: 16,
                          color: _ink,
                          height: 1.9,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  key: const ValueKey('edit-news'),
                  onPressed: submitting
                      ? null
                      : () => setState(() => reviewing = false),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: Text(t('ویرایش متن و کانال', 'Edit text & channel')),
                ),
              ],
              Text(
                bytes > maxBulletinTextBytes
                    ? t(
                        'متن طولانی است؛ کوتاه‌ترش کنید.',
                        'Text too long. Shorten it before continuing.',
                      )
                    : t(
                        '${_persianDigits('${(bytes * 100 / maxBulletinTextBytes).ceil()}')}٪ از ظرفیت متن',
                        'Space used: ${(bytes * 100 / maxBulletinTextBytes).ceil()}%',
                      ),
                key: const ValueKey('news-capacity'),
                style: TextStyle(
                  color: bytes > maxBulletinTextBytes ? _pink : _muted,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: math.min(bytes / maxBulletinTextBytes, 1),
                backgroundColor: _line,
                color: bytes > maxBulletinTextBytes ? _pink : _teal,
                minHeight: 3,
              ),
              const SizedBox(height: 20),
              Text(
                t(
                  'خبر عمومی است؛ همتاها می‌توانند آن را نگه دارند و بازنشر کنند. امضا هویت انسانی یا درستی خبر را تضمین نمی‌کند.',
                  'This news is public. Peers can keep and relay it. A signature does not verify human identity or factual accuracy.',
                ),
                style: const TextStyle(fontSize: 11, height: 1.8),
              ),
              if (submissionError != null) ...[
                const SizedBox(height: 16),
                _SubmissionError(submissionError!, farsi: fa),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
          child: FilledButton.icon(
            key: const ValueKey('submit-news'),
            onPressed: submitting ? null : reviewOrPublish,
            icon: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    reviewing ? Icons.send_rounded : Icons.visibility_outlined,
                  ),
            label: Text(
              submitting
                  ? t('در حال امضا…', 'Signing…')
                  : reviewing
                  ? t('امضا و انتشار', 'Sign & publish')
                  : t('بازبینی خبر', 'Review news'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SubmissionError extends StatelessWidget {
  const _SubmissionError(this.message, {required this.farsi});
  final String message;
  final bool farsi;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            farsi ? 'این کار کامل نشد' : 'That action did not finish',
            style: const TextStyle(color: _pink, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(message, style: const TextStyle(color: _pink, fontSize: 12)),
        ],
      ),
    ),
  );
}

class _LiveRadar extends StatefulWidget {
  const _LiveRadar({
    super.key,
    required this.active,
    required this.searching,
    required this.contacts,
    required this.animate,
    required this.number,
    required this.caption,
  });
  final bool active, searching, animate;
  final int contacts;
  final String number, caption;
  @override
  State<_LiveRadar> createState() => _LiveRadarState();
}

class _LiveRadarState extends State<_LiveRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );
  void updateMotion() {
    if (widget.active &&
        widget.animate &&
        !MediaQuery.disableAnimationsOf(context)) {
      motion.repeat();
    } else {
      motion.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateMotion();
  }

  @override
  void didUpdateWidget(covariant _LiveRadar oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateMotion();
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '${widget.number} ${widget.caption}',
    child: SizedBox(
      height: 184,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: motion,
        builder: (context, _) => CustomPaint(
          painter: _RadarPainter(
            progress: motion.value,
            contacts: widget.contacts,
            active: widget.active,
            searching: widget.searching,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.caption,
                  style: const TextStyle(
                    color: Color(0xFFB8D5DC),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({
    required this.progress,
    required this.contacts,
    required this.active,
    required this.searching,
  });
  final double progress;
  final int contacts;
  final bool active, searching;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width * .45, 82.0);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .8
      ..color = Colors.white.withValues(alpha: .12);
    for (final scale in [.35, .65, 1.0]) {
      canvas.drawCircle(center, radius * scale, line);
    }
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      line,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      line,
    );
    if (active) {
      canvas.drawCircle(
        center,
        radius * (.3 + .7 * progress),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _teal.withValues(alpha: (1 - progress) * .4),
      );
      if (searching) {
        final sweep = Paint()
          ..shader = SweepGradient(
            startAngle: 0,
            endAngle: math.pi / 2,
            colors: [_teal.withValues(alpha: 0), _teal.withValues(alpha: .22)],
            transform: GradientRotation(progress * math.pi * 2),
          ).createShader(Rect.fromCircle(center: center, radius: radius));
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          progress * math.pi * 2,
          math.pi / 2,
          true,
          sweep,
        );
      }
    }
    for (var i = 0; i < math.min(contacts, 6); i++) {
      final angle = i * 2.399 + .5;
      final r = radius * (.55 + (i % 3) * .15);
      canvas.drawCircle(
        center + Offset(math.cos(angle) * r, math.sin(angle) * r),
        3.5,
        Paint()..color = i == 0 ? _pink : _teal,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      contacts != oldDelegate.contacts ||
      active != oldDelegate.active ||
      searching != oldDelegate.searching;
}

String _persianDigits(String text) {
  const latin = '0123456789', persian = '۰۱۲۳۴۵۶۷۸۹';
  return text
      .split('')
      .map((c) => latin.contains(c) ? persian[latin.indexOf(c)] : c)
      .join();
}
