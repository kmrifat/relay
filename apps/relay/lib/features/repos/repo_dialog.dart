import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

/// Adds a repo (pick a folder first) or edits one.
Future<void> showRepoDialog(BuildContext context, WidgetRef ref, {required String projectId, Repo? repo}) async {
  Map<String, Object?>? info;
  String? path = repo?.data['localPath'] as String?;
  if (repo == null) {
    path = await getDirectoryPath(confirmButtonText: 'Add repository');
    if (path == null) return;
    info = await ref.read(clientProvider).map(M.reposInspect, {'path': path});
    if (info['isRepo'] != true) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$path is not a git repository.')));
      }
      return;
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(context: context, builder: (_) => _RepoDialog(projectId: projectId, repo: repo, info: info, path: path));
}

class _RepoDialog extends ConsumerStatefulWidget {
  const _RepoDialog({required this.projectId, this.repo, this.info, this.path});
  final String projectId;
  final Repo? repo;
  final Map<String, Object?>? info;
  final String? path;
  @override
  ConsumerState<_RepoDialog> createState() => _RepoDialogState();
}

class _RepoDialogState extends ConsumerState<_RepoDialog> {
  late final name = TextEditingController(text: widget.repo?.name ?? widget.info?['name'] as String? ?? '');
  late final role = TextEditingController(text: widget.repo?.role ?? widget.info?['role'] as String? ?? '');
  late final stack = TextEditingController(text: widget.repo?.stack ?? widget.info?['stack'] as String? ?? '');
  late final base = TextEditingController(text: widget.repo?.baseBranch ?? widget.info?['defaultBranch'] as String? ?? 'main');
  late final test = TextEditingController(text: widget.repo?.testCommand ?? widget.info?['testCommand'] as String? ?? '');
  late final contracts = TextEditingController(
      text: (widget.repo?.contractPaths ?? (widget.info?['contractPaths'] as List?)?.cast<String>() ?? const []).join(', '));
  late int step = widget.repo?.mergeStep ?? 0;
  late Set<String> deps = {...?widget.repo?.dependsOn};
  late String policy = widget.repo?.agentPolicy ?? 'allow';
  String? error;

  @override
  void initState() {
    super.initState();
    if (widget.repo == null) {
      // A new repo merges after everything it might depend on.
      final repos = ref.read(dataProvider).reposOf(widget.projectId);
      step = repos.isEmpty ? 0 : repos.map((r) => r.mergeStep).reduce((a, b) => a > b ? a : b);
      if (role.text == 'shared' || (widget.info?['contractPaths'] as List?)?.isNotEmpty == true) step = 0;
    }
  }

  Future<void> save() async {
    final client = ref.read(clientProvider);
    final fields = {
      'name': name.text.trim(),
      'role': role.text.trim(),
      'stack': stack.text.trim(),
      'baseBranch': base.text.trim().isEmpty ? 'main' : base.text.trim(),
      'testCommand': test.text.trim().isEmpty ? null : test.text.trim(),
      'contractPaths': contracts.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      'mergeStep': step,
      'dependsOn': deps.toList(),
      'agentPolicy': policy,
    };
    try {
      if (widget.repo == null) {
        await client.call(M.reposAdd, {'projectId': widget.projectId, 'path': widget.path, 'fields': fields});
      } else {
        await client.call(M.reposUpdate, {'id': widget.repo!.id, 'fields': fields});
      }
      await ref.read(dataProvider.notifier).reload(client);
      if (mounted) Navigator.pop(context);
    } on RpcError catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final others = ref.watch(dataProvider).reposOf(widget.projectId).where((r) => r.id != widget.repo?.id).toList();
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [SizedBox(width: 110, child: Text(label, textAlign: TextAlign.right, style: context.t(12, color: c.text2))), const SizedBox(width: 12), Expanded(child: child)]),
    );
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.fieldStroke)),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.repo == null ? 'Add repository' : 'Edit ${widget.repo!.name}', style: context.t(15, w: FontWeight.w700)),
            if (widget.path != null) ...[
              const SizedBox(height: 4),
              Text(widget.path!, style: context.t(11, family: mono, color: c.text3)),
            ],
            const SizedBox(height: 16),
            row('Name', FieldInput(controller: name)),
            row('Role', FieldInput(controller: role, hint: 'app, api, web, worker, shared, infra')),
            row('Stack', FieldInput(controller: stack, hint: 'Flutter, Laravel, React…')),
            row('Base branch', FieldInput(controller: base, mono: true)),
            row('Test command', FieldInput(controller: test, mono: true, hint: 'flutter test')),
            row('Contracts', FieldInput(controller: contracts, mono: true, hint: 'openapi.yaml (other repos depend on these)')),
            row(
              'Depends on',
              others.isEmpty
                  ? Text('No other repos yet', style: context.t(12, color: c.text3))
                  : Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final r in others)
                        GestureDetector(
                          onTap: () => setState(() => deps.contains(r.id) ? deps.remove(r.id) : deps.add(r.id)),
                          child: Pill(r.name, fg: deps.contains(r.id) ? Colors.white : c.text2, bg: deps.contains(r.id) ? hexColor(r.color) : c.inner, radius: 10),
                        ),
                    ]),
            ),
            row('Merge step', Row(children: [
              IconBtn(LucideIcons.minus, onTap: step > 0 ? () => setState(() => step--) : null),
              SizedBox(width: 30, child: Text('${step + 1}', textAlign: TextAlign.center, style: context.t(13, w: FontWeight.w600))),
              IconBtn(LucideIcons.plus, onTap: () => setState(() => step++)),
              const SizedBox(width: 8),
              Expanded(child: Text('Lower steps merge first. Repos in the same step merge together.', style: context.t(11, color: c.text3))),
            ])),
            row('Agents', Segmented<String>(small: true, options: const [('allow', 'Run freely'), ('ask', 'Ask before each run')], value: policy, onChanged: (v) => setState(() => policy = v))),
            if (error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(error!, style: context.t(12, color: c.danger))),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Btn('Cancel', onTap: () => Navigator.pop(context)),
              const SizedBox(width: 8),
              Btn(widget.repo == null ? 'Add' : 'Save', kind: BtnKind.primary, onTap: save),
            ]),
          ]),
        ),
      ),
    );
  }
}
