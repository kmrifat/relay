import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../agents/model_picker.dart';
import '../channel/channel_page.dart' show ChannelAgent, channelAgents;

/// ⌘J (design P05): ask any agent from anywhere. The question goes to the
/// product's channel with the agent's model, effort and what to do, so
/// the answer (or the task it makes) is where the team can see it. Live
/// runs and open questions are a keystroke away too.
Future<void> showAskPalette(BuildContext context, WidgetRef ref, {String? agentId}) async {
  final data = ref.read(dataProvider);
  if (data.projects.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => Align(alignment: const Alignment(0, -0.55), child: _AskPalette(agentId: agentId)),
  );
}

/// One row of the palette: an agent to ask, or something to continue.
sealed class _Item {}

class _AgentItem extends _Item {
  _AgentItem(this.agent);
  final ChannelAgent agent;
}

class _SteerItem extends _Item {
  _SteerItem(this.run, this.task);
  final Run run;
  final Task task;
}

class _AnswerItem extends _Item {
  _AnswerItem(this.task);
  final Task task;
}

class _AskPalette extends ConsumerStatefulWidget {
  const _AskPalette({this.agentId});

  /// Starts with this agent chosen (the team page's Ask).
  final String? agentId;
  @override
  ConsumerState<_AskPalette> createState() => _AskPaletteState();
}

class _AskPaletteState extends ConsumerState<_AskPalette> {
  final text = TextEditingController();
  final focus = FocusNode();
  late String projectId;
  int sel = 0;
  String? model, effort;
  String mode = 'answer';
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final data = ref.read(dataProvider);
    final nav = ref.read(navProvider);
    projectId = nav.projectId != null && data.get<Project>(Kind.project, nav.projectId) != null ? nav.projectId! : data.projects.first.id;
    // A team's agent asks about the team's first project.
    final agent = data.get<AgentProfile>(Kind.agent, widget.agentId);
    final team = agent == null ? null : data.teamOf(agent);
    if (team != null && team.projectIds.isNotEmpty && !team.projectIds.contains(projectId)) projectId = team.projectIds.first;
    final i = _items(data).indexWhere((x) => x is _AgentItem && x.agent.id == widget.agentId);
    if (i >= 0) sel = i;
    text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  List<_Item> _items(DataSnapshot data) {
    final client = ref.read(clientProvider);
    final me = client.hello['deviceId'] as String? ?? '';
    final myName = client.hello['userName'] as String? ?? 'You';
    final tasks = data.tasksOf(projectId);
    return [
      for (final a in channelAgents(data, me, myName)) _AgentItem(a),
      for (final t in tasks)
        if (data.activeRun(t) case final r? when RunStatus.isActive(r.status) && r.data['canSteer'] != false) _SteerItem(r, t),
      for (final t in tasks.where((t) => t.data['attention'] == 'question')) _AnswerItem(t),
    ];
  }

  ChannelAgent? _agentOf(List<_Item> items) => switch (items.elementAtOrNull(sel)) { _AgentItem(:final agent) => agent, _ => null };

  void _move(int d, int count) => setState(() {
    sel = count == 0 ? 0 : (sel + d).clamp(0, count - 1);
    model = null;
    effort = null;
  });

