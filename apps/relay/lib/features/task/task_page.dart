import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'diff_dialog.dart';
import 'run_pane.dart';
import 'task_bits.dart';

/// One task: details and change set on the left, its runs on the right
/// (designs T02 and T12).
class TaskPage extends ConsumerWidget {
  const TaskPage({super.key, required this.taskId});
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final task = data.get<Task>(Kind.task, taskId)!;
    final project = data.projectOf(task);
    final changes = data.changesOf(task.id);
    final repos = data.reposOf(task.projectId);
    final client = ref.read(clientProvider);
    final ready = changes.where((ch) => ch.status == 'ready').length;
    final touched = task.repoIds.isEmpty ? (repos.isEmpty ? 0 : 1) : task.repoIds.length;

    return Column(children: [
      Toolbar(
        leading: IconBtn(LucideIcons.chevronLeft, size: 16, tooltip: 'Back (Esc)', onTap: () => ref.read(navProvider.notifier).closeTask()),
        title: '${data.keyOf(task)} · ${task.title}',
        subtitle: '${project?.name ?? ''} · ${TaskStatus.label(task.status)}'
            '${repos.length > 1 ? ' · touches $touched of ${repos.length} repos' : ''}'
            '${changes.isNotEmpty ? ' · branch ${task.branchName(project?.key ?? '')}' : ''}',
        actions: [
          if (changes.isNotEmpty)
            Btn('Open workspace', icon: LucideIcons.folderOpen, onTap: () {
              ref.read(navProvider.notifier).closeTask();
              ref.read(navProvider.notifier).view(ProjectView.code);
            }),
          if (task.status != TaskStatus.running && task.status != TaskStatus.queued && task.status != TaskStatus.done)
            Btn('Queue', icon: LucideIcons.circleDot, onTap: () => client.call(M.tasksMove, {'id': task.id, 'status': TaskStatus.queued})),
          if (changes.isNotEmpty && task.status != TaskStatus.done)
            Btn(changes.length > 1 ? 'Merge in order' : 'Approve & merge', icon: LucideIcons.gitMerge, kind: ready > 0 ? BtnKind.primary : BtnKind.secondary,
                onTap: ready == 0 || task.status == TaskStatus.running ? null : () => _merge(context, ref, task)),
          Builder(builder: (context) => IconBtn(LucideIcons.ellipsis, onTap: () {
            final box = context.findRenderObject() as RenderBox;
            taskMenu(context, ref, task, box.localToGlobal(Offset(0, box.size.height)));
          })),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: Row(children: [
          SizedBox(width: 480, child: _Details(task: task)),
          Container(width: 1, color: c.separator),
          Expanded(child: RunPane(task: task)),
        ]),
      ),
    ]);
  }

  static Future<void> _merge(BuildContext context, WidgetRef ref, Task task) async {
    try {
      final res = await ref.read(clientProvider).list(M.changesMerge, {'taskId': task.id});
      final failed = res.where((r) => r['ok'] != true).toList();
      if (!context.mounted) return;
      if (failed.isNotEmpty) {
        showError(context, '${failed.first['repo']}: ${failed.first['error']}');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          width: 420,
          content: Text('Merged ${res.map((r) => r['repo']).join(' → ')}'),
        ));
      }
    } on RpcError catch (e) {
      if (context.mounted) showError(context, e.message);
    }
  }
}

class _Details extends ConsumerStatefulWidget {
  const _Details({required this.task});
  final Task task;
  @override
  ConsumerState<_Details> createState() => _DetailsState();
}

