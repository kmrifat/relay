import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../data/relay_data.dart';
import '../ui/markdown.dart';
import 'glass.dart';
import 'mobile_data.dart';
import 'mobile_shell.dart' show pendingPermission, PersonDot;
import 'sheets.dart';

/// I03 · a task with its live run: steps as they happen, the plan, the
/// change set, the thread. A permission request opens the glass sheet.
class RunScreen extends ConsumerStatefulWidget {
  const RunScreen({super.key, required this.taskId});
  final String taskId;
  @override
  ConsumerState<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends ConsumerState<RunScreen> {
  String tab = 'live';
  final steer = TextEditingController();
  final _shown = <Object?>{};

  Future<void> _call(String method, Map<String, Object?> params) async {
    try {
      await ref.read(clientProvider).call(method, params);
    } on RpcError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final t = view.data.get<Task>(Kind.task, widget.taskId);
    if (t == null) return const Scaffold(backgroundColor: MC.bg);
    final runs = view.data.runsOf(t.id);
    final run = view.data.activeRun(t) ?? runs.lastOrNull;
    final events = run == null ? const <RunEvent>[] : ref.watch(runEventsProvider(run.id));
    final agent = view.agent(run?.agentId ?? t.assignee, deviceId: run?.deviceId);
    final active = run != null && RunStatus.isActive(run.status);
    final pending = pendingPermission(events);

    // A new permission request: ask now, once.
    if (pending != null && run != null && !_shown.contains(pending.data['id'])) {
      _shown.add(pending.data['id']);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showPermissionSheet(context, ref, task: t, run: run, request: pending);
      });
    }

