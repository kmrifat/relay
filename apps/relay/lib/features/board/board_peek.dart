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

/// The board's side peek (design P03): enough of a task to steer it
/// without leaving the board. ↵ or Open goes to the full page.
class TaskPeek extends ConsumerStatefulWidget {
  const TaskPeek({super.key, required this.taskId, required this.onClose, required this.onOpen});
  final String taskId;
  final VoidCallback onClose, onOpen;
  @override
  ConsumerState<TaskPeek> createState() => _TaskPeekState();
}

class _TaskPeekState extends ConsumerState<TaskPeek> {
  final steer = TextEditingController();

  @override
  void dispose() {
    steer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = data.get<Task>(Kind.task, widget.taskId);
    if (t == null) return const SizedBox.shrink();
    final client = ref.read(clientProvider);
    final agent = t.assigneeKind == 'agent' ? data.get<AgentProfile>(Kind.agent, t.assignee) : null;
    final run = data.activeRun(t);
    final repos = data.reposOf(t.projectId).where((r) => t.repoIds.contains(r.id)).map((r) => r.name).join(', ');
    final checks = t.doneWhen;

    Future<void> send() async {
      final text = steer.text.trim();
      if (text.isEmpty) return;
      try {
        if (run != null && RunStatus.isActive(run.status) && run.data['canSteer'] != false) {
          await client.call(M.runsSteer, {'runId': run.id, 'text': text});
        } else {
          await client.call(M.commentsPost, {'taskId': t.id, 'body': text});
        }
        steer.clear();
      } on RpcError catch (e) {
        if (context.mounted) showError(context, e.message);
      }
    }

    return Container(
      color: c.bar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text('${data.keyOf(t)} · ${TaskStatus.label(t.status)}${repos.isEmpty ? '' : ' · $repos'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono, color: c.text3)),
            ),
            Btn('Open', small: true, kind: BtnKind.plain, tooltip: '↵', onTap: widget.onOpen),
            IconBtn(LucideIcons.x, size: 13, tooltip: 'Close (Esc)', onTap: widget.onClose),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 10), children: [
            Text(t.title, style: context.t(15, w: FontWeight.w700)),
            if (attentionBadge(context, t) case final b?) ...[const SizedBox(height: 6), Align(alignment: Alignment.centerLeft, child: b)],
            if (t.data['attention'] == 'question' && t.str('question') != null) ...[
              const SizedBox(height: 6),
              Text('"${t.str('question')}"', style: context.t(12, color: c.warning)),
            ],
            const SizedBox(height: 10),
            Box(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                AgentTile(agent: agent, agentId: t.assignee, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(agent == null ? (t.assigneeKind == 'person' ? '${t.assignee}' : 'Unassigned · routing picks') : agentLabel(agent), style: context.t(12, w: FontWeight.w600)),
                    if (agent != null)
                      Text([
                        data.get<AgentProfile>(Kind.agent, agent.runtimeId)?.name ?? agent.name,
                        modelLabel(agent, t.model != null && (t.modelFor == null || t.modelFor == agent.adapter) ? t.model : agent.model),
                        if ((t.effort ?? agent.effort) != null) 'effort ${t.effort ?? agent.effort}',
                      ].join(' · '), style: context.t(10.5, color: c.text2)),
                  ]),
                ),
                Builder(builder: (context) => Btn('Change', small: true, onTap: () {
                  final box = context.findRenderObject() as RenderBox;
                  assignMenu(context, ref, t, box.localToGlobal(Offset(0, box.size.height)));
                })),
              ]),
            ),
            if (t.brief.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(t.brief.trim(), maxLines: 6, overflow: TextOverflow.ellipsis, style: context.t(12, color: c.text2)),
            ],
            if (checks.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Done when · ${checks.where((x) => x.done).length} of ${checks.length}', style: context.t(11, w: FontWeight.w600, color: c.text2)),
              const SizedBox(height: 4),
              for (final (i, item) in checks.indexed)
                Pressable(
                  onTap: () => client.call(M.tasksUpdate, {
                    'id': t.id,
                    'fields': {'doneWhen': [for (final (j, x) in checks.indexed) {'text': x.text, 'done': j == i ? !x.done : x.done}]},
                  }),
                  builder: (context, hover, focus) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(item.done ? LucideIcons.circleCheck : LucideIcons.circle, size: 13, color: item.done ? c.success : c.text3),
                      const SizedBox(width: 6),
                      Expanded(child: Text(item.text, style: context.t(12, color: item.done ? c.text2 : c.text))),
                    ]),
                  ),
                ),
            ],
            if (run != null) ...[
              const SizedBox(height: 12),
              _LiveTail(run: run),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          child: FieldInput(
            controller: steer,
            size: 12,
            hint: run != null && RunStatus.isActive(run.status) ? 'Steer ${agent?.name ?? 'the agent'}… ↵ sends' : 'Comment on the task… ↵ sends',
            onSubmitted: (_) => send(),
          ),
        ),
      ]),
    );
  }
}

/// The last few steps of a run, as they stream in.
class _LiveTail extends ConsumerWidget {
  const _LiveTail({required this.run});
  final Run run;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final events = ref.watch(runEventsProvider(run.id)).where((e) => e.type == RunEventType.toolUse || e.type == RunEventType.message || e.type == RunEventType.steer).toList();
    final tail = events.length > 6 ? events.sublist(events.length - 6) : events;
    final tokens = run.tokensIn + run.tokensOut;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(RunStatus.isActive(run.status) ? 'Live' : 'Last run', style: context.t(11, w: FontWeight.w600, color: c.text2))),
          if (RunStatus.isActive(run.status)) ...[Dot(c.success, size: 6), const SizedBox(width: 4)],
          Text('${elapsed(run.startedAt, run.endedAt)}${tokens > 0 ? ' · ${(tokens / 1000).toStringAsFixed(0)}k tokens' : ''}', style: context.t(10.5, color: c.text3)),
        ]),
        const SizedBox(height: 6),
        if (tail.isEmpty) Text('Starting…', style: context.t(11, family: mono, color: c.text3)),
        for (final e in tail)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Text(
              switch (e.type) {
                RunEventType.toolUse => '› ${e.data['tool']} ${e.data['summary'] ?? ''}',
                RunEventType.steer => '→ ${e.data['text']}',
                _ => '${e.data['text']}',
              },
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.t(11, family: mono, color: e.type == RunEventType.message ? c.text : c.text2),
            ),
          ),
      ]),
    );
  }
}
