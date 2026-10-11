import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/features/code/code_session.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:xterm/xterm.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;

/// Pumps real time until [finder] matches [n] widgets.
Future<void> settleUntilN(WidgetTester tester, Finder finder, int n) async {
  for (var i = 0; i < 100 && finder.evaluate().length != n; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

void main() {
  test('an open file is unsaved only when its text differs', () {
    final f = OpenFile('a.dart', 'void main() {}\n');
    var told = 0;
    f.onDirty = () => told++;
    f.controller.selectAll(); // caret and selection moves are not edits
    expect(f.dirty, isFalse);
    f.controller.text = 'void main() { print(1); }\n';
    expect(f.dirty, isTrue);
    f.controller.text = 'void main() {}\n';
    expect(f.dirty, isFalse);
    expect(told, 2);
    f.dispose();
  });

  testWidgets('Code view: tabs close, terminals come and go, and it all stays when you leave', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final ui = <String, String>{'terminal.commands': '[{"name":"Dev server","command":"pnpm dev"}]'};
    final input = <String>[];
    final closed = <String>[];
    var terms = 0;
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.fsList: (_) => {'files': ['README.md', 'lib/main.dart']},
      M.gitStatus: (_) => [],
      M.fsRead: (p) => {'text': '# ${p['path']}\n'},
      M.termOpen: (_) => 'term${++terms}',
      M.termAttach: (p) => {'id': p['termId'], 'cwd': '/tmp/ws/api', 'data': base64Encode(utf8.encode('\$ '))},
      M.termInput: (p) {
        input.add(p['text'] as String? ?? utf8.decode(base64Decode(p['data'] as String)));
        return true;
      },
      M.termResize: (_) => true,
      M.termClose: (p) {
        closed.add(p['termId'] as String);
        return true;
      },
      M.uiGet: (p) => ui[p['key']],
      M.uiSet: (p) {
        final v = p['value'] as String?;
        v == null ? ui.remove(p['key']) : ui[p['key'] as String] = v;
        return true;
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.tap(find.text('Code').first);
    await settleUntil(tester, find.byTooltip('Kill terminal'));

    // A terminal opens with the view; + adds another, ✕ kills one.
    expect(find.byTooltip('Kill terminal'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
    await tester.tap(find.byTooltip('New terminal').first);
    await settleUntilN(tester, find.byTooltip('Kill terminal'), 2);
    expect(find.byTooltip('Kill terminal'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Kill terminal').first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.byTooltip('Kill terminal'), findsOneWidget);
    expect(closed, ['term1']);

    // Hide and show the terminal.
    await tester.tap(find.byTooltip('Hide terminal (Ctrl+`)'));
    await tester.pump();
    expect(find.byType(TerminalView), findsNothing);
    await tester.tap(find.byTooltip('Show terminal (Ctrl+`)'));
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);

    // Open two files; ✕ closes a tab.
    await tester.tap(find.text('README.md'));
    await settleUntil(tester, find.byTooltip('Close'));
    await tester.tap(find.text('lib'));
    await tester.pump();
    await tester.tap(find.text('main.dart'));
    await settleUntilN(tester, find.text('main.dart'), 2);
    expect(find.text('README.md'), findsNWidgets(2)); // explorer + tab
    await tester.tap(find.byTooltip('Close')); // the active tab: main.dart
    await tester.pump();
    expect(find.text('main.dart'), findsOneWidget);

    // Leave for the board and come back: the file and terminal are still open.
    await tester.tap(find.text('Board').first);
    await settleUntil(tester, find.text('Recurring meal plans'));
    expect(find.byType(TerminalView), findsNothing);
    await tester.tap(find.text('Code').first);
    await settleUntil(tester, find.byType(TerminalView));
    expect(find.text('README.md'), findsNWidgets(3)); // explorer, tab, breadcrumb
    expect(find.byTooltip('Kill terminal'), findsOneWidget);
    expect(closed, ['term1'], reason: 'leaving the view keeps the shell running');

    // …and it is kept in relayd for the next launch.
    await tester.pump(const Duration(milliseconds: 600)); // the save is debounced
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final saved = jsonDecode(ui['code.p1']!) as Map;
    expect(saved['files'], ['README.md']);
    expect((saved['terms'] as List).single['id'], 'term2');
    expect(saved['panelOpen'], true);

    // Saved commands: save one, then run it in the open terminal.
    await tester.tap(find.byTooltip('Saved commands'));
    await tester.pumpAndSettle();
    expect(find.text('Dev server  —  pnpm dev'), findsOneWidget, reason: 'saved earlier, shown the first time');
    await tester.tap(find.text('Save a command…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Tests');
    await tester.enterText(find.byType(TextField).at(1), 'dart test');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(jsonDecode(ui['terminal.commands']!), [
      {'name': 'Dev server', 'command': 'pnpm dev'},
      {'name': 'Tests', 'command': 'dart test'},
    ]);
    await tester.tap(find.byTooltip('Saved commands'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tests  —  dart test'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(input, contains('dart test\r'));

    await tester.binding.setSurfaceSize(null);
  });
}
