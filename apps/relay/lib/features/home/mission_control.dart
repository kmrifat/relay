import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/sidebar.dart' show inSmartList;
import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/split.dart';
import '../../ui/widgets.dart';
import '../agents/model_picker.dart';
import '../ask/ask_palette.dart';
import '../task/task_bits.dart' show statusColor;

/// What happened lately (relayd's `activity.list`), fetched again when
/// records change, at most every couple of seconds.
final activityProvider = FutureProvider.autoDispose.family<List<Map<String, Object?>>, String?>((ref, projectId) async {
  ref.watch(dataProvider.select((d) => d.rev ~/ 5)); // a refresh every few changes, not every one
  try {
    return await ref.read(clientProvider).list(M.activityList, {'projectId': ?projectId, 'limit': 150});
  } on RpcError catch (_) {
    return const []; // an older relayd
  }
});

/// The home page (design P01, ⌘0): every product at once, what each
/// agent on its team is doing, what needs you, and how the day went.
class MissionControl extends ConsumerStatefulWidget {
  const MissionControl({super.key});
  @override
  ConsumerState<MissionControl> createState() => _MissionControlState();
}

class _MissionControlState extends ConsumerState<MissionControl> {
  @override
  void initState() {
    super.initState();
    // Plans live in channel messages; load each product's channel.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (final p in ref.read(dataProvider).projects) {
        try {
          await ref.read(dataProvider.notifier).loadMessages(Channel.idFor(p.id));
        } on Object catch (_) {}
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final client = ref.read(clientProvider);
    final running = data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).length;
    final needs = needsYou(data);
    final agents = data.agents.where((a) => a.binaryPath != null).length;
    return Column(children: [
      Toolbar(
        title: 'Mission control',
        subtitle: '${data.projects.length} products · $agents agents · $running running · ${needs.length} need you',
        actions: [
          FutureBuilder(
            future: client.map(M.settingsGet),
            builder: (context, snap) {
              final paused = '${snap.data?['schedulerPaused']}' == 'true';
              return Btn(paused ? 'Resume all' : 'Pause all', small: true, icon: paused ? LucideIcons.play : LucideIcons.pause, onTap: () async {
                await client.call(M.settingsSet, {'values': {'schedulerPaused': !paused}});
                setState(() {});
              });
            },
          ),
          Btn('Ask an agent', small: true, kind: BtnKind.primary, icon: LucideIcons.sparkles, onTap: () => showAskPalette(context, ref)),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: ResizableSplit(
          id: 'home.right',
          sized: SplitSide.second,
          initial: 360,
          min: 300,
          keepOther: 520,
          first: ListView(padding: const EdgeInsets.all(16), children: [
            if (data.projects.isEmpty) Text('Add a project to get started.', style: context.t(13, color: c.text2)),
            for (final p in data.projects) ...[_ProductCard(project: p), const SizedBox(height: 12)],
            const _Today(),
          ]),
          second: Container(
            color: c.bar,
            child: ListView(padding: const EdgeInsets.all(14), children: [
              _NeedsYou(items: needs),
              const SizedBox(height: 14),
              const _Chatter(),
            ]),
          ),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ product

class _ProductCard extends ConsumerWidget {
  const _ProductCard({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final p = project;
    final n = ref.read(navProvider.notifier);
    final tasks = data.tasksOf(p.id);
    final repos = data.reposOf(p.id);
    final milestone = p.milestone.isEmpty ? tasks : tasks.where((t) => t.milestone == p.milestone).toList();
    final done = milestone.where((t) => t.status == TaskStatus.done).length;
    final needs = tasks.where((t) => inSmartList(AppPage.waiting, t)).length;
    final failed = tasks.where((t) => t.data['attention'] == 'failed').length;
    final cost = data.all<Run>(Kind.run).where((r) => r.data['projectId'] == p.id && _today(r.startedAt)).fold<double>(0, (s, r) => s + r.costUsd);
    // The lanes: the team on this product, else whoever has work here.
    final team = data.teams.where((t) => t.projectIds.contains(p.id)).toList();
    final laneIds = {
      for (final t in team) ...t.members,
      for (final t in tasks)
        if (t.assigneeKind == 'agent' && t.status != TaskStatus.done && t.status != TaskStatus.backlog) ?t.assignee,
    }.where((id) => data.get<AgentProfile>(Kind.agent, id) != null).toList();
    final counts = {for (final s in TaskStatus.columns) s: tasks.where((t) => t.status == s).length};

    return Box(
      padding: const EdgeInsets.all(14),
      border: needs > 0 ? c.warning.withValues(alpha: 0.6) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: hexColor(p.color), borderRadius: BorderRadius.circular(7)),
            child: Text(p.key.substring(0, 1), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Pressable(
                onTap: () => n.project(p.id),
                builder: (context, hover, focus) => Text(p.name, style: context.t(14, w: FontWeight.w700, color: hover ? c.accentIcon : c.text)),
              ),
              Row(children: [
                Flexible(
                  child: Text(
                    '${p.goal.isEmpty ? 'No goal yet' : 'Goal · ${p.goal}'} · ${repos.length} repo${repos.length == 1 ? '' : 's'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t(11.5, color: c.text2),
                  ),
                ),
                IconBtn(LucideIcons.pencil, size: 11, tooltip: 'Goal and milestone', onTap: () => showGoalDialog(context, ref, p)),
              ]),
            ]),
          ),
          SizedBox(
            width: 190,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(p.milestone.isEmpty ? 'All tasks' : 'Milestone · ${p.milestone}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text2))),
                Text('$done / ${milestone.length}', style: context.t(11, w: FontWeight.w600)),
              ]),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(minHeight: 4, value: milestone.isEmpty ? 0 : done / milestone.length, backgroundColor: c.inner, color: c.success),
              ),
              if (p.milestoneDue != null) Text('due ${_date(p.milestoneDue!)}', style: context.t(10.5, color: c.text3)),
            ]),
          ),
          const SizedBox(width: 12),
          if (needs > 0) Pill('$needs need you', fg: c.warning, bg: c.warningWash, icon: LucideIcons.hand),
          if (failed > 0) ...[const SizedBox(width: 6), Pill('$failed failed', fg: c.danger, bg: c.dangerWash, icon: LucideIcons.x)],
          if (cost > 0) ...[const SizedBox(width: 8), Text('\$${cost.toStringAsFixed(2)} today', style: context.t(11, color: c.text3))],
        ]),
        const SizedBox(height: 12),
        if (laneIds.isEmpty)
          Row(children: [
            Text('No agents on this product yet.', style: context.t(12, color: c.text2)),
            const SizedBox(width: 8),
            Btn('Ask an agent', small: true, kind: BtnKind.plain, onTap: () => showAskPalette(context, ref)),
          ])
        else
          LayoutBuilder(builder: (context, box) {
            final perRow = (box.maxWidth / 200).floor().clamp(1, 6);
            final w = (box.maxWidth - (perRow - 1) * 8) / perRow;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final id in laneIds) SizedBox(width: w, child: _Lane(agent: data.get<AgentProfile>(Kind.agent, id)!, projectId: p.id)),
            ]);
          }),
        const SizedBox(height: 10),
        Pressable(
          onTap: () => n.project(p.id),
          builder: (context, hover, focus) => Row(children: [
            Text('Board', style: context.t(11, color: c.text3)),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Row(children: [
                  for (final s in TaskStatus.columns)
                    if (counts[s]! > 0) Expanded(flex: counts[s]!, child: Container(height: 6, color: s == TaskStatus.done ? c.successWash : statusColor(context, s))),
                  if (tasks.isEmpty) Expanded(child: Container(height: 6, color: c.inner)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            Text([for (final s in TaskStatus.columns) '${counts[s]} ${_short[s]}'].join(' · '), style: context.t(11, color: hover ? c.text : c.text2)),
          ]),
        ),
      ]),
    );
  }
}

