import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

/// A literal web address in a signed plain-text post. No HTML/Markdown is run.
class NewsLink {
  const NewsLink(this.start, this.end, this.uri);
  final int start, end;
  final Uri uri;
}

final _webAddress = RegExp(
  r'''(?:https?://|www\.)[^\s<>"'«»،؛]+''',
  caseSensitive: false,
);
final _invisibleAddress = RegExp(
  r'[\x00-\x20\x7f\u200b-\u200f\u202a-\u202e\u2060-\u206f]',
);

/// Keep offsets into the original message so selection and copying are intact.
/// Bound recognizers even for a post consisting entirely of tiny addresses.
List<NewsLink> newsLinks(String text) {
  final links = <NewsLink>[];
  for (final match in _webAddress.allMatches(text)) {
    if (links.length == 64) break;
    // Do not turn a substring of another address/scheme into a different link.
    if (match.start > 0 &&
        !RegExp(r'''[\s(\[\{<>"'«»،؛:：]''').hasMatch(text[match.start - 1])) {
      continue;
    }
    var address = match.group(0)!;
    if (address.length > 2048 || _invisibleAddress.hasMatch(address)) continue;
    // Sentence punctuation and unmatched closing brackets are not URL content.
    while (address.isNotEmpty) {
      final last = address[address.length - 1];
      final opening = {')': '(', ']': '[', '}': '{'}[last];
      if ('.!?;:،؛؟…»'.contains(last) ||
          (opening != null &&
              last.allMatches(address).length >
                  opening.allMatches(address).length)) {
        address = address.substring(0, address.length - 1);
      } else {
        break;
      }
    }
    final uri = Uri.tryParse(
      address.toLowerCase().startsWith('www.') ? 'https://$address' : address,
    );
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        address.contains('\\')) {
      continue;
    }
    links.add(NewsLink(match.start, match.start + address.length, uri));
  }
  return links;
}

class NewsText extends StatefulWidget {
  const NewsText({super.key, required this.text, required this.fa});
  final String text;
  final bool fa;

  @override
  State<NewsText> createState() => _NewsTextState();
}

class _NewsTextState extends State<NewsText> {
  List<NewsLink> _links = [];
  final List<TapGestureRecognizer> _recognizers = [];
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _rebuildLinks();
  }

  @override
  void didUpdateWidget(NewsText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _rebuildLinks();
  }

  void _rebuildLinks() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _links = newsLinks(widget.text);
    for (final link in _links) {
      _recognizers.add(TapGestureRecognizer()..onTap = () => _open(link.uri));
    }
  }

  Future<void> _open(Uri uri) async {
    if (_opening) return;
    _opening = true;
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Missing browser/plugin or a platform refusal is a recoverable UI error.
    } finally {
      _opening = false;
    }
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.fa
                ? 'بازکردن پیوند ممکن نشد. می‌توانید نشانی را کپی کنید.'
                : 'Could not open this link. You can copy the address instead.',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: inkColor, fontSize: 16, height: 1.85);
    if (_links.isEmpty) return SelectableText(widget.text, style: style);
    final spans = <TextSpan>[];
    var start = 0;
    for (var index = 0; index < _links.length; index++) {
      final link = _links[index];
      if (link.start > start) {
        spans.add(TextSpan(text: widget.text.substring(start, link.start)));
      }
      spans.add(
        TextSpan(
          text: widget.text.substring(link.start, link.end),
          recognizer: _recognizers[index],
          mouseCursor: SystemMouseCursors.click,
          style: const TextStyle(
            color: tealTextColor,
            decoration: TextDecoration.underline,
            decorationColor: tealTextColor,
          ),
        ),
      );
      start = link.end;
    }
    if (start < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(start)));
    }
    return SelectableText.rich(TextSpan(children: spans), style: style);
  }
}