class _DetailsState extends ConsumerState<_Details> {
  late final brief = TextEditingController(text: widget.task.brief);
  final comment = TextEditingController();
  final newItem = TextEditingController();
  final briefFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    briefFocus.addListener(() {
      if (!briefFocus.hasFocus && brief.text != widget.task.brief) {
        _update({'brief': brief.text});
      }
    });
  }

  @override
  void didUpdateWidget(_Details old) {
    super.didUpdateWidget(old);
    if (!briefFocus.hasFocus && brief.text != widget.task.brief) brief.text = widget.task.brief;
  }

  @override
  void dispose() {
    brief.dispose();
    comment.dispose();
    newItem.dispose();
    briefFocus.dispose();
    super.dispose();
  }

  Future<void> _update(Map<String, Object?> fields) => ref.read(clientProvider).call(M.tasksUpdate, {'id': widget.task.id, 'fields': fields});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = widget.task;
    final repos = data.reposOf(t.projectId);
    final changes = data.changesOf(t.id);
    final comments = ref.watch(commentsProvider(t.id)).value ?? const [];
    final contractNotes = comments.where((cm) => cm.data['contract'] == true).toList();

    return ListView(padding: const EdgeInsets.all(20), children: [
      if (t.data['attention'] == 'question' && t.data['question'] != null) ...[
        Box(
          color: c.warningWash,
          border: c.warning,
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('The agent asks', style: context.t(12, w: FontWeight.w700, color: c.warning)),
            const SizedBox(height: 4),
            Text('${t.data['question']}', style: context.t(13)),
            const SizedBox(height: 4),
            Text('Reply in the discussion below; your answer goes straight to the agent.', style: context.t(11, color: c.text2)),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      if (t.data['attention'] == 'failed' && t.data['lastError'] != null) ...[
        Box(
          color: c.dangerWash,
          border: c.danger,
          padding: const EdgeInsets.all(12),
          child: Text('${t.data['lastError']}', maxLines: 6, overflow: TextOverflow.ellipsis, style: context.t(12, color: c.danger)),
        ),
        const SizedBox(height: 16),
      ],
      Box(
        child: Column(children: [
          FieldRow('Status', Row(children: [
            Icon(statusIcon(t.status), size: 13, color: statusColor(context, t.status)),
            const SizedBox(width: 6),
            Builder(builder: (context) => GestureDetector(
              onTap: () async {
                final box = context.findRenderObject() as RenderBox;
                final s = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [for (final s in TaskStatus.columns) (s, TaskStatus.label(s), statusIcon(s))]);
                if (s != null) await ref.read(clientProvider).call(M.tasksMove, {'id': t.id, 'status': s});
              },
              child: Text(TaskStatus.label(t.status), style: context.t(12, color: c.accentIcon)),
            )),
            const SizedBox(width: 8),
            ?attentionBadge(context, t),
          ])),
          const Hairline(),
          FieldRow('Assignee', Row(children: [
            Expanded(child: AssigneeLabel(t, size: 12)),
            Builder(builder: (context) => IconBtn(LucideIcons.pencil, size: 12, onTap: () async {
              final box = context.findRenderObject() as RenderBox;
              final choice = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
                ('auto', 'Any agent (routing rules)', LucideIcons.workflow),
                for (final a in data.agents.where((a) => a.binaryPath != null)) ('agent:${a.id}', a.name, LucideIcons.bot),
                ('me', 'Me', LucideIcons.user),
              ]);
              if (choice == null) return;
              if (choice == 'auto') await _update({'assigneeKind': 'agent', 'assignee': 'auto'});
              if (choice == 'me') await _update({'assigneeKind': 'person', 'assignee': ref.read(clientProvider).hello['userName'] ?? 'You'});
              if (choice.startsWith('agent:')) await _update({'assigneeKind': 'agent', 'assignee': choice.substring(6)});
            })),
          ])),
          if (t.pipeline.isNotEmpty) ...[
            const Hairline(),
            FieldRow('Pipeline', Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (var i = 0; i < t.pipeline.length; i++) ...[
                if (i > 0) Icon(LucideIcons.arrowRight, size: 11, color: c.text3),
                Pill(t.pipeline[i].name,
                    fg: switch (t.pipeline[i].status) { 'done' => c.success, 'running' => c.accentIcon, 'failed' => c.danger, _ => c.text2 },
                    bg: switch (t.pipeline[i].status) { 'done' => c.successWash, 'running' => c.accent.withValues(alpha: 0.2), _ => c.inner },
                    icon: t.pipeline[i].status == 'done' ? LucideIcons.check : null),
              ],
            ])),
          ],
          if (repos.length > 1) ...[
            const Hairline(),
            FieldRow('Repos', Wrap(spacing: 4, runSpacing: 4, children: [
              for (final r in repos)
                GestureDetector(
                  onTap: changes.isNotEmpty
                      ? null
                      : () {
                          final ids = {...t.repoIds};
                          ids.contains(r.id) ? ids.remove(r.id) : ids.add(r.id);
                          _update({'repoIds': ids.toList()});
                        },
                  child: Pill(r.name,
                      fg: t.repoIds.contains(r.id) ? Colors.white : c.text3,
                      bg: t.repoIds.contains(r.id) ? hexColor(r.color) : c.inner,
                      radius: 10),
                ),
            ])),
          ],
          const Hairline(),
          FieldRow('Priority', Segmented<int>(small: true, options: const [(0, 'None'), (1, 'P1'), (2, 'P2'), (3, 'P3')], value: t.priority, onChanged: (v) => _update({'priority': v}))),
          if (t.dependsOn.isNotEmpty) ...[
            const Hairline(),
            FieldRow('Blocked by', Wrap(spacing: 6, children: [
              for (final d in t.dependsOn)
                if (data.get<Task>(Kind.task, d) != null)
                  GestureDetector(
                    onTap: () => ref.read(navProvider.notifier).openTask(d),
                    child: Text(data.keyOf(data.get<Task>(Kind.task, d)!), style: context.t(12, family: mono, color: c.accentIcon)),
                  ),
            ])),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      Text('Brief for the agent', style: context.label),
      const SizedBox(height: 6),
      FieldInput(controller: brief, focusNode: briefFocus, hint: 'What should be done, and anything the agent should know', minLines: 3, maxLines: 12),
      const SizedBox(height: 16),
      Text('Done when · ${t.doneWhen.where((d) => d.done).length} of ${t.doneWhen.length}', style: context.label),
      const SizedBox(height: 6),
      for (var i = 0; i < t.doneWhen.length; i++)
        Hoverable(
          onTap: () {
            final items = [for (final d in t.doneWhen) d.toJson()];
            items[i] = {...items[i], 'done': !t.doneWhen[i].done};
            _update({'doneWhen': items});
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            child: Row(children: [
              Icon(t.doneWhen[i].done ? LucideIcons.circleCheck : LucideIcons.circle, size: 15, color: t.doneWhen[i].done ? c.success : c.text3),
              const SizedBox(width: 8),
              Expanded(child: Text(t.doneWhen[i].text, style: context.t(13, color: t.doneWhen[i].done ? c.text2 : c.text))),
            ]),
          ),
        ),
      SizedBox(
        height: 30,
        child: FieldInput(
          controller: newItem,
          hint: '+ Add a check, press ⏎',
          size: 12,
          onSubmitted: (v) {
            if (v.trim().isEmpty) return;
            _update({'doneWhen': [for (final d in t.doneWhen) d.toJson(), {'text': v.trim(), 'done': false}]});
            newItem.clear();
          },
        ),
      ),
      if (changes.isNotEmpty) ...[
        const SizedBox(height: 20),
        _ChangeSet(task: t, changes: changes),
      ],
      if (contractNotes.isNotEmpty) ...[
        const SizedBox(height: 16),
        Box(
          border: c.purple.withValues(alpha: 0.5),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(LucideIcons.package, size: 14, color: c.purple),
              const SizedBox(width: 8),
              Text('Contract between repos', style: context.t(13, w: FontWeight.w700)),
            ]),
            const SizedBox(height: 6),
            Text(contractNotes.last.body, style: context.t(12, color: c.text2)),
          ]),
        ),
      ],
      const SizedBox(height: 20),
      Text('Discussion', style: context.label),
      const SizedBox(height: 8),
      for (final cm in comments.where((cm) => cm.data['contract'] != true)) _comment(context, data, cm),
      const SizedBox(height: 6),
      FieldInput(
        controller: comment,
        hint: t.data['attention'] == 'question' ? 'Answer the agent…' : 'Comment, or @claude-code to reach a running agent',
        minLines: 1,
        maxLines: 5,
        onSubmitted: (v) async {
          if (v.trim().isEmpty) return;
          await ref.read(clientProvider).call(M.commentsPost, {'taskId': t.id, 'body': v.trim(), 'author': ref.read(clientProvider).hello['userName']});
          comment.clear();
        },
      ),
    ]);
  }

  Widget _comment(BuildContext context, DataSnapshot data, Comment cm) {
    final c = context.c;
    final agent = cm.authorKind == 'agent' ? data.get<AgentProfile>(Kind.agent, cm.data['agentId'] as String?) ??
        data.agents.where((a) => a.name == cm.author).firstOrNull : null;
    final toAgent = cm.to == null ? null : data.get<AgentProfile>(Kind.agent, cm.to);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        cm.authorKind == 'agent'
            ? AgentTile(agent: agent, agentId: cm.author, size: 22)
            : (cm.authorKind == 'system'
                ? Container(width: 22, height: 22, decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(6)), child: const Icon(LucideIcons.listChecks, size: 12, color: Colors.white))
                : Avatar(cm.author, size: 22, color: c.warning)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(cm.author, style: context.t(12, w: FontWeight.w600)),
              if (cm.authorKind == 'agent') ...[const SizedBox(width: 6), Pill(toAgent != null ? 'AGENT → ${toAgent.name.toUpperCase()}' : 'AGENT')],
              if (cm.data['question'] == true) ...[const SizedBox(width: 6), Pill('QUESTION', fg: c.warning, bg: c.warningWash)],
              const SizedBox(width: 6),
              Text(ago(cm.createdAt), style: context.t(11, color: c.text3)),
            ]),
            const SizedBox(height: 2),
            SelectableText(cm.body, style: context.t(13, height: 1.4)),
          ]),
        ),
      ]),
    );
  }
}