/// One agent on one product: who, on which model, and what it is doing.
class _Lane extends ConsumerWidget {
  const _Lane({required this.agent, required this.projectId});
  final AgentProfile agent;
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final a = agent;
    final mine = data.tasksOf(projectId).where((t) => t.assignee == a.id).toList();
    final run = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).firstOrNull;
    final runTask = run == null ? null : data.get<Task>(Kind.task, run.taskId);
    final waiting = mine.where((t) => inSmartList(AppPage.waiting, t)).firstOrNull;
    final failed = mine.where((t) => t.data['attention'] == 'failed').firstOrNull;
    final queued = mine.where((t) => t.status == TaskStatus.queued).firstOrNull;
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());
    final (String line, Widget badge, Color border) = waiting != null
        ? (waiting.str('question') ?? waiting.title, _state(context, LucideIcons.hand, 'WAITING ON YOU · ${data.keyOf(waiting)}', c.warning), c.warning)
        : runTask != null && run != null
            ? ('${run.data['currentStep'] ?? runTask.title}', _live(context, run, data.keyOf(runTask)), c.boxStroke)
            : failed != null
                ? ('${data.keyOf(failed)} failed: ${failed.str('lastError') ?? failed.title}', _state(context, LucideIcons.x, 'FAILED · retry or reassign', c.danger), c.danger)
                : limited
                    ? ('Plan limit reached', _state(context, LucideIcons.clock, 'BACK ${TimeOfDay.fromDateTime(a.limitedUntil!.toLocal()).format(context)}', c.warning), c.boxStroke)
                    : queued != null
                        ? ('Next: ${queued.title}', _state(context, LucideIcons.clock, 'QUEUED · ${data.keyOf(queued)}', c.accentIcon), c.boxStroke)
                        : ('Idle', _state(context, LucideIcons.clock, 'IDLE', c.text3), c.boxStroke);
    final team = data.teamOf(a);
    return Hoverable(
      radius: 6,
      onTap: () => team == null
          ? ref.read(navProvider.notifier).agent(a.id)
          : ref.read(navProvider.notifier).team(team.id, agentId: a.id),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: c.boxInner, borderRadius: BorderRadius.circular(6), border: Border.all(color: border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AgentTile(agent: a, size: 18),
            const SizedBox(width: 6),
            Text(a.name, style: context.t(12, w: FontWeight.w600)),
            const SizedBox(width: 6),
            Expanded(child: Text(a.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text3))),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 4, children: [
            Pill(modelLabel(a, a.model), fg: c.purple, bg: c.purpleWash),
            if (a.effort != null) Pill('effort ${a.effort}'),
          ]),
          const SizedBox(height: 6),
          Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t(12, color: waiting == null && runTask == null && failed == null ? c.text2 : c.text)),
          const SizedBox(height: 6),
          badge,
        ]),
      ),
    );
  }

  static Widget _state(BuildContext context, IconData icon, String text, Color color) => Row(children: [
    Icon(icon, size: 11, color: color),
    const SizedBox(width: 5),
    Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10, w: FontWeight.w600, color: color))),
  ]);

  static Widget _live(BuildContext context, Run run, String key) => Row(children: [
    Dot(run.status == RunStatus.paused ? context.c.warning : context.c.success, size: 6),
    const SizedBox(width: 5),
    Text(run.status == RunStatus.paused ? 'PAUSED' : 'LIVE ${elapsed(run.startedAt)}',
        style: context.t(10, w: FontWeight.w600, color: run.status == RunStatus.paused ? context.c.warning : context.c.success)),
    Text(' · $key', style: context.t(10, color: context.c.text3)),
  ]);
}

