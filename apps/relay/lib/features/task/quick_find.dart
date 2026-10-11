import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'task_bits.dart';

/// The toolbar search field; opens quick find.
class QuickFindField extends ConsumerWidget {
  const QuickFindField({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => showQuickFind(context, ref),
      child: Container(
        width: 260,
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: context.c.toolbarField, borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(LucideIcons.search, size: 13, color: context.c.text2),
          const SizedBox(width: 8),
          Expanded(child: Text('Search tasks', style: context.t(12, color: context.c.text2))),
          Text('⌘K', style: context.t(11, color: context.c.text3)),
        ]),
      ),
    ),
  );
}

Future<void> showQuickFind(BuildContext context, WidgetRef ref) => showDialog<void>(
  context: context,
  barrierColor: Colors.black38,
  builder: (_) => const Align(alignment: Alignment(0, -0.6), child: _QuickFind()),
);

class _QuickFind extends ConsumerStatefulWidget {
  const _QuickFind();
  @override
  ConsumerState<_QuickFind> createState() => _QuickFindState();
}

class _QuickFindState extends ConsumerState<_QuickFind> {
  String q = '';
  int sel = 0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final results = data.tasksOf(null).where((t) {
      final hay = '${data.keyOf(t)} ${t.title} ${t.brief} ${t.tags.join(' ')}'.toLowerCase();
      return words.every(hay.contains);
    }).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final shown = results.take(12).toList();
    void open(Task t) {
      Navigator.pop(context);
      ref.read(navProvider.notifier).project(t.projectId);
      ref.read(navProvider.notifier).openTask(t.id);
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 560,
        decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.fieldStroke), boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 30)]),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(() => sel = (sel + 1).clamp(0, shown.isEmpty ? 0 : shown.length - 1)),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(() => sel = (sel - 1).clamp(0, shown.isEmpty ? 0 : shown.length - 1)),
              },
              child: FieldInput(
                autofocus: true,
                hint: 'Find a task by key, title or tag',
                onChanged: (v) => setState(() {
                  q = v;
                  sel = 0;
                }),
                onSubmitted: (_) {
                  if (shown.isNotEmpty) open(shown[sel]);
                },
              ),
            ),
          ),
          if (shown.isNotEmpty) const Hairline(),
          for (var i = 0; i < shown.length; i++)
            Hoverable(
              radius: 0,
              selected: i == sel,
              onTap: () => open(shown[i]),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(children: [
                  Icon(statusIcon(shown[i].status), size: 13, color: i == sel ? Colors.white : statusColor(context, shown[i].status)),
                  const SizedBox(width: 10),
                  SizedBox(width: 64, child: Text(data.keyOf(shown[i]), style: context.t(12, family: mono, color: i == sel ? Colors.white : c.text3))),
                  Expanded(child: Text(shown[i].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13, color: i == sel ? Colors.white : c.text))),
                  Text(data.projectOf(shown[i])?.name ?? '', style: context.t(11, color: i == sel ? Colors.white70 : c.text3)),
                ]),
              ),
            ),
          if (q.isNotEmpty && shown.isEmpty) Padding(padding: const EdgeInsets.all(14), child: Text('No tasks match.', style: context.t(12, color: c.text2))),
        ]),
      ),
    );
  }
}
