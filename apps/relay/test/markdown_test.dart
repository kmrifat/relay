import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/ui/markdown.dart';

const _style = MdStyle(
  text: TextStyle(fontSize: 13, color: Colors.black),
  muted: Colors.grey,
  link: Colors.blue,
  codeBg: Color(0xFFF6F6F8),
  rule: Color(0xFFE3E3E6),
  mono: 'Menlo',
);

/// What an agent wrote in GA-3: bold, inline code, a fenced block, a list.
const _reply = '''I'm blocked on this one. Here's what I found:

**There is nothing on the branch to check.** `ga-3` and `main` point at `130636c`:

```
ga-3   130636c  feat: supplier contacts
main   130636c  [origin/main]
```

- `relay_task`, `relay_ask` — all "permissions not granted"
- `../PROJECT.md` — outside the allowed directory

| Check | Result |
|---|---|
| build | skipped |

> Paste the brief here, @claude-code. See [the docs](https://example.com).''';

Future<void> _pump(WidgetTester tester, Widget w) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w))));

String _allText(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text))) t.textSpan?.toPlainText() ?? t.data ?? '',
].join('\n');

void main() {
  testWidgets('agent Markdown is drawn, not shown as source', (tester) async {
    await _pump(tester, const Markdown(_reply, style: _style, mentions: true));
    final text = _allText(tester);
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('```')));
    expect(text, isNot(contains('`')));
    expect(text, isNot(contains('|---|')));
    expect(text, contains('There is nothing on the branch to check.'));
    expect(text, contains('ga-3   130636c  feat: supplier contacts\nmain   130636c  [origin/main]'));
    expect(find.text('•'), findsNWidgets(2));
    expect(find.byType(Table), findsOneWidget);
    expect(text, contains('the docs'));
    expect(text, isNot(contains('https://example.com')));

    // Bold is bold; the fenced block is monospace.
    final bold = tester.widgetList<Text>(find.byType(Text)).expand((t) {
      final spans = <TextSpan>[];
      t.textSpan?.visitChildren((s) {
        if (s is TextSpan && s.style?.fontWeight == FontWeight.w700) spans.add(s);
        return true;
      });
      return spans;
    });
    expect(bold.map((s) => s.text), contains('There is nothing on the branch to check.'));
    expect(tester.widget<Text>(find.textContaining('feat: supplier contacts')).style?.fontFamily, 'Menlo');
  });

  testWidgets('mentions and links: tapping a link opens it', (tester) async {
    final opened = <String>[];
    await _pump(tester, Markdown('Hi @sara, see [this](https://example.com/x).\n\n/task fix it', style: _style, mentions: true, onLink: opened.add));
    final spans = <TextSpan>[];
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      t.textSpan?.visitChildren((s) {
        if (s is TextSpan) spans.add(s);
        return true;
      });
    }
    expect(spans.firstWhere((s) => s.text == '@sara').style?.color, Colors.blue);
    expect(spans.firstWhere((s) => s.text == '/task').style?.color, Colors.blue);
    final link = spans.firstWhere((s) => s.text == 'this');
    (link.recognizer! as dynamic).onTap();
    expect(opened, ['https://example.com/x']);
  });

  testWidgets('plain text stays plain, line breaks kept', (tester) async {
    await _pump(tester, const Markdown('Done with GA-2.\nIt is ready for review.', style: _style));
    expect(_allText(tester), 'Done with GA-2.\nIt is ready for review.');
  });
}
