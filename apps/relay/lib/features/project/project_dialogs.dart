import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../../ui/platform.dart';

Future<void> showNewProjectDialog(BuildContext context, WidgetRef ref) =>
    showDialog<void>(context: context, builder: (_) => const _NewProject());

class _NewProject extends ConsumerStatefulWidget {
  const _NewProject();
  @override
  ConsumerState<_NewProject> createState() => _NewProjectState();
}

class _NewProjectState extends ConsumerState<_NewProject> {
  final name = TextEditingController();
  final key = TextEditingController();
  final folders = <(String path, Map<String, Object?> info)>[];
  bool keyEdited = false;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    name.addListener(() {
      if (keyEdited) return;
      final words = name.text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      key.text = (words.length > 1 ? words.map((w) => w[0]).join() : name.text.trim()).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (key.text.length > 3) key.text = key.text.substring(0, words.length > 1 ? key.text.length.clamp(0, 4) : 2);
    });
  }

  Future<void> addFolders() async {
    final paths = await getDirectoryPaths(confirmButtonText: 'Add');
    final client = ref.read(clientProvider);
    for (final p in paths) {
      if (p == null) continue;
      final info = await client.map(M.reposInspect, {'path': p});
      if (info['isRepo'] != true) {
        setState(() => error = '$p is not a git repository.');
        continue;
      }
      if (folders.any((f) => f.$2['topLevel'] == info['topLevel'])) continue;
      setState(() {
        folders.add((p, info));
        if (name.text.isEmpty) name.text = (info['name'] as String).replaceAll(RegExp(r'[-_](app|api|web|mobile|ios|android)$'), '');
      });
    }
  }

  Future<void> create() async {
    if (name.text.trim().isEmpty || key.text.trim().isEmpty) return setState(() => error = 'Name and key are needed.');
    setState(() => busy = true);
    final client = ref.read(clientProvider);
    try {
      final p = await client.map(M.projectsCreate, {'name': name.text.trim(), 'key': key.text.trim()});
      for (final (path, info) in folders) {
        final contracts = (info['contractPaths'] as List?) ?? const [];
        await client.call(M.reposAdd, {
          'projectId': p['id'],
          'path': path,
          'fields': {'mergeStep': contracts.isNotEmpty ? 0 : 1},
        });
      }
      await ref.read(dataProvider.notifier).reload(client);
      ref.read(navProvider.notifier).project(p['id'] as String, view: folders.length > 1 ? ProjectView.repos : ProjectView.board);
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
    return Dialog(
      child: SizedBox(
        width: 520,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New project', style: context.t(15, w: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('A project is a board over one or more git repositories.', style: context.t(12, color: c.text2)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(flex: 3, child: FieldInput(controller: name, autofocus: true, hint: 'Name, e.g. Kitchenly')),
              const SizedBox(width: 10),
              Expanded(child: FieldInput(controller: key, mono: true, hint: 'KEY', onChanged: (_) => keyEdited = true)),
            ]),
            const SizedBox(height: 6),
            Text('The key prefixes task ids: ${key.text.isEmpty ? 'KT' : key.text}-1, ${key.text.isEmpty ? 'KT' : key.text}-2…', style: context.t(11, color: c.text3)),
            const SizedBox(height: 16),
            Row(children: [
              Text('Repositories', style: context.label),
              const Spacer(),
              Btn('Add folders…', small: true, icon: LucideIcons.folderPlus, onTap: addFolders),
            ]),
            const SizedBox(height: 8),
            Box(
              child: folders.isEmpty
                  ? Padding(padding: const EdgeInsets.all(14), child: Text('Add the git folders this project spans. You can add more later under Repos.', style: context.t(12, color: c.text2)))
                  : Column(children: [
                      for (var i = 0; i < folders.length; i++) ...[
                        if (i > 0) const Hairline(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Row(children: [
                            Icon(LucideIcons.folderGit2, size: 14, color: c.accentIcon),
                            const SizedBox(width: 8),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(folders[i].$2['name'] as String, style: context.t(13, w: FontWeight.w600)),
                              Text('${folders[i].$2['stack'] ?? ''} · ${folders[i].$2['defaultBranch']}', style: context.t(11, color: c.text2)),
                            ])),
                            IconBtn(LucideIcons.x, size: 12, onTap: () => setState(() => folders.removeAt(i))),
                          ]),
                        ),
                      ],
                    ]),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: context.t(12, color: c.danger))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Btn('Cancel', onTap: () => Navigator.pop(context)),
              const SizedBox(width: 8),
              Btn(busy ? 'Creating…' : 'Create project', kind: BtnKind.primary, onTap: busy ? null : create),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// First run: no projects yet.
class NoProjects extends ConsumerWidget {
  const NoProjects({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final agents = data.agents.where((a) => a.binaryPath != null).toList();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(LucideIcons.layoutGrid, size: 34, color: c.accentIcon),
          const SizedBox(height: 14),
          Text('Your board starts with a project', style: context.t(18, w: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Pick the git folders it spans: one repo, or the app, api and shared repos of a bigger product.',
              textAlign: TextAlign.center, style: context.t(13, color: c.text2)),
          const SizedBox(height: 18),
          Btn('New project', kind: BtnKind.primary, icon: LucideIcons.plus, onTap: () => showNewProjectDialog(context, ref)),
          const SizedBox(height: 28),
          Box(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Agents found on ${Desk.thisComputer}', style: context.label),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 8, children: [
                for (final a in agents)
                  Row(mainAxisSize: MainAxisSize.min, children: [AgentTile(agent: a, size: 16), const SizedBox(width: 6), Text(a.name, style: context.t(12))]),
              ]),
              const SizedBox(height: 8),
              Text('The Demo agent works without any account, so you can try the whole flow first.', style: context.t(11, color: c.text3)),
            ]),
          ),
        ]),
      ),
    );
  }
}
