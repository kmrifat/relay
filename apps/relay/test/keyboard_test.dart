import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/commands.dart';
import 'package:relay/app/theme.dart';
import 'package:relay/ui/platform.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay/ui/split.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:xterm/xterm.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;

/// Presses ⌘ (Ctrl off the Mac) + [key].
Future<void> mod(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  final m = commands.first.keys.first as SingleActivator;
  final modKey = m.meta ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modKey);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modKey);
  await tester.pump();
}

Future<void> alt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
}

Map<String, Object? Function(Map<String, Object?>)> codeViewFakes(Map<String, String> ui) => {
  M.fsList: (_) => {'files': ['README.md']},
  M.gitStatus: (_) => [],
  M.fsRead: (p) => {'text': '# ${p['path']}\n'},
  M.termOpen: (_) => 'term1',
  M.termAttach: (p) => {'id': p['termId'], 'cwd': '/tmp/ws/api', 'data': base64Encode(utf8.encode('\$ '))},
  M.termInput: (_) => true,
  M.termResize: (_) => true,
  M.termClose: (_) => true,
  M.uiGet: (p) => ui[p['key']],
  M.uiSet: (p) {
    final v = p['value'] as String?;
    v == null ? ui.remove(p['key']) : ui[p['key'] as String] = v;
    return true;
  },
};

void main() {
  testWidgets('global keys work with the terminal focused; the terminal keeps Esc and arrows', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final ui = <String, String>{};
    final client = await tester.runAsync(() => fakeRelayd(extra: codeViewFakes(ui)));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));

    // ⌥5 opens Code; the terminal starts but doesn't take focus by itself.
    await alt(tester, LogicalKeyboardKey.digit5);
    await settleUntil(tester, find.byType(TerminalView));
    expect(find.byType(TerminalView), findsOneWidget);
    expect(terminalFocused, isFalse);

    // ⌃` folds the open panel; pressed again it opens and focuses the
    // terminal, which then has the keys (Esc and arrows go to vim).
    Future<void> ctrlBacktick() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.backquote);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 5; i++) {
        await tester.pump();
      }
    }

    await ctrlBacktick();
    expect(find.byType(TerminalView), findsNothing);
    await ctrlBacktick();
    await settleUntil(tester, find.byType(TerminalView));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(terminalFocused, isTrue);
    expect(typingFocused, isTrue);

    if (Desk.isMac) {
      // ⌘K still opens quick find with the terminal focused.
      await mod(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(find.text('Find a task by key, title or tag'), findsOneWidget);
      // While it is open, ⌘K doesn't open a second one.
      await mod(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(find.text('Find a task by key, title or tag'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    } else {
      // Off the Mac the commands use Ctrl, and Ctrl+K belongs to the shell.
      await mod(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(find.text('Find a task by key, title or tag'), findsNothing);
      expect(terminalFocused, isTrue);
    }

    // ⌥ digits are typing while the terminal has focus: no view switch.
    await alt(tester, LogicalKeyboardKey.digit2);
    expect(find.byType(TerminalView), findsOneWidget);
    // ⌘Esc (F6 off the Mac) leaves the terminal; then ⌥ digits switch views.
    if (Desk.isMac) {
      await mod(tester, LogicalKeyboardKey.escape);
    } else {
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pump();
    }
    expect(terminalFocused, isFalse);

    // ⌥2 → List, ⌘[ back to Code, ⌘] forward to List again.
    await alt(tester, LogicalKeyboardKey.digit2);
    await settleUntil(tester, find.text('Group by'));
    expect(find.text('Group by'), findsOneWidget);
    await mod(tester, LogicalKeyboardKey.bracketLeft);
    await settleUntil(tester, find.byType(TerminalView));
    expect(find.byType(TerminalView), findsOneWidget);
    await mod(tester, LogicalKeyboardKey.bracketRight);
    await settleUntil(tester, find.text('Group by'));
    expect(find.text('Group by'), findsOneWidget);

    // ⌘/ shows the keyboard map.
    await mod(tester, LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsWidgets);
    expect(find.text('Jump to anything'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('board: arrows move between cards and columns, Enter opens, Esc closes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.pump();

    // Backlog has KT-2; Running has KT-3; Review has KT-1.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // first card: KT-2
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // → Running: KT-3
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // → Review: KT-1
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleUntil(tester, find.text('KT-1 · Share a recipe with a link'));
    expect(find.text('KT-1 · Share a recipe with a link'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('KT-1 · Share a recipe with a link'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('list: arrows work as soon as it opens', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.tap(find.text('List'));
    await settleUntil(tester, find.text('Group by'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleUntil(tester, find.text('KT-3 · Login with magic link'));
    expect(find.text('KT-3 · Login with magic link'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('a split drags, keeps its size within bounds, saves it, and resets on double-click', (tester) async {
    final ui = <String, String>{};
    final client = await tester.runAsync(() => fakeRelayd(extra: codeViewFakes(ui)));
    await tester.binding.setSurfaceSize(const Size(800, 400));
    await tester.pumpWidget(ProviderScope(
      overrides: [clientProvider.overrideWithValue(client!)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: const Scaffold(
          body: ResizableSplit(id: 'test.split', initial: 200, min: 100, keepOther: 300, first: SizedBox.expand(key: Key('a')), second: SizedBox.expand(key: Key('b'))),
        ),
      ),
    ));
    await tester.pump();
    double width(String k) => tester.getSize(find.byKey(Key(k))).width;
    expect(width('a'), 200);

    await tester.dragFrom(const Offset(200.5, 200), const Offset(100, 0));
    await tester.pump();
    expect(width('a'), 300);
    // Never past the bounds: 800 − 300 kept − 1 divider.
    await tester.dragFrom(const Offset(300.5, 200), const Offset(900, 0));
    await tester.pump();
    expect(width('a'), 499);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect((jsonDecode(ui['panes']!) as Map)['test.split'], 499);

    // A window too small for both minimums doesn't throw.
    await tester.binding.setSurfaceSize(const Size(200, 400));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(width('a'), 100);

    await tester.binding.setSurfaceSize(const Size(800, 400));
    await tester.pump();
    await tester.tap(find.byType(GestureDetector).last);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(GestureDetector).last);
    await tester.pumpAndSettle();
    expect(width('a'), 200);
    await tester.binding.setSurfaceSize(null);
  });
}