// ------------------------------------------------------------------ needs you

/// Something waiting on you, newest first.
sealed class NeedItem {
  DateTime get at;
}

class _TaskNeed extends NeedItem {
  _TaskNeed(this.task);
  final Task task;
  @override
  DateTime get at => task.updatedAt;
}

class _PlanNeed extends NeedItem {
  _PlanNeed(this.message);
  final Message message;
  @override
  DateTime get at => message.createdAt;
}

/// Questions, permissions, approvals, plans and reviews, newest first.
List<NeedItem> needsYou(DataSnapshot data) => [
  for (final t in data.tasksOf(null))
    if (inSmartList(AppPage.waiting, t) || (t.status == TaskStatus.review && t.data['attention'] == null && data.changesOf(t.id).any((ch) => ch.status == 'ready'))) _TaskNeed(t),
  for (final m in data.all<Message>(Kind.message))
    if (m.data['tag'] == 'plan' && m.data['planState'] == 'proposed') _PlanNeed(m),
]..sort((a, b) => b.at.compareTo(a.at));

class _NeedsYou extends ConsumerStatefulWidget {
  const _NeedsYou({required this.items});
  final List<NeedItem> items;
  @override
  ConsumerState<_NeedsYou> createState() => _NeedsYouState();
}

class _NeedsYouState extends ConsumerState<_NeedsYou> {
  final _focus = FocusNode(debugLabel: 'needs-you');
  int sel = 0;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final items = widget.items;
    if (sel >= items.length) sel = items.isEmpty ? 0 : items.length - 1;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) {
        if (e is KeyUpEvent || items.isEmpty) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.keyJ || e.logicalKey == LogicalKeyboardKey.arrowDown) {
          setState(() => sel = (sel + 1).clamp(0, items.length - 1));
        } else if (e.logicalKey == LogicalKeyboardKey.keyK || e.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(() => sel = (sel - 1).clamp(0, items.length - 1));
        } else if (e.logicalKey == LogicalKeyboardKey.enter) {
          final it = items[sel];
          if (it is _TaskNeed) ref.read(navProvider.notifier).openTask(it.task.id);
          if (it is _PlanNeed) ref.read(navProvider.notifier).channel(it.message.channelId);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Box(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('Needs you · ${items.length}', style: context.t(12, w: FontWeight.w700))),
            Text('J / K · ↵ open', style: context.t(11, color: c.text3)),
          ]),
          const SizedBox(height: 8),
          if (items.isEmpty) Text('Nothing is waiting on you.', style: context.t(12, color: c.text2)),
          for (final (i, it) in items.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () {
                  setState(() => sel = i);
                  _focus.requestFocus();
                },
                child: Container(
                  foregroundDecoration: focusRing(context, i == sel && _focus.hasFocus, 6),
                  child: switch (it) {
                    _TaskNeed(:final task) => _TaskNeedCard(task: task),
                    _PlanNeed(:final message) => _PlanNeedCard(message: message),
                  },
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _TaskNeedCard extends ConsumerStatefulWidget {
  const _TaskNeedCard({required this.task});
  final Task task;
  @override
  ConsumerState<_TaskNeedCard> createState() => _TaskNeedCardState();
}

class _TaskNeedCardState extends ConsumerState<_TaskNeedCard> {
  final answer = TextEditingController();

  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = widget.task;
    final client = ref.read(clientProvider);
    final attention = t.data['attention'] as String?;
    final agent = data.get<AgentProfile>(Kind.agent, t.assignee);
    final run = data.activeRun(t);
    final who = agent?.name ?? 'The agent';
    final key = data.keyOf(t);
    Widget header(String text, {Color? color}) => Row(children: [
      AgentTile(agent: agent, agentId: t.assignee, size: 14),
      const SizedBox(width: 6),
      Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, w: FontWeight.w600, color: color ?? c.text))),
      IconBtn(LucideIcons.arrowUpRight, size: 12, tooltip: 'Open $key', onTap: () => ref.read(navProvider.notifier).openTask(t.id)),
    ]);
    final warn = attention != null;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: warn ? c.warningWash : c.boxInner, borderRadius: BorderRadius.circular(6), border: Border.all(color: warn ? c.warning : c.boxStroke)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (attention) {
        'question' => [
          header('$who asks · $key', color: c.warning),
          const SizedBox(height: 4),
          Text('${t.data['question'] ?? ''}', style: context.t(12)),
          const SizedBox(height: 6),
          FieldInput(controller: answer, size: 12, hint: 'Your answer · ↵ sends', onSubmitted: (v) async {
            if (v.trim().isEmpty) return;
            await client.call(M.commentsPost, {'taskId': t.id, 'body': v.trim()});
            answer.clear();
          }),
        ],
        'permission' => [
          header('$who wants to run · $key', color: c.warning),
          if (run != null) _Permission(run: run),
        ],
        'approval' => [
          header('$key waits for your OK', color: c.warning),
          const SizedBox(height: 4),
          Text('${t.data['question'] ?? t.title}', style: context.t(12)),
          const SizedBox(height: 6),
          Align(alignment: Alignment.centerLeft, child: Btn('Let it start', small: true, kind: BtnKind.primary, onTap: () => client.call(M.tasksUpdate, {'id': t.id, 'fields': {'approved': true, 'attention': null, 'question': null}}))),
        ],
        _ => [
          header('$key ready to merge'),
          const SizedBox(height: 4),
          Text(t.title, style: context.t(12)),
          const SizedBox(height: 6),
          Row(children: [
            DiffNums(data.changesOf(t.id).fold(0, (s, ch) => s + ch.additions), data.changesOf(t.id).fold(0, (s, ch) => s + ch.deletions)),
            const Spacer(),
            Btn('Review', small: true, onTap: () => ref.read(navProvider.notifier).openTask(t.id)),
          ]),
        ],
      }),
    );
  }
}

