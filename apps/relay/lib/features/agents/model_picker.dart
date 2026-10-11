import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../../app/theme.dart';
import '../../ui/widgets.dart';

/// "Opus" for `opus`, the name itself for a model typed by hand.
String modelLabel(AgentProfile? agent, String? model) {
  if (model == null || model.isEmpty) return 'default';
  final known = agent?.models.where((m) => m['id'] == model).firstOrNull;
  return known?['label'] as String? ?? model;
}

/// "Claude Code default: Opus · high", or just "… default" when the agent
/// leaves both to the CLI.
String agentDefaults(AgentProfile a) {
  final parts = [if (a.model != null) modelLabel(a, a.model), ?a.effort];
  return parts.isEmpty ? '${a.name} default' : '${a.name} default: ${parts.join(' · ')}';
}

/// Model and effort for one agent's CLI, as two small menus. Null means
/// "the default": whatever is set further down (step → task → agent → CLI),
/// which [inherited] names, e.g. "agent: Opus · high".
class ModelEffortPicker extends StatelessWidget {
  const ModelEffortPicker({super.key, required this.agent, required this.model, required this.effort, required this.onChanged, this.inherited, this.small = true});
  final AgentProfile? agent;
  final String? model, effort;
  final void Function(String? model, String? effort) onChanged;
  final String? inherited;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final a = agent;
    final efforts = a?.efforts ?? const <String>[];
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Builder(builder: (context) => Btn(
        'Model: ${modelLabel(a, model)}',
        small: small,
        icon: LucideIcons.brain,
        onTap: a == null ? null : () => _pickModel(context, a),
      )),
      if (efforts.isNotEmpty)
        Builder(builder: (context) => Btn(
          'Effort: ${effort ?? 'default'}',
          small: small,
          icon: LucideIcons.gauge,
          onTap: () async {
            final box = context.findRenderObject() as RenderBox;
            final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
              ('', 'Default', effort == null ? LucideIcons.check : null),
              for (final e in efforts) (e, e, e == effort ? LucideIcons.check : null),
            ]);
            if (v != null) onChanged(model, v.isEmpty ? null : v);
          },
        )),
      if (inherited != null && (model == null || (effort == null && efforts.isNotEmpty)))
        Text(inherited!, style: context.t(11, color: context.c.text3)),
    ]);
  }

  Future<void> _pickModel(BuildContext context, AgentProfile a) async {
    final box = context.findRenderObject() as RenderBox;
    final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
      ('', 'Default', model == null ? LucideIcons.check : null),
      for (final m in a.models)
        ('${m['id']}', [m['label'], if ((m['note'] as String? ?? '').isNotEmpty) m['note']].join(' · '), m['id'] == model ? LucideIcons.check : null),
      ('\u0000other', 'Other model…', LucideIcons.pencil),
    ]);
    if (v == null || !context.mounted) return;
    if (v != '\u0000other') return onChanged(v.isEmpty ? null : v, effort);
    final typed = await _askModelName(context, a, model);
    if (typed != null) onChanged(typed.isEmpty ? null : typed, effort);
  }
}

Future<String?> _askModelName(BuildContext context, AgentProfile a, String? current) {
  final ctrl = TextEditingController(text: current ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Model for ${a.name}', style: context.t(14, w: FontWeight.w600)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          FieldInput(controller: ctrl, autofocus: true, hint: 'The name ${a.name} takes, e.g. claude-sonnet-5-5', onSubmitted: (v) => Navigator.pop(context, v.trim())),
          const SizedBox(height: 8),
          Text('Passed to the CLI as it is. Leave empty for its default.', style: context.t(11, color: context.c.text3)),
        ]),
      ),
      actions: [
        Btn('Cancel', onTap: () => Navigator.pop(context)),
        Btn('Use it', kind: BtnKind.primary, onTap: () => Navigator.pop(context, ctrl.text.trim())),
      ],
    ),
  );
}
