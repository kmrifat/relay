import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/commands.dart';
import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../task/new_task_sheet.dart';
import '../task/task_bits.dart';

class BoardView extends ConsumerStatefulWidget {
  const BoardView({super.key, required this.projectId, this.repoFilter});
  final String projectId;
  final String? repoFilter;

  @override
  ConsumerState<BoardView> createState() => _BoardViewState();
}

/// The board, and its keys while it has focus: arrows or H/J/K/L move,
/// Enter or Space opens, ⌥←/⌥→ moves the card to the next column, A
/// assigns, R runs now, Q queues.
class _BoardViewState extends ConsumerState<BoardView> {
  final _focus = FocusNode(debugLabel: 'board');
  final _selectedKey = GlobalKey();
  String? _selected;

  @override
  void initState() {
    super.initState();
    focusContent.addListener(_takeFocus);
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
    setState(() => _selected = id);
    // Scroll just enough to show it, whichever side it is off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final policy in [ScrollPositionAlignmentPolicy.keepVisibleAtEnd, ScrollPositionAlignmentPolicy.keepVisibleAtStart]) {
        final ctx = _selectedKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignmentPolicy: policy);
      }
    });
  }

  KeyEventResult _key(KeyEvent e, List<List<Task>> cols) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isMetaPressed || kb.isControlPressed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    var ci = -1, ri = -1;
    for (var i = 0; i < cols.length && ci < 0; i++) {
      final j = cols[i].indexWhere((t) => t.id == _selected);
      if (j >= 0) (ci, ri) = (i, j);
    }
    // Nothing chosen yet: any move key picks the first card.
    if (ci < 0) {
      final first = cols.indexWhere((c) => c.isNotEmpty);
      if (first < 0) return KeyEventResult.ignored;
      const moves = [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.keyH, LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyK, LogicalKeyboardKey.keyL];
      if (!moves.contains(k)) return KeyEventResult.ignored;
      _select(cols[first].first.id);
      return KeyEventResult.handled;
    }
    final task = cols[ci][ri];
    void column(int d) {
      for (var i = ci + d; i >= 0 && i < cols.length; i += d) {
        if (cols[i].isEmpty) continue;
        _select(cols[i][ri.clamp(0, cols[i].length - 1)].id);
        return;
      }
    }

    void move(int d) {
      final to = ci + d;
      if (to < 0 || to >= TaskStatus.columns.length) return;
      final maxPos = cols[to].fold<double>(0, (m, t) => t.position > m ? t.position : m);
      ref.read(clientProvider).call(M.tasksMove, {'id': task.id, 'status': TaskStatus.columns[to], 'position': maxPos + 1});
    }

    Offset anchor() {
      final box = _selectedKey.currentContext?.findRenderObject() as RenderBox?;
      return box == null ? Offset.zero : box.localToGlobal(Offset(0, box.size.height));
    }

    final alt = kb.isAltPressed;
    switch (k) {
      case LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.keyH:
        alt ? move(-1) : column(-1);
      case LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.keyL:
        alt ? move(1) : column(1);
      case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.keyK:
        _select(cols[ci][(ri - 1).clamp(0, cols[ci].length - 1)].id);
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.keyJ:
        _select(cols[ci][(ri + 1).clamp(0, cols[ci].length - 1)].id);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.space:
        openTask(ref, task.id);
      case LogicalKeyboardKey.keyA:
        assignMenu(context, ref, task, anchor());
      case LogicalKeyboardKey.keyR:
        runNow(context, ref, task);
      case LogicalKeyboardKey.keyQ:
        ref.read(clientProvider).call(M.tasksMove, {'id': task.id, 'status': TaskStatus.queued});
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(dataProvider);
    final tasks = data.tasksOf(widget.projectId).where((t) => widget.repoFilter == null || t.repoIds.contains(widget.repoFilter)).toList();
    final cols = [
      for (final s in TaskStatus.columns) tasks.where((t) => t.status == s).toList()..sort((a, b) => a.position.compareTo(b.position)),
    ];
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) => _key(e, cols),
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: LayoutBuilder(builder: (context, box) {
            final w = ((box.maxWidth - 4 * 12) / 5).clamp(200.0, 320.0);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var i = 0; i < cols.length; i++) ...[
                  SizedBox(
                    width: w,
                    height: box.maxHeight,
                    child: _Column(
                      status: TaskStatus.columns[i],
                      projectId: widget.projectId,
                      tasks: cols[i],
                      selected: _selected,
                      selectedKey: _selectedKey,
                      showFocus: _focus.hasFocus,
                      onSelect: (id) {
                        _select(id);
                        _focus.requestFocus();
                      },
                    ),
                  ),
                  if (i < cols.length - 1) const SizedBox(width: 12),
                ],
              ]),
            );
          }),
        ),
      ),
    );
  }
}

