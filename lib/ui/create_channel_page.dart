/// Full-screen form that creates a channel owned by this device.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pilot_platform/pilot_platform.dart';

import '../app_controller.dart';
import '../core/snapshot_dto.dart';
import 'channel_tools.dart';
import 'localization.dart';
import 'shared_widgets.dart';
import 'theme.dart';

class CreateChannelPage extends StatefulWidget {
  const CreateChannelPage({
    super.key,
    required this.app,
    this.initialName = '',
    this.initialDescription = '',
  });
  final AppController app;
  final String initialName, initialDescription;
  @override
  State<CreateChannelPage> createState() => _CreateChannelPageState();
}

class _CreateChannelPageState extends State<CreateChannelPage> with Localized {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final description = TextEditingController();
  final scroll = ScrollController();
  bool submitting = false;
  String? submissionError;
  @override
  void initState() {
    super.initState();
    name.text = widget.initialName;
    description.text = widget.initialDescription;
  }

  @override
  bool get fa => isFarsiLanguage(widget.app.languageCode);

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    scroll.dispose();
    super.dispose();
  }

  void revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && submissionError != null && scroll.hasClients) {
        scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> submit() async {
    if (submitting || widget.app.busy || !form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      submitting = true;
      submissionError = null;
    });
    if (Snapshot.fromJson(widget.app.snapshot).channelKeyManagement) {
      await submitProtected();
      return;
    }
    final before = Snapshot.fromJson(widget.app.snapshot).channels
        .map((c) => c.id)
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
      revealError();
    } else {
      final snapshot = Snapshot.fromJson(widget.app.snapshot);
      if (snapshot.channelKeyManagement) {
        final added = snapshot.channels
            .where((c) => !before.contains(c.id))
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
                channelId: added.id,
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

  Future<void> submitProtected() async {
    String? token;
    var saved = false;
    try {
      final secret = await showRecoveryPassword(
        context,
        fa: fa,
        creating: true,
      );
      if (secret == null || !mounted) return;
      final result = await widget.app.channelAction('prepareProtectedChannel', {
        'name': name.text.trim(),
        'description': description.text.trim(),
        'password': secret,
      });
      final prepared = jsonDecode(result!) as Map;
      token = prepared['token'] as String;
      saved = await PilotPlatform.saveChannelDocument(
        prepared['file'] as String,
        'FarvaharTrends-owner-recovery-1.json',
      );
      if (!saved) {
        if (mounted) {
          setState(
            () => submissionError = t(
              'ذخیره لغو شد؛ کانال منتشر نشده است.',
              'Saving was cancelled; the channel was not published.',
            ),
          );
        }
        return;
      }
      await widget.app.channelAction('commitProtectedChannel', {
        'token': token,
      });
      token = null;
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(
          () => submissionError = saved
              ? t(
                  'فایل ذخیره شد، اما ساخت کانال کامل نشد. فایل را نگه دارید و از «بازیابی و همکاری» باز کنید.',
                  'The file was saved, but channel creation did not finish. Keep it and open it from Recovery & collaboration.',
                )
              : t(
                  'کانال ساخته نشد. فضای ذخیره‌سازی و دسترسی فایل را بررسی کنید و دوباره تلاش کنید.',
                  'The channel was not created. Check storage space and file access, then try again.',
                ),
        );
      }
    } finally {
      if (token != null) {
        try {
          await widget.app.channelAction('cancelProtectedChannel', {
            'token': token,
          });
        } catch (_) {
          /* Preparation expires locally. */
        }
      }
      if (mounted) {
        setState(() => submitting = false);
        revealError();
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !submitting,
    child: Scaffold(
      key: const ValueKey('create-channel-page'),
      appBar: AppBar(
        title: Text(t('ساخت کانال', 'Create a channel')),
        backgroundColor: canvasColor,
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            controller: scroll,
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
              if (submissionError != null) ...[
                SubmissionError(submissionError!, farsi: fa),
                const SizedBox(height: 16),
              ],
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
              if (Snapshot.fromJson(widget.app.snapshot)
                  .channelKeyManagement) ...[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.key_outlined, color: tealTextColor),
                      const SizedBox(height: 10),
                      Text(
                        t(
                          'فایل بازیابی، جدا از گوشی',
                          'Keep recovery separate from your phone',
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t(
                          'پیش از انتشار کانال، یک فایل رمزگذاری‌شده ذخیره می‌کنید. این فایل می‌تواند کلید انتشار گم‌شده یا سرقت‌شده را عوض کند. یک نسخه را بیرون از این گوشی و رمز را جدا نگه دارید.',
                          'Before publishing the channel, save an encrypted recovery kit. It can replace a lost or stolen publishing key. Keep a copy away from this phone, and keep its password separately.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 23),
              ],
              Text(
                t('پیش‌نمایش کانال', 'CHANNEL PREVIEW'),
                style: const TextStyle(
                  fontSize: 10,
                  color: mutedColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const IconTile(Icons.campaign_outlined, color: tealColor),
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
                      style: const TextStyle(
                        color: tealTextColor,
                        fontSize: 11,
                      ),
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