/// The pending permission of [run], answered right here.
class _Permission extends ConsumerWidget {
  const _Permission({required this.run});
  final Run run;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final events = ref.watch(runEventsProvider(run.id));
    final answered = {for (final e in events.where((e) => e.type == RunEventType.permissionAnswer)) e.data['id']};
    final pending = events.where((e) => e.type == RunEventType.permission && !answered.contains(e.data['id'])).lastOrNull;
    if (pending == null) return const SizedBox.shrink();
    Future<void> answer(String a) => ref.read(clientProvider).call(M.permissionsAnswer, {'runId': run.id, 'requestId': pending.data['id'], 'answer': a});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(4)),
        child: Text('${pending.data['tool']}: ${pending.data['summary']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono)),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 4, children: [
        Btn('Allow', small: true, kind: BtnKind.primary, onTap: () => answer('allow_once')),
        Btn('Always for this run', small: true, onTap: () => answer('allow_always')),
        Btn('Deny', small: true, kind: BtnKind.danger, onTap: () => answer('deny')),
      ]),
    ]);
  }
}

class _PlanNeedCard extends ConsumerWidget {
  const _PlanNeedCard({required this.message});
  final Message message;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final m = message;
    final items = m.maps('items');
    final client = ref.read(clientProvider);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.purpleWash, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.purple)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          AgentTile(agent: data.agents.where((a) => a.name == m.author).firstOrNull, agentId: m.author, size: 14),
          const SizedBox(width: 6),
          Expanded(child: Text('${m.author} proposes ${items.length} task${items.length == 1 ? '' : 's'}', style: context.t(11, w: FontWeight.w600, color: c.purple))),
        ]),
        const SizedBox(height: 4),
        Text(m.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t(12)),
        for (final it in items.take(4)) Text('· ${it['title']}${it['agent'] == null ? '' : ' — ${it['agent']}'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text2)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          Btn('Approve and start', small: true, kind: BtnKind.primary, onTap: () => client.call(M.plansApprove, {'planId': m.data['planId'] ?? m.id})),
          Btn('Open in channel', small: true, onTap: () => ref.read(navProvider.notifier).channel(m.channelId)),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ chatter

/// Agents talking to each other, handing work on and reporting.
class _Chatter extends ConsumerWidget {
  const _Chatter();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final feed = (ref.watch(activityProvider(null)).value ?? const [])
        .where((e) => const {'agent-message', 'handoff', 'report', 'post'}.contains(e['kind']))
        .take(25)
        .toList();
    return Box(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Team chatter', style: context.t(12, w: FontWeight.w700))),
          Btn('All activity', small: true, kind: BtnKind.plain, onTap: () => ref.read(navProvider.notifier).page(AppPage.activity)),
        ]),
        const SizedBox(height: 8),
        if (feed.isEmpty) Text('When agents message each other or hand work on, it shows here.', style: context.t(12, color: c.text2)),
        for (final e in feed) ActivityRow(item: e, data: data),
      ]),
    );
  }
}

