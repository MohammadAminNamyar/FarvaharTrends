/// The earlier paired-pilot UI, reachable from the reader's "Advanced
/// diagnostics" button: manual peer trust, test bulletins and trial results.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pilot_platform/pilot_platform.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_controller.dart';
import '../core/bootstrap_config.dart';
import '../core/models.dart';
import '../core/snapshot_dto.dart';
import 'legacy_text.dart';
import 'localization.dart';
import 'shared_widgets.dart';
import 'theme.dart';

class LegacyDiagnosticsPage extends StatefulWidget {
  const LegacyDiagnosticsPage({super.key, required this.app});
  final AppController app;
  @override
  State<LegacyDiagnosticsPage> createState() => _LegacyDiagnosticsState();
}

class _LegacyDiagnosticsState extends State<LegacyDiagnosticsPage>
    with WidgetsBindingObserver {
  int tab = 0;
  AppController get app => widget.app;
  Snapshot get snapshot => Snapshot.fromJson(app.snapshot);
  // This page predates the typed views and still renders raw map fields.
  List<Map<String, dynamic>> get peers => [
    for (final peer in snapshot.peers) peer.raw,
  ];
  List<TrialItem> get trials => snapshot.trials;
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
                      'assets/brand/farvahar-mark.png',
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
                        LegacyText(
                          'FarvaharTrends',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: inkColor,
                            letterSpacing: -.7,
                          ),
                        ),
                        SizedBox(height: 3),
                        LegacyText(
                          'INDEPENDENT BY DESIGN',
                          style: TextStyle(
                            fontSize: 7.5,
                            fontWeight: FontWeight.w800,
                            color: mutedColor,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const AppTag('PILOT', color: goldColor),
                  IconButton(
                    tooltip: 'Pilot guide',
                    onPressed: _guide,
                    icon: const Icon(
                      Icons.help_outline_rounded,
                      size: 21,
                      color: mutedColor,
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
                      CircularProgressIndicator(
                        color: tealColor,
                        strokeWidth: 2,
                      ),
                      SizedBox(height: 20),
                      LegacyText('Preparing your device identity…'),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: RefreshIndicator(
                  color: tealColor,
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
          border: Border(top: BorderSide(color: lineColor)),
        ),
        child: NavigationBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          height: 74,
          selectedIndex: tab,
          indicatorColor: tealColor.withValues(alpha: .12),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              fontFamily: LanguageScope.isFarsi(context)
                  ? 'Vazirmatn'
                  : 'Manrope',
              fontSize: 10,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w800
                  : FontWeight.w600,
              color: states.contains(WidgetState.selected)
                  ? inkColor
                  : mutedColor,
            ),
          ),
          onDestinationSelected: (value) => setState(() => tab = value),
          destinations: [
            NavigationDestination(
              icon: Icon(Icons.space_dashboard_outlined, size: 21),
              selectedIcon: Icon(
                Icons.space_dashboard_rounded,
                size: 21,
                color: inkColor,
              ),
              label: diagnostic(context, 'Overview'),
            ),
            NavigationDestination(
              icon: Icon(Icons.hub_outlined, size: 22),
              selectedIcon: Icon(Icons.hub_rounded, size: 22, color: inkColor),
              label: diagnostic(context, 'Peers'),
            ),
            NavigationDestination(
              icon: Icon(Icons.article_outlined, size: 22),
              selectedIcon: Icon(
                Icons.article_rounded,
                size: 22,
                color: inkColor,
              ),
              label: diagnostic(context, 'Bulletins'),
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_rounded, size: 23),
              selectedIcon: Icon(
                Icons.bar_chart_rounded,
                size: 23,
                color: inkColor,
              ),
              label: diagnostic(context, 'Results'),
            ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _overview() {
    final connected = snapshot.connectedCount;
    final confirmed = trials.fold<int>(0, (n, item) => n + item.confirmed);
    return [
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: inkColor,
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
                      Icon(Icons.circle, color: tealColor, size: 6),
                      SizedBox(width: 7),
                      Expanded(
                        child: LegacyText(
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
                    child: LegacyText(
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
                  const LegacyText(
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
                      Container(width: 21, height: 2, color: tealColor),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: LegacyText(
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
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(
                  app.running
                      ? Icons.sensors_rounded
                      : Icons.sensors_off_rounded,
                  color: app.running ? tealColor : mutedColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LegacyText(
                        app.running ? 'Receiving is on' : 'Receiving is off',
                        style: const TextStyle(
                          color: inkColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      LegacyText(
                        app.running
                            ? (app.activeMode
                                  ? 'Active Android mode'
                                  : 'Standard comparison mode')
                            : 'Your phone is ready when you are.',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: mutedColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: app.running ? tealColor : const Color(0xFFC3CFD5),
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
                label: LegacyText(
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
                  child: const LegacyText(
                    'Try standard mode for comparison',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: mutedColor),
                  ),
                ),
              ),
            if (app.running)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LegacyText(
                  'Stay connected to a reachable paired peer. Android active mode shows a persistent receiving notification.',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: mutedColor,
                    height: 1.6,
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          Expanded(
            child: MetricTile(
              value: '$connected',
              label: 'CONNECTED PEERS',
              icon: Icons.hub_outlined,
              color: tealColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MetricTile(
              value: '$confirmed',
              label: 'LOCKED + ≤ 5 MIN',
              icon: Icons.verified_outlined,
              color: errorColor,
            ),
          ),
        ],
      ),
      const SizedBox(height: 26),
      const _Section('Your device', 'A few conditions shape every connection.'),
      const SizedBox(height: 13),
      AppCard(
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
                label: const LegacyText('Battery settings'),
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
        child: const AppCard(
          child: Row(
            children: [
              IconTile(Icons.science_outlined, color: goldColor),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LegacyText(
                      'Make your first connection',
                      style: TextStyle(
                        color: inkColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                    SizedBox(height: 4),
                    LegacyText(
                      'A five-step guide to a meaningful trial.',
                      style: TextStyle(color: mutedColor, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: inkColor, size: 19),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _condition(IconData icon, String name, String value) => Row(
    children: [
      Icon(icon, size: 18, color: mutedColor),
      const SizedBox(width: 10),
      Expanded(
        child: LegacyText(
          name,
          style: const TextStyle(
            fontSize: 11.5,
            color: inkColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      Flexible(
        child: LegacyText(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(fontSize: 11, color: mutedColor),
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
    AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconTile(Icons.badge_outlined, color: tealColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LegacyText(
                      'Your pairing card',
                      style: TextStyle(
                        color: inkColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    LegacyText(
                      app.label,
                      style: const TextStyle(fontSize: 11, color: mutedColor),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit your card',
                onPressed: app.identity == null ? null : _editOwn,
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 19,
                  color: mutedColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LegacyText(
            app.advertisedHost.isEmpty
                ? 'Trust only · no dialing address'
                : '${app.advertisedHost}:$defaultPeerPort',
            style: const TextStyle(color: mutedColor, fontSize: 11),
          ),
          const SizedBox(height: 9),
          if (app.identity != null) Fingerprint(app.identity!.id),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: app.identity == null ? null : _showOwn,
              icon: const Icon(Icons.ios_share_rounded, size: 17),
              label: const LegacyText('Show pairing card'),
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('share-starting-peers'),
              onPressed: app.identity == null ? null : _shareStartingPeers,
              icon: const Icon(Icons.qr_code_2_rounded, size: 17),
              label: const LegacyText('Share starting peers'),
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
        AppTag('${peers.length}', color: tealColor),
      ],
    ),
    const SizedBox(height: 14),
    SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: app.busy || app.identity == null ? null : _importPeer,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const LegacyText('Import a peer card or starting-peer list'),
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

  Widget _peerCard(Map<String, dynamic> peer) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IconTile(Icons.person_outline_rounded, color: tealColor),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LegacyText(
                    peer['name']?.toString() ?? 'Peer',
                    style: const TextStyle(
                      color: inkColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  LegacyText(
                    peer['connected'] == true
                        ? 'Connected'
                        : 'Waiting for a route',
                    style: TextStyle(
                      color: peer['connected'] == true
                          ? tealTextColor
                          : mutedColor,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded, color: mutedColor),
              onSelected: (value) =>
                  value == 'edit' ? _editPeer(peer) : _removePeer(peer),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'edit',
                  child: LegacyText('Update address'),
                ),
                PopupMenuItem(
                  value: 'remove',
                  child: LegacyText('Remove trust'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 13),
        LegacyText(
          (peer['host'] as String? ?? '').isEmpty
              ? 'Trust only · no dialing address'
              : '${peer['host']}:${peer['port']}',
          style: const TextStyle(fontSize: 11, color: mutedColor),
        ),
        const SizedBox(height: 9),
        Fingerprint(peer['id'] as String),
      ],
    ),
  );

  List<Widget> _bulletinPage() {
    final bulletins = [for (final item in snapshot.bulletins) item.raw];
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
          label: const LegacyText('Publish a test bulletin'),
        ),
      ),
      if (!app.running || peers.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: LegacyText(
            'Start receiving and pair a peer to publish.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: mutedColor),
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
          AppTag('${bulletins.length}', color: tealColor),
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
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        color: tealColor,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: LegacyText(
                          'SIGNATURE VERIFIED',
                          style: TextStyle(
                            fontSize: 8,
                            color: tealTextColor,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8,
                          ),
                        ),
                      ),
                      LegacyText(
                        _time(item['createdAtMs']),
                        style: const TextStyle(fontSize: 9, color: mutedColor),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  LegacyText(
                    item['text']?.toString() ?? '',
                    style: const TextStyle(
                      color: inkColor,
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
                      LegacyText(
                        'Run ${item['runId']}',
                        style: const TextStyle(color: mutedColor, fontSize: 9),
                      ),
                      LegacyText(
                        '№ ${item['sequence']}',
                        style: const TextStyle(color: mutedColor, fontSize: 9),
                      ),
                      LegacyText(
                        'Source ${_short(item['sourceId'])}',
                        style: const TextStyle(color: mutedColor, fontSize: 9),
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
    final enrolled = trials.fold<int>(0, (n, r) => n + r.enrolled);
    final confirmed = trials.fold<int>(0, (n, r) => n + r.confirmed);
    final unlocked = trials.fold<int>(0, (n, r) => n + r.timelyUnlocked);
    final unknown = trials.fold<int>(0, (n, r) => n + r.unknown);
    return [
      const _PageIntro(
        'Measure the connection.',
        'Evidence from your own trials. Every paired recipient stays in the count.',
      ),
      const SizedBox(height: 23),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppTag('LOCKED DELIVERY · ≤ 5 MIN', color: tealColor),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                LegacyText(
                  '$confirmed',
                  style: const TextStyle(
                    color: inkColor,
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
                    child: LegacyText(
                      '/ $enrolled recipients',
                      style: const TextStyle(color: mutedColor, fontSize: 12),
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
                color: tealColor,
                backgroundColor: canvasColor,
              ),
            ),
            const SizedBox(height: 17),
            const LegacyText(
              'Confirmed only when a signed receipt returns to the source within five minutes and the receiver reports a known locked state.',
              style: TextStyle(fontSize: 11, color: mutedColor, height: 1.65),
            ),
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _resultMini(
                    '$unlocked',
                    'Timely · unlocked',
                    errorColor,
                  ),
                ),
                Expanded(
                  child: _resultMini(
                    '$unknown',
                    'Unproven / missing',
                    mutedColor,
                  ),
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
            child: AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: LegacyText(
                          trial.raw['runId']?.toString() ?? 'Trial',
                          style: const TextStyle(
                            color: inkColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      LegacyText(
                        _time(trial.raw['createdAtMs']),
                        style: const TextStyle(color: mutedColor, fontSize: 9),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Wrap(
                    spacing: 13,
                    runSpacing: 8,
                    children: [
                      LegacyText(
                        '${trial.raw['confirmed']} locked ≤ 5 min',
                        style: const TextStyle(
                          color: tealTextColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      LegacyText(
                        '${trial.raw['timelyUnlocked']} timely unlocked',
                        style: const TextStyle(color: mutedColor, fontSize: 10),
                      ),
                      LegacyText(
                        '${trial.raw['unknown']} unproven',
                        style: const TextStyle(color: mutedColor, fontSize: 10),
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
          label: const LegacyText('Export trial report'),
        ),
      ),
      const SizedBox(height: 13),
      Center(
        child: TextButton.icon(
          onPressed: _guide,
          icon: const Icon(Icons.science_outlined, size: 16),
          label: const LegacyText(
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
      LegacyText(
        value,
        style: TextStyle(
          color: color,
          fontSize: 24,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 4),
      LegacyText(
        label,
        style: const TextStyle(color: mutedColor, fontSize: 9.5),
      ),
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
        const Icon(Icons.error_outline_rounded, color: errorColor, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: LegacyText(
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
      color: tealColor.withValues(alpha: .065),
      border: Border.all(color: tealColor.withValues(alpha: .17)),
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
              LegacyText(
                title,
                style: const TextStyle(
                  color: inkColor,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              LegacyText(
                body,
                style: const TextStyle(
                  color: mutedColor,
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
    final card = app.ownCard();
    final token = card.toText();
    // The compact JSON card is the smallest scannable form of the same card.
    final qrData = jsonEncode(card.toJson());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LegacyText('Your pairing card'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const LegacyText(
                  'Copy this card to the other phone. Compare the complete fingerprint together. Import their card here too.',
                ),
                const SizedBox(height: 18),
                Fingerprint(app.identity!.id),
                const SizedBox(height: 18),
                _QrPanel(qrData, keyName: 'own-card'),
                const SizedBox(height: 18),
                SelectableText(
                  token,
                  style: const TextStyle(fontSize: 9, color: mutedColor),
                  maxLines: 8,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LegacyText('Close'),
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
            label: const LegacyText('Copy card'),
          ),
        ],
      ),
    );
  }

  Future<void> _shareStartingPeers() async {
    final String document;
    try {
      document = await app.exportBootstrapDocument();
    } catch (ex) {
      app.recordFailure(ex);
      return;
    }
    if (!mounted) return;
    final config = parseBootstrapConfig(document);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LegacyText('Share starting peers'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const LegacyText(
                  'A starting-peer list only introduces dialing addresses. It cannot sign news or change what this phone shares. Share it with people you know; it stays on this phone otherwise.',
                ),
                const SizedBox(height: 12),
                LegacyText(
                  config.isEmpty
                      ? 'Nothing shareable yet: give your card a public address or wait for helper contacts.'
                      : '${config.peers.length} starting peers · ${config.dhtBootstrap.length} DHT nodes',
                  style: const TextStyle(color: mutedColor, fontSize: 11),
                ),
                const SizedBox(height: 18),
                _QrPanel(document, keyName: 'starting-peers'),
                const SizedBox(height: 18),
                SelectableText(
                  document,
                  key: const ValueKey('starting-peers-text'),
                  style: const TextStyle(fontSize: 9, color: mutedColor),
                  maxLines: 8,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LegacyText('Close'),
          ),
          FilledButton.icon(
            key: const ValueKey('copy-starting-peers'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: document));
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
                _toast('Starting-peer list copied');
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const LegacyText('Copy list'),
          ),
        ],
      ),
    );
  }

  Future<void> _importPeer() async {
    final token = TextEditingController();
    String? error;
    final document = await _inputDialog<(String, BootstrapConfig)>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const LegacyText('Import a peer card or starting-peer list'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LegacyText(
                    'Paste the card shared by the other test phone, or a starting-peer list.',
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('import-peer-text'),
                    controller: token,
                    maxLines: 5,
                    maxLength: maxBootstrapConfigBytes,
                    decoration: const InputDecoration(
                      labelText: 'Pairing token',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (error != null)
                    LegacyText(
                      error!,
                      style: const TextStyle(color: errorColor, fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const LegacyText('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('review-import'),
              onPressed: () {
                try {
                  final text = token.text.trim();
                  Navigator.pop(dialogContext, (
                    text,
                    app.parseBootstrapDocument(text),
                  ));
                } catch (ex) {
                  app.recordFailure(ex);
                  update(() => error = app.error);
                }
              },
              child: const LegacyText('Review identity'),
            ),
          ],
        ),
      ),
    );
    token.dispose();
    if (document == null || !mounted) return;
    final (text, config) = document;
    final cards = config.peers;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: LegacyText(
          cards.length == 1
              ? 'Trust ${cards.single.name}?'
              : 'Trust ${cards.length} starting peers?',
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LegacyText(
                  'Compare every group below with the fingerprint shown on the other phone, using a channel you trust.',
                ),
                for (final card in cards) ...[
                  const SizedBox(height: 18),
                  if (cards.length > 1)
                    LegacyText(
                      card.name,
                      style: const TextStyle(
                        color: inkColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  Fingerprint(card.id),
                  const SizedBox(height: 8),
                  LegacyText(
                    card.host.isEmpty
                        ? 'Trust only · no dialing address'
                        : 'Address: ${card.host}:${card.port}',
                  ),
                ],
                if (config.dhtBootstrap.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  LegacyText(
                    'DHT nodes: ${config.dhtBootstrap.join(', ')}',
                    style: const TextStyle(color: mutedColor, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
                const LegacyText(
                  'This peer can send signed test bulletins and receive yours. A matching fingerprint confirms identity, not network reachability.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const LegacyText('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('approve-import'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const LegacyText('Fingerprint matches · trust'),
          ),
        ],
      ),
    );
    if (approved == true) {
      await app.perform(() => app.importBootstrapDocument(text));
    }
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
          title: LegacyText(title),
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
                  const LegacyText(
                    'Use an address the other phone can reach. Wi-Fi addresses usually work only on the same local network.',
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: LegacyText(
                        error!,
                        style: const TextStyle(color: errorColor, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const LegacyText('Cancel'),
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
                  app.recordFailure(ex);
                  update(() => error = app.error);
                }
              },
              child: const LegacyText('Save address'),
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
        title: const LegacyText('Remove this peer’s trust?'),
        content: LegacyText(
          '${peer['name']} will no longer be a trusted source or connection. Earlier trial enrollment remains in your results.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const LegacyText('Keep peer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const LegacyText('Remove peer'),
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
          text: 'FarvaharTrends connection test. This is harmless public test content.',
        );
    String? error;
    final message = await _inputDialog<(String, String)>(
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, update) => AlertDialog(
          title: const LegacyText('Publish a test bulletin'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LegacyText(
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
                  LegacyText(
                    '${utf8.encode(text.text).length} / $maxBulletinTextBytes UTF-8 bytes',
                    style: TextStyle(
                      fontSize: 10,
                      color:
                          utf8.encode(text.text).length > maxBulletinTextBytes
                          ? errorColor
                          : mutedColor,
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: LegacyText(
                        error!,
                        style: const TextStyle(color: errorColor, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const LegacyText('Cancel'),
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
              child: const LegacyText('Sign & publish'),
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
        title: const LegacyText('Export a trial report?'),
        content: const LegacyText(
          'The report contains public peer fingerprints, test labels, signed receipts, timing, device conditions, and trial outcomes. It excludes raw IP addresses, names, private keys, certificates, and message content. Identifiers and timing may link activity. Share it only with people you trust.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const LegacyText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const LegacyText('Export report'),
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
            const AppTag('THE FIRST REAL TRIAL', color: goldColor),
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
                    LegacyText(
                      step.$1,
                      style: const TextStyle(
                        color: tealTextColor,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LegacyText(
                            step.$2,
                            style: const TextStyle(
                              color: inkColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 7),
                          LegacyText(
                            step.$3,
                            style: const TextStyle(
                              color: mutedColor,
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
              child: const LegacyText('Ready to begin'),
            ),
          ],
        ),
      ),
    ),
  );
  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LegacyText(message)));
    }
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.subtitle);
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      LegacyText(
        title,
        style: const TextStyle(
          color: inkColor,
          fontWeight: FontWeight.w800,
          fontSize: 17,
          letterSpacing: -.3,
        ),
      ),
      const SizedBox(height: 5),
      LegacyText(
        subtitle,
        style: const TextStyle(color: mutedColor, fontSize: 10.5, height: 1.6),
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
      LegacyText(title, style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 12),
      LegacyText(
        body,
        style: const TextStyle(color: mutedColor, fontSize: 12, height: 1.8),
      ),
    ],
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => AppCard(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 19),
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
          const SizedBox(height: 19),
          LegacyText(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: inkColor,
              fontWeight: FontWeight.w800,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          LegacyText(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: mutedColor,
              height: 1.8,
            ),
          ),
        ],
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
      ..color = tealColor.withValues(alpha: .13);
    canvas.drawLine(points[0], points[1], edge);
    canvas.drawLine(points[1], points[2], edge);
    canvas.drawLine(points[0], points[3], edge);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        points[i],
        i == 2 ? 4 : 3,
        Paint()
          ..color = (i == 2 ? goldColor : tealColor).withValues(alpha: .75),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

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

/// Largest payload a version-40 QR code holds in byte mode at error
/// correction level M. Larger content keeps the copyable text instead.
const int maxQrBytes = 2331;

class _QrPanel extends StatelessWidget {
  const _QrPanel(this.data, {required this.keyName});
  final String data;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    if (utf8.encode(data).length > maxQrBytes) {
      return LegacyText(
        'This content is too large for a QR code. Use the copy button to share it as text.',
        key: ValueKey('qr-$keyName-too-large'),
        style: const TextStyle(color: mutedColor, fontSize: 11),
      );
    }
    return Center(
      child: Container(
        key: ValueKey('qr-$keyName'),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: lineColor),
        ),
        child: QrImageView(
          data: data,
          size: 236,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          backgroundColor: Colors.white,
          errorStateBuilder: (context, _) => SizedBox(
            width: 236,
            child: LegacyText(
              'This content is too large for a QR code. Use the copy button to share it as text.',
              key: ValueKey('qr-$keyName-too-large'),
              style: const TextStyle(color: mutedColor, fontSize: 11),
            ),
          ),
        ),
      ),
    );
  }
}
