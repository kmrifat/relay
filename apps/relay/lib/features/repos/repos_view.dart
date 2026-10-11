import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../../ui/platform.dart';
import 'repo_dialog.dart';

/// Project repositories (design T11): map, table, how agents see them.
class ReposView extends ConsumerWidget {
  const ReposView({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final project = data.get<Project>(Kind.project, projectId)!;
    final repos = data.reposOf(projectId);
    final tasks = data.tasksOf(projectId);
    final steps = <int, List<Repo>>{};
    for (final r in repos) {
      steps.putIfAbsent(r.mergeStep, () => []).add(r);
    }
    final stepKeys = steps.keys.toList()..sort();

    return Row(children: [
      Expanded(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Row(children: [
            Text('Repo map', style: context.t(13, w: FontWeight.w700)),
            const SizedBox(width: 10),
            Text('lines point to what a repo depends on', style: context.t(11, color: c.text3)),
            const Spacer(),
            Btn('Add repository', icon: LucideIcons.plus, kind: BtnKind.primary, onTap: () => showRepoDialog(context, ref, projectId: projectId)),
          ]),
          const SizedBox(height: 10),
          Box(
            padding: const EdgeInsets.all(16),
            child: repos.isEmpty
                ? SizedBox(height: 120, child: Center(child: Text('No repositories yet. Add the folders this project lives in.', style: context.t(12, color: c.text2))))
                : _RepoMap(repos: repos),
          ),
          const SizedBox(height: 16),
          Box(
            child: Column(children: [
              Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: c.bar, borderRadius: const BorderRadius.vertical(top: Radius.circular(8))),
                child: Row(children: [
                  Expanded(flex: 5, child: Text('Repository', style: context.label)),
                  Expanded(flex: 3, child: Text('Role', style: context.label)),
                  Expanded(flex: 2, child: Text('Base', style: context.label)),
                  Expanded(flex: 4, child: Text('On ${Desk.thisComputer}', style: context.label)),
                  Expanded(flex: 1, child: Text('Tasks', style: context.label)),
                  Expanded(flex: 2, child: Text('Agents', style: context.label)),
                  const SizedBox(width: 24),
                ]),
              ),
              for (var i = 0; i < repos.length; i++) ...[
                if (i > 0) const Hairline(),
                _RepoRow(repo: repos[i], zebra: i.isOdd, openTasks: tasks.where((t) => t.status != TaskStatus.done && t.repoIds.contains(repos[i].id)).length),
              ],
            ]),
          ),
        ]),
      ),
      Container(width: 1, color: c.separator),
      Container(
        width: 320,
        color: c.bar,
        padding: const EdgeInsets.all(18),
        child: ListView(children: [
          Text('How agents see ${project.name}', style: context.t(13, w: FontWeight.w700)),
          Text('Every repo a task touches, in one folder', style: context.t(11, color: c.text2)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('~/…/workspaces/${project.key.toLowerCase()}/${project.key.toLowerCase()}-N/', style: context.t(11, family: mono)),
              for (final r in repos) Text('  ├ ${r.name.padRight(9)} worktree or link', style: context.t(11, family: mono, color: c.text2)),
              Text('  └ PROJECT.md  repo map', style: context.t(11, family: mono, color: c.accentIcon)),
            ]),
          ),
          const SizedBox(height: 8),
          Text('Repos a task changes get their own worktree on the task\'s branch. The rest are linked read-only so the agent can still look things up.',
              style: context.t(11, color: c.text2)),
          const SizedBox(height: 16),
          Text('Merge order', style: context.label),
          const SizedBox(height: 6),
          Box(
            child: Column(children: [
              for (var i = 0; i < stepKeys.length; i++) ...[
                if (i > 0) const Hairline(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(children: [
                    SizedBox(width: 16, child: Text('${i + 1}', style: context.t(11, color: c.text3))),
                    for (final r in steps[stepKeys[i]]!) ...[Dot(hexColor(r.color), size: 8), const SizedBox(width: 5), Text(r.name, style: context.t(12)), const SizedBox(width: 10)],
                  ]),
                ),
              ],
              if (stepKeys.isEmpty) Padding(padding: const EdgeInsets.all(10), child: Text('—', style: context.t(12, color: c.text3))),
            ]),
          ),
          const SizedBox(height: 16),
          Text('Per-repo rules', style: context.label),
          const SizedBox(height: 6),
          for (final r in repos) ...[
            if (r.testCommand != null) _rule(context, hexColor(r.color), '${r.name}: ${r.testCommand} must pass'),
            if (r.contractPaths.isNotEmpty) _rule(context, hexColor(r.color), '${r.name}: contract ${r.contractPaths.join(', ')}'),
            if (r.agentPolicy == 'ask') _rule(context, c.warning, '${r.name}: agents ask before each run'),
          ],
        ]),
      ),
    ]);
  }

  Widget _rule(BuildContext context, Color color, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 5), child: Dot(color, size: 6)),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: context.t(12))),
    ]),
  );
}

