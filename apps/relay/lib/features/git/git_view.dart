import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

const _rowH = 28.0;
const _laneW = 14.0;
const _laneColors = [Color(0xFF4D9BFF), Color(0xFFD97757), Color(0xFFD49BF5), Color(0xFF32D74B), Color(0xFFFFB340), Color(0xFF4D6BFE), Color(0xFFFF6961)];

/// The Git log (design T09).
class GitView extends ConsumerStatefulWidget {
  const GitView({super.key, required this.projectId});
  final String projectId;
  @override
  ConsumerState<GitView> createState() => _GitViewState();
}

class _GitViewState extends ConsumerState<GitView> {
  String? repoId; // null = all repos
  List<Map<String, Object?>> commits = [];
  List<Map<String, Object?>> worktrees = [];
  Map<String, Object?> branches = {};
  Map<String, Object?>? selected;
  Map<String, Object?>? detail;
  String query = '';
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final repos = ref.read(dataProvider).reposOf(widget.projectId);
    repoId = repos.length == 1 ? repos.first.id : null;
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Future<void> load() async {
    final client = ref.read(clientProvider);
    final repos = ref.read(dataProvider).reposOf(widget.projectId).where((r) => r.data['localPath'] != null).toList();
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (repoId == null) {
        final all = <Map<String, Object?>>[];
        for (final r in repos) {
          for (final c in await client.list(M.gitLog, {'path': r.data['localPath'], 'limit': 150})) {
            all.add({...c, 'repo': r.name, 'repoColor': r.color, 'repoPath': r.data['localPath']});
          }
        }
        all.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
        commits = all;
        worktrees = [];
        branches = {};
      } else {
        final r = ref.read(dataProvider).get<Repo>(Kind.repo, repoId)!;
        final path = r.data['localPath'] as String;
        commits = [for (final c in await client.list(M.gitLog, {'path': path, 'limit': 400})) {...c, 'repo': r.name, 'repoColor': r.color, 'repoPath': path}];
        worktrees = await client.list(M.gitWorktrees, {'path': path});
        branches = await client.map(M.gitBranches, {'path': path});
      }
    } on RpcError catch (e) {
      error = e.message;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> select(Map<String, Object?> c) async {
    setState(() {
      selected = c;
      detail = null;
    });
    final d = await ref.read(clientProvider).map(M.gitShow, {'path': c['repoPath'], 'hash': c['hash']});
    if (mounted && selected == c) setState(() => detail = d);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final repos = data.reposOf(widget.projectId);
    final agents = {for (final a in data.agents) a.id: a};
    final shown = query.isEmpty
        ? commits
        : commits.where((x) => '${x['subject']} ${x['hash']} ${x['task'] ?? ''} ${x['author']}'.toLowerCase().contains(query.toLowerCase())).toList();
    final allMode = repoId == null;
    final maxLanes = allMode ? 0 : commits.fold<int>(1, (m, x) => ((x['graph'] as Map?)?['lanes'] as int? ?? 1) > m ? (x['graph'] as Map)['lanes'] as int : m);
    final graphW = allMode ? 0.0 : (maxLanes * _laneW + 12).clamp(40.0, 160.0);

    if (repos.isEmpty) return Center(child: Text('Add a repository under Repos to see its history.', style: context.t(13, color: c.text2)));

    return Row(children: [
      // Branches + worktrees.
      Container(
        width: 230,
        color: c.bar,
        padding: const EdgeInsets.all(10),
        child: ListView(children: [
          Text('Repository', style: context.label),
          const SizedBox(height: 6),
          if (repos.length > 1)
            Hoverable(
              selected: repoId == null,
              onTap: () {
                setState(() => repoId = null);
                load();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(children: [
                  Icon(LucideIcons.boxes, size: 13, color: repoId == null ? Colors.white : c.text2),
                  const SizedBox(width: 8),
                  Text('All repos', style: context.t(12, color: repoId == null ? Colors.white : c.text)),
                ]),
              ),
            ),
          for (final r in repos)
            Hoverable(
              selected: repoId == r.id,
              onTap: r.data['localPath'] == null
                  ? null
                  : () {
                      setState(() => repoId = r.id);
                      load();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(children: [
                  Dot(hexColor(r.color), size: 8),
                  const SizedBox(width: 8),
                  Expanded(child: Text(r.name, style: context.t(12, color: repoId == r.id ? Colors.white : (r.data['localPath'] == null ? c.text3 : c.text)))),
                  Text(r.baseBranch, style: context.t(10, family: mono, color: repoId == r.id ? Colors.white70 : c.text3)),
                ]),
              ),
            ),
          if (!allMode) ...[
            const SizedBox(height: 14),
            Text('Local branches', style: context.label),
            const SizedBox(height: 6),
            for (final b in (branches['local'] as List? ?? const []).cast<String>())
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(children: [
                  Dot(b == branches['current'] ? c.accentIcon : c.text3, size: 7),
                  const SizedBox(width: 8),
                  Expanded(child: Text(b, style: context.t(12, w: b == branches['current'] ? FontWeight.w600 : FontWeight.w400))),
                  if (b == branches['current']) Icon(LucideIcons.check, size: 11, color: c.accentIcon),
                ]),
              ),
            const SizedBox(height: 14),
            Text('Agent worktrees', style: context.label),
            const SizedBox(height: 6),
            for (final w in worktrees.skip(1))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(LucideIcons.folderGit2, size: 12, color: c.text2),
                    const SizedBox(width: 6),
                    Expanded(child: Text(w['branch'] as String? ?? '(detached)', style: context.t(12, family: mono))),
                  ]),
                  Text(_worktreeNote(data, w), style: context.t(10, color: c.text3)),
                ]),
              ),
            if (worktrees.length <= 1) Padding(padding: const EdgeInsets.all(8), child: Text('None', style: context.t(12, color: c.text3))),
          ],
        ]),
      ),
      Container(width: 1, color: c.separator),
      // Log.
      Expanded(
        child: Column(children: [
          Container(
            height: 34,
            color: c.bar,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(children: [
              SizedBox(width: 220, height: 24, child: FieldInput(hint: 'Text, hash or task (KT-88)', size: 11, onChanged: (v) => setState(() => query = v))),
              const SizedBox(width: 8),
              IconBtn(LucideIcons.refreshCw, size: 13, tooltip: 'Reload', onTap: load),
              if (loading) const Padding(padding: EdgeInsets.only(left: 8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))),
              const Spacer(),
              if (allMode) Text('Newest first across repos', style: context.t(11, color: c.text3)),
            ]),
          ),
          Container(
            height: 24,
            color: c.bar,
            padding: const EdgeInsets.only(right: 8),
            child: Row(children: [
              SizedBox(width: allMode ? 80 : graphW, child: Padding(padding: const EdgeInsets.only(left: 10), child: Text(allMode ? 'Repo' : '', style: context.label))),
              Expanded(child: Text('Commit', style: context.label)),
              SizedBox(width: 150, child: Text('Author', style: context.label)),
              SizedBox(width: 74, child: Text('Date', style: context.label)),
              SizedBox(width: 62, child: Text('Hash', style: context.label)),
            ]),
          ),
          const Hairline(),
          Expanded(
            child: error != null
                ? Center(child: Text(error!, style: context.t(12, color: c.danger)))
                : ListView.builder(
                    itemExtent: _rowH,
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final x = shown[i];
                      final sel = selected?['hash'] == x['hash'];
                      final agent = agents[x['agent']];
                      final refs = ((x['refs'] as List?) ?? const []).cast<String>();
                      return GestureDetector(
                        onTap: () => select(x),
                        child: Container(
                          color: sel ? c.accent : (i.isOdd ? c.zebra : Colors.transparent),
                          padding: const EdgeInsets.only(right: 8),
                          child: Row(children: [
                            if (allMode)
                              SizedBox(width: 80, child: Padding(padding: const EdgeInsets.only(left: 10), child: Align(alignment: Alignment.centerLeft, child: Pill(x['repo'] as String, fg: sel ? Colors.white : hexColor(x['repoColor'] as String?), bg: sel ? Colors.white24 : hexColor(x['repoColor'] as String?).withValues(alpha: 0.18)))))
                            else
                              SizedBox(width: graphW, height: _rowH, child: CustomPaint(painter: _GraphPainter(x['graph'] as Map?, highlight: sel))),
                            Expanded(
                              child: Row(children: [
                                for (final r in refs.take(3))
                                  Padding(padding: const EdgeInsets.only(right: 5), child: Pill(r.replaceFirst('HEAD -> ', ''), fg: sel ? Colors.white : c.accentIcon, bg: sel ? Colors.white24 : c.accent.withValues(alpha: 0.18))),
                                Flexible(child: Text(x['subject'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: sel ? Colors.white : c.text, w: (x['parents'] as List?)?.length == 2 ? FontWeight.w600 : FontWeight.w400))),
                                if (x['task'] != null) ...[const SizedBox(width: 6), Pill(x['task'] as String, mono: true, fg: sel ? Colors.white : null, bg: sel ? Colors.white24 : null)],
                              ]),
                            ),
                            SizedBox(
                              width: 150,
                              child: Row(children: [
                                if (x['agent'] != null) AgentTile(agent: agent, agentId: x['agent'] as String, size: 14) else Avatar(x['author'] as String? ?? '?', size: 14, color: c.accent),
                                const SizedBox(width: 6),
                                Expanded(child: Text(agent?.name ?? (x['author'] as String? ?? ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: sel ? Colors.white : c.text))),
                              ]),
                            ),
                            SizedBox(width: 74, child: Text(ago(DateTime.tryParse(x['date'] as String? ?? '')), style: context.t(12, color: sel ? Colors.white : c.text2))),
                            SizedBox(width: 62, child: Text((x['hash'] as String).substring(0, 7), style: context.t(11, family: mono, color: sel ? Colors.white : c.text3))),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
      Container(width: 1, color: c.separator),
      // Details.
      Container(
        width: 330,
        color: c.bar,
        padding: const EdgeInsets.all(16),
        child: selected == null
            ? Center(child: Text('Select a commit', style: context.t(12, color: c.text3)))
            : ListView(children: [
                Text(selected!['subject'] as String? ?? '', style: context.t(14, w: FontWeight.w700)),
                const SizedBox(height: 12),
                Box(
                  child: Column(children: [
                    FieldRow('Author', Row(children: [
                      if (selected!['agent'] != null) ...[AgentTile(agent: agents[selected!['agent']], agentId: selected!['agent'] as String, size: 14), const SizedBox(width: 6)],
                      Expanded(child: Text(selected!['agent'] != null ? '${agents[selected!['agent']]?.name ?? selected!['agent']} for ${selected!['author']}' : selected!['author'] as String, style: context.t(12))),
                    ]), labelWidth: 64),
                    const Hairline(),
                    FieldRow('Hash', SelectableText((selected!['hash'] as String).substring(0, 12), style: context.t(12, family: mono)), labelWidth: 64),
                    if (selected!['task'] != null) ...[const Hairline(), FieldRow('Task', Text(selected!['task'] as String, style: context.t(12, family: mono, color: c.accentIcon)), labelWidth: 64)],
                    const Hairline(),
                    FieldRow('Repo', Text(selected!['repo'] as String? ?? '', style: context.t(12)), labelWidth: 64),
                    const Hairline(),
                    FieldRow('Date', Text(DateTime.tryParse(selected!['date'] as String)?.toLocal().toString().substring(0, 16) ?? '', style: context.t(12)), labelWidth: 64),
                  ]),
                ),
                const SizedBox(height: 14),
                if (detail == null)
                  const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)))
                else ...[
                  if ((detail!['body'] as String).split('\n').length > 1) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(8)),
                      child: SelectableText(detail!['body'] as String, style: context.t(12, height: 1.4)),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Text('Changed files · ${(detail!['files'] as List).length}', style: context.label),
                  const SizedBox(height: 6),
                  for (final f in (detail!['files'] as List).cast<Map>())
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Icon(LucideIcons.fileCode, size: 12, color: c.accentIcon),
                        const SizedBox(width: 6),
                        Expanded(child: Text(f['path'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: c.accentIcon))),
                        DiffNums(f['additions'] as int, f['deletions'] as int),
                      ]),
                    ),
                  const SizedBox(height: 14),
                  Row(children: [Btn('Copy hash', icon: LucideIcons.copy, onTap: () => copyText(selected!['hash'] as String))]),
                ],
              ]),
      ),
    ]);
  }

  String _worktreeNote(DataSnapshot data, Map<String, Object?> w) {
    final path = w['path'] as String;
    for (final ch in data.all<ChangeEntry>(Kind.change)) {
      if (ch.worktreePath == path || path.endsWith(ch.worktreePath ?? '\u0000')) {
        final agent = data.get<AgentProfile>(Kind.agent, ch.agentId);
        return '${agent?.name ?? 'Relay'} · ${ch.status}';
      }
    }
    return path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~');
  }
}

