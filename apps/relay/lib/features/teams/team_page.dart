import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/split.dart';
import '../../ui/widgets.dart';
import '../agents/model_picker.dart';
import '../ask/ask_palette.dart';

/// A team of agents (design P02): how work flows between them, who they
/// are, and an inspector to change one: the CLI it runs on, its model and
/// effort, its responsibilities and what it may do.
class TeamPage extends ConsumerWidget {
  const TeamPage({super.key, required this.teamId, this.agentId});
  final String teamId;
  final String? agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final team = data.get<Team>(Kind.team, teamId);
    if (team == null) return Center(child: Text('This team was deleted.', style: context.t(13, color: c.text2)));
    final members = [for (final id in team.members) ?data.get<AgentProfile>(Kind.agent, id)];
    final selected = members.where((a) => a.id == agentId).firstOrNull ?? members.firstOrNull;
    final projects = [for (final id in team.projectIds) ?data.get<Project>(Kind.project, id)];
    final client = ref.read(clientProvider);

    return Column(children: [
      Toolbar(
        title: team.name,
        subtitle: '${members.length} agent${members.length == 1 ? '' : 's'}'
            '${projects.isEmpty ? '' : ' · works on ${projects.map((p) => p.name).join(', ')}'}'
            ' · ${team.planApproval ? 'plans wait for your OK' : 'plans start on their own'}',
        actions: [
          Btn('Add agent', icon: LucideIcons.plus, kind: BtnKind.primary, onTap: () => showNewAgentDialog(context, ref, team)),
          Builder(builder: (context) => IconBtn(LucideIcons.ellipsis, onTap: () async {
            final box = context.findRenderObject() as RenderBox;
            final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
              ('approval', team.planApproval ? 'Let plans start on their own' : 'Plans wait for my OK', LucideIcons.shieldCheck),
              ('delete', 'Delete team and its agents', LucideIcons.trash2),
            ]);
            if (v == 'approval') await client.call(M.teamsUpdate, {'id': team.id, 'fields': {'planApproval': !team.planApproval}});
            if (v == 'delete' && context.mounted && await _confirm(context, 'Delete ${team.name}?', 'Its ${members.length} agents go too. Tasks stay, unassigned.')) {
              await client.call(M.teamsDelete, {'id': team.id});
              ref.read(navProvider.notifier).page(AppPage.agents);
            }
          })),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: ResizableSplit(
          id: 'team.inspector',
          sized: SplitSide.second,
          initial: 420,
          min: 340,
          keepOther: 420,
          first: ListView(padding: const EdgeInsets.all(16), children: [
            _Workflow(team: team, members: members),
            const SizedBox(height: 14),
            _Members(team: team, members: members, selected: selected?.id),
            const SizedBox(height: 14),
            _Projects(team: team),
          ]),
          second: selected == null
              ? Center(child: Btn('Add an agent', icon: LucideIcons.plus, onTap: () => showNewAgentDialog(context, ref, team)))
              : _Inspector(key: ValueKey(selected.id), agent: selected, team: team),
        ),
      ),
    ]);
  }
}

/// You → PM → devs → QA → you, from the team's handoffs.
class _Workflow extends StatelessWidget {
  const _Workflow({required this.team, required this.members});
  final Team team;
  final List<AgentProfile> members;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    // Columns by distance from "you", following handoffs (not back to you).
    final level = <String, int>{'you': 0};
    for (var pass = 0; pass < members.length + 1; pass++) {
      for (final e in team.edges) {
        final from = '${e['from']}', to = '${e['to']}';
        if (to == 'you' || !level.containsKey(from)) continue;
        final l = level[from]! + 1;
        if ((level[to] ?? -1) < l && l <= members.length) level[to] = l;
      }
    }
    final columns = <int, List<AgentProfile>>{};
    for (final a in members) {
      (columns[level[a.id] ?? 1] ??= []).add(a);
    }
    final backToYou = team.edges.any((e) => e['to'] == 'you');
    Widget node(String title, String detail, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6), border: Border.all(color: color)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: context.t(11.5, w: FontWeight.w600)),
        if (detail.isNotEmpty) Text(detail, style: context.t(10.5, color: c.text2)),
      ]),
    );
    final arrow = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(LucideIcons.arrowRight, size: 14, color: c.text3));
    final keys = columns.keys.toList()..sort();
    return Box(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('How work flows', style: context.t(12, w: FontWeight.w700))),
          Text('Each arrow is a handoff Relay makes for you', style: context.t(11, color: c.text3)),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            node('You', 'goal or request', c.text3),
            for (final k in keys) ...[
              arrow,
              Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final a in columns[k]!) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: node('${a.name} · ${a.role.isEmpty ? 'agent' : a.role}', '', hexColor(a.color))),
              ]),
            ],
            if (backToYou) ...[arrow, node('You review', 'approve and merge', c.warning)],
          ]),
        ),
      ]),
    );
  }
}

