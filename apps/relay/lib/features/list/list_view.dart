import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/commands.dart';
import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../task/task_bits.dart';

enum _Who { all, people, agents }

/// The grouped task table (design T07).
class TaskListView extends ConsumerStatefulWidget {
  const TaskListView({super.key, required this.projectId, this.repoFilter, this.tasksOverride, this.showFilters = true});
  final String? projectId;
  final String? repoFilter;

  /// Smart lists pass their own tasks.
  final List<Task>? tasksOverride;
  final bool showFilters;

  @override
  ConsumerState<TaskListView> createState() => _TaskListViewState();
}

class _TaskListViewState extends ConsumerState<TaskListView> {
  _Who who = _Who.all;
  final collapsed = <String>{TaskStatus.done, TaskStatus.backlog};
  String? selected;
  final _focus = FocusNode(debugLabel: 'list');
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    focusContent.addListener(_takeFocus);
    // The list's keys work as soon as it opens, unless you are somewhere
    // else on purpose (the sidebar, a field).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusIsIdle) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    focusContent.removeListener(_takeFocus);
    _focus.dispose();
    super.dispose();
  }

  void _takeFocus() {
    if (mounted) _focus.requestFocus();
  }

  void _select(String id) {
    setState(() => selected = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final policy in [ScrollPositionAlignmentPolicy.keepVisibleAtEnd, ScrollPositionAlignmentPolicy.keepVisibleAtStart]) {
        final ctx = _selectedKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignmentPolicy: policy);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    var tasks = widget.tasksOverride ?? data.tasksOf(widget.projectId);
    if (widget.repoFilter != null) tasks = tasks.where((t) => t.repoIds.contains(widget.repoFilter)).toList();
    tasks = switch (who) {
      _Who.all => tasks,
      _Who.people => tasks.where((t) => t.assigneeKind == 'person').toList(),
      _Who.agents => tasks.where((t) => t.assigneeKind == 'agent' || t.pipeline.isNotEmpty).toList(),
    };
    const order = [TaskStatus.running, TaskStatus.review, TaskStatus.queued, TaskStatus.backlog, TaskStatus.done];
    final rows = <Widget>[];
    var zebra = false;
    for (final s in order) {
      final group = tasks.where((t) => t.status == s).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (group.isEmpty) continue;
      final isCollapsed = collapsed.contains(s);
      rows.add(Hoverable(
        radius: 0,
        onTap: () => setState(() => isCollapsed ? collapsed.remove(s) : collapsed.add(s)),
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(isCollapsed ? LucideIcons.chevronRight : LucideIcons.chevronDown, size: 12, color: c.text2),
              const SizedBox(width: 8),
              Icon(statusIcon(s), size: 13, color: statusColor(context, s)),
              const SizedBox(width: 8),
              Text(TaskStatus.label(s), style: context.t(12, w: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${group.length}', style: context.t(12, color: c.text3)),
            ]),
          ),
        ),
      ));
      if (isCollapsed) continue;
      for (final t in group) {
        zebra = !zebra;
        rows.add(_Row(
          key: selected == t.id ? _selectedKey : ValueKey(t.id),
          task: t,
          zebra: zebra,
          selected: selected == t.id,
          onSelect: () {
            _select(t.id);
            _focus.requestFocus();
          },
        ));
      }
    }

    final visible = <Task>[
      for (final s in order)
        if (!collapsed.contains(s)) ...(tasks.where((t) => t.status == s).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))),
    ];
    void move(int d) {
      if (visible.isEmpty) return;
      final i = visible.indexWhere((t) => t.id == selected);
      _select(visible[(i + d).clamp(0, visible.length - 1)].id);
    }

    KeyEventResult key(KeyEvent e) {
      if (e is KeyUpEvent) return KeyEventResult.ignored;
      final current = visible.where((t) => t.id == selected).firstOrNull;
      final kb = HardwareKeyboard.instance;
      if (kb.isMetaPressed || kb.isControlPressed || kb.isAltPressed) return KeyEventResult.ignored;
      switch (e.logicalKey) {
        case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.keyJ:
          move(1);
        case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.keyK:
          move(-1);
        case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.space when current != null:
          ref.read(navProvider.notifier).openTask(current.id);
        case LogicalKeyboardKey.keyA when current != null:
          final box = _selectedKey.currentContext?.findRenderObject() as RenderBox?;
          assignMenu(context, ref, current, box == null ? Offset.zero : box.localToGlobal(Offset(200, box.size.height)));
        case LogicalKeyboardKey.keyR when current != null:
          runNow(context, ref, current);
        case LogicalKeyboardKey.keyQ when current != null:
          ref.read(clientProvider).call(M.tasksMove, {'id': current.id, 'status': TaskStatus.queued});
        default:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }

    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) => key(e),
      child: Column(children: [
      if (widget.showFilters)
        Container(
          height: 36,
          color: c.bar,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Text('Group by', style: context.t(12, color: c.text2)),
            const SizedBox(width: 8),
            Pill('Status', fg: c.text, bg: c.control, radius: 5),
            const SizedBox(width: 14),
            Segmented<_Who>(
              small: true,
              options: const [(_Who.all, 'All'), (_Who.people, 'People'), (_Who.agents, 'Agents')],
              value: who,
              onChanged: (v) => setState(() => who = v),
            ),
          ]),
        ),
      Container(
        height: 26,
        color: c.bar,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(width: 70, child: Text('ID', style: context.label)),
          Expanded(child: Text('Title', style: context.label)),
          SizedBox(width: 180, child: Text('Assignee', style: context.label)),
          SizedBox(width: 130, child: Text('Status', style: context.label)),
          SizedBox(width: 100, child: Text('Branch', style: context.label)),
          SizedBox(width: 100, child: Text('Changes', style: context.label)),
          SizedBox(width: 80, child: Text('Updated ↓', style: context.label)),
          SizedBox(width: 34, child: Text('Pri', style: context.label)),
        ]),
      ),
      const Hairline(),
      Expanded(
        child: rows.isEmpty
            ? Center(child: Text('No tasks here.', style: context.t(13, color: c.text2)))
            : ListView(children: rows),
      ),
    ]));
  }
}

