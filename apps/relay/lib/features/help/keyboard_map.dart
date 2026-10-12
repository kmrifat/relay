import 'package:flutter/material.dart';

import '../../app/commands.dart';
import '../../app/theme.dart';
import '../../ui/widgets.dart';

/// Every key Relay knows (design P06). ? or ⌘/ opens it.
Future<void> showKeyboardMap(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => const _KeyboardMap(),
);

class _KeyboardMap extends StatelessWidget {
  const _KeyboardMap();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final all = commands;
    Widget group(String title, List<(String, String)> rows) => Expanded(
      child: Box(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title.toUpperCase(), style: context.label),
          const SizedBox(height: 8),
          for (final (label, keys) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(label, style: context.t(12.5))),
                const SizedBox(width: 12),
                Text(keys, style: context.t(12, family: mono, color: c.accentIcon)),
              ]),
            ),
        ]),
      ),
    );
    List<(String, String)> rowsOf(CommandGroup g) {
      final rows = <(String, String)>[];
      for (final cmd in all.where((x) => x.group == g)) {
        if (cmd.id.startsWith('project.')) {
          if (cmd.id == Cmd.project(0)) rows.add(('Project 1–9', '${keyLabel(cmd.keys.first)} … ${keyLabel(all.firstWhere((x) => x.id == Cmd.project(8)).keys.first)}'));
          continue;
        }
        if (cmd.id.startsWith('view.')) {
          if (cmd.id == Cmd.view(0)) {
            rows.add((viewNames.join(' · '), '${keyLabel(cmd.keys.first)} … ${keyLabel(all.firstWhere((x) => x.id == Cmd.view(viewNames.length - 1)).keys.first)}'));
          }
          continue;
        }
        rows.add((cmd.label, cmd.keys.map(keyLabel).join('  ')));
      }
      return rows;
    }

    return Dialog(
      backgroundColor: c.window,
      insetPadding: const EdgeInsets.all(40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.boxStroke)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Keyboard shortcuts', style: context.t(20, w: FontWeight.w700))),
              Btn('Close', onTap: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 4),
            Text('Global keys work even while the terminal or editor has focus. Esc gets you out of a task.',
                style: context.t(12.5, color: c.text2)),
            const SizedBox(height: 18),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                group(CommandGroup.go.title, rowsOf(CommandGroup.go)),
                const SizedBox(width: 14),
                group(CommandGroup.product.title, rowsOf(CommandGroup.product)),
                const SizedBox(width: 14),
                group('On a task (board, list)', viewKeys),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