class _RepoRow extends ConsumerWidget {
  const _RepoRow({required this.repo, required this.zebra, required this.openTasks});
  final Repo repo;
  final bool zebra;
  final int openTasks;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final path = repo.data['localPath'] as String?;
    final cloned = path != null && repo.data['cloned'] != false;
    final agentIds = <String>{
      for (final ch in data.all<ChangeEntry>(Kind.change))
        if (ch.repoId == repo.id && ch.agentId != null) ch.agentId!,
    };
    return Container(
      height: 46,
      color: zebra ? c.zebra : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: Row(children: [
            Container(width: 5, height: 28, decoration: BoxDecoration(color: hexColor(repo.color), borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 10),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(repo.name, style: context.t(13, w: FontWeight.w600)),
                Text(repo.remoteUrl ?? 'no remote', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10, family: mono, color: c.text3)),
              ]),
            ),
          ]),
        ),
        Expanded(flex: 3, child: Text([repo.stack, repo.role].where((s) => s.isNotEmpty).join(' · '), style: context.t(12))),
        Expanded(flex: 2, child: Text(repo.baseBranch, style: context.t(12, family: mono, color: c.text2))),
        Expanded(
          flex: 4,
          child: cloned
              ? Row(children: [
                  Icon(LucideIcons.check, size: 12, color: c.success),
                  const SizedBox(width: 6),
                  Expanded(child: Text(Desk.tilde(path), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono, color: c.text2))),
                ])
              : Row(children: [
                  Btn('Clone', small: true, icon: LucideIcons.download, onTap: repo.remoteUrl == null ? null : () => ref.read(clientProvider).call(M.reposClone, {'id': repo.id})),
                  const SizedBox(width: 6),
                  Text('not on ${Desk.thisComputer}', style: context.t(11, color: c.text3)),
                ]),
        ),
        Expanded(flex: 1, child: Text('$openTasks', style: context.t(12))),
        Expanded(
          flex: 2,
          child: repo.agentPolicy == 'ask'
              ? Row(children: [Icon(LucideIcons.lock, size: 12, color: c.warning), const SizedBox(width: 4), Text('ask first', style: context.t(11, color: c.warning))])
              : Row(children: [for (final a in agentIds.take(4)) Padding(padding: const EdgeInsets.only(right: 3), child: AgentTile(agent: data.get<AgentProfile>(Kind.agent, a), agentId: a, size: 14))]),
        ),
        Builder(builder: (context) => IconBtn(LucideIcons.ellipsis, onTap: () async {
          final box = context.findRenderObject() as RenderBox;
          final at = box.localToGlobal(Offset(0, box.size.height));
          final choice = await showMenuAt<String>(context, at, [('edit', 'Edit…', LucideIcons.pencil), ('remove', 'Remove from project', LucideIcons.trash2)]);
          if (!context.mounted) return;
          if (choice == 'edit') await showRepoDialog(context, ref, projectId: repo.projectId, repo: repo);
          if (choice == 'remove') await ref.read(clientProvider).call(M.reposRemove, {'id': repo.id});
        })),
      ]),
    );
  }
}

/// Lays repos out in rows by dependency depth and draws the links.
class _RepoMap extends StatelessWidget {
  const _RepoMap({required this.repos});
  final List<Repo> repos;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final r in repos) r.id: r};
    final depth = <String, int>{};
    int d(Repo r, [Set<String>? seen]) {
      if (depth.containsKey(r.id)) return depth[r.id]!;
      final s = seen ?? {};
      if (!s.add(r.id)) return 0;
      final deps = r.dependsOn.where(byId.containsKey).map((x) => d(byId[x]!, s)).toList();
      return depth[r.id] = deps.isEmpty ? 0 : deps.reduce((a, b) => a > b ? a : b) + 1;
    }

    for (final r in repos) {
      d(r);
    }
    final maxDepth = depth.values.fold<int>(0, (a, b) => a > b ? a : b);
    // Dependents on top, foundations (shared) at the bottom, like the design.
    final rows = [for (var i = maxDepth; i >= 0; i--) repos.where((r) => depth[r.id] == i).toList()];
    const boxW = 160.0, boxH = 48.0, gapX = 40.0, gapY = 34.0;
    final width = rows.fold<double>(0, (m, row) => row.length * (boxW + gapX) > m ? row.length * (boxW + gapX) : m);
    final pos = <String, Offset>{};
    for (var y = 0; y < rows.length; y++) {
      final row = rows[y];
      final rowW = row.length * (boxW + gapX) - gapX;
      for (var x = 0; x < row.length; x++) {
        pos[row[x].id] = Offset((width - rowW) / 2 + x * (boxW + gapX), y * (boxH + gapY));
      }
    }
    final height = rows.length * (boxH + gapY) - gapY;
    return Center(
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: _LinkPainter(repos, pos, boxW, boxH, context.c.control),
          child: Stack(children: [
            for (final r in repos)
              Positioned(
                left: pos[r.id]!.dx,
                top: pos[r.id]!.dy,
                width: boxW,
                height: boxH,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(color: context.c.codeBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: hexColor(r.color))),
                  child: Row(children: [
                    Icon(_icon(r), size: 16, color: hexColor(r.color)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, w: FontWeight.w600)),
                        Text([r.stack, r.role].where((s) => s.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10, color: context.c.text3)),
                      ]),
                    ),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  static IconData _icon(Repo r) => switch (r.role.toLowerCase()) {
    'app' => LucideIcons.smartphone,
    'web' => LucideIcons.monitor,
    'api' => LucideIcons.server,
    'worker' => LucideIcons.boxes,
    'shared' => LucideIcons.package,
    'infra' => LucideIcons.cloudCog,
    _ => LucideIcons.folderGit2,
  };
}

class _LinkPainter extends CustomPainter {
  _LinkPainter(this.repos, this.pos, this.w, this.h, this.color);
  final List<Repo> repos;
  final Map<String, Offset> pos;
  final double w, h;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final r in repos) {
      for (final dep in r.dependsOn) {
        final a = pos[r.id], b = pos[dep];
        if (a == null || b == null) continue;
        final from = Offset(a.dx + w / 2, a.dy + h);
        final to = Offset(b.dx + w / 2, b.dy);
        final midY = (from.dy + to.dy) / 2;
        canvas.drawPath(
          Path()
            ..moveTo(from.dx, from.dy)
            ..lineTo(from.dx, midY)
            ..lineTo(to.dx, midY)
            ..lineTo(to.dx, to.dy),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LinkPainter old) => true;
}
