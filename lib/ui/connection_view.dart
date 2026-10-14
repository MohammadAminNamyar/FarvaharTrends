/// The "Connection" tab: discovery status, delivery mode, transport paths and
/// the privacy notes.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/delivery_mode.dart';
import '../core/snapshot_dto.dart';
import 'channel_tools.dart';
import 'live_radar.dart';
import 'localization.dart';
import 'reader_widgets.dart';
import 'shared_widgets.dart';
import 'theme.dart';

/// Builds the Connection tab's list items. It is not a widget so the shell's
/// lazily built `ListView.builder` keeps one item per section, exactly as
/// before the split.
class ConnectionView with Localized {
  const ConnectionView({
    required this.app,
    required this.snapshot,
    required this.fa,
    required this.animateRadar,
    required this.onExploreNews,
  });
  final AppController app;
  final Snapshot snapshot;
  @override
  final bool fa;
  final bool animateRadar;
  final VoidCallback onExploreNews;

  /// `paused`, `connected`, `searching` or the engine's discovery state.
  String get state {
    if (!app.running) return 'paused';
    if (snapshot.connectedCount > 0) return 'connected';
    if (app.deliveryMode == DeliveryMode.allNetworks &&
        snapshot.overlay.isAvailable) {
      return 'searching';
    }
    return snapshot.discoveryState;
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

  List<Widget> build(BuildContext context) {
    final connected = snapshot.connectedCount;
    return [
      ReaderIntro(
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
          color: inkColor,
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
                      color: app.running ? tealColor : Colors.white38,
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
                  const AppTag('PILOT', color: pinkColor),
                ],
              ),
              LiveRadar(
                key: const ValueKey('peer-radar'),
                active: app.running,
                searching: state == 'searching',
                contacts: connected,
                animate: animateRadar,
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
            child: MetricTile(
              key: const ValueKey('active-connections-metric'),
              value: n(connected),
              label: t('اتصال‌های فعال', 'ACTIVE CONNECTIONS'),
              icon: Icons.hub_outlined,
              color: tealColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: MetricTile(
              value: n(snapshot.channels.length),
              label: t('کانال ذخیره‌شده', 'SAVED CHANNELS'),
              icon: Icons.grid_view_rounded,
              color: pinkColor,
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _deliveryModeCard(),
      const SizedBox(height: 18),
      AppCard(
        child: Row(
          children: [
            const IconTile(Icons.auto_awesome_outlined, color: tealColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t('اتصال خودکار', 'Automatic connection'),
                    style: const TextStyle(
                      color: inkColor,
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
                      color: mutedColor,
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
                color: tealTextColor,
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
      ReaderNote(
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
          onPressed: onExploreNews,
          icon: const Icon(Icons.article_outlined, size: 18),
          label: Text(t('مرور خبرها', 'Explore the news')),
        ),
      ),
    ];
  }

  Widget _privacyDetails() => AppCard(
    child: ExpansionTile(
      key: const ValueKey('privacy-details'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(Icons.info_outline_rounded, color: tealTextColor),
      title: Text(
        t('جزئیات حریم خصوصی', 'Privacy details'),
        style: const TextStyle(
          color: inkColor,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
      children: [
        ReaderNote(
          Icons.location_off_outlined,
          t('حریم خصوصی در شبکه', 'Connection privacy'),
          t(
            'سرور مرکزی اجباری برای جمع‌آوری خبر یا انتخاب‌های شما نداریم. خبرهای عمومی میان همتاها جابه‌جا می‌شوند؛ انتخاب دنبال‌کردن و اعتماد روی این گوشی می‌ماند. در حالت همهٔ شبکه‌ها، شبکهٔ کشف عمومی به یافتن همتاها کمک می‌کند و همتاهای آن می‌توانند اطلاعات اتصال را ببینند. کلید انتشار از کلید اتصال جداست. موقعیت GPS را نمی‌خوانیم.',
            'There is no required central server collecting your news or choices. Public news moves between peers; follow and trust choices stay on this phone. In All networks mode, a public discovery network helps find peers and its peers can observe connection metadata. Publishing and connections use separate keys. We do not read your GPS location.',
          ),
        ),
        const SizedBox(height: 12),
        ReaderNote(
          Icons.shield_outlined,
          t('مرزهای حفاظت', 'Protection limits'),
          t(
            'خواندن یا بازنشر خبر به‌معنای نویسنده‌بودن شما نیست. حتی دریافت خبر از خارج ایران، امنیت یا ناشناس‌ماندن شما را تضمین نمی‌کند.\n\nهمتای نزدیک و زمان ارسال ممکن است شما را مشخص کند. در حالت همهٔ شبکه‌ها، همتاها و اپراتور IP اتصال شما را می‌بینند. ارتباط‌های هویتی نسخه‌های قبلی پاک نمی‌شوند.',
            'Reading or forwarding news does not mean you originally published it. Receiving news from outside Iran does not guarantee safety or anonymity.\n\nNearby peers and timing may identify you. In All networks mode, peers and your provider can see your connection IP. Earlier identity links cannot be erased.',
          ),
        ),
        const SizedBox(height: 12),
        ReaderNote(
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
    return AppCard(
      key: const ValueKey('delivery-mode-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('خبر از چه مسیرهایی برسد؟', 'How should news reach you?'),
            style: const TextStyle(
              color: inkColor,
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
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.8,
              color: mutedColor,
            ),
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
                    style: const TextStyle(fontSize: 10, color: mutedColor),
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
        color: selected ? tealColor.withValues(alpha: .08) : canvasColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: selected ? tealColor : lineColor),
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
                Icon(
                  icon,
                  color: selected ? tealTextColor : mutedColor,
                  size: 21,
                ),
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
                          color: inkColor,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 10,
                          height: 1.7,
                          color: mutedColor,
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
                  color: selected ? tealTextColor : mutedColor,
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
    final counts = snapshot.activeTransportCounts;
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
          (counts[route] ?? 0) + (route == 'ip' ? (counts['overlay'] ?? 0) : 0);
      if (count > 0) return t('${n(count)} اتصال فعال', '${n(count)} active');
      if (!app.running) return t('متوقف', 'Paused');
      if (route == 'ip') {
        final stage = snapshot.overlay.discoveryStage;
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
        final diagnostic = snapshot.discoveryLastError;
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

    return AppCard(
      key: const ValueKey('transport-priority-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('بهترین مسیرِ در دسترس', 'Best available path'),
            style: const TextStyle(
              color: inkColor,
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
            style: const TextStyle(
              fontSize: 10.5,
              height: 1.8,
              color: mutedColor,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < routes.length; i++) ...[
            if (i > 0) const Divider(height: 20, color: lineColor),
            Row(
              children: [
                Icon(
                  routes[i].$2,
                  color: (counts[routes[i].$1] ?? 0) > 0
                      ? tealTextColor
                      : mutedColor,
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
                      color: inkColor,
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
                      color: (counts[routes[i].$1] ?? 0) > 0
                          ? tealTextColor
                          : mutedColor,
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
              style: const TextStyle(
                fontSize: 10,
                height: 1.8,
                color: mutedColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
