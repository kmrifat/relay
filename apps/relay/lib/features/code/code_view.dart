import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'terminal_panel.dart';

/// A folder Relay can open: a repo's own checkout or a task's worktree.
class CodeRoot {
  CodeRoot(this.label, this.path, {this.agentId, this.taskId, this.runId, this.color});
  final String label;
  final String path;
  final String? agentId;
  final String? taskId;
  final String? runId;
  final String? color;
}

List<CodeRoot> codeRoots(DataSnapshot data, String projectId) {
  final roots = <CodeRoot>[];
  final repos = data.reposOf(projectId);
  for (final r in repos) {
    final path = r.data['localPath'] as String?;
    if (path != null) roots.add(CodeRoot('${r.name} · ${r.baseBranch}', path, color: r.color));
  }
  for (final t in data.tasksOf(projectId)) {
    for (final ch in data.changesOf(t.id)) {
      if (ch.worktreePath == null || ch.status == 'merged') continue;
      final repo = data.get<Repo>(Kind.repo, ch.repoId);
      final run = data.activeRun(t);
      roots.add(CodeRoot('${data.keyOf(t)} · ${repo?.name ?? ''}', ch.worktreePath!,
          agentId: ch.agentId, taskId: t.id, runId: run?.id, color: repo?.color));
    }
  }
  return roots;
}

class CodeView extends ConsumerStatefulWidget {
  const CodeView({super.key, required this.projectId, this.initialRoot});
  final String projectId;
  final String? initialRoot;
  @override
  ConsumerState<CodeView> createState() => _CodeViewState();
}

class _OpenFile {
  _OpenFile(this.path, this.controller);
  final String path;
  final CodeLineEditingController controller;
  bool dirty = false;
}

