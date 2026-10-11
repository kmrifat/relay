import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../app/theme.dart' show hexColor;
import '../data/relay_data.dart';
import 'glass.dart';
import 'mobile_data.dart';
import 'mobile_shell.dart' show openTask;

/// I03's sheet: "Claude Code wants to run …" with Deny / Allow once /
/// Always allow. The answer goes to the Mac running the agent.
Future<void> showPermissionSheet(BuildContext context, WidgetRef ref, {required Task task, required Run run, required RunEvent request}) {
  final view = ref.read(phoneViewProvider);
  final agent = view.agent(run.agentId, deviceId: run.deviceId);
  final project = view.data.projectOf(task);
  final device = view.data.get<DeviceInfo>(Kind.device, run.deviceId);
  final input = request.data['input'];
  final command = input is Map ? (input['command'] ?? input['file_path'] ?? input['path'] ?? input.values.firstOrNull) : input;
  Future<void> answer(BuildContext sheet, String a) async {
    Navigator.of(sheet).pop();
    try {
      await ref.read(clientProvider).call(M.permissionsAnswer, {'runId': run.id, 'requestId': request.data['id'], 'answer': a});
    } on RpcError catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  return showGlassSheet<void>(
    context,
    (sheet) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Center(
        child: Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(color: MC.orangeWash, shape: BoxShape.circle),
          child: const Icon(LucideIcons.shieldCheck, color: MC.orange, size: 28),
        ),
      ),
      const SizedBox(height: 12),
      Text('${agent.name} wants to run', textAlign: TextAlign.center, style: mt(22, w: FontWeight.w700)),
      const SizedBox(height: 4),
      Text('on ${device?.name ?? view.macName} · ${view.data.keyOf(task)}', textAlign: TextAlign.center, style: mt(15, color: MC.text2)),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: const Color(0x0F000000), borderRadius: BorderRadius.circular(14)),
        child: Text('${command ?? request.data['tool']}', maxLines: 6, overflow: TextOverflow.ellipsis, style: mt(15, family: 'Menlo')),
      ),
      if (request.data['summary'] != null) ...[
        const SizedBox(height: 12),
        Text('${request.data['summary']}', style: mt(15, color: MC.text2)),
      ],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: MButton('Deny', destructive: true, height: 52, onTap: () => answer(sheet, 'deny'))),
        const SizedBox(width: 10),
        Expanded(child: MButton('Allow once', primary: true, height: 52, onTap: () => answer(sheet, 'allow_once'))),
      ]),
      const SizedBox(height: 12),
      GestureDetector(
        onTap: () => answer(sheet, 'allow_always'),
        child: Text('Always allow in ${project?.name ?? 'this project'}', textAlign: TextAlign.center, style: mt(16, color: MC.accent)),
      ),
    ]),
  );
}

/// New task from the phone: it runs on your Mac (or a teammate's shared agent).
Future<void> showNewTaskSheet(BuildContext context, WidgetRef ref, {String? projectId}) {
  final view = ref.read(phoneViewProvider);
  final projects = view.data.projects;
  if (projects.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Make a project on your Mac first.')));
    return Future.value();
  }
  final title = TextEditingController();
  var pid = projectId ?? projects.first.id;
  String? agent = view.data.agents.firstOrNull?.id;
  return showGlassSheet<void>(
    context,
    (sheet) => StatefulBuilder(
      builder: (sheet, setState) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('New task', style: mt(22, w: FontWeight.w700)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(color: MC.card, borderRadius: BorderRadius.circular(14)),
          child: TextField(
            controller: title,
            autofocus: true,
            style: mt(17),
            cursorOpacityAnimates: false,
            decoration: InputDecoration(border: InputBorder.none, hintText: 'What should get done?', hintStyle: mt(17, color: MC.text3)),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final p in projects)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(p.name), selected: p.id == pid, onSelected: (_) => setState(() => pid = p.id)),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final a in view.data.agents)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  avatar: AgentSquare(letter: a.letter, color: hexColor(a.color), size: 18),
                  label: Text(a.name),
                  selected: a.id == agent,
                  onSelected: (_) => setState(() => agent = a.id),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        MButton('Queue on ${view.macName}', primary: true, height: 52, onTap: () async {
          if (title.text.trim().isEmpty) return;
          Navigator.of(sheet).pop();
          await ref.read(clientProvider).call(M.tasksCreate, {
            'projectId': pid,
            'fields': {'title': title.text.trim(), 'status': TaskStatus.queued, if (agent != null) ...{'assigneeKind': 'agent', 'assignee': agent}},
          });
        }),
      ]),
    ),
  );
}

/// Search every task by key or title.
Future<void> showSearchSheet(BuildContext context, WidgetRef ref) {
  final q = ValueNotifier('');
  return showGlassSheet<void>(
    context,
    (sheet) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(color: MC.card, borderRadius: BorderRadius.circular(999)),
          child: Row(children: [
            const Icon(LucideIcons.search, color: MC.text3),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                autofocus: true,
                style: mt(17),
                cursorOpacityAnimates: false,
                onChanged: (v) => q.value = v.trim().toLowerCase(),
                decoration: InputDecoration(border: InputBorder.none, hintText: 'Tasks', hintStyle: mt(17, color: MC.text3)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: ValueListenableBuilder<String>(
            valueListenable: q,
            builder: (context, query, _) {
              final data = ref.read(dataProvider);
              final tasks = data.tasksOf(null).where((t) => query.isEmpty || '${data.keyOf(t)} ${t.title}'.toLowerCase().contains(query)).take(40).toList();
              return ListView(children: [
                for (final t in tasks)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: Text(t.title, style: mt(16)),
                    subtitle: Text('${data.keyOf(t)} · ${TaskStatus.label(t.status)}', style: mt(13, color: MC.text2)),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      openTask(context, t.id);
                    },
                  ),
              ]);
            },
          ),
        ),
      ]),
    ),
  );
}

Future<String?> showProjectPicker(BuildContext context, List<Project> projects, String current) => showGlassSheet<String>(
  context,
  (sheet) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text('Projects', style: mt(22, w: FontWeight.w700)),
    const SizedBox(height: 8),
    for (final p in projects)
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Tile(Text(p.key.substring(0, 1)), color: hexColor(p.color, MC.accent)),
        title: Text(p.name, style: mt(17, w: p.id == current ? FontWeight.w600 : FontWeight.w400)),
        trailing: p.id == current ? const Icon(LucideIcons.check, color: MC.accent) : null,
        onTap: () => Navigator.of(sheet).pop(p.id),
      ),
  ]),
);