class _Members extends ConsumerWidget {
  const _Members({required this.team, required this.members, required this.selected});
  final Team team;
  final List<AgentProfile> members;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    Widget head(String t, double? w) => w == null ? Expanded(child: Text(t, style: context.label)) : SizedBox(width: w, child: Text(t, style: context.label));
    return Box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(children: [head('AGENT', 190), head('RUNS ON', 110), head('MODEL · EFFORT', 150), head('SLOTS', 60), head('NOW', null)]),
        ),
        const Hairline(),
        if (members.isEmpty)
          Padding(padding: const EdgeInsets.all(16), child: Text('No agents yet. Add one, or start a team from a template.', style: context.t(12, color: c.text2))),
        for (final a in members) _MemberRow(agent: a, team: team, selected: a.id == selected, data: data),
      ]),
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({required this.agent, required this.team, required this.selected, required this.data});
  final AgentProfile agent;
  final Team team;
  final bool selected;
  final DataSnapshot data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final a = agent;
    final runs = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).toList();
    final run = runs.firstOrNull;
    final task = run == null ? null : data.get<Task>(Kind.task, run.taskId);
    final waiting = data.tasksOf(null).where((t) => t.assignee == a.id && (t.data['attention'] == 'question' || t.data['attention'] == 'permission')).firstOrNull;
    final next = data.tasksOf(null).where((t) => t.assignee == a.id && t.status == TaskStatus.queued).firstOrNull;
    final cli = data.get<AgentProfile>(Kind.agent, a.runtimeId);
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());
    final fg = selected ? Colors.white : c.text;
    final fg2 = selected ? Colors.white70 : c.text2;
    final (Widget icon, String now, Color nowColor) = limited
        ? (Icon(LucideIcons.clock, size: 12, color: c.warning), 'Limit reached', c.warning)
        : waiting != null
            ? (Icon(LucideIcons.hand, size: 12, color: c.warning), 'Waiting on you · ${data.keyOf(waiting)}', c.warning)
            : task != null
                ? (Dot(c.success, size: 6), '${data.keyOf(task)} ${task.title}', fg)
                : (Icon(LucideIcons.clock, size: 12, color: fg2), next == null ? 'Idle' : 'Next: ${data.keyOf(next)}', fg2);
    return Hoverable(
      radius: 0,
      selected: selected,
      onTap: () => ref.read(navProvider.notifier).team(team.id, agentId: a.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(children: [
          SizedBox(
            width: 190,
            child: Row(children: [
              AgentTile(agent: a, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12.5, w: FontWeight.w600, color: fg)),
                  Text(a.role.isEmpty ? 'agent' : a.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: fg2)),
                ]),
              ),
            ]),
          ),
          SizedBox(width: 110, child: Text(cli?.name ?? a.runtimeId, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: a.binaryPath == null ? c.danger : fg))),
          SizedBox(
            width: 150,
            child: Wrap(spacing: 4, children: [
              Pill(modelLabel(a, a.model), fg: selected ? Colors.white : c.purple, bg: selected ? Colors.white24 : c.purpleWash),
              if (a.effort != null) Pill(a.effort!, fg: selected ? Colors.white : null, bg: selected ? Colors.white24 : null),
            ]),
          ),
          SizedBox(width: 60, child: Text('${runs.length} / ${a.slots}', style: context.t(12, color: fg))),
          icon,
          const SizedBox(width: 6),
          Expanded(child: Text(now, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11.5, color: selected ? Colors.white : nowColor))),
        ]),
      ),
    );
  }
}

