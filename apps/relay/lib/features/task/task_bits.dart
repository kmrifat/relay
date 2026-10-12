import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

IconData statusIcon(String s) => switch (s) {
  TaskStatus.backlog => LucideIcons.circle,
  TaskStatus.queued => LucideIcons.circleDot,
  TaskStatus.running => LucideIcons.zap,
  TaskStatus.review => LucideIcons.gitPullRequest,
  TaskStatus.done => LucideIcons.circleCheck,
  _ => LucideIcons.circle,
};

Color statusColor(BuildContext context, String s) => switch (s) {
  TaskStatus.queued => context.c.accentIcon,
  TaskStatus.running => context.c.success,
  TaskStatus.review => context.c.warning,
  TaskStatus.done => context.c.success,
  _ => context.c.text3,
};

/// "Asks you", "Needs permission", "Failed" badges.
Widget? attentionBadge(BuildContext context, Task t) {
  final a = t.data['attention'] as String?;
  final c = context.c;
  return switch (a) {
    'permission' => Pill('Needs permission', fg: c.warning, bg: c.warningWash),
    'question' => Pill('Asks you', fg: c.warning, bg: c.warningWash),
    'approval' => Pill('Needs your OK', fg: c.warning, bg: c.warningWash),
    'failed' => Pill('Failed', fg: c.danger, bg: c.dangerWash),
    _ => null,
  };
}

Widget priorityBadge(BuildContext context, Task t) => t.priority == 0
    ? const SizedBox.shrink()
    : Pill('P${t.priority}', fg: t.priority == 1 ? context.c.danger : context.c.text2, bg: t.priority == 1 ? context.c.dangerWash : context.c.inner);

/// Who's on it: an agent tile + name, a person, or "Unassigned".
class AssigneeLabel extends ConsumerWidget {
  const AssigneeLabel(this.task, {super.key, this.size = 11, this.onAccent = false});
  final Task task;
  final double size;
  final bool onAccent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final fg = onAccent ? Colors.white : context.c.text2;
    final steps = task.pipeline;
    if (steps.isNotEmpty) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) Text(' → ', style: context.t(size, color: fg)),
          steps[i].assigneeKind == 'agent'
              ? AgentTile(agent: data.get<AgentProfile>(Kind.agent, steps[i].assignee), agentId: steps[i].assignee, size: 14)
              : Avatar(steps[i].assignee, size: 14, color: context.c.warning),
        ],
      ]);
    }
    if (task.assigneeKind == 'agent') {
      final a = data.get<AgentProfile>(Kind.agent, task.assignee);
      return Row(mainAxisSize: MainAxisSize.min, children: [
        AgentTile(agent: a, agentId: task.assignee, size: 16),
        const SizedBox(width: 6),
        Flexible(child: Text(a?.name ?? task.assignee ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(size, color: fg))),
      ]);
    }
    if (task.assigneeKind == 'person' && task.assignee != null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Avatar(task.assignee!, size: 16),
        const SizedBox(width: 6),
        Text(task.assignee!, style: context.t(size, color: fg)),
      ]);
    }
    return Text('Unassigned · routing picks', style: context.t(size, color: onAccent ? Colors.white70 : context.c.text3));
  }
}

/// One chip per repo the task touches, with its change status as a dot.
class RepoChips extends ConsumerWidget {
  const RepoChips(this.task, {super.key});
  final Task task;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final repos = data.reposOf(task.projectId);
    if (repos.length < 2 || task.repoIds.isEmpty) return const SizedBox.shrink();
    final changes = {for (final ch in data.changesOf(task.id)) ch.repoId: ch};
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final r in repos.where((r) => task.repoIds.contains(r.id)))
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: hexColor(r.color).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(4)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (changes[r.id]?.status == 'merged')
              Icon(LucideIcons.check, size: 9, color: hexColor(r.color))
            else if (changes[r.id] != null)
              Dot(switch (changes[r.id]!.status) {
                'running' => context.c.success,
                'ready' => context.c.warning,
                'failed' => context.c.danger,
                _ => context.c.text3,
              }, size: 5),
            if (changes[r.id] != null) const SizedBox(width: 4),
            Text(r.name, style: context.t(10, color: hexColor(r.color), w: FontWeight.w600)),
          ]),
        ),
    ]);
  }
}

