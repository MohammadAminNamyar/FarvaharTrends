/// Bottom-sheet picker that filters the news feed to one followed channel.
library;

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/snapshot_dto.dart';
import 'localization.dart';
import 'reader_widgets.dart';
import 'theme.dart';

class NewsChannelSelection {
  const NewsChannelSelection(this.channelId);
  final String? channelId;
}

class NewsChannelPicker extends StatefulWidget {
  const NewsChannelPicker({
    super.key,
    required this.app,
    required this.selection,
  });
  final AppController app;
  final ValueGetter<String?> selection;

  @override
  State<NewsChannelPicker> createState() => _NewsChannelPickerState();
}

class _NewsChannelPickerState extends State<NewsChannelPicker> with Localized {
  final search = TextEditingController();
  String query = '';
  @override
  bool get fa => isFarsiLanguage(widget.app.languageCode);

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
          followedChannels(widget.app, Snapshot.fromJson(widget.app.snapshot))
            ..sort(
              (a, b) =>
                  normalizeSearchText(a.name)
                      .compareTo(normalizeSearchText(b.name)),
            );
      final selectedId = widget.selection();
      final selected = following.any((c) => c.id == selectedId)
          ? selectedId
          : null;
      final matches = following
          .where(
            (c) =>
                normalizeSearchText('${c.name} ${c.id}')
                    .contains(normalizeSearchText(query)),
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
                        color: inkColor,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('close-news-channel-picker'),
                    tooltip: t('بستن', 'Close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: mutedColor),
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
                        style: const TextStyle(color: mutedColor, fontSize: 12),
                      ),
                    );
                  }
                  final channel = matches[index - 1];
                  final id = channel.id;
                  return _option(
                    id,
                    channel.name,
                    channel.description,
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
        selectedTileColor: tealColor.withValues(alpha: .08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        leading: Icon(
          id == null ? Icons.dynamic_feed_outlined : Icons.campaign_outlined,
          color: selected ? tealTextColor : mutedColor,
        ),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: inkColor,
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
                style: const TextStyle(color: mutedColor, fontSize: 10),
              ),
        trailing: selected
            ? const Icon(
                Icons.check_circle_rounded,
                color: tealTextColor,
                size: 21,
              )
            : const SizedBox(width: 21),
        onTap: () => Navigator.pop(context, NewsChannelSelection(id)),
      );
}