    final top = MediaQuery.of(context).padding.top;
    final status = active ? (run.status == RunStatus.waiting ? 'Waiting' : (run.status == RunStatus.paused ? 'Paused' : 'Running')) : TaskStatus.label(t.status);
    return Scaffold(
      backgroundColor: MC.bg,
      body: BackdropGroup(
        child: Stack(children: [
          ListView(
            padding: EdgeInsets.fromLTRB(16, top + 62, 16, 120),
            children: [
              Text('${view.data.keyOf(t)} · $status', style: mt(14, color: MC.text2, family: 'Menlo')),
              const SizedBox(height: 4),
              Text(t.title, style: mt(28, w: FontWeight.w700, height: 1.15)),
              const SizedBox(height: 6),
              Row(children: [
                AgentSquare(letter: agent.letter, color: agent.color, size: 20),
                const SizedBox(width: 8),
                Flexible(child: Text('${agent.name} on ${view.whereRuns(run?.deviceId ?? t.str('runOn'))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(15, color: MC.text2))),
                if (active) ...[
                  const SizedBox(width: 8),
                  Container(width: 7, height: 7, decoration: const BoxDecoration(color: MC.green, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(shortAgo(run.createdAt), style: mt(15, color: MC.green)),
                ],
              ]),
              const SizedBox(height: 14),
              GlassSegments<String>(
                options: const [('live', 'Live'), ('plan', 'Plan'), ('diff', 'Diff'), ('thread', 'Thread')],
                value: tab,
                onChanged: (v) => setState(() => tab = v),
              ),
              const SizedBox(height: 14),
              ...switch (tab) {
                'plan' => _plan(t),
                'diff' => _diff(view, t),
                'thread' => [_Thread(t)],
                _ => _live(run, events),
              },
            ],
          ),
          Positioned(
            top: top + 6,
            left: 16,
            right: 16,
            child: Row(children: [
              GlassCircle(icon: LucideIcons.chevronLeft, onTap: () => Navigator.of(context).pop(), semantics: 'Back'),
              const Spacer(),
              if (active)
                GlassPill(items: [
                  run.status == RunStatus.paused
                      ? (LucideIcons.play, () => _call(M.runsResume, {'runId': run.id}), 'Resume')
                      : (LucideIcons.pause, () => _call(M.runsPause, {'runId': run.id}), 'Pause'),
                  (LucideIcons.square, () => _call(M.runsStop, {'runId': run.id}), 'Stop'),
                ])
              else if (t.status != TaskStatus.done)
                GlassPill(items: [(LucideIcons.play, () => _call(M.runsStart, {'taskId': t.id}), 'Start a run')]),
            ]),
          ),
          if (active && tab == 'live')
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).padding.bottom + 8,
              child: Glass(
                padding: const EdgeInsets.fromLTRB(18, 2, 6, 2),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: steer,
                      style: mt(16),
                      cursorOpacityAnimates: false,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _steer(run),
                      decoration: InputDecoration(border: InputBorder.none, hintText: 'Tell ${agent.name}…', hintStyle: mt(16, color: MC.text3)),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _steer(run),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(color: MC.accent, shape: BoxShape.circle),
                      child: const Icon(LucideIcons.arrowUp, color: Colors.white, size: 20),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Future<void> _steer(Run run) async {
    final text = steer.text.trim();
    if (text.isEmpty) return;
    steer.clear();
    await _call(M.runsSteer, {'runId': run.id, 'text': text});
  }

  List<Widget> _live(Run? run, List<RunEvent> events) {
    if (run == null) return [Center(child: Padding(padding: const EdgeInsets.only(top: 30), child: Text('No run yet. Tap ▶ to start one on your Mac.', style: mt(15, color: MC.text2))))];
    final tools = <String, (RunEvent, RunEvent?)>{};
    for (final e in events) {
      if (e.type == RunEventType.toolUse) tools['${e.data['id']}'] = (e, null);
      if (e.type == RunEventType.toolResult && tools.containsKey('${e.data['id']}')) tools['${e.data['id']}'] = (tools['${e.data['id']}']!.$1, e);
    }
    final lastMsg = events.where((e) => e.type == RunEventType.message).lastOrNull;
    final active = RunStatus.isActive(run.status);
    return [
      if (tools.isNotEmpty)
        MCard(
          child: Column(children: [
            for (final (use, result) in tools.values.toList().reversed.take(12).toList().reversed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  Icon(
                    result == null ? (active ? LucideIcons.refreshCw : LucideIcons.minus) : (result.data['ok'] == false ? LucideIcons.x : LucideIcons.check),
                    size: 16,
                    color: result == null ? MC.accent : (result.data['ok'] == false ? MC.red : MC.green),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('${use.data['summary'] ?? use.data['tool']}',
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: mt(16, w: result == null ? FontWeight.w600 : FontWeight.w400)),
                  ),
                ]),
              ),
          ]),
        ),
      if (lastMsg != null) ...[
        const SizedBox(height: 12),
        MCard(child: Markdown('${lastMsg.data['text']}', style: phoneMd(), selectable: false)),
      ],
      if (run.summary != null && !active && run.summary!.trim() != '${lastMsg?.data['text'] ?? ''}'.trim()) ...[
        const SizedBox(height: 12),
        MCard(child: Markdown(run.summary!, style: phoneMd(), selectable: false)),
      ],
      if (tools.isEmpty && lastMsg == null && active)
        Center(child: Padding(padding: const EdgeInsets.only(top: 24), child: Text('Waiting for the first step…', style: mt(15, color: MC.text2)))),
    ];
  }

  List<Widget> _plan(Task t) => [
    if (t.brief.isNotEmpty) MCard(child: Text(t.brief, style: mt(16, height: 1.35))),
    if (t.doneWhen.isNotEmpty) ...[
      const MSection('Done when'),
      MCard(
        child: Column(children: [
          for (final c in t.doneWhen)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(c.done ? LucideIcons.circleCheck : LucideIcons.circle, size: 18, color: c.done ? MC.green : MC.text3),
                const SizedBox(width: 10),
                Expanded(child: Text(c.text, style: mt(16))),
              ]),
            ),
        ]),
      ),
    ],
    if (t.brief.isEmpty && t.doneWhen.isEmpty) Center(child: Text('No plan written for this task.', style: mt(15, color: MC.text2))),
  ];

  List<Widget> _diff(PhoneView view, Task t) {
    final changes = view.data.changesOf(t.id);
    if (changes.isEmpty) return [Center(child: Text('No changes yet.', style: mt(15, color: MC.text2)))];
    return [
      MCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (final (i, c) in changes.indexed) ...[
            if (i > 0) const Divider(height: 1, color: MC.separator),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const Icon(LucideIcons.gitBranch, size: 18, color: MC.text2),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(view.data.get<Repo>(Kind.repo, c.repoId)?.name ?? 'repo', style: mt(16, w: FontWeight.w600)),
                    Text('${c.data['branch'] ?? ''} · ${c.status} · ${c.data['filesChanged'] ?? 0} files', style: mt(14, color: MC.text2)),
                  ]),
                ),
                Text('+${c.data['additions'] ?? 0}', style: mt(15, color: MC.green)),
                const SizedBox(width: 6),
                Text('−${c.data['deletions'] ?? 0}', style: mt(15, color: MC.red)),
              ]),
            ),
          ],
        ]),
      ),
      Padding(padding: const EdgeInsets.all(8), child: Text('Review and merge the code on your Mac.', textAlign: TextAlign.center, style: mt(13, color: MC.text2))),
    ];
  }
}

/// The task thread on the phone, with a reply box (through the Mac).
class _Thread extends ConsumerStatefulWidget {
  const _Thread(this.t);
  final Task t;
  @override
  ConsumerState<_Thread> createState() => _ThreadState();
}

class _ThreadState extends ConsumerState<_Thread> {
  final reply = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final comments = ref.watch(commentsProvider(widget.t.id)).value ?? const <Comment>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in comments)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: MCard(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PersonDot(c.author, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c.author} · ${shortAgo(c.createdAt)}', style: mt(13, w: FontWeight.w600, color: MC.text2)),
                  const SizedBox(height: 2),
                  Markdown(c.body, style: phoneMd(), mentions: true, selectable: false),
                ]),
              ),
            ]),
          ),
        ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: MC.card, borderRadius: BorderRadius.circular(999)),
        child: TextField(
          controller: reply,
          style: mt(16),
          cursorOpacityAnimates: false,
          textInputAction: TextInputAction.send,
          onSubmitted: (v) async {
            if (v.trim().isEmpty) return;
            reply.clear();
            try {
              await ref.read(clientProvider).call(M.commentsPost, {'taskId': widget.t.id, 'body': v.trim()});
            } on RpcError catch (e) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
          decoration: InputDecoration(border: InputBorder.none, hintText: 'Reply on this task', hintStyle: mt(16, color: MC.text3)),
        ),
      ),
    ]);
  }
}
