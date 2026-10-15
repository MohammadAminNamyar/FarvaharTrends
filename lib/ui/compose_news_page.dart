/// Full-screen composer: write, review, then sign and publish news.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pilot_platform/pilot_platform.dart';

import '../app_controller.dart';
import '../core/media_store.dart';
import '../core/models.dart';
import '../core/snapshot_dto.dart';
import 'localization.dart';
import 'shared_widgets.dart';
import 'theme.dart';

class ComposeNewsPage extends StatefulWidget {
  const ComposeNewsPage({
    super.key,
    required this.app,
    required this.channels,
    required this.selectedId,
  });
  final AppController app;
  final List<ChannelItem> channels;
  final String selectedId;
  @override
  State<ComposeNewsPage> createState() => _ComposeNewsPageState();
}

class _ComposeNewsPageState extends State<ComposeNewsPage> with Localized {
  final form = GlobalKey<FormState>();
  final text = TextEditingController();
  String get nickname => widget.app.writerNickname;
  late String selectedId = widget.selectedId;
  Uint8List? image;
  bool pickingImage = false;
  bool reviewing = false;
  bool submitting = false;
  String? submissionError;
  @override
  bool get fa => isFarsiLanguage(widget.app.languageCode);
  int get bytes => utf8.encode(text.text).length;
  ChannelItem get channel =>
      widget.channels.firstWhere((c) => c.id == selectedId);

  @override
  void dispose() {
    text.dispose();
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
      if (nickname != channel.writerNickname) {
        await widget.app.channelAction('setWriterNickname', {
          'channelId': selectedId,
          'nickname': nickname,
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
        backgroundColor: canvasColor,
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
                          value: c.id,
                          child: Text(c.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: submitting
                      ? null
                      : (value) => setState(() {
                          selectedId = value!;
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
                          style: const TextStyle(
                            fontSize: 11,
                            color: mutedColor,
                          ),
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
                  Text(
                    t(
                      'تصویر پیوست‌شده می‌تواند از وای‌فای یا اینترنت همراه فرستاده شود؛ دریافت آن به انتخاب خواننده بستگی دارد.',
                      'Your attached photo can be sent over Wi-Fi or mobile data. Readers control whether they download it.',
                    ),
                    style: const TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                const SizedBox(height: 12),
              ] else ...[
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.campaign_outlined,
                            color: tealTextColor,
                            size: 20,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              channel.name,
                              style: const TextStyle(
                                color: inkColor,
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
                        style: const TextStyle(
                          fontSize: 10,
                          color: tealTextColor,
                        ),
                      ),
                      const Divider(height: 28),
                      if (nickname.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            t('نویسنده: $nickname', 'By $nickname'),
                            style: const TextStyle(
                              color: mutedColor,
                              fontSize: 12,
                            ),
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
                          color: inkColor,
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
                        '${persianDigits('${(bytes * 100 / maxBulletinTextBytes).ceil()}')}٪ از ظرفیت متن',
                        'Space used: ${(bytes * 100 / maxBulletinTextBytes).ceil()}%',
                      ),
                key: const ValueKey('news-capacity'),
                style: TextStyle(
                  color: bytes > maxBulletinTextBytes ? errorColor : mutedColor,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 7),
              LinearProgressIndicator(
                value: math.min(bytes / maxBulletinTextBytes, 1),
                backgroundColor: lineColor,
                color: bytes > maxBulletinTextBytes ? errorColor : tealColor,
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
                SubmissionError(submissionError!, farsi: fa),
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