/// One row per repo the task changes: status, agent, diff, merge.
class _ChangeSet extends ConsumerWidget {
  const _ChangeSet({required this.task, required this.changes});
  final Task task;
  final List<ChangeEntry> changes;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final repos = {for (final r in data.reposOf(task.projectId)) r.id: r};
    final sorted = [...changes]..sort((a, b) => (repos[a.repoId]?.mergeStep ?? 0).compareTo(repos[b.repoId]?.mergeStep ?? 0));
    final merged = changes.where((ch) => ch.status == 'merged').length;
    final ready = changes.where((ch) => ch.status == 'ready').length;
    final running = changes.where((ch) => ch.status == 'running').length;
    return Box(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Text('Change set', style: context.t(13, w: FontWeight.w700)),
            const SizedBox(width: 8),
            Expanded(child: Text('${changes.length} repo${changes.length == 1 ? '' : 's'} · $merged merged · $ready ready · $running running', style: context.t(11, color: c.text2))),
          ]),
        ),
        for (var i = 0; i < sorted.length; i++) ...[
          const Hairline(),
          _changeRow(context, ref, sorted[i], repos[sorted[i].repoId], i + 1, data),
        ],
      ]),
    );
  }

  Widget _changeRow(BuildContext context, WidgetRef ref, ChangeEntry ch, Repo? repo, int n, DataSnapshot data) {
    final c = context.c;
    final agent = data.get<AgentProfile>(Kind.agent, ch.agentId);
    final (bg, fg, label) = switch (ch.status) {
      'merged' => (c.successWash, c.success, 'Merged${ch.data['mergedBy'] != null ? ' by ${ch.data['mergedBy']}' : ''}'),
      'ready' => (c.warningWash, c.warning, 'Ready'),
      'running' => (c.successWash, c.success, 'Running'),
      'failed' => (c.dangerWash, c.danger, 'Merge failed'),
      _ => (c.inner, c.text2, 'No changes yet'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Column(children: [
        Row(children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: ch.status == 'merged' ? c.success : Colors.transparent, shape: BoxShape.circle, border: Border.all(color: ch.status == 'merged' ? c.success : fg, width: 1.5)),
            child: ch.status == 'merged' ? const Icon(LucideIcons.check, size: 11, color: Colors.black) : Text('$n', style: context.t(10, w: FontWeight.w700, color: fg)),
          ),
          const SizedBox(width: 10),
          Dot(hexColor(repo?.color), size: 8),
          const SizedBox(width: 6),
          Expanded(child: Text(repo?.name ?? '?', style: context.t(13, w: FontWeight.w600))),
          if (ch.agentId != null) ...[AgentTile(agent: agent, agentId: ch.agentId, size: 14), const SizedBox(width: 10)],
          DiffNums(ch.additions, ch.deletions),
          const SizedBox(width: 10),
          Pill(label, fg: fg, bg: bg, radius: 10),
        ]),
        if (ch.status == 'failed' && ch.checks != null)
          Padding(padding: const EdgeInsets.only(top: 6, left: 30), child: Text(ch.checks!, style: context.t(11, color: c.danger))),
        if (ch.worktreePath != null && ch.status != 'merged')
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 30),
            child: Row(children: [
              Expanded(child: Text('${ch.branch} · ${ch.filesChanged} file${ch.filesChanged == 1 ? '' : 's'}', style: context.t(11, family: mono, color: c.text3))),
              Btn('Diff', small: true, icon: LucideIcons.gitCompare, onTap: () => showDiffDialog(context, ref, ch, repo)),
              const SizedBox(width: 6),
              if (ch.prUrl != null)
                Btn('Open PR', small: true, icon: LucideIcons.externalLink, onTap: () => Process.run('open', [ch.prUrl!]))
              else if (repo?.remoteUrl != null && ch.status == 'ready')
                Btn('Push', small: true, icon: LucideIcons.upload, onTap: () async {
                  try {
                    final res = await ref.read(clientProvider).list(M.changesPush, {'taskId': ch.taskId, 'repoId': ch.repoId});
                    if (!context.mounted || res.isEmpty) return;
                    if (res.first['ok'] != true) {
                      showError(context, '${res.first['error']}');
                    } else if (res.first['url'] != null) {
                      await Process.run('open', [res.first['url'] as String]);
                    }
                  } on RpcError catch (e) {
                    if (context.mounted) showError(context, e.message);
                  }
                }),
              if (ch.status == 'ready') ...[
                const SizedBox(width: 6),
                Btn('Merge ${repo?.name ?? ''}', small: true, onTap: () async {
                  try {
                    final res = await ref.read(clientProvider).list(M.changesMerge, {'taskId': ch.taskId, 'repoId': ch.repoId});
                    if (res.isNotEmpty && res.first['ok'] != true && context.mounted) showError(context, '${res.first['error']}');
                  } on RpcError catch (e) {
                    if (context.mounted) showError(context, e.message);
                  }
                }),
              ],
            ]),
          ),
      ]),
    );
  }
}