class _Row extends ConsumerWidget {
  const _Row({super.key, required this.task, required this.zebra, required this.selected, required this.onSelect});
  final Task task;
  final bool zebra;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = task;
    final run = data.activeRun(t);
    final changes = data.changesOf(t.id);
    final adds = changes.fold<int>(0, (s, ch) => s + ch.additions);
    final dels = changes.fold<int>(0, (s, ch) => s + ch.deletions);
    final fg = selected ? Colors.white : c.text;
    final fg2 = selected ? Colors.white : c.text2;
    final project = data.projectOf(t);

    Widget status;
    final attention = t.data['attention'] as String?;
    if (run != null) {
      status = Row(children: [
        SizedBox(width: 44, child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(minHeight: 4, value: (0.1 + run.toolCalls * 0.08).clamp(0.1, 0.9), backgroundColor: selected ? Colors.white30 : c.inner, color: selected ? Colors.white : c.success))),
        const SizedBox(width: 6),
        Text('Live ${elapsed(run.startedAt)}', style: context.t(11, color: selected ? Colors.white : c.success)),
      ]);
    } else if (attention == 'failed') {
      status = Row(children: [Icon(LucideIcons.x, size: 12, color: fg2), const SizedBox(width: 4), Text('Failed', style: context.t(11, color: selected ? Colors.white : c.danger))]);
    } else if (attention != null) {
      status = Row(children: [Dot(c.warning), const SizedBox(width: 6), Text('Waiting', style: context.t(11, color: selected ? Colors.white : c.warning))]);
    } else if (t.status == TaskStatus.queued) {
      final blocked = t.dependsOn.any((d) => data.get<Task>(Kind.task, d)?.status != TaskStatus.done);
      status = Row(children: [
        Icon(blocked ? LucideIcons.lock : LucideIcons.clock, size: 12, color: fg2),
        const SizedBox(width: 4),
        Text(blocked ? 'Blocked' : (DateTime.tryParse(t.startAt) != null ? 'At ${TimeOfDay.fromDateTime(DateTime.parse(t.startAt).toLocal()).format(context)}' : 'Next free slot'), style: context.t(11, color: fg2)),
      ]);
    } else {
      status = Text(TaskStatus.label(t.status), style: context.t(11, color: fg2));
    }

    return GestureDetector(
      onSecondaryTapDown: (d) => taskMenu(context, ref, t, d.globalPosition),
      onDoubleTap: () => ref.read(navProvider.notifier).openTask(t.id),
      onTap: onSelect,
      child: Container(
        height: 34,
        color: selected ? c.accent : (zebra ? c.zebra : Colors.transparent),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          SizedBox(width: 70, child: Text(data.keyOf(t), style: context.t(12, family: mono, color: selected ? Colors.white : c.text3))),
          Expanded(
            child: Row(children: [
              Flexible(child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13, w: selected ? FontWeight.w600 : FontWeight.w400, color: fg))),
              for (final tag in t.tags.take(2)) ...[const SizedBox(width: 8), Pill(tag, fg: selected ? Colors.white : null, bg: selected ? Colors.white24 : null)],
              const SizedBox(width: 6),
              RepoChips(t),
            ]),
          ),
          SizedBox(width: 180, child: AssigneeLabel(t, size: 12, onAccent: selected)),
          SizedBox(width: 130, child: status),
          SizedBox(width: 100, child: Text(changes.isEmpty ? '—' : t.branchName(project?.key ?? ''), style: context.t(11, family: mono, color: fg2))),
          SizedBox(width: 100, child: changes.isEmpty ? Text('—', style: context.t(11, color: fg2)) : Align(alignment: Alignment.centerLeft, child: DiffNums(adds, dels, onAccent: selected))),
          SizedBox(width: 80, child: Text(ago(t.updatedAt), style: context.t(12, color: fg2))),
          SizedBox(width: 34, child: Text(t.priority == 0 ? '' : 'P${t.priority}', style: context.t(11, w: FontWeight.w700, color: selected ? Colors.white : (t.priority == 1 ? c.danger : c.text3)))),
        ]),
      ),
    );
  }
}