/// Live run line: progress + current step, for cards and rows.
class RunLine extends ConsumerWidget {
  const RunLine(this.task, {super.key});
  final Task task;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final run = data.activeRun(task);
    if (run == null) return const SizedBox.shrink();
    final step = run.data['currentStep'] as String?;
    return Row(children: [
      Icon(run.status == RunStatus.paused ? LucideIcons.pause : LucideIcons.refreshCw, size: 11, color: context.c.accentIcon),
      const SizedBox(width: 6),
      Expanded(
        child: Text(step ?? (run.status == RunStatus.starting ? 'Starting…' : 'Working…'),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10.5, family: mono, color: context.c.text2)),
      ),
    ]);
  }
}

Future<void> openTask(WidgetRef ref, String id) async => ref.read(navProvider.notifier).openTask(id);

/// Context menu actions shared by board cards and list rows.
Future<void> taskMenu(BuildContext context, WidgetRef ref, Task t, Offset at) async {
  final client = ref.read(clientProvider);
  final choice = await showMenuAt<String>(context, at, [
    ('open', 'Open', LucideIcons.panelRight),
    if (t.status != TaskStatus.queued && t.status != TaskStatus.running) ('queue', 'Queue for an agent', LucideIcons.circleDot),
    if (t.status != TaskStatus.running) ('run', 'Run now', LucideIcons.play),
    ('backlog', 'Move to Backlog', LucideIcons.circle),
    ('done', 'Mark done', LucideIcons.circleCheck),
    ('delete', 'Delete', LucideIcons.trash2),
  ]);
  switch (choice) {
    case 'open':
      await openTask(ref, t.id);
    case 'queue':
      await client.call(M.tasksMove, {'id': t.id, 'status': TaskStatus.queued});
    case 'run':
      if (context.mounted) await runNow(context, ref, t);
    case 'backlog':
      await client.call(M.tasksMove, {'id': t.id, 'status': TaskStatus.backlog});
    case 'done':
      await client.call(M.tasksMove, {'id': t.id, 'status': TaskStatus.done});
    case 'delete':
      await client.call(M.tasksDelete, {'id': t.id});
  }
}

/// "Pria · Project manager" for a role agent, the CLI's name otherwise.
String agentLabel(AgentProfile a) => a.role.isEmpty ? a.name : '${a.name} · ${a.role}';

/// Who does [t]: routing picks, a named agent, or me. Shared by the task
/// page and the board's A key.
Future<void> assignMenu(BuildContext context, WidgetRef ref, Task t, Offset at) async {
  final data = ref.read(dataProvider);
  final client = ref.read(clientProvider);
  final choice = await showMenuAt<String>(context, at, [
    ('auto', 'Any agent (routing rules)', LucideIcons.workflow),
    for (final a in data.agents.where((a) => a.binaryPath != null)) ('agent:${a.id}', agentLabel(a), a.isRole ? LucideIcons.userRound : LucideIcons.bot),
    ('me', 'Me', LucideIcons.user),
  ]);
  if (choice == null) return;
  final fields = switch (choice) {
    'auto' => {'assigneeKind': 'agent', 'assignee': 'auto'},
    'me' => {'assigneeKind': 'person', 'assignee': client.hello['userName'] ?? 'You'},
    _ => {'assigneeKind': 'agent', 'assignee': choice.substring(6)},
  };
  await client.call(M.tasksUpdate, {'id': t.id, 'fields': fields});
}

/// Starts an agent on [t] now, saying why not if it can't.
Future<void> runNow(BuildContext context, WidgetRef ref, Task t) async {
  try {
    await ref.read(clientProvider).call(M.runsStart, {'taskId': t.id});
  } on RpcError catch (e) {
    if (context.mounted) showError(context, e.message);
  }
}

void showError(BuildContext context, String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
  behavior: SnackBarBehavior.floating,
  width: 460,
  backgroundColor: context.c.dangerWash,
  content: Text(message, style: context.t(12, color: context.c.danger)),
));