class _Column extends ConsumerWidget {
  const _Column({required this.status, required this.tasks, required this.projectId, this.selected, required this.selectedKey, this.showFocus = false, required this.onSelect});
  final String status;
  final List<Task> tasks;
  final String projectId;
  final String? selected;
  final GlobalKey selectedKey;
  final bool showFocus;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.read(clientProvider);
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => d.data.status != status,
      onAcceptWithDetails: (d) {
        final maxPos = tasks.fold<double>(0, (m, t) => t.position > m ? t.position : m);
        client.call(M.tasksMove, {'id': d.data.id, 'status': status, 'position': maxPos + 1});
      },
      builder: (context, candidates, _) => Container(
        decoration: BoxDecoration(
          color: candidates.isNotEmpty ? context.c.accent.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(children: [
              Icon(statusIcon(status), size: 13, color: statusColor(context, status)),
              const SizedBox(width: 6),
              Expanded(child: Text(TaskStatus.label(status), style: context.t(12, w: FontWeight.w600))),
              Text('${tasks.length}', style: context.t(11, color: context.c.text3)),
              if (status == TaskStatus.backlog || status == TaskStatus.queued)
                IconBtn(LucideIcons.plus, size: 13, tooltip: 'New task', onTap: () => showNewTaskSheet(context, ref, status: status)),
            ]),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: tasks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final t = tasks[i];
                final isSelected = t.id == selected;
                return KeyedSubtree(
                  key: isSelected ? selectedKey : ValueKey(t.id),
                  child: _DraggableCard(task: t, focused: isSelected && showFocus, onSelect: () => onSelect(t.id)),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

class _DraggableCard extends StatelessWidget {
  const _DraggableCard({required this.task, this.focused = false, this.onSelect});
  final Task task;
  final bool focused;
  final VoidCallback? onSelect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Draggable<Task>(
      data: task,
      feedback: Material(color: Colors.transparent, child: SizedBox(width: box.maxWidth, child: Opacity(opacity: 0.9, child: TaskCard(task: task)))),
      childWhenDragging: Opacity(opacity: 0.35, child: TaskCard(task: task)),
      child: TaskCard(task: task, focused: focused, onSelect: onSelect),
    ),
  );
}

class TaskCard extends ConsumerWidget {
  const TaskCard({super.key, required this.task, this.focused = false, this.onSelect});
  final Task task;

  /// The board's keyboard selection is on this card.
  final bool focused;

  /// Called on click before the task opens, so the board remembers it.
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = task;
    final live = t.status == TaskStatus.running;
    final attention = t.data['attention'] as String?;
    final run = data.activeRun(t);
    final changes = data.changesOf(t.id);
    final adds = changes.fold<int>(0, (s, ch) => s + ch.additions);
    final dels = changes.fold<int>(0, (s, ch) => s + ch.deletions);
    final border = attention == 'permission' || attention == 'question'
        ? c.warning
        : (attention == 'failed' ? c.danger : (live ? c.success : c.boxStroke));
    final done = t.status == TaskStatus.done;

    return Hoverable(
      onTap: () {
        onSelect?.call();
        openTask(ref, t.id);
      },
      onSecondaryTapDown: (d) => taskMenu(context, ref, t, d.globalPosition),
      focused: focused,
      radius: 8,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: done ? c.bar : c.box,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(data.keyOf(t), softWrap: false, style: context.t(11, family: mono, color: c.text3)),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(alignment: WrapAlignment.end, spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (live && run != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Dot(run.status == RunStatus.paused ? c.warning : c.success, size: 6),
                    const SizedBox(width: 4),
                    Text(run.status == RunStatus.paused ? 'PAUSED' : 'LIVE ${elapsed(run.startedAt)}',
                        style: context.t(10, w: FontWeight.w600, color: run.status == RunStatus.paused ? c.warning : c.success)),
                  ]),
                ?attentionBadge(context, t),
                if (t.priority > 0) priorityBadge(context, t),
              ]),
            ),
          ]),
          const SizedBox(height: 6),
          Text(t.title, style: context.t(13, w: done ? FontWeight.w400 : FontWeight.w600, color: done ? c.text2 : c.text)),
          if (t.tags.isNotEmpty || (t.repoIds.isNotEmpty && data.reposOf(t.projectId).length > 1)) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final tag in t.tags) Pill(tag),
              RepoChips(t),
            ]),
          ],
          if (live) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              // Static, not indeterminate: an animated bar per running card
              // would repaint the board every frame (docs/perf.md).
              child: LinearProgressIndicator(
                minHeight: 3,
                value: _progress(t, run),
                backgroundColor: c.inner,
                color: run?.status == RunStatus.waiting || run?.status == RunStatus.paused ? c.warning : c.success,
              ),
            ),
            const SizedBox(height: 7),
            RunLine(t),
          ],
          if (attention == 'question' && t.data['question'] != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: c.warningWash, borderRadius: BorderRadius.circular(5)),
              child: Text('"${t.data['question']}"', style: context.t(11)),
            ),
          ],
          if (attention == 'failed' && t.data['lastError'] != null) ...[
            const SizedBox(height: 6),
            Text(t.data['lastError'] as String, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.danger)),
          ],
          if (t.status == TaskStatus.review && changes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(LucideIcons.fileDiff, size: 12, color: c.text3),
              const SizedBox(width: 6),
              DiffNums(adds, dels),
              const SizedBox(width: 8),
              Builder(builder: (context) {
                final n = changes.fold<int>(0, (s, ch) => s + ch.filesChanged);
                return Text('$n file${n == 1 ? '' : 's'}', style: context.t(11, color: c.text3));
              }),
            ]),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: AssigneeLabel(t)),
            if (t.dependsOn.isNotEmpty && t.status == TaskStatus.queued)
              Text('after ${t.dependsOn.length} task${t.dependsOn.length == 1 ? '' : 's'}', style: context.t(11, color: c.text3)),
            if (done) Text(ago(t.updatedAt), style: context.t(11, color: c.text3)),
          ]),
          if (t.status == TaskStatus.review && attention == null && changes.any((ch) => ch.status == 'ready')) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Btn('Approve & merge', kind: BtnKind.primary, small: true, onTap: () async {
                  try {
                    final res = await ref.read(clientProvider).list(M.changesMerge, {'taskId': t.id});
                    final failed = res.where((r) => r['ok'] != true).toList();
                    if (failed.isNotEmpty && context.mounted) showError(context, '${failed.first['repo']}: ${failed.first['error']}');
                  } on RpcError catch (e) {
                    if (context.mounted) showError(context, e.message);
                  }
                }),
              ),
              const SizedBox(width: 6),
              Btn('Diff', small: true, onTap: () => openTask(ref, t.id)),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// How far along a running task is: pipeline step, else tool calls so far.
double _progress(Task t, Run? run) {
  final steps = t.pipeline;
  if (steps.isNotEmpty) {
    final done = steps.where((s) => s.status == 'done').length;
    return ((done + 0.5) / steps.length).clamp(0.05, 0.95);
  }
  final tools = run?.toolCalls ?? 0;
  return (0.1 + tools * 0.08).clamp(0.1, 0.9);
}