/// Draws one row of the commit graph: lines to the next row, then the dot.
class _GraphPainter extends CustomPainter {
  _GraphPainter(this.graph, {this.highlight = false});
  final Map? graph;
  final bool highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final g = graph;
    if (g == null) return;
    final lane = g['lane'] as int;
    double x(int l) => 10 + l * _laneW;
    final mid = size.height / 2;
    final paint = Paint()
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final s in (g['segments'] as List)) {
      final seg = (s as List).cast<int>();
      final from = seg[0], to = seg[1], color = seg[2];
      paint.color = _laneColors[color % _laneColors.length];
      if (from == lane && to != lane) {
        // From this commit's dot down-sideways into another lane.
        final path = Path()
          ..moveTo(x(from), mid)
          ..cubicTo(x(from), size.height, x(to), mid, x(to), size.height + 1);
        canvas.drawPath(path, paint);
      } else if (from == to) {
        canvas.drawLine(Offset(x(from), from == lane ? mid : -1), Offset(x(to), size.height + 1), paint);
      } else {
        final path = Path()
          ..moveTo(x(from), -1)
          ..cubicTo(x(from), mid, x(to), mid, x(to), size.height + 1);
        canvas.drawPath(path, paint);
      }
    }
    // The incoming line from above into the dot.
    paint.color = _laneColors[lane % _laneColors.length];
    canvas.drawLine(Offset(x(lane), -1), Offset(x(lane), mid), paint..color = paint.color.withValues(alpha: 0.9));
    canvas.drawCircle(Offset(x(lane), mid), 4.5, Paint()..color = _laneColors[lane % _laneColors.length]);
    if (highlight) canvas.drawCircle(Offset(x(lane), mid), 4.5, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_GraphPainter old) => old.graph != graph || old.highlight != highlight;
}