/// Which projects the team works on.
class _Projects extends ConsumerWidget {
  const _Projects({required this.team});
  final Team team;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final client = ref.read(clientProvider);
    return Box(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Works on', style: context.t(12, w: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in data.projects)
            _Toggle(
              label: p.name,
              on: team.projectIds.contains(p.id),
              color: hexColor(p.color),
              onTap: () => client.call(M.teamsUpdate, {
                'id': team.id,
                'fields': {'projectIds': team.projectIds.contains(p.id) ? [...team.projectIds.where((x) => x != p.id)] : [...team.projectIds, p.id]},
              }),
            ),
        ]),
        const SizedBox(height: 8),
        Text('Its agents show on these projects\' boards and in Mission control.', style: context.t(11, color: c.text3)),
      ]),
    );
  }
}

/// Edit one agent (design P02's right column).
class _Inspector extends ConsumerStatefulWidget {
  const _Inspector({super.key, required this.agent, required this.team});
  final AgentProfile agent;
  final Team team;
  @override
  ConsumerState<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends ConsumerState<_Inspector> {
  late final name = TextEditingController(text: widget.agent.name);
  late final role = TextEditingController(text: widget.agent.role);
  late final duties = TextEditingController(text: widget.agent.responsibilities);
  final _nameFocus = FocusNode(), _roleFocus = FocusNode(), _dutiesFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Text saves when you leave the field.
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus && name.text.trim().isNotEmpty && name.text.trim() != widget.agent.name) _update({'name': name.text.trim(), 'letter': name.text.trim()[0].toUpperCase()});
    });
    _roleFocus.addListener(() {
      if (!_roleFocus.hasFocus && role.text.trim() != widget.agent.role) _update({'role': role.text.trim()});
    });
    _dutiesFocus.addListener(() {
      if (!_dutiesFocus.hasFocus && duties.text.trim() != widget.agent.responsibilities) _update({'responsibilities': duties.text.trim()});
    });
  }

  @override
  void dispose() {
    for (final f in [_nameFocus, _roleFocus, _dutiesFocus]) {
      f.dispose();
    }
    name.dispose();
    role.dispose();
    duties.dispose();
    super.dispose();
  }

  Future<void> _update(Map<String, Object?> fields) => ref.read(clientProvider).call(M.agentsUpdate, {'id': widget.agent.id, 'fields': fields});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final a = data.get<AgentProfile>(Kind.agent, widget.agent.id) ?? widget.agent;
    final clis = data.clis.where((x) => x.binaryPath != null).toList();
    Widget label(String t) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(t, style: context.t(11, w: FontWeight.w600, color: c.text2)));

    return Container(
      color: c.bar,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          AgentTile(agent: a, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              FieldInput(controller: name, focusNode: _nameFocus, size: 14, hint: 'Name', onSubmitted: (_) => _nameFocus.unfocus()),
              const SizedBox(height: 4),
              FieldInput(controller: role, focusNode: _roleFocus, size: 12, hint: 'Role, e.g. Sr backend dev', onSubmitted: (_) => _roleFocus.unfocus()),
            ]),
          ),
          const SizedBox(width: 8),
          Btn('Ask', icon: LucideIcons.sparkles, small: true, onTap: () => showAskPalette(context, ref, agentId: a.id)),
        ]),
        const SizedBox(height: 16),
        label('Runs on'),
        if (clis.isEmpty)
          Text('No agent CLI found on this computer yet.', style: context.t(12, color: c.danger))
        else
          Align(
            alignment: Alignment.centerLeft,
            child: Segmented<String>(
              small: true,
              options: [for (final x in clis) (x.id, x.name)],
              value: clis.any((x) => x.id == a.runtimeId) ? a.runtimeId : clis.first.id,
              // Another CLI takes other model names and efforts.
              onChanged: (v) => _update({'runtime': v, 'model': null, 'effort': null}),
            ),
          ),
        const SizedBox(height: 14),
        label('Model and effort'),
        ModelEffortPicker(
          agent: a,
          model: a.model,
          effort: a.effort,
          small: false,
          inherited: a.model == null && a.effort == null ? 'the CLI\'s own' : null,
          onChanged: (m, e) => _update({'model': m, 'effort': e}),
        ),
        const SizedBox(height: 14),
        label('Responsibilities (added to every run)'),
        FieldInput(controller: duties, focusNode: _dutiesFocus, minLines: 5, maxLines: 12, size: 12, hint: 'What this agent owns, how it hands work on, when it asks you'),
        const SizedBox(height: 14),
        label('Allowed to'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final cap in AgentCap.all)
            _Toggle(
              label: AgentCap.label(cap),
              on: a.can(cap),
              onTap: () => _update({'caps': a.can(cap) ? [...a.caps.where((x) => x != cap)] : [...a.caps, cap]}),
            ),
        ]),
        const SizedBox(height: 6),
        Text(a.can(AgentCap.editCode) ? 'Without Run shell, Claude Code can\'t use Bash.' : 'Without Edit code, runs are read-only.', style: context.t(11, color: c.text3)),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: label('Runs at once')),
          IconBtn(LucideIcons.minus, size: 12, onTap: a.slots > 1 ? () => _update({'slots': a.slots - 1}) : null),
          SizedBox(width: 28, child: Text('${a.slots}', textAlign: TextAlign.center, style: context.t(12, w: FontWeight.w600))),
          IconBtn(LucideIcons.plus, size: 12, onTap: () => _update({'slots': a.slots + 1})),
        ]),
        Row(children: [
          Expanded(child: label('Takes new work')),
          Transform.scale(scale: 0.7, child: Switch(value: a.enabled, onChanged: (v) => _update({'enabled': v}), activeTrackColor: c.accent)),
        ]),
        const SizedBox(height: 10),
        if (a.isRole)
          Align(
            alignment: Alignment.centerLeft,
            child: Btn('Delete ${a.name}', kind: BtnKind.danger, small: true, icon: LucideIcons.trash2, onTap: () async {
              if (!await _confirm(context, 'Delete ${a.name}?', 'Its tasks stay, unassigned from it.')) return;
              await ref.read(clientProvider).call(M.agentsDelete, {'id': a.id});
              ref.read(navProvider.notifier).team(widget.team.id);
            }),
          ),
        const SizedBox(height: 6),
        Text('Changes apply to the next run; running work keeps its settings.', style: context.t(11, color: c.text3)),
      ]),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.on, required this.onTap, this.color});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final col = color ?? c.accentIcon;
    return Pressable(
      onTap: onTap,
      builder: (context, hover, focus) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: on ? col.withValues(alpha: 0.18) : c.inner, borderRadius: BorderRadius.circular(5)),
        foregroundDecoration: focusRing(context, focus, 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(on ? LucideIcons.check : LucideIcons.x, size: 11, color: on ? col : c.text3),
          const SizedBox(width: 5),
          Text(label, style: context.t(11.5, color: on ? c.text : c.text2)),
        ]),
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: context.t(14, w: FontWeight.w600)),
        content: Text(body, style: context.t(12, color: context.c.text2)),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(context, false)),
          Btn('Delete', kind: BtnKind.danger, onTap: () => Navigator.pop(context, true)),
        ],
      ),
    ) ??
    false;