/// One line of activity: who, to whom, on what, and what was said.
class ActivityRow extends ConsumerWidget {
  const ActivityRow({super.key, required this.item, required this.data});
  final Map<String, Object?> item;
  final DataSnapshot data;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final e = item;
    final from = data.agents.where((a) => a.id == e['from'] || a.name == e['fromName']).firstOrNull;
    final at = DateTime.tryParse('${e['at']}');
    final head = switch (e['kind']) {
      'agent-message' => '${e['fromName']} → ${e['toName']}',
      'handoff' => 'Handoff',
      'report' => '${e['fromName']} reported',
      'post' => '${e['fromName']} in the channel',
      'run' => '${e['fromName']} ${e['status'] == RunStatus.done ? 'finished' : e['status']}',
      _ => '${e['fromName']}',
    };
    return Hoverable(
      onTap: e['taskId'] == null ? null : () => ref.read(navProvider.notifier).openTask('${e['taskId']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          e['kind'] == 'handoff' ? Icon(LucideIcons.arrowRightLeft, size: 16, color: c.accentIcon) : AgentTile(agent: from, agentId: '${e['fromName']}', size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$head${e['key'] == null ? '' : ' · ${e['key']}'}${at == null ? '' : ' · ${ago(at)}'}', style: context.t(10.5, color: c.text3)),
              Text('${e['text']}', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.t(12)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------ today

/// Who worked on what today, plan limits per CLI, and the day's numbers.
class _Today extends ConsumerWidget {
  const _Today();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final runs = data.all<Run>(Kind.run).where((r) => _today(r.startedAt)).toList();
    final byAgent = <String, List<Run>>{};
    for (final r in runs) {
      (byAgent[r.agentId] ??= []).add(r);
    }
    final now = DateTime.now();
    final start = runs.isEmpty ? now.subtract(const Duration(hours: 8)) : runs.map((r) => r.startedAt!.toLocal()).reduce((a, b) => a.isBefore(b) ? a : b);
    final span = now.difference(start).inSeconds.clamp(60, 86400).toDouble();
    final done = data.tasksOf(null).where((t) => t.status == TaskStatus.done && _today(t.updatedAt)).length;
    final merged = data.all<ChangeEntry>(Kind.change).where((ch) => ch.status == 'merged' && _today(ch.updatedAt)).length;
    final cost = runs.fold<double>(0, (s, r) => s + r.costUsd);
    final tokens = runs.fold<int>(0, (s, r) => s + r.tokensIn + r.tokensOut);
    Color colorOf(Run r) {
      if (r.status == RunStatus.failed) return c.danger;
      if (r.status == RunStatus.waiting) return c.warning;
      final p = data.get<Project>(Kind.project, r.data['projectId'] as String?);
      return p == null ? c.accent : hexColor(p.color);
    }

    return Box(
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Who worked on what · today', style: context.t(12, w: FontWeight.w700))),
              Text('${TimeOfDay.fromDateTime(start).format(context)} → now', style: context.t(10.5, color: c.text3)),
            ]),
            const SizedBox(height: 8),
            if (byAgent.isEmpty) Text('No runs yet today.', style: context.t(12, color: c.text2)),
            for (final MapEntry(key: id, value: rs) in byAgent.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                    width: 90,
                    child: Row(children: [
                      AgentTile(agent: data.get<AgentProfile>(Kind.agent, id), agentId: id, size: 12),
                      const SizedBox(width: 5),
                      Expanded(child: Text(data.get<AgentProfile>(Kind.agent, id)?.name ?? id, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11))),
                    ]),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, box) => SizedBox(
                      height: 12,
                      child: Stack(children: [
                        Positioned.fill(child: Container(decoration: BoxDecoration(color: c.inner.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(2)))),
                        for (final r in rs)
                          Positioned(
                            left: box.maxWidth * r.startedAt!.toLocal().difference(start).inSeconds / span,
                            width: (box.maxWidth * (r.endedAt ?? now).difference(r.startedAt!).inSeconds / span).clamp(3.0, box.maxWidth),
                            top: 1,
                            bottom: 1,
                            child: Tooltip(
                              message: '${data.get<Task>(Kind.task, r.taskId)?.title ?? ''} · ${r.status}',
                              child: Container(decoration: BoxDecoration(color: colorOf(r), borderRadius: BorderRadius.circular(2))),
                            ),
                          ),
                      ]),
                    )),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 230,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Plans', style: context.t(12, w: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final a in data.clis.where((a) => a.binaryPath != null)) _PlanMeter(agent: a),
            const SizedBox(height: 10),
            Row(children: [
              _Stat('$done', 'tasks done'),
              _Stat('$merged', 'merged'),
              _Stat(tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(0)}k' : '$tokens', 'tokens'),
              if (cost > 0) _Stat('\$${cost.toStringAsFixed(2)}', 'API spend'),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// A CLI's plan: limited until when, or how busy today.
class _PlanMeter extends ConsumerWidget {
  const _PlanMeter({required this.agent});
  final AgentProfile agent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final a = agent;
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());
    final onIt = data.agents.where((x) => x.runtimeId == a.id).map((x) => x.id).toSet();
    final active = data.all<Run>(Kind.run).where((r) => onIt.contains(r.agentId) && RunStatus.isActive(r.status)).length;
    final slots = data.agents.where((x) => onIt.contains(x.id)).fold<int>(0, (s, x) => s + x.slots);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(a.plan.isEmpty ? a.name : '${a.name} · ${a.plan}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11))),
          Text(limited ? 'limit · back ${TimeOfDay.fromDateTime(a.limitedUntil!.toLocal()).format(context)}' : '$active of $slots busy',
              style: context.t(11, color: limited ? c.warning : c.text2)),
        ]),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(minHeight: 5, value: limited ? 1 : (slots == 0 ? 0 : active / slots), backgroundColor: c.inner, color: limited ? c.warning : c.accentIcon),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.value, this.label);
  final String value, label;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(value, style: context.t(16, w: FontWeight.w700)),
      Text(label, style: context.t(10.5, color: context.c.text3)),
    ]),
  );
}

