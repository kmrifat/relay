import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

/// The agent fleet (design T03): CLIs on this Mac, usage, slots, routing.
class FleetPage extends ConsumerStatefulWidget {
  const FleetPage({super.key});
  @override
  ConsumerState<FleetPage> createState() => _FleetPageState();
}

class _FleetPageState extends ConsumerState<FleetPage> {
  Map<String, String> settings = {};
  bool detecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    final s = await client.map(M.settingsGet);
    // agents.list carries today's usage; fold it into the cache.
    await ref.read(dataProvider.notifier).reload(client);
    if (mounted) setState(() => settings = s.map((k, v) => MapEntry(k, '$v')));
  }

  Future<void> _set(String key, String value) async {
    final s = await ref.read(clientProvider).map(M.settingsSet, {'values': {key: value}});
    if (mounted) setState(() => settings = s.map((k, v) => MapEntry(k, '$v')));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final agents = data.agents;
    final installed = agents.where((a) => a.binaryPath != null).toList();
    final missing = agents.where((a) => a.binaryPath == null).toList();
    final active = data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).length;
    final client = ref.read(clientProvider);

    return Column(children: [
      Toolbar(
        title: 'Agents',
        subtitle: '${installed.length} on this Mac · $active running · ${installed.fold<int>(0, (s, a) => s + a.slots)} slots',
        actions: [
          Btn(detecting ? 'Looking…' : 'Find CLIs', icon: LucideIcons.refreshCw, onTap: detecting
              ? null
              : () async {
                  setState(() => detecting = true);
                  await client.call(M.agentsDetect);
                  await _load();
                  if (mounted) setState(() => detecting = false);
                }),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: Row(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text('On this Mac · uses the CLIs and plans you already have', style: context.label),
              const SizedBox(height: 12),
              LayoutBuilder(builder: (context, box) {
                final cols = box.maxWidth > 760 ? 2 : 1;
                final w = (box.maxWidth - (cols - 1) * 14) / cols;
                return Wrap(spacing: 14, runSpacing: 14, children: [for (final a in installed) SizedBox(width: w, child: _AgentCard(agent: a))]);
              }),
              if (missing.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Known but not found on PATH', style: context.label),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final a in missing) Pill('${a.name}${a.data['version'] == null ? '' : ' (was ${a.data['version']})'}', radius: 5),
                ]),
              ],
              const SizedBox(height: 16),
              Text('Relay looks for claude, codex, gemini, opencode and aider on your login shell\'s PATH. '
                  'Agents sign in with their own accounts; Relay never sees those credentials.',
                  style: context.t(11, color: c.text3)),
            ]),
          ),
          Container(width: 1, color: c.separator),
          Container(
            width: 340,
            color: c.bar,
            padding: const EdgeInsets.all(20),
            child: ListView(children: [
              Text('Routing rules', style: context.t(13, w: FontWeight.w700)),
              Text('Who picks up a task when nobody is named', style: context.t(11, color: c.text2)),
              const SizedBox(height: 12),
              _Rules(agents: installed),
              const SizedBox(height: 20),
              Text('Guardrails', style: context.t(13, w: FontWeight.w700)),
              const SizedBox(height: 10),
              Box(
                child: Column(children: [
                  _stepper(context, 'Runs at once on this Mac', int.tryParse(settings['maxConcurrent'] ?? '4') ?? 4, (v) => _set('maxConcurrent', '$v')),
                  const Hairline(),
                  _toggle(context, 'Ask before shell & edits', settings['askBeforeShell'] != 'false', (v) => _set('askBeforeShell', '$v')),
                  const Hairline(),
                  _toggle(context, 'Agents can message each other', settings['agentMessages'] != 'false', (v) => _set('agentMessages', '$v')),
                  const Hairline(),
                  _toggle(context, 'Keep running when closed', settings['keepRunningWhenClosed'] != 'false', (v) => _set('keepRunningWhenClosed', '$v')),
                ]),
              ),
              const SizedBox(height: 10),
              Text('Each run gets its own git worktree, so agents never edit your checkout or each other\'s files.', style: context.t(11, color: c.text3)),
            ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _toggle(BuildContext context, String label, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(children: [
      Expanded(child: Text(label, style: context.t(12))),
      Transform.scale(scale: 0.7, child: Switch(value: value, onChanged: onChanged, activeTrackColor: context.c.accent)),
    ]),
  );

  Widget _stepper(BuildContext context, String label, int value, ValueChanged<int> onChanged) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(children: [
      Expanded(child: Text(label, style: context.t(12))),
      IconBtn(LucideIcons.minus, size: 12, onTap: value > 1 ? () => onChanged(value - 1) : null),
      SizedBox(width: 24, child: Text('$value', textAlign: TextAlign.center, style: context.t(12, w: FontWeight.w600))),
      IconBtn(LucideIcons.plus, size: 12, onTap: () => onChanged(value + 1)),
    ]),
  );
}

class _AgentCard extends ConsumerWidget {
  const _AgentCard({required this.agent});
  final AgentProfile agent;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final a = agent;
    final runs = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).toList();
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());
    final today = (a.data['today'] as Map?)?.cast<String, Object?>() ?? const {};
    final tokens = ((today['tokensIn'] as num?) ?? 0) + ((today['tokensOut'] as num?) ?? 0);
    final cost = (today['costUsd'] as num?)?.toDouble() ?? 0;
    final client = ref.read(clientProvider);
    Future<void> update(Map<String, Object?> f) => client.call(M.agentsUpdate, {'id': a.id, 'fields': f});

    return Box(
      border: limited ? c.warning : null,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          AgentTile(agent: a, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, style: context.t(14, w: FontWeight.w700)),
              Text('${(a.binaryPath ?? '').replaceFirst(RegExp(r'^/Users/[^/]+'), '~')}${a.version != null ? ' · ${a.version!.split(' ').first}' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono, color: c.text2)),
            ]),
          ),
          if (limited)
            Pill('Limit reached', fg: c.warning, bg: c.warningWash, icon: LucideIcons.clock, radius: 10)
          else if (runs.isNotEmpty)
            Pill('Running ${runs.length}', fg: c.success, bg: c.successWash, radius: 10)
          else
            Pill(a.enabled ? 'Idle' : 'Off', radius: 10),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          SizedBox(width: 76, child: Text('Plan', style: context.t(12, color: c.text2))),
          Expanded(child: Text(a.plan.isEmpty ? (a.adapter == 'demo' ? 'Built in, no account' : 'Signed in through the CLI') : a.plan, style: context.t(12))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(width: 76, child: Text('Today', style: context.t(12, color: c.text2))),
          Expanded(child: Text('${today['runs'] ?? 0} runs · ${tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : tokens} tokens${cost > 0 ? ' · \$${cost.toStringAsFixed(2)}' : ''}', style: context.t(12))),
        ]),
        if (limited) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: c.warningWash, borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Expanded(child: Text('Back at ${TimeOfDay.fromDateTime(a.limitedUntil!.toLocal()).format(context)}. Queued work waits, or goes to your fallback rule.', style: context.t(11))),
              Btn('Clear', small: true, onTap: () => update({'limitedUntil': null})),
            ]),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(width: 76, child: Text('Slots', style: context.t(12, color: c.text2))),
          for (var i = 0; i < a.slots; i++)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: i < runs.length
                  ? Pill(data.get<Task>(Kind.task, runs[i].taskId) == null ? 'busy' : data.keyOf(data.get<Task>(Kind.task, runs[i].taskId)!), mono: true, fg: Colors.white, bg: c.accent)
                  : Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(border: Border.all(color: c.fieldStroke), borderRadius: BorderRadius.circular(4)), child: Text('free', style: context.t(10, color: c.text3))),
            ),
          const Spacer(),
          IconBtn(LucideIcons.minus, size: 12, onTap: a.slots > 1 ? () => update({'slots': a.slots - 1}) : null),
          IconBtn(LucideIcons.plus, size: 12, onTap: () => update({'slots': a.slots + 1})),
        ]),
        if (a.goodAt.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(children: [
            SizedBox(width: 76, child: Text('Good at', style: context.t(12, color: c.text2))),
            Expanded(child: Wrap(spacing: 4, runSpacing: 4, children: [for (final g in a.goodAt) Pill(g)])),
          ]),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Text('Use for new work', style: context.t(12, color: c.text2)),
          const Spacer(),
          Transform.scale(scale: 0.7, child: Switch(value: a.enabled, onChanged: (v) => update({'enabled': v}), activeTrackColor: c.accent)),
        ]),
      ]),
    );
  }
}

