import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

Future<void> showNewTaskSheet(BuildContext context, WidgetRef ref, {String? status}) async {
  final data = ref.read(dataProvider);
  if (data.projects.isEmpty) return;
  final nav = ref.read(navProvider);
  final projectId = nav.projectId ?? data.projects.first.id;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => Align(
      alignment: Alignment.topCenter,
      child: Padding(padding: const EdgeInsets.only(top: 52), child: _NewTask(projectId: projectId, initialStatus: status, repoFilter: nav.repoFilter)),
    ),
  );
}

class _Step {
  _Step(this.name, this.kind, this.assignee, this.note);
  String name;
  String kind; // agent | person
  String assignee;
  String note;
}

class _NewTask extends ConsumerStatefulWidget {
  const _NewTask({required this.projectId, this.initialStatus, this.repoFilter});
  final String projectId;
  final String? initialStatus;
  final String? repoFilter;
  @override
  ConsumerState<_NewTask> createState() => _NewTaskState();
}

class _NewTaskState extends ConsumerState<_NewTask> {
  late String projectId = widget.projectId;
  final title = TextEditingController();
  final brief = TextEditingController();
  final tags = TextEditingController();
  late Set<String> repoIds = {?widget.repoFilter};
  List<Map<String, Object?>> suggestions = [];
  String assignee = 'auto'; // auto | agent id | me
  bool pipeline = false;
  late List<_Step> steps;
  String start = 'slot'; // now | slot | tonight | backlog
  String? error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final agents = ref.read(dataProvider).agents.where((a) => a.binaryPath != null).toList();
    String pick(int i) => agents.isEmpty ? 'auto' : agents[i % agents.length].id;
    steps = [
      _Step('Plan', 'agent', pick(0), 'Write PLAN.md, then wait for an OK'),
      _Step('Build', 'agent', pick(1), 'Implement the plan'),
      _Step('Test', 'agent', pick(2), 'Add tests, run them until green'),
      _Step('Review', 'person', ref.read(clientProvider).hello['userName'] as String? ?? 'You', 'A person approves the merge'),
    ];
    if (widget.initialStatus == TaskStatus.backlog) start = 'backlog';
    title.addListener(_suggest);
    brief.addListener(_suggest);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    title.dispose();
    brief.dispose();
    tags.dispose();
    super.dispose();
  }

  void _suggest() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final text = '${title.text} ${brief.text}'.trim();
      if (text.length < 6) return;
      final s = await ref.read(clientProvider).list(M.tasksSuggestRepos, {'projectId': projectId, 'text': text, 'repoIds': repoIds.toList()});
      if (mounted) setState(() => suggestions = s);
    });
  }

  Future<void> create() async {
    if (title.text.trim().isEmpty) return setState(() => error = 'Give the task a title.');
    final client = ref.read(clientProvider);
    final userName = client.hello['userName'] as String? ?? 'You';
    final now = DateTime.now();
    final tonight = DateTime(now.year, now.month, now.day + 1, 1);
    final fields = <String, Object?>{
      'title': title.text.trim(),
      'brief': brief.text.trim(),
      'repoIds': repoIds.toList(),
      'tags': tags.text.split(RegExp(r'[,\s]+')).map((s) => s.replaceFirst('#', '')).where((s) => s.isNotEmpty).toList(),
      'status': start == 'backlog' ? TaskStatus.backlog : TaskStatus.queued,
      'startAt': switch (start) { 'tonight' => tonight.toUtc().toIso8601String(), 'now' => 'now', _ => 'slot' },
      if (pipeline)
        'pipeline': [for (final s in steps) {'name': s.name, 'assigneeKind': s.kind, 'assignee': s.assignee, 'note': s.note, 'status': 'pending'}]
      else if (assignee == 'me')
        ...{'assigneeKind': 'person', 'assignee': userName}
      else
        ...{'assigneeKind': 'agent', 'assignee': assignee},
    };
    try {
      final t = await client.map(M.tasksCreate, {'projectId': projectId, 'fields': fields});
      if (start == 'now' && !pipeline && assignee != 'me') {
        try {
          await client.call(M.runsStart, {'taskId': t['id'], if (assignee != 'auto') 'agentId': assignee});
        } on RpcError catch (_) {}
      }
      if (mounted) Navigator.pop(context);
    } on RpcError catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final project = data.get<Project>(Kind.project, projectId)!;
    final repos = data.reposOf(projectId);
    final agents = data.agents.where((a) => a.binaryPath != null).toList();
    Widget row(String label, Widget child, {bool top = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: top ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
        SizedBox(width: 90, child: Padding(padding: EdgeInsets.only(top: top ? 6 : 0), child: Text(label, textAlign: TextAlign.right, style: context.t(12, color: c.text2)))),
        const SizedBox(width: 12),
        Expanded(child: child),
      ]),
    );

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 680,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height - 90),
        decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.fieldStroke), boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 40, offset: Offset(0, 16))]),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('New task', style: context.t(15, w: FontWeight.w700)),
              const Spacer(),
              Builder(builder: (context) => GestureDetector(
                onTap: () async {
                  final box = context.findRenderObject() as RenderBox;
                  final p = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [for (final p in data.projects) (p.id, p.name, null)]);
                  if (p != null) {
                    setState(() {
                      projectId = p;
                      repoIds = {};
                      suggestions = [];
                    });
                  }
                },
                child: Row(children: [
                  Text('${project.name} · ⌘N', style: context.t(11, color: c.text3)),
                  Icon(LucideIcons.chevronDown, size: 11, color: c.text3),
                ]),
              )),
            ]),
            const SizedBox(height: 16),
            row('Title', FieldInput(controller: title, autofocus: true, hint: 'Show cooking time in the recipe list')),
            if (repos.length > 1)
              row('Repos', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final r in repos)
                    GestureDetector(
                      onTap: () {
                        setState(() => repoIds.contains(r.id) ? repoIds.remove(r.id) : repoIds.add(r.id));
                        _suggest();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: repoIds.contains(r.id) ? hexColor(r.color).withValues(alpha: 0.2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: repoIds.contains(r.id) ? hexColor(r.color) : c.fieldStroke),
                        ),
                        child: Text(r.name, style: context.t(12, color: repoIds.contains(r.id) ? hexColor(r.color) : c.text2)),
                      ),
                    ),
                ]),
                for (final s in suggestions.where((s) => !repoIds.contains(s['repoId'])))
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: c.purpleWash, borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      Icon(LucideIcons.sparkles, size: 13, color: c.purple),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Probably touches ${s['name']}: ${s['reason']}.', style: context.t(12))),
                      Btn('Add ${s['name']}', small: true, onTap: () => setState(() => repoIds.add(s['repoId'] as String))),
                    ]),
                  ),
              ]), top: true),
            row('Brief', FieldInput(controller: brief, minLines: 3, maxLines: 8, hint: 'What should be done, constraints, where to look'), top: true),
            row('Tags', FieldInput(controller: tags, hint: '#tests, #ui (routing rules can use tags)', size: 12)),
            const Hairline(),
            const SizedBox(height: 12),
            row('Who', Row(children: [
              Segmented<bool>(small: true, options: const [(false, 'One assignee'), (true, 'Pipeline')], value: pipeline, onChanged: (v) => setState(() => pipeline = v)),
              const SizedBox(width: 10),
              if (!pipeline)
                Builder(builder: (context) => GestureDetector(
                  onTap: () async {
                    final box = context.findRenderObject() as RenderBox;
                    final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
                      ('auto', 'Any agent (routing rules)', LucideIcons.workflow),
                      for (final a in agents) (a.id, a.name, LucideIcons.bot),
                      ('me', 'Me', LucideIcons.user),
                    ]);
                    if (v != null) setState(() => assignee = v);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: c.control, borderRadius: BorderRadius.circular(5)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (agents.any((a) => a.id == assignee)) ...[AgentTile(agent: agents.firstWhere((a) => a.id == assignee), size: 14), const SizedBox(width: 6)],
                      Text(assignee == 'auto' ? 'Any agent' : (assignee == 'me' ? 'Me' : agents.firstWhere((a) => a.id == assignee).name), style: context.t(12)),
                      const SizedBox(width: 4),
                      Icon(LucideIcons.chevronDown, size: 11, color: c.text2),
                    ]),
                  ),
                )),
            ])),
            if (pipeline)
              row('Steps', Column(children: [
                for (var i = 0; i < steps.length; i++) _stepRow(context, i, agents),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Btn('Add step', kind: BtnKind.plain, icon: LucideIcons.plus, small: true, onTap: () => setState(() => steps.add(_Step('Step ${steps.length + 1}', 'agent', agents.isEmpty ? 'auto' : agents.first.id, '')))),
                ),
              ]), top: true),
            row('Start', Wrap(spacing: 14, runSpacing: 6, children: [
              for (final (v, label) in const [('now', 'Now'), ('slot', 'When a slot frees up'), ('tonight', 'Tonight at 01:00'), ('backlog', 'Keep in Backlog')])
                GestureDetector(
                  onTap: () => setState(() => start = v),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(start == v ? LucideIcons.circleDot : LucideIcons.circle, size: 14, color: start == v ? c.accentIcon : c.text3),
                    const SizedBox(width: 6),
                    Text(label, style: context.t(13)),
                  ]),
                ),
            ])),
            if (error != null) Text(error!, style: context.t(12, color: c.danger)),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Btn('Cancel', onTap: () => Navigator.pop(context)),
              const SizedBox(width: 8),
              Btn(start == 'backlog' ? 'Create' : 'Create and queue', kind: BtnKind.primary, onTap: create),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _stepRow(BuildContext context, int i, List<AgentProfile> agents) {
    final c = context.c;
    final s = steps[i];
    final userName = ref.read(clientProvider).hello['userName'] as String? ?? 'You';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: s.kind == 'person' ? c.warning : c.accent, shape: BoxShape.circle),
          child: Text('${i + 1}', style: context.t(11, w: FontWeight.w700, color: Colors.white)),
        ),
        const SizedBox(width: 10),
        SizedBox(width: 90, child: FieldInput(controller: TextEditingController(text: s.name), size: 12, onChanged: (v) => s.name = v)),
        const SizedBox(width: 8),
        Expanded(child: FieldInput(controller: TextEditingController(text: s.note), size: 12, hint: 'What this step does', onChanged: (v) => s.note = v)),
        const SizedBox(width: 8),
        Builder(builder: (context) => GestureDetector(
          onTap: () async {
            final box = context.findRenderObject() as RenderBox;
            final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
              for (final a in agents) ('agent:${a.id}', a.name, LucideIcons.bot),
              ('person', 'A person ($userName)', LucideIcons.user),
            ]);
            if (v == null) return;
            setState(() {
              if (v == 'person') {
                s.kind = 'person';
                s.assignee = userName;
              } else {
                s.kind = 'agent';
                s.assignee = v.substring(6);
              }
            });
          },
          child: Container(
            width: 150,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(color: c.control, borderRadius: BorderRadius.circular(5)),
            child: Row(children: [
              s.kind == 'agent' ? AgentTile(agent: agents.where((a) => a.id == s.assignee).firstOrNull, agentId: s.assignee, size: 14) : Avatar(s.assignee, size: 14, color: c.warning),
              const SizedBox(width: 6),
              Expanded(child: Text(s.kind == 'agent' ? (agents.where((a) => a.id == s.assignee).firstOrNull?.name ?? s.assignee) : s.assignee, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12))),
              Icon(LucideIcons.chevronDown, size: 11, color: c.text2),
            ]),
          ),
        )),
        IconBtn(LucideIcons.x, size: 12, onTap: steps.length > 1 ? () => setState(() => steps.removeAt(i)) : null),
      ]),
    );
  }
}
