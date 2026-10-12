import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../chat/chat_panel.dart';
import 'fleet_page.dart';

/// One agent's page: what it is doing now, what it picks up next, what it
/// did lately, and its settings. Every row opens its task.
class AgentPage extends ConsumerWidget {
  const AgentPage({super.key, required this.agentId});
  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final a = data.get<AgentProfile>(Kind.agent, agentId);
    if (a == null) {
      return Column(children: [
        const Toolbar(title: 'Agent'),
        Container(height: 1, color: c.separator),
        Expanded(child: Center(child: Text('This agent is gone.', style: context.t(13, color: c.text2)))),
      ]);
    }
    // Its work: side-panel chats are conversations, not work.
    final runs = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && data.get<Task>(Kind.task, r.taskId)?.data['ask'] != 'chat').toList();
    final active = runs.where((r) => RunStatus.isActive(r.status)).toList()..sort((x, y) => (y.startedAt ?? DateTime(2000)).compareTo(x.startedAt ?? DateTime(2000)));
    final recent = runs.where((r) => RunStatus.isFinished(r.status)).toList()..sort((x, y) => (y.endedAt ?? DateTime(2000)).compareTo(x.endedAt ?? DateTime(2000)));
    final next = data.tasksOf(null).where((t) => t.status == TaskStatus.queued && t.assigneeKind == 'agent' && t.assignee == a.id).toList()
      ..sort((x, y) => x.position.compareTo(y.position));
    final waiting = active.where((r) => r.status == RunStatus.waiting).length;
    final team = data.teamOf(a);

    return Column(children: [
      Toolbar(
        title: a.name,
        subtitle: [
          if (a.isRole) a.role.isEmpty ? 'Role agent' : a.role else 'CLI on this Mac',
          active.isEmpty ? 'idle' : '${active.length} of ${a.slots} slots busy',
          if (waiting > 0) '$waiting waiting for you',
        ].join(' · '),
        actions: [
          if (team != null) Btn('Team ${team.name}', icon: LucideIcons.users, onTap: () => ref.read(navProvider.notifier).team(team.id, agentId: a.id)),
          Btn('Chat with ${a.name}', icon: LucideIcons.messageCircle, kind: BtnKind.primary, onTap: () => ref.read(chatProvider.notifier).openWith(a.id)),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(20), children: [
              _Section(
                title: 'Working now',
                hint: 'Tasks ${a.name} is running. Open one to watch it, answer it or stop it.',
                empty: 'Nothing running. Queue a task for ${a.name}, or chat with it.',
                rows: [for (final r in active) _RunRow(run: r)],
              ),
              _Section(
                title: 'Up next',
                hint: 'Queued for ${a.name}; it starts them as slots free up.',
                empty: 'Nothing queued for ${a.name}.',
                rows: [for (final t in next) _TaskRow(task: t)],
              ),
              _Section(
                title: 'Recent work',
                hint: 'Its last runs, newest first.',
                empty: 'No finished runs yet.',
                rows: [for (final r in recent.take(20)) _RunRow(run: r)],
              ),
            ]),
          ),
          Container(width: 1, color: c.separator),
          SizedBox(
            width: 380,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text('Settings', style: context.label),
              const SizedBox(height: 8),
              AgentCard(agent: a, onPage: true),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.hint, required this.empty, required this.rows});
  final String title, hint, empty;
  final List<Widget> rows;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(title, style: context.t(13, w: FontWeight.w700)),
          const SizedBox(width: 6),
          if (rows.isNotEmpty) Text('${rows.length}', style: context.t(12, color: c.text3)),
        ]),
        Text(hint, style: context.t(11, color: c.text2)),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Box(padding: const EdgeInsets.all(14), child: Text(empty, style: context.t(12, color: c.text3)))
        else
          Box(
            child: Column(children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const Hairline(), r],
            ]),
          ),
      ]),
    );
  }
}

/// A run: its task, where it stands, and when. Opens the task.
class _RunRow extends ConsumerWidget {
  const _RunRow({required this.run});
  final Run run;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final r = run;
    final task = data.get<Task>(Kind.task, r.taskId);
    final (label, fg, bg) = switch (r.status) {
      RunStatus.waiting => ('Needs you', c.warning, c.warningWash),
      RunStatus.paused => ('Paused', c.text2, c.inner),
      RunStatus.done => ('Done', c.success, c.successWash),
      RunStatus.failed => ('Failed', c.danger, c.dangerWash),
      RunStatus.stopped => ('Stopped', c.text2, c.inner),
      _ => ('Running', c.success, c.successWash),
    };
    final tokens = r.tokensIn + r.tokensOut;
    final when = RunStatus.isActive(r.status) ? 'for ${elapsed(r.startedAt)}' : ago(r.endedAt);
    return _Row(
      onTap: task == null ? null : () => ref.read(navProvider.notifier).openTask(task.id),
      leading: Pill(label, fg: fg, bg: bg, radius: 10),
      keyText: task == null ? null : data.keyOf(task),
      title: task?.title ?? (r.prompt.isEmpty ? 'A run' : r.prompt),
      detail: [
        ?data.get<Project>(Kind.project, task?.projectId)?.name,
        ?r.model,
        if (tokens > 0) '${tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : tokens} tokens',
        if (r.error != null && r.status == RunStatus.failed) r.error!,
      ].join(' · '),
      trailing: when,
    );
  }
}

/// A queued task. Opens it.
class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});
  final Task task;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    return _Row(
      onTap: () => ref.read(navProvider.notifier).openTask(task.id),
      leading: Pill(TaskStatus.label(task.status), radius: 10),
      keyText: data.keyOf(task),
      title: task.title,
      detail: data.projectOf(task)?.name ?? '',
      trailing: ago(task.updatedAt),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.onTap, required this.leading, required this.keyText, required this.title, required this.detail, required this.trailing});
  final VoidCallback? onTap;
  final Widget leading;
  final String? keyText;
  final String title, detail, trailing;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Hoverable(
      onTap: onTap,
      radius: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(children: [
          SizedBox(width: 84, child: Align(alignment: Alignment.centerLeft, child: leading)),
          if (keyText != null) SizedBox(width: 64, child: Text(keyText!, style: context.t(11, family: mono, color: c.text3))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12.5, w: FontWeight.w600)),
              if (detail.isNotEmpty) Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text2)),
            ]),
          ),
          const SizedBox(width: 10),
          Text(trailing, style: context.t(11, color: c.text3)),
          if (onTap != null) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(LucideIcons.chevronRight, size: 13, color: c.text3)),
        ]),
      ),
    );
  }
}
