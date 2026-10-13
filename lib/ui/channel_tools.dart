import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pilot_platform/pilot_platform.dart';

import '../app_controller.dart';
import '../core/channel_recovery.dart';

class ChannelToolsPage extends StatefulWidget {
  const ChannelToolsPage({
    super.key,
    required this.app,
    this.channelId,
    this.startBackup = false,
  });
  final AppController app;
  final String? channelId;
  final bool startBackup;
  @override
  State<ChannelToolsPage> createState() => _ChannelToolsPageState();
}

class _ChannelToolsPageState extends State<ChannelToolsPage> {
  @override
  void initState() {
    super.initState();
    if (widget.startBackup) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) backup();
      });
    }
  }

  bool busy = false;
  String? message;
  bool get fa => widget.app.languageCode != 'en';
  String t(String f, String e) => fa ? f : e;
  AppController get app => widget.app;
  Future<void> work(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => message = t(
            'عملیات انجام نشد. فایل، رمز یا دسترسی کانال را بررسی کنید.',
            'Could not complete this action. Check the file, password and channel permission.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> password(bool creating) => showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RecoveryPassword(fa: fa, creating: creating),
  );
  Future<void> backup() => work(() async {
    final secret = await password(true);
    if (secret == null || !mounted) return;
    final file = await app.channelAction('exportChannelRecovery', {
      'channelId': widget.channelId,
      'password': secret,
    });
    if (file == null) throw StateError('Backup unavailable');
    final saved = await PilotPlatform.saveChannelDocument(
      file,
      'PersianTrend-recovery.json',
    );
    if (mounted) {
      setState(
        () => message = saved
            ? t(
                'نسخهٔ بازیابی ذخیره شد. فایل و رمز را جداگانه و امن نگه دارید.',
                'Recovery file saved. Keep the file and password safe and separate.',
              )
            : t(
                'ذخیره لغو شد؛ نسخهٔ بازیابی ذخیره نشده است.',
                'Saving was cancelled; no recovery file was saved.',
              ),
      );
    }
  });
  Future<void> restore() => work(() async {
    final file = await PilotPlatform.openChannelDocument();
    if (file == null || !mounted) return;
    final secret = await password(false);
    if (secret == null) return;
    await app.channelAction('restoreChannelRecovery', {
      'file': file,
      'password': secret,
    });
    if (mounted) {
      setState(
        () => message = t(
          'دسترسی مالک کانال بازیابی شد.',
          'Channel ownership restored.',
        ),
      );
    }
  });
  Future<void> requestEditor() => work(() async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => _EditorName(fa: fa),
    );
    if (label == null) return;
    final file = await app.channelAction('createEditorRequest', {
      'label': label,
    });
    if (file == null) throw StateError('Request unavailable');
    final saved = await PilotPlatform.saveChannelDocument(
      file,
      'PersianTrend-editor-request.json',
    );
    if (mounted) {
      setState(
        () => message = saved
            ? t(
                'فایل درخواست را برای مالک کانال بفرستید. دعوت‌نامه را روی همین دستگاه باز کنید.',
                'Send the request file to the channel owner. Open their invitation on this same device.',
              )
            : t('ذخیرهٔ درخواست لغو شد.', 'Saving the request was cancelled.'),
      );
    }
  });
  Future<void> invite() => work(() async {
    final file = await PilotPlatform.openChannelDocument();
    if (file == null || !mounted) return;
    final details = await app.channelAction('inspectEditorRequest', {
      'file': file,
    });
    if (details == null || !mounted) return;
    final request = jsonDecode(details) as Map;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('افزودن نویسنده', 'Add an editor')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${request['label']}'),
              const SizedBox(height: 12),
              Text(
                t(
                  'شناسه را از راهی قابل اعتماد با نویسنده تطبیق دهید. دسترسی فقط برای همین کانال است.',
                  'Verify this fingerprint with the editor through a trusted contact. Access is limited to this channel.',
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                request['fingerprint'] as String,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('لغو', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('تأیید دسترسی', 'Approve access')),
          ),
        ],
      ),
    );
    if (approved != true) return;
    final invitation = await app.channelAction('approveEditor', {
      'channelId': widget.channelId,
      'file': file,
    });
    if (invitation == null) throw StateError('Invitation unavailable');
    final saved = await PilotPlatform.saveChannelDocument(
      invitation,
      'PersianTrend-editor-invitation.json',
    );
    if (mounted) {
      setState(
        () => message = saved
            ? t(
                'دعوت‌نامه ذخیره شد؛ آن را برای همان نویسنده بفرستید. رمز بازیابی را به او ندهید.',
                'Invitation saved; send it to that editor. Keep your recovery password private.',
              )
            : t(
                'ذخیره لغو شد. اگر دعوت‌نامه ارسال نشده، دسترسی این نویسنده را لغو کنید.',
                'Saving was cancelled. Revoke this editor if you did not send the invitation.',
              ),
      );
    }
  });
  Future<void> accept() => work(() async {
    final file = await PilotPlatform.openChannelDocument();
    if (file == null) return;
    await app.channelAction('acceptEditorInvitation', {'file': file});
    if (mounted) {
      setState(
        () => message = t(
          'دعوت‌نامه پذیرفته شد؛ اکنون می‌توانید در کانال خبر بنویسید.',
          'Invitation accepted. You can now write news in this channel.',
        ),
      );
    }
  });
  Future<void> revoke(String id) => work(() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('لغو دسترسی نویسنده؟', 'Revoke editor access?')),
        content: Text(
          t(
            'پس از دریافت این تغییر، دستگاه‌ها خبرهای این دعوت‌نامه، از جمله خبرهای قبلی آن را نمی‌پذیرند.',
            'Devices receiving this update will reject news signed with this invitation, including previously cached posts.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('انصراف', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('لغو دسترسی', 'Revoke access')),
          ),
        ],
      ),
    );
    if (approved != true) return;
    await app.channelAction('revokeEditor', {
      'channelId': widget.channelId,
      'grantId': id,
    });
    if (mounted) {
      setState(
        () => message = t(
          'لغو دسترسی امضا و برای همگام‌سازی آماده شد.',
          'Signed revocation saved and queued for syncing.',
        ),
      );
    }
  });
  Future<void> removeChannel() async {
    if (busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('حذف کانال؟', 'Remove this channel?')),
        content: Text(
          t(
            'پس از رسیدن دستور امضاشده، دستگاه‌های به‌روز کانال و خبرهایش را پنهان می‌کنند. نسخه‌های ذخیره‌شده پاک نمی‌شوند. بازگرداندن کانال حذف‌شده پشتیبانی نمی‌شود.',
            'Updated devices will hide this channel and its news when they receive the signed removal. Saved copies cannot be erased. Removed channels cannot be restored.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('انصراف', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('حذف کانال', 'Remove channel')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await work(() async {
      await app.channelAction('removeChannel', {'channelId': widget.channelId});
      if (mounted) Navigator.of(context).pop();
    });
  }

  Widget tile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback action,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ListTile(
      contentPadding: const EdgeInsets.all(16),
      leading: Icon(icon, color: const Color(0xFF267E7B)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(subtitle),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: busy ? null : action,
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) {
      final channel = (app.snapshot['channels'] as List? ?? [])
          .whereType<Map>()
          .where((c) => c['id'] == widget.channelId)
          .firstOrNull;
      return Directionality(
        textDirection: fa ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          backgroundColor: const Color(0xFFF4F7F8),
          appBar: AppBar(
            title: Text(
              widget.channelId == null
                  ? t('بازیابی و همکاری', 'Recovery & collaboration')
                  : t('مدیریت کانال', 'Manage channel'),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (busy) const LinearProgressIndicator(),
              if (channel != null) ...[
                Text(
                  channel['name'] as String,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
              ],
              if (channel?['owned'] == true) ...[
                tile(
                  Icons.key_rounded,
                  t('ذخیرهٔ نسخهٔ بازیابی', 'Save recovery file'),
                  t(
                    'رمز ذخیره نمی‌شود؛ برای بازیابی هم فایل و هم رمز لازم است.',
                    'The password is not saved; both file and password are needed for recovery.',
                  ),
                  backup,
                ),
                tile(
                  Icons.person_add_alt_1_rounded,
                  t('دعوت نویسنده', 'Invite an editor'),
                  t(
                    'فایل درخواست نویسنده را باز کنید و دعوت‌نامه را برای او بفرستید.',
                    'Open an editor’s request file, then send them the invitation.',
                  ),
                  invite,
                ),
                for (final editor
                    in (channel!['editors'] as List? ?? []).whereType<Map>())
                  Card(
                    child: ListTile(
                      title: Text(editor['label'] as String),
                      subtitle: Text(
                        t(
                          'دسترسی محدود به این کانال',
                          'Access to this channel',
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: t('لغو دسترسی', 'Revoke access'),
                        onPressed: busy
                            ? null
                            : () => revoke(editor['id'] as String),
                        icon: const Icon(Icons.person_remove_outlined),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const ValueKey('remove-channel'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFAF2353),
                  ),
                  onPressed: busy ? null : removeChannel,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(t('حذف کانال', 'Remove channel')),
                ),
                const SizedBox(height: 16),
              ],
              if (widget.channelId == null) ...[
                tile(
                  Icons.settings_backup_restore_rounded,
                  t('بازیابی کانال', 'Restore a channel'),
                  t(
                    'فایل بازیابی را انتخاب کنید و رمز آن را وارد کنید.',
                    'Choose your recovery file and enter its password.',
                  ),
                  restore,
                ),
                tile(
                  Icons.edit_note_rounded,
                  t('درخواست نویسندگی', 'Request editor access'),
                  t(
                    'نویسنده: درخواست بسازید و فایل آن را برای مالک کانال بفرستید.',
                    'Editor: create a request and send its file to the channel owner.',
                  ),
                  requestEditor,
                ),
                tile(
                  Icons.mark_email_read_outlined,
                  t('بازکردن دعوت‌نامه', 'Open an invitation'),
                  t(
                    'روی دستگاهی باز کنید که درخواست نویسندگی را ساخته است.',
                    'Use the same device that created the editor request.',
                  ),
                  accept,
                ),
              ],
              if (message != null)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(message!, style: const TextStyle(height: 1.8)),
                ),
              Text(
                t(
                  'نسخه‌های بازیابی قدیمی تغییرات جدید نویسندگان و حذف خبرها را ندارند. پس از تغییرات مهم، نسخهٔ تازه ذخیره کنید.',
                  'Older recovery files lack later editor and removal updates. Save a fresh copy after important changes.',
                ),
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF5A717C),
                  height: 1.8,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RecoveryPassword extends StatefulWidget {
  const _RecoveryPassword({required this.fa, required this.creating});
  final bool fa, creating;
  @override
  State<_RecoveryPassword> createState() => _RecoveryPasswordState();
}

class _RecoveryPasswordState extends State<_RecoveryPassword> {
  final password = TextEditingController(),
      confirmation = TextEditingController();
  final form = GlobalKey<FormState>();
  String t(String f, String e) => widget.fa ? f : e;
  @override
  void dispose() {
    password.clear();
    confirmation.clear();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: widget.fa ? TextDirection.rtl : TextDirection.ltr,
    child: AlertDialog(
      title: Text(
        widget.creating
            ? t('رمز نسخهٔ بازیابی', 'Recovery password')
            : t('بازیابی کانال', 'Restore channel'),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t(
                  'چند واژهٔ تصادفی و نامرتبط انتخاب کنید. رمز را ذخیره نمی‌کنیم؛ آن را جدا از فایل نگه دارید.',
                  'Use several random, unrelated words. We do not save this password; keep it separate from the file.',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('recovery-password'),
                controller: password,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                autofillHints: const [],
                maxLength: 256,
                decoration: InputDecoration(labelText: t('رمز', 'Password')),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return t('رمز را وارد کنید.', 'Enter your password.');
                  }
                  if (widget.creating) {
                    try {
                      ChannelRecovery.validatePassword(value);
                    } catch (_) {
                      return t(
                        'حداقل ۱۶ نویسه و چند واژهٔ نامرتبط.',
                        'At least 16 characters and unrelated words.',
                      );
                    }
                  }
                  return null;
                },
              ),
              if (widget.creating)
                TextFormField(
                  key: const ValueKey('recovery-password-confirm'),
                  controller: confirmation,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  enableIMEPersonalizedLearning: false,
                  autofillHints: const [],
                  maxLength: 256,
                  decoration: InputDecoration(
                    labelText: t('تکرار رمز', 'Confirm password'),
                  ),
                  validator: (value) => value == password.text
                      ? null
                      : t('رمزها یکسان نیستند.', 'Passwords do not match.'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t('انصراف', 'Cancel')),
        ),
        FilledButton(
          onPressed: () {
            if (form.currentState!.validate()) {
              Navigator.pop(context, password.text);
            }
          },
          child: Text(t('ادامه', 'Continue')),
        ),
      ],
    ),
  );
}

class _EditorName extends StatefulWidget {
  const _EditorName({required this.fa});
  final bool fa;
  @override
  State<_EditorName> createState() => _EditorNameState();
}

class _EditorNameState extends State<_EditorName> {
  final name = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.fa ? 'نام نویسنده' : 'Editor name'),
    content: TextField(
      controller: name,
      maxLength: 80,
      decoration: InputDecoration(
        hintText: widget.fa ? 'نام مستعار شما' : 'Your display name',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.fa ? 'انصراف' : 'Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (name.text.trim().isNotEmpty) {
            Navigator.pop(context, name.text.trim());
          }
        },
        child: Text(widget.fa ? 'ساخت درخواست' : 'Create request'),
      ),
    ],
  );
}

class ReaderSettingsCard extends StatelessWidget {
  const ReaderSettingsCard({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final fa = app.languageCode != 'en';
    String t(String f, String e) => fa ? f : e;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('خبرخوان شما', 'Your reader'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('news-notifications'),
              contentPadding: EdgeInsets.zero,
              title: Text(t('اعلان خبرهای تازه', 'News notifications')),
              subtitle: Text(
                t(
                  'فقط کانال‌های دنبال‌شده؛ بدون متن خبر در اعلان',
                  'Followed channels only; article text stays out of alerts',
                ),
              ),
              value: app.newsNotifications,
              onChanged: app.busy
                  ? null
                  : (value) =>
                        app.perform(() => app.setNewsNotifications(value)),
            ),
            const Divider(),
            Text(
              t('دریافت تصویر', 'Image downloads'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('image-mode-${app.imageMode}'),
              initialValue: app.imageMode,
              isExpanded: true,
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
            const SizedBox(height: 10),
            Text(
              t(
                'متن جداگانه می‌رسد. تصویرها حداکثر ۹۶ کیلوبایت هستند و از بلوتوث فرستاده نمی‌شوند. وای‌فای به‌تنهایی سرعت بالا را تضمین نمی‌کند.',
                'Text arrives separately. Images are limited to 96 KB and do not travel over Bluetooth. Wi-Fi alone does not guarantee a fast connection.',
              ),
              style: const TextStyle(fontSize: 11, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }
}
