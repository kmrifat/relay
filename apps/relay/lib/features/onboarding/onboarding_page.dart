import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

/// First run on the Mac (M9-01): your name, the agent CLIs found on this
/// Mac, a repo, a first task, and the team (optional). Each step can be
/// skipped; Relay remembers it's done.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key, required this.onDone});
  final VoidCallback onDone;
  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  int step = 0;
  final name = TextEditingController();
  final title = TextEditingController(text: 'Read the code and write OVERVIEW.md: what it does, how it is built, how to run it');
  List<Map<String, Object?>> agents = const [];
  bool detecting = false;
  String? projectId;
  String? repoName;
  String? agentId;
  String? error;
  bool busy = false;

  RelayClient get client => ref.read(clientProvider);

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final s = await client.map(M.settingsGet);
      final n = '${s['userName'] ?? ''}';
      if (mounted && n != 'You') name.text = n;
    });
  }

  Future<void> _detect() async {
    setState(() => detecting = true);
    try {
      await client.call(M.agentsDetect);
      final list = await client.list(M.agentsList);
      if (!mounted) return;
      setState(() {
        agents = list;
        final found = list.where((a) => a['binaryPath'] != null).toList();
        agentId = (found.where((a) => a['id'] == 'claude-code').firstOrNull ?? found.where((a) => a['id'] != 'demo').firstOrNull ?? found.firstOrNull)?['id'] as String?;
      });
    } finally {
      if (mounted) setState(() => detecting = false);
    }
  }

  Future<void> _addRepo() async {
    final path = await getDirectoryPath(confirmButtonText: 'Add repository');
    if (path == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final info = await client.map(M.reposInspect, {'path': path});
      if (info['isRepo'] != true) throw RpcError(RpcError.invalidParams, 'That folder is not a git repository.');
      final folder = path.split('/').where((s) => s.isNotEmpty).last;
      final words = folder.split(RegExp(r'[-_\s]+')).where((w) => w.isNotEmpty).toList();
      var key = (words.length > 1 ? words.map((w) => w[0]).join() : folder.substring(0, folder.length < 2 ? folder.length : 2)).toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
      if (key.isEmpty) key = 'P';
      Map<String, Object?> p;
      try {
        p = await client.map(M.projectsCreate, {'name': folder, 'key': key});
      } on RpcError {
        p = await client.map(M.projectsCreate, {'name': folder, 'key': '$key${DateTime.now().second % 10}'});
      }
      await client.map(M.reposAdd, {'projectId': p['id'], 'path': path});
      setState(() {
        projectId = p['id'] as String;
        repoName = folder;
        step = 3;
      });
    } on RpcError catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _queue() async {
    if (projectId == null || title.text.trim().isEmpty) return setState(() => step = 4);
    setState(() => busy = true);
    try {
      final t = await client.map(M.tasksCreate, {
        'projectId': projectId,
        'fields': {
          'title': title.text.trim(),
          'status': TaskStatus.queued,
          if (agentId != null) ...{'assigneeKind': 'agent', 'assignee': agentId},
        },
      });
      ref.read(navProvider.notifier).project(projectId!);
      ref.read(navProvider.notifier).openTask(t['id'] as String);
      setState(() => step = 4);
    } on RpcError catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _finish({bool team = false}) async {
    await client.call(M.settingsSet, {'values': {'onboarded': true}});
    widget.onDone();
    if (team) ref.read(navProvider.notifier).page(AppPage.settings);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final steps = ['You', 'Agents', 'Repository', 'First task', 'Team'];
    return Container(
      color: c.window,
      child: Center(
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(LucideIcons.listChecks, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Text('Welcome to Relay', style: context.t(22, w: FontWeight.w700)),
                const Spacer(),
                Btn('Skip setup', kind: BtnKind.plain, onTap: _finish),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                for (final (i, s) in steps.indexed) ...[
                  if (i > 0) Expanded(child: Container(height: 1, color: i <= step ? c.accent : c.separator)),
                  Pill(s, fg: i == step ? Colors.white : (i < step ? c.accent : c.text3), bg: i == step ? c.accent : c.inner),
                ],
              ]),
              const SizedBox(height: 24),
              Box(padding: const EdgeInsets.all(20), child: _step(context)),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: context.t(12, color: c.danger))),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _step(BuildContext context) {
    final c = context.c;
    Widget lead(String head, String body) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(head, style: context.t(16, w: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(body, style: context.t(13, color: c.text2)),
      const SizedBox(height: 16),
    ]);
    Widget actions(List<Widget> buttons) => Row(mainAxisAlignment: MainAxisAlignment.end, children: [
      for (final (i, b) in buttons.indexed) ...[if (i > 0) const SizedBox(width: 8), b],
    ]);

    switch (step) {
      case 0:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lead('Your agents, on your Mac',
              'Relay runs the coding agents you already pay for (Claude Code, Codex, Gemini, OpenCode, Aider) side by side, on one board with you and your team. Logins and keys never leave this Mac.'),
          FieldRow('Your name', FieldInput(controller: name, hint: 'Shown on comments, merges and to teammates', autofocus: true), labelWidth: 90),
          const SizedBox(height: 16),
          actions([
            Btn('Continue', kind: BtnKind.primary, onTap: () async {
              if (name.text.trim().isNotEmpty) await client.call(M.settingsSet, {'values': {'userName': name.text.trim()}});
              setState(() => step = 1);
              _detect();
            }),
          ]),
        ]);
      case 1:
        final found = agents.where((a) => a['binaryPath'] != null).toList();
        final missing = agents.where((a) => a['binaryPath'] == null).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lead('Agents on this Mac', 'Relay looked on your login shell\'s PATH. Install more any time; Agents → Detect finds them.'),
          if (detecting) Text('Looking…', style: context.t(12, color: c.text2)),
          for (final a in found)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                AgentTile(agent: AgentProfile(a), size: 20),
                const SizedBox(width: 10),
                Text('${a['name']}', style: context.t(13, w: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(child: Text(a['id'] == 'demo' ? 'built in · try Relay without an account' : '${a['version'] ?? ''}', style: context.t(11, color: c.text3))),
                Icon(LucideIcons.circleCheck, size: 14, color: c.success),
              ]),
            ),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Not found: ${missing.map((a) => a['name']).join(', ')}', style: context.t(11, color: c.text3)),
          ],
          if (found.any((a) => a['id'] == 'claude-code')) ...[
            const SizedBox(height: 8),
            Text('Claude Code needs to be signed in once: run `claude /login` in Terminal.', style: context.t(11, color: c.text2)),
          ],
          const SizedBox(height: 16),
          actions([
            Btn('Look again', onTap: detecting ? null : _detect),
            Btn('Continue', kind: BtnKind.primary, onTap: () => setState(() => step = 2)),
          ]),
        ]);
      case 2:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lead('Pick a repository', 'A project is a board over one or more git repos. Agents work in their own worktree and branch, never in your checkout.'),
          actions([
            Btn('Later', onTap: () => setState(() => step = 4)),
            Btn(busy ? 'Adding…' : 'Choose a folder…', kind: BtnKind.primary, icon: LucideIcons.folderGit2, onTap: busy ? null : _addRepo),
          ]),
        ]);
      case 3:
        final found = agents.where((a) => a['binaryPath'] != null).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lead('A first task for $repoName', 'Something safe to watch an agent do. It runs in its own branch; you review before anything merges.'),
          FieldInput(controller: title, maxLines: 3, minLines: 2),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 6, children: [
            for (final a in found)
              ChoiceChip(
                avatar: AgentTile(agent: AgentProfile(a), size: 16),
                label: Text('${a['name']}', style: context.t(12)),
                selected: agentId == a['id'],
                onSelected: (_) => setState(() => agentId = a['id'] as String),
              ),
          ]),
          const SizedBox(height: 16),
          actions([
            Btn('Skip', onTap: () => setState(() => step = 4)),
            Btn(busy ? 'Queuing…' : 'Queue it', kind: BtnKind.primary, onTap: busy ? null : _queue),
          ]),
        ]);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lead('Working with others, or from your iPhone?',
              'Team sync goes through your own Cloudflare account — no Relay server, everything encrypted on this Mac. Your iPhone pairs through the same team.'),
          actions([
            Btn('Not now', onTap: _finish),
            Btn('Set up a team', kind: BtnKind.primary, icon: LucideIcons.users, onTap: () => _finish(team: true)),
          ]),
        ]);
    }
  }
}
