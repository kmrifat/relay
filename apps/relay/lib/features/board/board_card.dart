import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../agents/model_picker.dart';
import '../task/task_bits.dart';

/// A board card (design P03). [compact] leaves out the live line, tags and
/// the merge buttons.
class TaskCard extends ConsumerWidget {
  const TaskCard({super.key, required this.task, this.focused = false, this.selected = false, this.onSelect, this.onOpen, this.compact = false});
  final Task task;

  /// The board's keyboard selection is on this card.
  final bool focused;

  /// It is the one in the peek.
  final bool selected;

  /// A click: the board selects it and shows it in the peek.
  final VoidCallback? onSelect;

  /// The full task page (the Diff button; the board opens on a second click).
  final VoidCallback? onOpen;
  final bool compact;

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

    final agent = t.assigneeKind == 'agent' ? data.get<AgentProfile>(Kind.agent, t.assignee) : null;
    final model = t.model != null && (t.modelFor == null || t.modelFor == agent?.adapter) ? t.model : agent?.model;
    final checks = t.doneWhen;
    final pr = changes.where((ch) => ch.prUrl != null).firstOrNull;
    return Hoverable(
      onTap: onSelect ?? () => openTask(ref, t.id),
      onSecondaryTapDown: (d) => taskMenu(context, ref, t, d.globalPosition),
      focused: focused,
      radius: 8,
      child: Container(
        padding: EdgeInsets.all(compact ? 9 : 10),
        decoration: BoxDecoration(
          color: done ? c.bar : (selected ? Color.lerp(c.box, c.accent, 0.12) : c.box),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? c.accentIcon : border, width: selected ? 1.5 : 1),
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
                if (t.data['draft'] == true) Pill('Draft · plan', fg: c.purple, bg: c.purpleWash),
                if (t.str('verdict') == 'failed') Pill('QA failed', fg: c.danger, bg: c.dangerWash),
                if (t.priority > 0) priorityBadge(context, t),
              ]),
            ),
          ]),
          const SizedBox(height: 6),
          Text(t.title, style: context.t(13, w: done ? FontWeight.w400 : FontWeight.w600, color: done ? c.text2 : c.text)),
          if (!compact && (t.tags.isNotEmpty || (t.repoIds.isNotEmpty && data.reposOf(t.projectId).length > 1))) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final tag in t.tags) Pill(tag),
              RepoChips(t),
            ]),
          ],
          if (live && !compact) ...[
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
          if (pr != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(LucideIcons.gitPullRequest, size: 11, color: pr.status == 'merged' ? c.purple : c.success),
              const SizedBox(width: 4),
              Text(_prLabel(pr.prUrl!), style: context.t(10.5)),
              if (pr.checks != null) ...[const SizedBox(width: 6), Flexible(child: Text(pr.checks!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10.5, color: pr.checks!.contains('fail') ? c.danger : c.success)))],
            ]),
          ],
          if (t.status == TaskStatus.review && changes.isNotEmpty && !compact) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(LucideIcons.fileDiff, size: 12, color: c.text3),
              const SizedBox(width: 6),
              DiffNums(adds, dels),
              const SizedBox(width: 8),
              Flexible(child: Builder(builder: (context) {
                final n = changes.fold<int>(0, (s, ch) => s + ch.filesChanged);
                return Text('$n file${n == 1 ? '' : 's'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text3));
              })),
            ]),
          ],
          const SizedBox(height: 8),
          Row(children: [
            if (checks.isNotEmpty) ...[
              Icon(LucideIcons.listChecks, size: 11, color: c.text3),
              const SizedBox(width: 3),
              Text('${checks.where((x) => x.done).length}/${checks.length}', style: context.t(10.5, color: c.text3)),
              const SizedBox(width: 6),
            ],
            if (model != null && !done) ...[Pill(modelLabel(agent, model), fg: c.purple, bg: c.purpleWash), const SizedBox(width: 6)],
            Expanded(child: AssigneeLabel(t)),
            if (t.dependsOn.isNotEmpty && t.status == TaskStatus.queued)
              Text('after ${t.dependsOn.length} task${t.dependsOn.length == 1 ? '' : 's'}', style: context.t(11, color: c.text3)),
            if (done) Text(ago(t.updatedAt), style: context.t(11, color: c.text3)),
          ]),
          if (!compact && t.status == TaskStatus.review && attention == null && changes.any((ch) => ch.status == 'ready')) ...[
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
              Btn('Diff', small: true, onTap: onOpen ?? () => openTask(ref, t.id)),
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

/// "PR #212" from a pull request URL.
String _prLabel(String url) {
  final n = RegExp(r'/(\d+)/?$').firstMatch(url)?.group(1);
  return n == null ? 'PR' : 'PR #$n';
}