  Future<void> _go(List<_Item> items, {bool open = false}) async {
    final item = items.elementAtOrNull(sel);
    final body = text.text.trim();
    if (item == null || busy) return;
    if (body.isEmpty) return setState(() => error = 'Type what you want to ask first.');
    final client = ref.read(clientProvider);
    final n = ref.read(navProvider.notifier);
    setState(() => busy = true);
    try {
      switch (item) {
        case _AgentItem(:final agent):
          final channel = Channel.idFor(projectId);
          await client.call(M.messagesPost, {
            'channelId': channel,
            'body': body,
            'agent': agent.id,
            'model': ?model,
            'effort': ?effort,
            'mode': mode,
          });
          if (open) n.channel(channel);
        case _SteerItem(:final run, :final task):
          await client.call(M.runsSteer, {'runId': run.id, 'text': body});
          if (open) n.openTask(task.id);
        case _AnswerItem(:final task):
          await client.call(M.commentsPost, {'taskId': task.id, 'body': body});
          if (open) n.openTask(task.id);
      }
      if (mounted) Navigator.pop(context);
    } on RpcError catch (e) {
      setState(() {
        error = e.message;
        busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final items = _items(data);
    if (sel >= items.length) sel = items.isEmpty ? 0 : items.length - 1;
    final target = _agentOf(items);
    final profile = target != null && target.mine ? data.get<AgentProfile>(Kind.agent, target.id) : null;
    final project = data.get<Project>(Kind.project, projectId)!;
    final agentCount = items.whereType<_AgentItem>().length;

    Widget row(int i, Widget leading, String title, String detail, {Color? detailColor, String? key}) => Hoverable(
      selected: i == sel,
      onTap: () => setState(() => sel = i),
      onDoubleTap: () => _go(items),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          leading,
          const SizedBox(width: 10),
          SizedBox(width: 170, child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12.5, w: i == sel ? FontWeight.w600 : FontWeight.w400, color: i == sel ? Colors.white : c.text))),
          Expanded(child: Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11.5, color: i == sel ? Colors.white70 : (detailColor ?? c.text2)))),
          if (key != null) Text(key, style: context.t(11, color: i == sel ? Colors.white70 : c.text3)),
        ]),
      ),
    );

    String agentDetail(ChannelAgent a) {
      final p = a.mine ? data.get<AgentProfile>(Kind.agent, a.id) : null;
      if (p == null) return "${a.owner}'s";
      final active = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).length;
      final defaults = [if (p.model != null) modelLabel(p, p.model), ?p.effort].join(' · ');
      return [if (defaults.isNotEmpty) defaults, active >= p.slots ? 'all slots busy' : '${p.slots - active} slot${p.slots - active == 1 ? '' : 's'} free'].join(' · ');
    }

    final rows = <Widget>[];
    var i = 0;
    for (final item in items) {
      if (i == 0 && item is _AgentItem) rows.add(_section(context, 'AGENTS · type to ask, ↑↓ to choose, 1–9 when empty'));
      if (item is! _AgentItem && (i == 0 || items[i - 1] is _AgentItem)) rows.add(_section(context, 'CONTINUE'));
      rows.add(switch (item) {
        _AgentItem(:final agent) => row(i, AgentTile(agent: AgentProfile({'color': agent.color, 'letter': agent.letter}), size: 20), agent.name, agentDetail(agent), key: i < 9 ? '${i + 1}' : null),
        _SteerItem(:final run, :final task) => row(i, Icon(LucideIcons.play, size: 16, color: c.success), 'Steer ${data.keyOf(task)}', '${data.get<AgentProfile>(Kind.agent, run.agentId)?.name ?? run.agentId} is working on ${task.title}'),
        _AnswerItem(:final task) => row(i, Icon(LucideIcons.hand, size: 16, color: c.warning), 'Answer ${data.keyOf(task)}', '${task.data['question'] ?? task.title}', detailColor: c.warning),
      });
      i++;
    }

    return Material(
      color: Colors.transparent,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1, items.length),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1, items.length),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _go(items, open: true),
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _go(items, open: true),
        },
        child: Container(
          width: 700,
          decoration: BoxDecoration(color: c.toolbar, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.fieldStroke), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 50, offset: Offset(0, 20))]),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Row(children: [
                Icon(LucideIcons.sparkles, size: 18, color: c.accentIcon),
                const SizedBox(width: 10),
                if (items.elementAtOrNull(sel) case _AgentItem(:final agent)) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(5)),
                    child: Text(agent.name, style: context.t(13, w: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: TextField(
                    controller: text,
                    focusNode: focus,
                    autofocus: true,
                    cursorOpacityAnimates: false,
                    style: context.t(15),
                    inputFormatters: [
                      // 1–9 in an empty box pick an agent instead of typing.
                      TextInputFormatter.withFunction((old, next) {
                        if (old.text.isEmpty && RegExp(r'^[1-9]$').hasMatch(next.text)) {
                          final n = int.parse(next.text) - 1;
                          if (n < agentCount) WidgetsBinding.instance.addPostFrameCallback((_) => setState(() => sel = n));
                          return old;
                        }
                        return next;
                      }),
                    ],
                    onSubmitted: (_) => _go(items),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: switch (items.elementAtOrNull(sel)) {
                        _SteerItem() => 'Tell the agent something while it works',
                        _AnswerItem() => 'Your answer',
                        _ => 'Ask or tell ${target?.name ?? 'an agent'} something',
                      },
                      hintStyle: context.t(15, color: c.text3),
                    ),
                  ),
                ),
                Text('↵', style: context.t(12, color: c.text3)),
              ]),
            ),
            if (target != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Builder(builder: (context) => Btn(project.name, small: true, icon: LucideIcons.folder, onTap: () async {
                    final box = context.findRenderObject() as RenderBox;
                    final p = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [for (final p in data.projects) (p.id, p.name, null)]);
                    if (p != null) setState(() => projectId = p);
                  })),
                  if (profile != null)
                    ModelEffortPicker(agent: profile, model: model, effort: effort, onChanged: (m, e) => setState(() {
                      model = m;
                      effort = e;
                    })),
                  Segmented<String>(
                    small: true,
                    options: const [('answer', 'Just answer'), ('task', 'Make a task'), ('plan', 'Plan')],
                    value: mode,
                    onChanged: (v) => setState(() => mode = v),
                  ),
                ]),
              ),
            const Hairline(),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(8), children: rows),
            ),
            const Hairline(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: c.bar,
              child: Row(children: [
                Expanded(
                  child: Text(error ?? '↑↓ choose · ↵ ask · ⌘↵ ask and open · Esc close',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: error == null ? c.text3 : c.danger)),
                ),
                const SizedBox(width: 12),
                Text('Answers go to #${data.channels.where((ch) => ch.id == Channel.idFor(projectId)).firstOrNull?.name ?? project.name}', style: context.t(11, color: c.text3)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label) =>
      Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 4), child: Text(label, style: context.label));
}
