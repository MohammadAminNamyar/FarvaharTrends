import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/models.dart';
import 'localization.dart';
import 'reader_widgets.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget with Localized {
  const SettingsPage({super.key, required this.app});
  final AppController app;
  @override
  bool get fa => isFarsiLanguage(app.languageCode);

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 8),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: mutedColor,
            ),
          ),
        ),
        Material(
          clipBehavior: Clip.antiAlias,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: lineColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    ),
  );

  Widget _toggle(
    String key,
    String title,
    String subtitle,
    bool value,
    Future<void> Function(bool) update,
  ) => SwitchListTile.adaptive(
    key: ValueKey(key),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    title: Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        color: inkColor,
        fontWeight: FontWeight.w700,
      ),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: mutedColor, height: 1.65),
      ),
    ),
    value: value,
    onChanged: app.busy ? null : (value) => app.perform(() => update(value)),
  );

  Widget _note(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Text(
      text,
      key: key,
      style: const TextStyle(fontSize: 11, color: mutedColor, height: 1.7),
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Scaffold(
      key: const ValueKey('settings-page'),
      backgroundColor: canvasColor,
      appBar: AppBar(
        title: Text(t('تنظیمات', 'Settings')),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          key: const ValueKey('settings-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (app.error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: ReaderNote(
                    Icons.info_outline_rounded,
                    t('توجه', 'Notice'),
                    app.error!,
                    onDismiss: app.dismissError,
                    dismissLabel: t('بستن', 'Dismiss'),
                  ),
                ),
              _section(t('انتشار خبر', 'Publishing'), [
                ListTile(
                  key: const ValueKey('writer-nickname-setting'),
                  leading: const Icon(
                    Icons.badge_outlined,
                    color: tealTextColor,
                  ),
                  title: Text(t('نام مستعار نویسنده', 'Writer nickname')),
                  subtitle: Text(
                    app.writerNickname.isEmpty
                        ? t('نامی انتخاب نشده', 'No nickname set')
                        : app.writerNickname,
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: app.busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => _WriterNicknameDialog(app: app),
                        ),
                ),
                _note(
                  t(
                    'این نام به‌صورت عمومی زیر خبرهای تازهٔ شما در همهٔ کانال‌ها نمایش داده می‌شود. نام واقعی لازم نیست؛ خبرهای قبلی تغییر نمی‌کنند.',
                    'This name is public below your new posts across all channels. A real name is not required; existing posts stay unchanged.',
                  ),
                ),
              ]),
              _section(t('اعلان‌ها', 'Notifications'), [
                _toggle(
                  'news-notifications',
                  t('اعلان خبرهای تازه', 'News notifications'),
                  t(
                    'فقط کانال‌های دنبال‌شده؛ بدون متن خبر در اعلان',
                    'Followed channels only; article text stays out of alerts',
                  ),
                  app.newsNotifications,
                  app.setNewsNotifications,
                ),
              ]),
              _section(t('تصاویر و مصرف اینترنت', 'Images & data'), [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('image-mode-${app.imageMode}'),
                    initialValue: app.imageMode,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t('دریافت تصویر', 'Image downloads'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'wifiOnly',
                        child: Text(t('فقط وای‌فای', 'Wi-Fi only')),
                      ),
                      DropdownMenuItem(
                        value: 'any',
                        child: Text(
                          t('وای‌فای و اینترنت همراه', 'Wi-Fi and mobile data'),
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'never',
                        child: Text(t('فقط متن', 'Text only')),
                      ),
                    ],
                    onChanged: app.busy
                        ? null
                        : (value) {
                            if (value != null) {
                              app.perform(() => app.setImageMode(value));
                            }
                          },
                  ),
                ),
                _note(
                  t(
                    'این انتخاب برای تصویرهای دریافتی است. تصویری که به خبر خود پیوست می‌کنید، می‌تواند از اینترنت همراه هم فرستاده شود. تصویرها حداکثر ۹۶ کیلوبایت هستند و از بلوتوث فرستاده نمی‌شوند.',
                    'This controls received images. A photo you attach to your own news can also be sent over mobile data. Images are limited to 96 KB and do not travel over Bluetooth.',
                  ),
                ),
              ]),
              _section(t('دریافت در پس‌زمینه', 'Background receiving'), [
                _toggle(
                  'restart-after-reboot',
                  t(
                    'ادامهٔ دریافت پس از راه‌اندازی مجدد',
                    'Keep receiving after reboot',
                  ),
                  t(
                    'برنامه تلاش می‌کند سرویس دریافت با اعلان قابل مشاهده را پس از راه‌اندازی مجدد گوشی یا بسته شدن توسط سیستم دوباره فعال کند.',
                    'The app tries to restart its visible receiving service after a phone reboot or an OS kill.',
                  ),
                  app.restartAfterReboot,
                  app.setRestartAfterReboot,
                ),
                _note(
                  t(
                    'توقف دستی در برنامه این راه‌اندازی را تا شروع بعدی خاموش می‌کند. توقف اجباری و مدیریت باتری سازنده همچنان سرویس را پایان می‌دهند. این گزینه آنچه به اشتراک می‌گذارید را تغییر نمی‌دهد.',
                    'Pressing Stop in the app disarms this until the next start. Force-stop and manufacturer battery killers still end the service. This does not change what is shared.',
                  ),
                  key: const ValueKey('restart-after-reboot-explanation'),
                ),
              ]),
              _section(t('کشف و ارتباط با همتاها', 'Peer discovery'), [
                _toggle(
                  'internet-announce',
                  t(
                    'اعلام حضور در شبکهٔ اینترنتی',
                    'Announce on the Internet network',
                  ),
                  t(
                    'روشن: گوشی‌های دیگر می‌توانند این دستگاه را از راه اینترنت پیدا کنند. خاموش: فقط خودتان به دیگران وصل می‌شوید.',
                    'On: other phones can find this device over the Internet. Off: only you connect out to others.',
                  ),
                  app.internetAnnounce,
                  app.setInternetAnnounce,
                ),
                _note(
                  t(
                    'با خاموش کردن، اعلام حضور متوقف و کشف اینترنتی دوباره راه‌اندازی می‌شود. دریافت از دستگاه‌های نزدیک ادامه دارد. همتاهای متصل همچنان نشانی شما را می‌بینند.',
                    'Turning this off stops announcing this device and restarts Internet discovery. Nearby receiving continues. Connected peers still see your address.',
                  ),
                  key: const ValueKey('internet-announce-explanation'),
                ),
                const Divider(height: 1),
                _toggle(
                  'public-discovery',
                  t(
                    'استفاده از سرویس‌های کشف عمومی',
                    'Use public discovery services',
                  ),
                  t(
                    'خاموش: کشف با همتاهای ذخیره‌شده و معرفی‌شده ادامه می‌یابد. این گزینه مسیرها را به داخل یک کشور محدود نمی‌کند.',
                    'Off: use saved and shared peers. This does not restrict connections to one country.',
                  ),
                  app.publicDiscovery,
                  app.setPublicDiscovery,
                ),
                const Divider(height: 1),
                _toggle(
                  'discovery-helper',
                  t(
                    'کمک به اتصال دوبارهٔ دیگران',
                    'Help other phones reconnect',
                  ),
                  t(
                    'با روشن بودن اعلام حضور و در صورت دسترس‌پذیری، این گوشی به کشف همتاها کمک می‌کند و نشانی اتصال آن به اشتراک گذاشته می‌شود. دریافت و انتقال خبر به این گزینه وابسته نیست.',
                    'When announcing and reachable, this phone helps discovery and shares its connection address. Receiving and forwarding news also work with this off.',
                  ),
                  app.discoveryHelper,
                  app.setDiscoveryHelper,
                ),
              ]),
              Text(
                app.appVersion == 'development'
                    ? t('نسخهٔ توسعه', 'Development build')
                    : '${t('نسخهٔ برنامه', 'App version')} ${app.appVersion}',
                key: const ValueKey('reader-app-version'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: mutedColor),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _WriterNicknameDialog extends StatefulWidget {
  const _WriterNicknameDialog({required this.app});
  final AppController app;
  @override
  State<_WriterNicknameDialog> createState() => _WriterNicknameDialogState();
}

class _WriterNicknameDialogState extends State<_WriterNicknameDialog>
    with Localized {
  late final name = TextEditingController(text: widget.app.writerNickname);
  final form = GlobalKey<FormState>();
  bool saving = false;
  String? error;
  @override
  bool get fa => isFarsiLanguage(widget.app.languageCode);
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    await widget.app.perform(() => widget.app.setWriterNickname(name.text));
    if (!mounted) return;
    if (widget.app.error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        saving = false;
        error = widget.app.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(t('نام مستعار نویسنده', 'Writer nickname')),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const ValueKey('settings-writer-nickname'),
                controller: name,
                enabled: !saving,
                autofocus: true,
                maxLength: 60,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => save(),
                decoration: InputDecoration(
                  labelText: t('نام مستعار (اختیاری)', 'Nickname (optional)'),
                  helperText: t(
                    'برای برداشتن نام، این کادر را خالی کنید.',
                    'Leave blank to remove your nickname.',
                  ),
                  helperMaxLines: 3,
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final clean = (value ?? '').trim();
                  if (clean.isEmpty) return null;
                  try {
                    validateNewsByline(clean);
                    return null;
                  } catch (_) {
                    return t(
                      'نام کوتاه و تک‌خطی، حداکثر ۶۰ نویسه وارد کنید.',
                      'Use a single-line nickname of up to 60 characters.',
                    );
                  }
                },
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: const TextStyle(color: errorColor),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(t('انصراف', 'Cancel')),
        ),
        FilledButton(
          key: const ValueKey('save-writer-nickname'),
          onPressed: saving ? null : save,
          child: Text(
            saving ? t('در حال ذخیره…', 'Saving…') : t('ذخیره', 'Save'),
          ),
        ),
      ],
    ),
  );
}