/// A new role agent in [team] on one of this computer's CLIs.
Future<void> showNewAgentDialog(BuildContext context, WidgetRef ref, Team team) async {
  final data = ref.read(dataProvider);
  final clis = data.clis.where((x) => x.binaryPath != null).toList();
  final name = TextEditingController();
  final role = TextEditingController();
  var runtime = clis.firstOrNull?.id;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) => AlertDialog(
      title: Text('New agent in ${team.name}', style: context.t(14, w: FontWeight.w600)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          FieldInput(controller: name, autofocus: true, hint: 'Name, e.g. Dana'),
          const SizedBox(height: 8),
          FieldInput(controller: role, hint: 'Role, e.g. Sr mobile dev'),
          const SizedBox(height: 10),
          if (clis.isEmpty)
            Text('No agent CLI found on this computer yet.', style: context.t(12, color: context.c.danger))
          else
            Segmented<String>(small: true, options: [for (final x in clis) (x.id, x.name)], value: runtime!, onChanged: (v) => setState(() => runtime = v)),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: context.t(12, color: context.c.danger))),
        ]),
      ),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(context)),
        Btn('Add', kind: BtnKind.primary, onTap: runtime == null ? null : () async {
          try {
            final a = await ref.read(clientProvider).map(M.agentsCreate, {
              'fields': {'name': name.text.trim(), 'role': role.text.trim(), 'runtime': runtime, 'teamId': team.id, 'color': _colors[team.members.length % _colors.length]},
            });
            if (context.mounted) Navigator.pop(context);
            ref.read(navProvider.notifier).team(team.id, agentId: a['id'] as String);
          } on RpcError catch (e) {
            setState(() => error = e.message);
          }
        }),
      ],
    )),
  );
}

