import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'task_bits.dart';

/// The live run of a task (design T02, right side).
class RunPane extends ConsumerStatefulWidget {
  const RunPane({super.key, required this.task});
  final Task task;
  @override
  ConsumerState<RunPane> createState() => _RunPaneState();
}

class _RunPaneState extends ConsumerState<RunPane> {
  String? runId; // null = latest
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
    final runs = data.runsOf(widget.task.id);
    final client = ref.read(clientProvider);
    if (runs.isEmpty) return _NoRun(task: widget.task);
    final run = runs.firstWhere((r) => r.id == runId, orElse: () => runs.last);
    final agent = data.get<AgentProfile>(Kind.agent, run.agentId);
    final active = RunStatus.isActive(run.status);
    final index = runs.indexOf(run) + 1;

    return Container(
      color: c.codeBg,
      child: Column(children: [
        Container(
          height: 52,
          color: c.bar,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            AgentTile(agent: agent, agentId: run.agentId, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${agent?.name ?? run.agentId} · run #$index', style: context.t(13, w: FontWeight.w700)),
                Text([
                  if (agent?.version != null) agent!.version!.split(' ').first,
                  if (agent?.plan.isNotEmpty == true) agent!.plan,
                  _status(run),
                ].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text2)),
              ]),
            ),
            if (active) ...[
              Btn(run.status == RunStatus.paused ? 'Resume' : 'Pause', icon: run.status == RunStatus.paused ? LucideIcons.play : LucideIcons.pause,
                  onTap: () => client.call(run.status == RunStatus.paused ? M.runsResume : M.runsPause, {'runId': run.id})),
              const SizedBox(width: 6),
              Builder(builder: (context) => Btn('Hand off…', icon: LucideIcons.workflow, onTap: () async {
                final box = context.findRenderObject() as RenderBox;
                final others = data.agents.where((a) => a.id != run.agentId && a.binaryPath != null && a.enabled).toList();
                final to = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [for (final a in others) (a.id, a.name, null)]);
                if (to != null) {
                  try {
                    await client.call(M.runsHandoff, {'runId': run.id, 'agentId': to});
                  } on RpcError catch (e) {
                    if (context.mounted) showError(context, e.message);
                  }
                }
              })),
              const SizedBox(width: 6),
              Btn('Stop', kind: BtnKind.danger, onTap: () => client.call(M.runsStop, {'runId': run.id})),
            ] else
              Btn('Run again', icon: LucideIcons.play, onTap: () async {
                try {
                  await client.call(M.runsStart, {'taskId': widget.task.id, 'agentId': run.agentId, 'note': 'Continue from where the last run ended.'});
                } on RpcError catch (e) {
                  if (context.mounted) showError(context, e.message);
                }
              }),
          ]),
        ),
        Container(
          color: c.bar,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          height: 32,
          child: Row(children: [
            for (final r in runs.reversed.take(6).toList().reversed)
              GestureDetector(
                onTap: () => setState(() => runId = r.id),
                child: Container(
                  margin: const EdgeInsets.only(right: 14),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: r.id == run.id ? c.accent : Colors.transparent, width: 2))),
                  alignment: Alignment.center,
                  child: Row(children: [
                    AgentTile(agent: data.get<AgentProfile>(Kind.agent, r.agentId), agentId: r.agentId, size: 12),
                    const SizedBox(width: 5),
                    Text('#${runs.indexOf(r) + 1}', style: context.t(12, w: r.id == run.id ? FontWeight.w600 : FontWeight.w400, color: r.id == run.id ? c.text : c.text2)),
                    const SizedBox(width: 4),
                    Dot(_statusColor(context, r.status), size: 6),
                  ]),
                ),
              ),
            const Spacer(),
            Text('${_k(run.tokensIn)} in · ${_k(run.tokensOut)} out${run.costUsd > 0 ? ' · \$${run.costUsd.toStringAsFixed(3)}' : ''} · ${run.toolCalls} tools',
                style: context.t(11, color: c.text3)),
          ]),
        ),
        Container(height: 1, color: c.inner),
        Expanded(child: _Stream(run: run)),
        if (active)
          Container(
            color: c.bar,
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              FieldInput(
                controller: steer,
                hint: run.data['canSteer'] == false
                    ? '${agent?.name ?? 'This agent'} can\'t take messages while it runs'
                    : 'Steer the run… "use the Worker binding", or ask a question',
                minLines: 2,
                maxLines: 4,
                onSubmitted: (_) => _send(run),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Icon(LucideIcons.atSign, size: 13, color: c.text3),
                const SizedBox(width: 6),
                Expanded(child: Text('Goes to the agent and the task thread · ⏎ sends', style: context.t(11, color: c.text3))),
                Btn('Send', kind: BtnKind.primary, icon: LucideIcons.send, onTap: () => _send(run)),
              ]),
            ]),
          ),
      ]),
    );
  }

  Future<void> _send(Run run) async {
    final text = steer.text.trim();
    if (text.isEmpty) return;
    final client = ref.read(clientProvider);
    try {
      await client.call(M.runsSteer, {'runId': run.id, 'text': text});
      await client.call(M.commentsPost, {'taskId': run.taskId, 'body': text});
      steer.clear();
    } on RpcError catch (e) {
      if (mounted) showError(context, e.message);
    }
  }

  String _status(Run r) => switch (r.status) {
    RunStatus.running || RunStatus.starting => 'running ${elapsed(r.startedAt)}',
    RunStatus.waiting => 'waiting for you',
    RunStatus.paused => 'paused',
    RunStatus.done => 'done in ${elapsed(r.startedAt, r.endedAt)}',
    RunStatus.failed => 'failed',
    RunStatus.stopped => 'stopped',
    _ => r.status,
  };

  static String _k(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
}