/// Column names for the one-line board summary.
const _short = {
  TaskStatus.backlog: 'backlog',
  TaskStatus.queued: 'ready',
  TaskStatus.running: 'in progress',
  TaskStatus.review: 'in review',
  TaskStatus.done: 'done',
};

bool _today(DateTime? t) {
  if (t == null) return false;
  final l = t.toLocal(), n = DateTime.now();
  return l.year == n.year && l.month == n.month && l.day == n.day;
}

String _date(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = d.toLocal();
  return '${months[l.month - 1]} ${l.day}';
}

/// A product's goal and milestone (design P01's card header).
Future<void> showGoalDialog(BuildContext context, WidgetRef ref, Project p) async {
  final goal = TextEditingController(text: p.goal);
  final milestone = TextEditingController(text: p.milestone);
  var due = p.milestoneDue;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) => AlertDialog(
      title: Text('${p.name}: goal and milestone', style: context.t(14, w: FontWeight.w600)),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldInput(controller: goal, autofocus: true, hint: 'Goal, e.g. Checkout with refunds by Oct 30'),
          const SizedBox(height: 8),
          FieldInput(controller: milestone, hint: 'Milestone, e.g. Checkout v1'),
          const SizedBox(height: 8),
          Row(children: [
            Text(due == null ? 'No due date' : 'Due ${_date(due!)}', style: context.t(12, color: context.c.text2)),
            const Spacer(),
            Btn(due == null ? 'Set due date' : 'Change', small: true, onTap: () async {
              final d = await showDatePicker(context: context, firstDate: DateTime.now().subtract(const Duration(days: 30)), lastDate: DateTime.now().add(const Duration(days: 730)), initialDate: due ?? DateTime.now().add(const Duration(days: 14)));
              if (d != null) setState(() => due = d);
            }),
            if (due != null) IconBtn(LucideIcons.x, size: 12, onTap: () => setState(() => due = null)),
          ]),
          const SizedBox(height: 6),
          Text('New tasks count towards the milestone unless you untick it on the task.', style: context.t(11, color: context.c.text3)),
        ]),
      ),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(context)),
        Btn('Save', kind: BtnKind.primary, onTap: () async {
          await ref.read(clientProvider).call(M.projectsUpdate, {
            'id': p.id,
            'fields': {'goal': goal.text.trim(), 'milestone': milestone.text.trim(), 'milestoneDue': due?.toUtc().toIso8601String()},
          });
          if (context.mounted) Navigator.pop(context);
        }),
      ],
    )),
  );
}
