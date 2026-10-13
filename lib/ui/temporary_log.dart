import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/peer_activity.dart';

const _ink = Color(0xFF183F51);
const _muted = Color(0xFF5A717C);
const _teal = Color(0xFF267E7B);
const _line = Color(0xFFDFE9EC);

class TemporaryLogView extends StatelessWidget {
  const TemporaryLogView({super.key, required this.app});
  final AppController app;
  bool get fa => app.languageCode != 'en';
  String t(String farsi, String english) => fa ? farsi : english;
  String digits(Object value) {
    final text = '$value';
    if (!fa) return text;
    return text.replaceAllMapped(
      RegExp(r'[0-9]'),
      (m) => '۰۱۲۳۴۵۶۷۸۹'[int.parse(m[0]!)],
    );
  }

  String route(dynamic value) => switch (value) {
    'overlay' => t('شبکهٔ همتاها', 'Peer network'),
    'ip' => t('اینترنت / شبکهٔ داخلی', 'Internet / domestic network'),
    'lan' => t('وای‌فای محلی', 'Local Wi-Fi'),
    'wifiDirect' => t('وای‌فای مستقیم', 'Wi-Fi Direct'),
    'bluetooth' => t('بلوتوث', 'Bluetooth'),
    _ => t('مسیر ثبت نشده', 'Route not recorded'),
  };

  String shortId(String id) => id.substring(0, 12);

  @override
  Widget build(BuildContext context) {
    // Validate again at the presentation boundary, including legacy snapshots.
    final rows = temporaryPeerActivity(
      (app.snapshot['temporaryPeerActivity'] as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
          .reversed,
    );
    final active = (app.snapshot['peers'] as List? ?? [])
        .whereType<Map>()
        .where(
          (peer) =>
              peer['connected'] == true &&
              peer['id'] is String &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(peer['id'] as String),
        )
        .take(16)
        .toList();
    final seen = rows.map((row) => row['peerId']).toSet().length;
    final ownId = app.identity?.id ?? app.snapshot['identityId'];
    return ListView.builder(
      key: const ValueKey('temporary-log-list'),
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      itemCount: 4 + rows.length,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('گزارش موقت', 'Temporary log'),
                  style: const TextStyle(
                    fontSize: 23,
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  t(
                    'فقط ارتباط‌های همین گوشی ثبت می‌شود؛ این فهرستِ همهٔ کاربران یا تأیید خواندن خبر نیست.',
                    'Shows connections to this phone. It is not a list of all users or proof that they read news.',
                  ),
                  style: const TextStyle(color: _muted, height: 1.8),
                ),
                if (ownId is String &&
                    RegExp(r'^[a-f0-9]{64}$').hasMatch(ownId)) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(
                        t('شناسهٔ اتصال این گوشی:', 'This phone’s connection:'),
                      ),
                      Text(
                        shortId(ownId),
                        semanticsLabel: t(
                          'شناسهٔ اتصال این گوشی: ${shortId(ownId)}',
                          'This phone’s connection: ${shortId(ownId)}',
                        ),
                        key: const ValueKey('temporary-log-own-id'),
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          color: _ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('temporary-log-copy-id'),
                        tooltip: t('کپی شناسهٔ اتصال', 'Copy connection ID'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: 17,
                          color: _muted,
                        ),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: shortId(ownId)),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                t(
                                  'شناسهٔ اتصال کپی شد.',
                                  'Connection ID copied.',
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
                if (app.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    t(
                      'این کار کامل نشد؛ دوباره تلاش کنید.',
                      'That action did not finish. Please try again.',
                    ),
                    key: const ValueKey('temporary-log-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          );
        }
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _stat(
                    t('اتصال فعال', 'Connected now'),
                    active.length,
                    'temporary-log-connected-count',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _stat(
                    t('همتای ثبت‌شده', 'Logged peers'),
                    seen,
                    'temporary-log-seen-count',
                  ),
                ),
              ],
            ),
          );
        }
        if (index == 2) {
          if (active.isEmpty) return const SizedBox.shrink();
          return _panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('هم‌اکنون متصل', 'Connected now'),
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                for (final peer in active)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        const Icon(Icons.circle, size: 6, color: _teal),
                        Text(
                          shortId(peer['id'] as String),
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            color: _ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(route(peer['transport'])),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }
        if (index == 3) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      t('آخرین فعالیت‌ها', 'Recent activity'),
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('temporary-log-clear'),
                      onPressed: rows.isEmpty || app.busy
                          ? null
                          : () => app.perform(app.clearTemporaryLog),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text(t('پاک‌کردن گزارش', 'Clear log')),
                    ),
                  ],
                ),
                Text(
                  t(
                    'حداکثر ${digits(maxTemporaryPeerActivity)} رویداد روی همین گوشی. تعداد همتاها، شمار افراد یا نصب‌ها نیست.',
                    'Up to $maxTemporaryPeerActivity entries on this phone. Peer counts are not counts of people or installations.',
                  ),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 11,
                    height: 1.8,
                  ),
                ),
                if (rows.isEmpty) ...[
                  const SizedBox(height: 20),
                  _panel(
                    child: Text(
                      t(
                        'هنوز فعالیتی ثبت نشده است. پس از اتصال موفق به یک همتا، زمان و مسیر ارتباط اینجا نمایش داده می‌شود.',
                        'No activity recorded yet. A successful peer connection will appear here with its time and transport.',
                      ),
                      key: const ValueKey('temporary-log-empty'),
                    ),
                  ),
                ],
              ],
            ),
          );
        }
        return _event(context, rows[index - 4], index - 4);
      },
    );
  }

  Widget _stat(String label, int count, String key) => _panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
        const SizedBox(height: 6),
        Text(
          digits(count),
          key: ValueKey(key),
          style: const TextStyle(
            color: _ink,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );

  Widget _event(BuildContext context, Map<String, dynamic> row, int index) {
    final kind = row['kind'];
    final title = switch (kind) {
      'connected' => t('اتصال برقرار شد', 'Connection established'),
      'disconnected' => t('اتصال پایان یافت', 'Connection ended'),
      _ => t('خبر با امضای معتبر دریافت شد', 'Signed news received'),
    };
    final icon = switch (kind) {
      'connected' => Icons.link_rounded,
      'disconnected' => Icons.link_off_rounded,
      _ => Icons.mark_email_read_outlined,
    };
    final at = DateTime.fromMillisecondsSinceEpoch(row['atWallMs'] as int)
        .toLocal();
    String pad(int value) => '$value'.padLeft(2, '0');
    final time =
        '${at.year}/${pad(at.month)}/${pad(at.day)} · ${pad(at.hour)}:${pad(at.minute)}:${pad(at.second)}';
    return _panel(
      child: Row(
        key: ValueKey('temporary-log-event-$index'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFEDF5F5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: kind == 'disconnected' ? _muted : _teal,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    Text(
                      shortId(row['peerId'] as String),
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      route(row['transport']),
                      style: const TextStyle(color: _teal, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Tooltip(
                  message: t('زمان محلی همین گوشی', 'Local time on this phone'),
                  child: Text(
                    digits(time),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(color: _muted, fontSize: 10.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel({required Widget child}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(18),
    ),
    child: child,
  );
}