Color _statusColor(BuildContext context, String s) => switch (s) {
  RunStatus.running || RunStatus.starting => context.c.success,
  RunStatus.waiting || RunStatus.paused => context.c.warning,
  RunStatus.failed => context.c.danger,
  RunStatus.done => context.c.accentIcon,
  _ => context.c.text3,
};

class _NoRun extends ConsumerWidget {
  const _NoRun({required this.task});
  final Task task;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final agents = data.agents.where((a) => a.binaryPath != null && a.enabled).toList();
    return Container(
      color: c.codeBg,
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.bot, size: 28, color: c.text3),
          const SizedBox(height: 10),
          Text('No agent has worked on this yet', style: context.t(13, w: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Queue it for the next free slot, or start one now.', style: context.t(12, color: c.text2)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            for (final a in agents)
              Btn('Run with ${a.name}', icon: LucideIcons.play, onTap: () async {
                try {
                  await ref.read(clientProvider).call(M.runsStart, {'taskId': task.id, 'agentId': a.id});
                } on RpcError catch (e) {
                  if (context.mounted) showError(context, e.message);
                }
              }),
            if (task.status != TaskStatus.queued)
              Btn('Queue', kind: BtnKind.primary, icon: LucideIcons.circleDot, onTap: () => ref.read(clientProvider).call(M.tasksMove, {'id': task.id, 'status': TaskStatus.queued})),
          ]),
          if (agents.isEmpty) ...[
            const SizedBox(height: 10),
            Text('No agent CLIs found. Install Claude Code, Codex or another, then refresh under Agents.', style: context.t(11, color: c.text3)),
          ],
        ]),
      ),
    );
  }
}