class _Rules extends ConsumerWidget {
  const _Rules({required this.agents});
  final List<AgentProfile> agents;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final rules = data.rules;
    final client = ref.read(clientProvider);
    String name(String id) => agents.where((a) => a.id == id).firstOrNull?.name ?? id;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Box(
        child: Column(children: [
          for (var i = 0; i < rules.length; i++) ...[
            if (i > 0) const Hairline(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(rules[i].when == 'else' ? 'ELSE' : 'IF', style: context.t(10, color: c.text3)),
                    if (rules[i].when != 'else')
                      Text(switch (rules[i].when) { 'tag' => 'tag is #${rules[i].value}', 'step' => 'step is ${rules[i].value}', 'limit' => 'an agent hits its limit', _ => rules[i].value }, style: context.t(12)),
                    Row(children: [
                      Text('THEN  ', style: context.t(10, color: c.text3)),
                      AgentTile(agent: agents.where((a) => a.id == rules[i].agentId).firstOrNull, agentId: rules[i].agentId, size: 13),
                      const SizedBox(width: 6),
                      Text(name(rules[i].agentId), style: context.t(12)),
                    ]),
                  ]),
                ),
                IconBtn(LucideIcons.x, size: 12, onTap: () => client.call(M.rulesDelete, {'id': rules[i].id})),
              ]),
            ),
          ],
          if (rules.isEmpty)
            Padding(padding: const EdgeInsets.all(12), child: Text('No rules: tasks for "any agent" go to the least busy one.', style: context.t(12, color: c.text2))),
        ]),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Builder(builder: (context) => Btn('Add rule', kind: BtnKind.plain, icon: LucideIcons.plus, small: true, onTap: agents.isEmpty
            ? null
            : () async {
                final box = context.findRenderObject() as RenderBox;
                final at = box.localToGlobal(Offset(0, box.size.height));
                final when = await showMenuAt<String>(context, at, [('tag', 'If a task has a tag…', null), ('step', 'If the pipeline step is…', null), ('limit', 'If an agent hits its limit', null), ('else', 'Otherwise', null)]);
                if (when == null || !context.mounted) return;
                var value = '';
                if (when == 'tag' || when == 'step') {
                  value = await _ask(context, when == 'tag' ? 'Tag (without #)' : 'Step name (e.g. Review)') ?? '';
                  if (value.isEmpty || !context.mounted) return;
                }
                final agent = await showMenuAt<String>(context, at, [for (final a in agents) (a.id, 'Then ${a.name}', null)]);
                if (agent == null) return;
                await client.call(M.rulesSave, {'fields': {'when': when, 'value': value.replaceFirst('#', ''), 'agentId': agent, 'order': rules.length}});
              })),
      ),
    ]);
  }

  Future<String?> _ask(BuildContext context, String label) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label, style: context.t(14, w: FontWeight.w600)),
        content: SizedBox(width: 280, child: FieldInput(controller: ctl, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v.trim()))),
        actions: [Btn('Cancel', onTap: () => Navigator.pop(context)), Btn('OK', kind: BtnKind.primary, onTap: () => Navigator.pop(context, ctl.text.trim()))],
      ),
    );
  }
}