const _colors = ['#8944AB', '#0A64D8', '#C77700', '#1F9D55', '#D49BF5', '#FF6961'];

/// A new team, empty or from a template (Product squad, Solo builder, Bug crew).
Future<void> showNewTeamDialog(BuildContext context, WidgetRef ref) async {
  final client = ref.read(clientProvider);
  final data = ref.read(dataProvider);
  final templates = await client.list(M.teamsTemplates);
  if (!context.mounted) return;
  final name = TextEditingController();
  String? template = templates.firstOrNull?['id'] as String?;
  final projectIds = <String>{?ref.read(navProvider).projectId};
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final c = context.c;
      return AlertDialog(
        title: Text('New agent team', style: context.t(14, w: FontWeight.w600)),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FieldInput(controller: name, autofocus: true, hint: 'Name, e.g. Shopfront squad'),
            const SizedBox(height: 12),
            Text('Start from', style: context.t(11, w: FontWeight.w600, color: c.text2)),
            const SizedBox(height: 6),
            for (final t in [...templates, {'id': null, 'name': 'Empty team', 'summary': 'add agents yourself'}])
              Hoverable(
                selected: template == t['id'],
                onTap: () => setState(() => template = t['id'] as String?),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    Text('${t['name']}', style: context.t(12.5, w: FontWeight.w600, color: template == t['id'] ? Colors.white : c.text)),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${t['summary']}', style: context.t(11.5, color: template == t['id'] ? Colors.white70 : c.text2))),
                  ]),
                ),
              ),
            const SizedBox(height: 12),
            Text('Works on', style: context.t(11, w: FontWeight.w600, color: c.text2)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in data.projects)
                _Toggle(label: p.name, on: projectIds.contains(p.id), color: hexColor(p.color), onTap: () => setState(() => projectIds.contains(p.id) ? projectIds.remove(p.id) : projectIds.add(p.id))),
            ]),
            const SizedBox(height: 10),
            Text('Each role gets the best CLI you have: Opus for the PM, Sonnet for devs, Haiku for QA. Change any of it after.',
                style: context.t(11, color: c.text3)),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: context.t(12, color: c.danger))),
          ]),
        ),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(context)),
          Btn('Create team', kind: BtnKind.primary, onTap: () async {
            try {
              final t = await client.map(M.teamsCreate, {'name': name.text.trim(), 'template': ?template, 'projectIds': projectIds.toList()});
              if (context.mounted) Navigator.pop(context);
              ref.read(navProvider.notifier).team(t['id'] as String);
            } on RpcError catch (e) {
              setState(() => error = e.message);
            }
          }),
        ],
      );
    }),
  );
}
