import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../app/theme.dart';
import '../mobile/glass.dart';
import 'platform.dart';
import 'widgets.dart';

/// Colours and fonts for [Markdown]; the Mac and the phone pass their own.
class MdStyle {
  const MdStyle({
    required this.text,
    required this.muted,
    required this.link,
    required this.codeBg,
    required this.rule,
    required this.mono,
  });

  /// Body text: size, colour, line height.
  final TextStyle text;
  final Color muted;

  /// Links and @mentions.
  final Color link;
  final Color codeBg;
  final Color rule;
  final String mono;
}

/// What agents write: GitHub-flavoured Markdown (headings, lists, code,
/// tables, quotes), drawn with Relay's own type instead of shown as source.
/// With [mentions], `@name` and a leading `/task` are picked out as in
/// channel messages.
class Markdown extends StatefulWidget {
  const Markdown(this.source, {super.key, required this.style, this.onLink, this.mentions = false, this.selectable = true});
  final String source;
  final MdStyle style;

  /// Opens a link; links are shown but not tappable without it.
  final void Function(String url)? onLink;
  final bool mentions;
  final bool selectable;

  @override
  State<Markdown> createState() => _MarkdownState();
}

class _MarkdownState extends State<Markdown> {
  late List<md.Node> _nodes = _parse(widget.source);
  final _recognizers = <GestureRecognizer>[];

  static List<md.Node> _parse(String s) =>
      md.Document(extensionSet: md.ExtensionSet.gitHubFlavored, encodeHtml: false).parseLines(s.replaceAll('\r\n', '\n').split('\n'));