class _CodeViewState extends ConsumerState<CodeView> {
  CodeRoot? root;
  List<String> files = [];
  Map<String, String> status = {};
  final expanded = <String>{''};
  final open = <_OpenFile>[];
  int active = -1;
  String? takeoverTerm;
  int termKey = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final roots = codeRoots(ref.read(dataProvider), widget.projectId);
      if (roots.isNotEmpty) pick(roots.firstWhere((r) => r.path == widget.initialRoot, orElse: () => roots.first));
    });
  }

  Future<void> pick(CodeRoot r) async {
    final client = ref.read(clientProvider);
    setState(() {
      root = r;
      files = [];
      open.clear();
      active = -1;
      takeoverTerm = null;
      termKey++;
    });
    try {
      final list = await client.map(M.fsList, {'path': r.path});
      final st = await client.list(M.gitStatus, {'path': r.path});
      if (!mounted || root != r) return;
      setState(() {
        files = (list['files'] as List).cast<String>();
        status = {for (final s in st) s['path'] as String: s['letter'] as String};
      });
    } on RpcError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> openFile(String rel) async {
    final i = open.indexWhere((f) => f.path == rel);
    if (i >= 0) return setState(() => active = i);
    final res = await ref.read(clientProvider).map(M.fsRead, {'path': p.join(root!.path, rel)});
    final text = res['binary'] == true
        ? '(binary file, ${res['size']} bytes)'
        : (res['tooLarge'] == true ? '(file too large to open here: ${res['size']} bytes)' : res['text'] as String);
    final f = _OpenFile(rel, CodeLineEditingController.fromText(text));
    f.controller.addListener(() {
      if (!f.dirty) setState(() => f.dirty = true);
    });
    setState(() {
      open.add(f);
      active = open.length - 1;
    });
  }

  Future<void> save() async {
    if (active < 0) return;
    final f = open[active];
    await ref.read(clientProvider).call(M.fsWrite, {'path': p.join(root!.path, f.path), 'text': f.controller.text});
    setState(() => f.dirty = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final roots = codeRoots(data, widget.projectId);
    if (roots.isEmpty) return Center(child: Text('Add a repository under Repos to browse its code.', style: context.t(13, color: c.text2)));
    final run = root?.runId == null ? null : data.get<Run>(Kind.run, root!.runId);
    final agent = data.get<AgentProfile>(Kind.agent, root?.agentId);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.keyS, meta: true): save},
      child: Row(children: [
        // Explorer.
        Container(
          width: 250,
          color: c.bar,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Builder(builder: (context) => Hoverable(
                onTap: () async {
                  final box = context.findRenderObject() as RenderBox;
                  final at = box.localToGlobal(Offset(0, box.size.height));
                  final chosen = await showMenuAt<CodeRoot>(context, at, [for (final r in roots) (r, r.label, r.taskId == null ? LucideIcons.folder : LucideIcons.folderGit2)]);
                  if (chosen != null) pick(chosen);
                },
                child: Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(color: c.inner, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    if (root?.agentId != null) ...[AgentTile(agent: agent, agentId: root!.agentId, size: 14), const SizedBox(width: 6)],
                    Expanded(child: Text(root?.label ?? 'Choose a folder', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, family: mono))),
                    if (run != null && RunStatus.isActive(run.status)) ...[Dot(c.success, size: 6), const SizedBox(width: 6)],
                    Icon(LucideIcons.chevronsUpDown, size: 12, color: c.accentIcon),
                  ]),
                ),
              )),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 4),
              child: Row(children: [
                Expanded(child: Text('EXPLORER', style: context.label)),
                IconBtn(LucideIcons.refreshCw, size: 12, tooltip: 'Refresh', onTap: root == null ? null : () => pick(root!)),
              ]),
            ),
            Expanded(child: _tree(context)),
          ]),
        ),
        Container(width: 1, color: c.separator),
        // Editor + panel.
        Expanded(
          child: Column(children: [
            Container(
              height: 34,
              color: c.bar,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (var i = 0; i < open.length; i++)
                  GestureDetector(
                    onTap: () => setState(() => active = i),
                    child: Container(
                      color: i == active ? c.window : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        Icon(LucideIcons.fileCode, size: 13, color: c.accentIcon),
                        const SizedBox(width: 6),
                        Text(p.basename(open[i].path), style: context.t(12, color: i == active ? c.text : c.text2)),
                        const SizedBox(width: 6),
                        open[i].dirty
                            ? Dot(c.text2, size: 7)
                            : IconBtn(LucideIcons.x, size: 11, onTap: () => setState(() {
                                open.removeAt(i);
                                active = open.isEmpty ? -1 : active.clamp(0, open.length - 1);
                              })),
                      ]),
                    ),
                  ),
              ]),
            ),
            Container(
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.centerLeft,
              child: Row(children: [
                Expanded(child: Text(active < 0 ? '' : open[active].path.split('/').join(' › '), style: context.t(11, color: c.text2))),
                if (active >= 0 && status[open[active].path] != null)
                  Text(status[open[active].path] == 'U' ? 'new file' : 'changed on this branch', style: context.t(11, color: c.text2)),
              ]),
            ),
            Expanded(
              child: active < 0
                  ? Center(child: Text('Open a file from the explorer. ⌘S saves.', style: context.t(12, color: c.text3)))
                  : CodeEditor(
                      key: ValueKey(open[active].path),
                      controller: open[active].controller,
                      wordWrap: false,
                      style: CodeEditorStyle(
                        fontSize: 12.5,
                        fontFamily: mono,
                        fontHeight: 1.5,
                        textColor: c.text,
                        backgroundColor: c.window,
                        selectionColor: c.accent.withValues(alpha: 0.35),
                        cursorColor: c.accentIcon,
                        cursorLineColor: c.text.withValues(alpha: 0.04),
                        codeTheme: CodeHighlightTheme(
                          languages: {_lang(open[active].path): CodeHighlightThemeMode(mode: _mode(open[active].path))},
                          theme: context.isDark ? atomOneDarkTheme : atomOneLightTheme,
                        ),
                      ),
                      indicatorBuilder: (context, editing, chunk, notifier) => Row(children: [
                        DefaultCodeLineNumber(
                          controller: editing,
                          notifier: notifier,
                          textStyle: TextStyle(color: c.text3, fontSize: 12, fontFamily: mono),
                          focusedTextStyle: TextStyle(color: c.text, fontSize: 12, fontFamily: mono),
                        ),
                        const SizedBox(width: 10),
                      ]),
                    ),
            ),
            Container(height: 1, color: c.inner),
            SizedBox(height: 270, child: root == null ? const SizedBox() : _panel(context, run, agent)),
          ]),
        ),
      ]),
    );
  }

  Widget _panel(BuildContext context, Run? run, AgentProfile? agent) {
    final c = context.c;
    final client = ref.read(clientProvider);
    return Column(children: [
      Container(
        height: 30,
        color: c.bar,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(children: [
          Text('TERMINAL', style: context.t(11, w: FontWeight.w700)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(takeoverTerm != null ? '· you took over from ${agent?.name ?? 'the agent'}' : '· zsh in ${root!.path.replaceFirst(RegExp(r'^/Users/[^/]+'), '~')}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text3)),
          ),
          IconBtn(LucideIcons.plus, size: 13, tooltip: 'New terminal', onTap: () => setState(() {
            takeoverTerm = null;
            termKey++;
          })),
        ]),
      ),
      Expanded(
        child: Row(children: [
          Expanded(
            child: Container(
              color: c.codeBg,
              child: RelayTerminal(key: ValueKey('term-$termKey-${root!.path}'), cwd: root!.path, termId: takeoverTerm),
            ),
          ),
          if (run != null) ...[
            Container(width: 1, color: c.inner),
            SizedBox(
              width: 420,
              child: Container(
                color: context.isDark ? const Color(0xFF1F1A18) : c.box,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                    child: Row(children: [
                      AgentTile(agent: agent, agentId: run.agentId, size: 14),
                      const SizedBox(width: 6),
                      Expanded(child: Text('${agent?.name ?? run.agentId} · ${RunStatus.isActive(run.status) ? 'watching' : run.status}', style: context.t(11, w: FontWeight.w600))),
                      if (run.status == RunStatus.paused && takeoverTerm != null)
                        Btn('Hand back', small: true, kind: BtnKind.primary, onTap: () async {
                          await client.call(M.runsResume, {'runId': run.id});
                          try {
                            await client.call(M.runsSteer, {'runId': run.id, 'text': 'I made some changes by hand in the workspace. Check `git status` and continue.'});
                          } on RpcError catch (_) {}
                          setState(() => takeoverTerm = null);
                        })
                      else if (RunStatus.isActive(run.status)) ...[
                        Btn(run.status == RunStatus.paused ? 'Resume' : 'Pause', small: true, onTap: () => client.call(run.status == RunStatus.paused ? M.runsResume : M.runsPause, {'runId': run.id})),
                        const SizedBox(width: 6),
                        Btn('Take over', small: true, kind: BtnKind.primary, icon: LucideIcons.hand, onTap: () async {
                          final id = await client.call<String>(M.termTakeover, {'runId': run.id});
                          setState(() {
                            takeoverTerm = id;
                            termKey++;
                          });
                        }),
                      ],
                    ]),
                  ),
                  Expanded(child: _AgentMirror(runId: run.id)),
                ]),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  Widget _tree(BuildContext context) {
    final c = context.c;
    // Build rows for expanded folders only.
    final rows = <(String path, String name, int depth, bool dir)>[];
    final children = <String, Set<String>>{};
    for (final f in files) {
      final parts = f.split('/');
      for (var i = 0; i < parts.length; i++) {
        final parent = parts.take(i).join('/');
        final self = parts.take(i + 1).join('/');
        (children[parent] ??= {}).add(self);
      }
    }
    final fileSet = files.toSet();
    void walk(String dir, int depth) {
      final kids = (children[dir] ?? {}).toList()
        ..sort((a, b) {
          final ad = !fileSet.contains(a), bd = !fileSet.contains(b);
          if (ad != bd) return ad ? -1 : 1;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });
      for (final k in kids) {
        final isDir = !fileSet.contains(k);
        rows.add((k, k.split('/').last, depth, isDir));
        if (isDir && expanded.contains(k)) walk(k, depth + 1);
      }
    }

    walk('', 0);
    final changedDirs = <String>{for (final s in status.keys) for (var i = 1; i < s.split('/').length; i++) s.split('/').take(i).join('/')};
    final activePath = active >= 0 ? open[active].path : null;
    return ListView.builder(
      itemExtent: 22,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (path, name, depth, dir) = rows[i];
        final letter = status[path];
        final color = switch (letter) { 'U' || 'A' => const Color(0xFF73C991), 'M' || 'R' => const Color(0xFFE2C08D), 'D' => c.danger, _ => c.text };
        final sel = path == activePath;
        return GestureDetector(
          onTap: () => dir ? setState(() => expanded.contains(path) ? expanded.remove(path) : expanded.add(path)) : openFile(path),
          child: Container(
            color: sel ? c.accent : Colors.transparent,
            padding: EdgeInsets.only(left: 10.0 + depth * 14, right: 10),
            child: Row(children: [
              if (dir) Icon(expanded.contains(path) ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 11, color: c.text2) else const SizedBox(width: 11),
              const SizedBox(width: 4),
              Icon(dir ? (expanded.contains(path) ? LucideIcons.folderOpen : LucideIcons.folder) : LucideIcons.fileCode, size: 13, color: sel ? Colors.white : (dir ? c.accentIcon : (letter != null ? color : c.accentIcon))),
              const SizedBox(width: 6),
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: sel ? Colors.white : (letter != null ? color : c.text)))),
              if (letter != null) Text(letter, style: context.t(11, w: FontWeight.w700, color: sel ? Colors.white : color)),
              if (dir && changedDirs.contains(path)) Dot(const Color(0xFFE2C08D), size: 6),
            ]),
          ),
        );
      },
    );
  }

  static String _lang(String path) => p.extension(path).replaceFirst('.', '');

  static Mode _mode(String path) => switch (p.extension(path)) {
    '.dart' => langDart,
    '.ts' || '.tsx' || '.js' || '.jsx' || '.mjs' => langTypescript,
    '.json' => langJson,
    '.yaml' || '.yml' => langYaml,
    '.md' => langMarkdown,
    '.php' => langPhp,
    '.py' => langPython,
    '.go' => langGo,
    '.rs' => langRust,
    '.swift' => langSwift,
    '.kt' || '.kts' => langKotlin,
    '.java' => langJava,
    '.sql' => langSql,
    '.css' || '.scss' => langCss,
    '.xml' || '.html' || '.plist' => langXml,
    '.sh' || '.zsh' || '.bash' => langBash,
    _ => langMarkdown,
  };
}

/// The agent's run as terminal-style lines (a read-only mirror).
class _AgentMirror extends ConsumerWidget {
  const _AgentMirror({required this.runId});
  final String runId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final events = ref.watch(runEventsProvider(runId));
    final shown = events.where((e) => e.type == RunEventType.toolUse || e.type == RunEventType.toolResult || e.type == RunEventType.message || e.type == RunEventType.permission).toList();
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      itemCount: shown.length,
      itemBuilder: (context, i) {
        final e = shown[shown.length - 1 - i];
        final (prefix, color, text) = switch (e.type) {
          RunEventType.toolUse => ('● ', c.success, '${e.data['tool']}(${e.data['summary']})'),
          RunEventType.toolResult => ('  └ ', c.text3, '${e.data['summary'] ?? ''}'),
          RunEventType.permission => ('? ', c.warning, 'Asks to run ${e.data['tool']}: ${e.data['summary']}'),
          _ => ('', c.text, '${e.data['text'] ?? ''}'),
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text('$prefix$text', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.t(11.5, family: mono, color: color, height: 1.35)),
        );
      },
    );
  }
}