/// The run's events: steps, messages, permission cards.
class _Stream extends ConsumerWidget {
  const _Stream({required this.run});
  final Run run;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(runEventsProvider(run.id));
    final answered = {for (final e in events.where((e) => e.type == RunEventType.permissionAnswer)) e.data['id']};
    final items = events.where((e) => e.type != RunEventType.usage && e.type != RunEventType.permissionAnswer).toList();
    // Pair tool uses with their results.
    final results = {for (final e in events.where((e) => e.type == RunEventType.toolResult)) e.data['id']: e};
    final visible = items.where((e) => e.type != RunEventType.toolResult || !events.any((u) => u.type == RunEventType.toolUse && u.data['id'] == e.data['id'])).toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(16),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final e = visible[visible.length - 1 - i];
        return Padding(padding: const EdgeInsets.only(bottom: 10), child: _event(context, ref, e, results, answered));
      },
    );
  }

  Widget _event(BuildContext context, WidgetRef ref, RunEvent e, Map<Object?, RunEvent> results, Set<Object?> answered) {
    final c = context.c;
    final time = TimeOfDay.fromDateTime(e.at.toLocal()).format(context);
    switch (e.type) {
      case RunEventType.toolUse:
        final res = results[e.data['id']];
        final done = res != null;
        final ok = res?.data['ok'] != false;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: done
                ? Icon(ok ? LucideIcons.check : LucideIcons.x, size: 13, color: ok ? c.success : c.danger)
                : SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.accentIcon)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${e.data['tool']}  ${e.data['summary'] ?? ''}', style: context.t(12, family: mono, color: done ? c.text2 : c.text)),
              if (res != null && (res.data['summary'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('${res.data['summary']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono, color: c.text3)),
                ),
            ]),
          ),
          Text(time, style: context.t(11, color: c.text3)),
        ]);
      case RunEventType.message:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: c.bar, borderRadius: BorderRadius.circular(8)),
          child: SelectableText('${e.data['text']}', style: context.t(13, height: 1.45)),
        );
      case RunEventType.steer:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
            child: Text('${e.data['text']}', style: context.t(12)),
          ),
        );
      case RunEventType.permission:
        final pending = !answered.contains(e.data['id']) && RunStatus.isActive(run.status);
        final client = ref.read(clientProvider);
        Future<void> answer(String a) => client.call(M.permissionsAnswer, {'runId': run.id, 'requestId': e.data['id'], 'answer': a});
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: pending ? c.warningWash : c.bar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: pending ? c.warning : c.inner),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.shieldCheck, size: 15, color: pending ? c.warning : c.text3),
              const SizedBox(width: 8),
              Text(pending ? 'Wants to use ${e.data['tool']}' : 'Asked to use ${e.data['tool']}', style: context.t(13, w: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(6)),
              child: SelectableText('${e.data['summary']}', style: context.t(12, family: mono)),
            ),
            if (pending) ...[
              const SizedBox(height: 10),
              Row(children: [
                Btn('Allow once', kind: BtnKind.primary, onTap: () => answer('allow_once')),
                const SizedBox(width: 8),
                Btn('Always for this run', onTap: () => answer('allow_always')),
                const SizedBox(width: 8),
                Btn('Deny', kind: BtnKind.danger, onTap: () => answer('deny')),
              ]),
            ],
          ]),
        );
      case RunEventType.status:
        final s = e.data['status'] as String? ?? '';
        final failed = s == 'failed';
        return Row(children: [
          Icon(failed ? LucideIcons.circleAlert : LucideIcons.info, size: 12, color: failed ? c.danger : c.text3),
          const SizedBox(width: 8),
          Expanded(child: Text(e.data['detail'] as String? ?? s, maxLines: failed ? 6 : 2, overflow: TextOverflow.ellipsis, style: context.t(11, color: failed ? c.danger : c.text3))),
          Text(time, style: context.t(11, color: c.text3)),
        ]);
      case RunEventType.error:
        return Text('${e.data['text']}', style: context.t(12, family: mono, color: c.danger));
      case RunEventType.toolResult:
        return Text('↳ ${e.data['summary'] ?? ''}', style: context.t(11, family: mono, color: c.text3));
      default:
        return Text('${e.data['text'] ?? ''}', style: context.t(12, family: mono, color: c.text2));
    }
  }
}