  @override
  void didUpdateWidget(Markdown old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _nodes = _parse(widget.source);
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _blocks(_nodes));
    return widget.selectable ? SelectionArea(child: body) : body;
  }

  MdStyle get s => widget.style;
  double get _size => s.text.fontSize ?? 13;

  // ------------------------------------------------------------- blocks

  List<Widget> _blocks(List<md.Node> nodes) {
    final out = <Widget>[];
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      out.add(_para(List.of(inline)));
      inline.clear();
    }

    for (final n in nodes) {
      if (n is md.Element && _isBlock(n.tag)) {
        flush();
        out.add(_block(n));
      } else {
        inline.add(n);
      }
    }
    flush();
    // Space between blocks, none after the last.
    return [
      for (var i = 0; i < out.length; i++) ...[if (i > 0) SizedBox(height: _size * 0.6), out[i]],
    ];
  }

  static const _blockTags = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'pre', 'blockquote', 'hr', 'table'};
  static bool _isBlock(String tag) => _blockTags.contains(tag);

  Widget _block(md.Element e) {
    switch (e.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final grow = switch (e.tag) { 'h1' => 5.0, 'h2' => 3.0, 'h3' => 1.5, _ => 0.0 };
        return _para(e.children ?? const [], style: s.text.copyWith(fontSize: _size + grow, fontWeight: FontWeight.w700));
      case 'ul' || 'ol':
        return _list(e);
      case 'pre':
        final code = e.children?.firstOrNull;
        final text = (code is md.Element ? code.textContent : e.textContent).replaceFirst(RegExp(r'\n$'), '');
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: s.codeBg, borderRadius: BorderRadius.circular(6), border: Border.all(color: s.rule)),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(text, style: s.text.copyWith(fontFamily: s.mono, fontSize: _size - 1, height: 1.45)),
          ),
        );
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: s.rule, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: _quoted(() => _blocks(e.children ?? const []))),
        );
      case 'hr':
        return Container(height: 1, color: s.rule);
      case 'table':
        return _table(e);
      default: // p, and a stray li
        return _para(e.children ?? const []);
    }
  }

  /// Inside a blockquote, text is muted.
  bool _inQuote = false;
  List<Widget> _quoted(List<Widget> Function() build) {
    final was = _inQuote;
    _inQuote = true;
    try {
      return build();
    } finally {
      _inQuote = was;
    }
  }

  Widget _list(md.Element list) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = (list.children ?? const []).whereType<md.Element>().where((e) => e.tag == 'li').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < items.length; i++)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : _size * 0.3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: ordered ? _size * 1.8 : _size * 1.2,
              child: Text(ordered ? '${start + i}.' : '•', style: s.text.copyWith(color: s.muted)),
            ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: _blocks(items[i].children ?? const [])),
            ),
          ]),
        ),
    ]);
  }

  Widget _table(md.Element table) {
    final rows = <(bool, List<md.Element>)>[];
    for (final section in (table.children ?? const []).whereType<md.Element>()) {
      for (final tr in (section.children ?? const []).whereType<md.Element>()) {
        rows.add((section.tag == 'thead', (tr.children ?? const []).whereType<md.Element>().toList()));
      }
    }
    final cols = rows.fold<int>(0, (m, r) => r.$2.length > m ? r.$2.length : m);
    if (cols == 0) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: s.rule),
        children: [
          for (final (head, cells) in rows)
            TableRow(
              decoration: head ? BoxDecoration(color: s.codeBg) : null,
              children: [
                for (var i = 0; i < cols; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: i < cells.length
                        ? _para(cells[i].children ?? const [], style: head ? s.text.copyWith(fontWeight: FontWeight.w700) : null)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _para(List<md.Node> nodes, {TextStyle? style}) {
    final spans = <InlineSpan>[];
    for (final n in nodes) {
      _inline(n, const TextStyle(), spans);
    }
    // A tight list item's text ends with the newline before the next item.
    if (spans.lastOrNull case TextSpan(text: final t?) when t.endsWith('\n')) {
      spans[spans.length - 1] = TextSpan(text: t.trimRight(), style: (spans.last as TextSpan).style);
    }
    final base = style ?? s.text;
    return Text.rich(TextSpan(style: _inQuote ? base.copyWith(color: s.muted) : base, children: spans));
  }

  // ------------------------------------------------------------- inline

  void _inline(md.Node n, TextStyle st, List<InlineSpan> out) {
    if (n is md.Text) {
      _text(n.text, st, out);
      return;
    }
    if (n is! md.Element) return;
    final kids = n.children ?? const <md.Node>[];
    switch (n.tag) {
      case 'strong':
        for (final k in kids) {
          _inline(k, st.copyWith(fontWeight: FontWeight.w700), out);
        }
      case 'em':
        for (final k in kids) {
          _inline(k, st.copyWith(fontStyle: FontStyle.italic), out);
        }
      case 'del':
        for (final k in kids) {
          _inline(k, st.copyWith(decoration: TextDecoration.lineThrough), out);
        }
      case 'code':
        out.add(TextSpan(
          text: n.textContent,
          style: st.copyWith(fontFamily: s.mono, fontSize: _size - 1, backgroundColor: s.codeBg),
        ));
      case 'a':
        final href = n.attributes['href'];
        final linkStyle = st.copyWith(color: s.link, decoration: TextDecoration.underline, decorationColor: s.link);
        GestureRecognizer? tap;
        if (href != null && widget.onLink != null) {
          tap = TapGestureRecognizer()..onTap = () => widget.onLink!(href);
          _recognizers.add(tap);
        }
        for (final k in kids) {
          if (k is md.Text) {
            out.add(TextSpan(text: k.text, style: linkStyle, recognizer: tap, mouseCursor: tap == null ? null : SystemMouseCursors.click));
          } else {
            _inline(k, linkStyle, out);
          }
        }
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'img':
        out.add(TextSpan(text: n.attributes['alt'] ?? '', style: st.copyWith(color: s.muted)));
      case 'input': // a GitHub task-list box
        out.add(TextSpan(text: n.attributes['checked'] != null ? '☑ ' : '☐ ', style: st));
      default:
        for (final k in kids) {
          _inline(k, st, out);
        }
    }
  }

  static final _mention = RegExp(r'@[A-Za-z0-9_.-]+|^/task\b');

  void _text(String text, TextStyle st, List<InlineSpan> out) {
    if (!widget.mentions) {
      out.add(TextSpan(text: text, style: st));
      return;
    }
    var last = 0;
    for (final m in _mention.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start), style: st));
      out.add(TextSpan(text: m.group(0), style: st.copyWith(color: s.link, fontWeight: FontWeight.w600)));
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last), style: st));
  }
}

extension MdTheme on BuildContext {
  /// Markdown in the desktop app's type and colours.
  MdStyle md(double size, {double height = 1.45}) =>
      MdStyle(text: t(size, height: height), muted: c.text2, link: c.accentIcon, codeBg: c.codeBg, rule: c.inner, mono: mono);
}

/// Markdown on the phone (I05): on a white card, or white on a blue bubble.
MdStyle phoneMd({double size = 16, bool onAccent = false}) => onAccent
    ? MdStyle(
        text: mt(size, color: Colors.white, height: 1.3),
        muted: Colors.white70,
        link: Colors.white,
        codeBg: Colors.white.withValues(alpha: 0.16),
        rule: Colors.white38,
        mono: 'Menlo',
      )
    : MdStyle(text: mt(size, height: 1.3), muted: MC.text2, link: MC.accent, codeBg: MC.bg, rule: MC.separator, mono: 'Menlo');

/// Opens web and mail links from agent text; anything else (file paths,
/// custom schemes) stays inert.
void openWebLink(String url) {
  final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
  if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') Desk.open(url);
}
