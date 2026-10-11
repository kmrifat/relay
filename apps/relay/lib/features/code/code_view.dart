
import 'package:flutter/gestures.dart';
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
import '../../ui/platform.dart';
import '../task/new_task_sheet.dart';
import 'code_session.dart';
import 'term_hub.dart';
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
    final changes = data.changesOf(t.id).where((ch) => ch.worktreePath != null && ch.status != 'merged').toList();
    if (repos.length > 1 && changes.isNotEmpty) {
      roots.add(CodeRoot('${data.keyOf(t)} · workspace (all repos)', p.dirname(changes.first.worktreePath!),
          agentId: changes.first.agentId, taskId: t.id, runId: data.activeRun(t)?.id));
    }
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

class _CodeViewState extends ConsumerState<CodeView> {
  CodeSession get session => ref.read(codeSessionProvider(widget.projectId));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guard(() async {
      final roots = codeRoots(ref.read(dataProvider), widget.projectId);
      final s = session;
      if (!s.restored) {
        await s.restore([for (final r in roots) r.path], prefer: widget.initialRoot);
      } else if (widget.initialRoot != null && widget.initialRoot != s.rootPath) {
        final r = roots.where((r) => r.path == widget.initialRoot).firstOrNull;
        if (r != null) await _pick(r);
      }
      if (s.panelOpen && s.terms.isEmpty) await s.newTerminal(Desk.shellName);
    }));
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
    } on RpcError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Save / Don't save / Cancel for unsaved [names]; true to go ahead.
  Future<bool> _resolveUnsaved(List<int> indexes) async {
    final s = session;
    final dirty = indexes.where((i) => s.files[i].dirty).toList();
    if (dirty.isEmpty) return true;
    final names = dirty.map((i) => p.basename(s.files[i].path)).join(', ');
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(dirty.length == 1 ? 'Save changes to $names?' : 'Save changes to ${dirty.length} files?', style: context.t(14, w: FontWeight.w600)),
        content: Text(dirty.length == 1 ? 'Your changes are lost if you don\'t save them.' : '$names have unsaved changes.', style: context.t(12, color: context.c.text2)),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(context)),
          Btn('Don\'t save', onTap: () => Navigator.pop(context, 'discard')),
          Btn('Save', kind: BtnKind.primary, onTap: () => Navigator.pop(context, 'save')),
        ],
      ),
    );
    if (answer == null) return false;
    if (answer == 'save') {
      for (final i in dirty) {
        await s.save(i);
      }
    }
    return true;
  }

  Future<void> _closeFile(int i) => _guard(() async {
    if (await _resolveUnsaved([i])) session.closeFile(i);
  });

  Future<void> _pick(CodeRoot r) => _guard(() async {
    final s = session;
    if (r.path != s.rootPath && !await _resolveUnsaved([for (var i = 0; i < s.files.length; i++) i])) return;
    await s.pick(r.path);
  });

  Future<void> _togglePanel() async {
    final s = session;
    s.togglePanel();
    if (s.panelOpen && s.terms.isEmpty) await _guard(() => s.newTerminal(Desk.shellName));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(codeSessionProvider(widget.projectId));
    // Watched here; the builder below reads them (it runs outside this build).
    ref.watch(dataProvider);
    ref.watch(termHubProvider);
    ref.watch(savedCommandsProvider); // starts loading them
    return ListenableBuilder(listenable: s, builder: (context, _) => _build(context, s));
  }

  Widget _build(BuildContext context, CodeSession s) {
    final c = context.c;
    final data = ref.read(dataProvider);
    final roots = codeRoots(data, widget.projectId);
    if (roots.isEmpty) return Center(child: Text('Add a repository under Repos to browse its code.', style: context.t(13, color: c.text2)));
    final root = roots.where((r) => r.path == s.rootPath).firstOrNull;
    final run = root?.runId == null ? null : data.get<Run>(Kind.run, root!.runId);
    final agent = data.get<AgentProfile>(Kind.agent, root?.agentId);
    final file = s.activeFile;

    return CallbackShortcuts(
      bindings: {
        Desk.key(LogicalKeyboardKey.keyS): () => _guard(() => s.save()),
        Desk.key(LogicalKeyboardKey.keyW): () {
          if (s.active >= 0) _closeFile(s.active);
        },
        const SingleActivator(LogicalKeyboardKey.backquote, control: true): _togglePanel,
      },
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
                  if (chosen != null) _pick(chosen);
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
                Builder(builder: (context) => IconBtn(LucideIcons.externalLink, size: 12, tooltip: 'Open in…', onTap: root == null ? null : () async {
                  final box = context.findRenderObject() as RenderBox;
                  final app = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
                    for (final e in Desk.editors) (e, e == 'Visual Studio Code' ? 'VS Code' : e, null),
                    (Desk.fileManager, Desk.fileManager, null),
                  ]);
                  if (app == null) return;
                  final r = await Desk.openIn(app, root.path);
                  if (r.exitCode != 0 && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$app is not installed')));
                  }
                })),
                IconBtn(LucideIcons.refreshCw, size: 12, tooltip: 'Refresh', onTap: root == null ? null : () => _guard(s.refresh)),
              ]),
            ),
            Expanded(child: _tree(context, s)),
          ]),
        ),
        Container(width: 1, color: c.separator),
        // Editor + panel.
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final panelHeight = s.panelHeight.clamp(120.0, (box.maxHeight - 160).clamp(120.0, double.infinity));
            return Column(children: [
              Container(
                height: 34,
                color: c.bar,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (var i = 0; i < s.files.length; i++)
                    _EditorTab(
                      name: p.basename(s.files[i].path),
                      active: i == s.active,
                      dirty: s.files[i].dirty,
                      onTap: () => s.select(i),
                      onClose: () => _closeFile(i),
                    ),
                ]),
              ),
              Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.centerLeft,
                child: Row(children: [
                  Expanded(child: Text(file == null ? '' : file.path.split('/').join(' › '), style: context.t(11, color: c.text2))),
                  if (file != null && s.status[file.path] != null)
                    Text(s.status[file.path] == 'U' ? 'new file' : 'changed on this branch', style: context.t(11, color: c.text2)),
                  if (file != null) ...[
                    const SizedBox(width: 10),
                    Btn('New task from selection', small: true, kind: BtnKind.plain, icon: LucideIcons.plus, onTap: () {
                      final sel = file.controller.selectedText;
                      final line = file.controller.selection.startIndex + 1;
                      final snippet = sel.isEmpty ? '' : '\n\n```\n${sel.length > 2000 ? sel.substring(0, 2000) : sel}\n```';
                      showNewTaskSheet(context, ref, brief: 'In `${file.path}` around line $line:$snippet\n\n');
                    }),
                  ],
                ]),
              ),
              Expanded(
                child: file == null
                    ? Center(child: Text('Open a file from the explorer. ${Desk.isMac ? '⌘S saves, ⌘W closes' : 'Ctrl+S saves, Ctrl+W closes'}.', style: context.t(12, color: c.text3)))
                    : CodeEditor(
                        key: ValueKey('${s.rootPath}/${file.path}'),
                        controller: file.controller,
                        readOnly: file.readOnly,
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
                            languages: {_lang(file.path): CodeHighlightThemeMode(mode: _mode(file.path))},
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
              // Drag to resize the panel.
              MouseRegion(
                cursor: s.panelOpen ? SystemMouseCursors.resizeRow : MouseCursor.defer,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: s.panelOpen ? (d) => s.resizePanel((panelHeight - d.delta.dy).clamp(120.0, box.maxHeight - 160)) : null,
                  child: Container(height: 5, alignment: Alignment.bottomCenter, child: Container(height: 1, color: c.inner)),
                ),
              ),
              SizedBox(height: s.panelOpen ? panelHeight : 30, child: root == null ? const SizedBox() : _panel(context, s, root, run, agent)),
            ]);
          }),
        ),
      ]),
    );
  }

  Widget _panel(BuildContext context, CodeSession s, CodeRoot root, Run? run, AgentProfile? agent) {
    final c = context.c;
    final client = ref.read(clientProvider);
    final hub = ref.read(termHubProvider);
    final tab = s.activeTab;
    final term = tab == null ? null : hub[tab.id];
    final takeover = run == null ? null : s.takeoverFor(run.id);
    return Column(children: [
      Container(
        height: 30,
        color: c.bar,
        padding: const EdgeInsets.only(left: 14, right: 8),
        child: Row(children: [
          GestureDetector(onTap: _togglePanel, child: Text('TERMINAL', style: context.t(11, w: FontWeight.w700))),
          const SizedBox(width: 10),
          Expanded(
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (var i = 0; i < s.terms.length; i++)
                _TermTabChip(
                  label: s.terms[i].label,
                  takeover: s.terms[i].runId != null,
                  exited: hub[s.terms[i].id]?.exited ?? true,
                  active: s.panelOpen && i == s.activeTerm,
                  onTap: () {
                    s.selectTerm(i);
                    if (!s.panelOpen) s.togglePanel();
                  },
                  onClose: () => _guard(() => s.closeTerminal(i)),
                ),
            ]),
          ),
          IconBtn(LucideIcons.plus, size: 13, tooltip: 'New terminal', onTap: () => _guard(() => s.newTerminal(Desk.shellName))),
          Builder(builder: (context) => IconBtn(LucideIcons.bookmark, size: 13, tooltip: 'Saved commands', onTap: () => _savedCommands(context, s, term))),
          IconBtn(s.panelOpen ? LucideIcons.chevronDown : LucideIcons.chevronUp, size: 13, tooltip: s.panelOpen ? 'Hide terminal (Ctrl+`)' : 'Show terminal (Ctrl+`)', onTap: _togglePanel),
        ]),
      ),
      if (s.panelOpen)
        Expanded(
          child: Row(children: [
            Expanded(
              child: Container(
                color: c.codeBg,
                child: term == null
                    ? Center(child: Btn('New terminal', icon: LucideIcons.squareTerminal, onTap: () => _guard(() => s.newTerminal(Desk.shellName))))
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                          child: Text(
                            tab!.runId != null ? 'You took over from ${agent?.name ?? 'the agent'} in ${Desk.tilde(term.cwd)}' : '${Desk.shellName} in ${Desk.tilde(term.cwd)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t(11, color: c.text3),
                          ),
                        ),
                        Expanded(child: RelayTerminal(key: ValueKey(term.id), session: term)),
                      ]),
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
                        if (run.status == RunStatus.paused && takeover != null)
                          Btn('Hand back', small: true, kind: BtnKind.primary, onTap: () => _guard(() async {
                            await client.call(M.runsResume, {'runId': run.id});
                            try {
                              await client.call(M.runsSteer, {'runId': run.id, 'text': 'I made some changes by hand in the workspace. Check `git status` and continue.'});
                            } on RpcError catch (_) {}
                            await s.closeTerminal(s.terms.indexOf(takeover));
                          }))
                        else if (RunStatus.isActive(run.status)) ...[
                          Btn(run.status == RunStatus.paused ? 'Resume' : 'Pause', small: true, onTap: () => client.call(run.status == RunStatus.paused ? M.runsResume : M.runsPause, {'runId': run.id})),
                          const SizedBox(width: 6),
                          Btn('Take over', small: true, kind: BtnKind.primary, icon: LucideIcons.hand, onTap: () => _guard(() => s.takeover(run.id, agent?.name ?? 'the agent'))),
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

  /// The saved-commands menu: run one in the open terminal, save a new one,
  /// or remove one.
  Future<void> _savedCommands(BuildContext anchor, CodeSession s, TermSession? term) async {
    final saved = ref.read(savedCommandsProvider);
    await saved.ready;
    if (!anchor.mounted) return;
    final box = anchor.findRenderObject() as RenderBox;
    final at = box.localToGlobal(Offset(0, box.size.height));
    final choice = await showMenuAt<String>(anchor, at, [
      for (final cmd in saved.items) ('run:${cmd.name}', '${cmd.name}  —  ${cmd.command}', LucideIcons.play),
      ('add', 'Save a command…', LucideIcons.plus),
      if (saved.items.isNotEmpty) ('manage', 'Manage saved commands…', LucideIcons.settings2),
    ]);
    if (choice == null || !mounted) return;
    if (choice == 'add') return _editCommand(saved);
    if (choice == 'manage') return _manageCommands(saved);
    final cmd = saved.items.where((c) => 'run:${c.name}' == choice).firstOrNull;
    if (cmd == null) return;
    var target = term;
    if (target == null || target.exited) {
      await _guard(() => s.newTerminal(Desk.shellName));
      target = s.activeTab == null ? null : ref.read(termHubProvider)[s.activeTab!.id];
    }
    target?.run(cmd.command);
  }

  Future<void> _editCommand(SavedCommands saved, {({String name, String command})? editing}) async {
    final r = await showDialog<({String name, String command})>(context: context, builder: (_) => _CommandDialog(editing: editing));
    if (r == null) return;
    if (editing != null && editing.name != r.name) await saved.remove(editing.name);
    await _guard(() => saved.add(r.name, r.command));
  }

  Future<void> _manageCommands(SavedCommands saved) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Saved commands', style: context.t(14, w: FontWeight.w600)),
      content: SizedBox(
        width: 480,
        child: ListenableBuilder(
          listenable: saved,
          builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            if (saved.items.isEmpty) Text('None saved.', style: context.t(12, color: context.c.text2)),
            for (final cmd in saved.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cmd.name, style: context.t(13, w: FontWeight.w600)),
                      Text(cmd.command, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, family: mono, color: context.c.text2)),
                    ]),
                  ),
                  IconBtn(LucideIcons.pencil, size: 13, tooltip: 'Edit', onTap: () => _editCommand(saved, editing: cmd)),
                  IconBtn(LucideIcons.trash2, size: 13, tooltip: 'Remove', onTap: () => _guard(() => saved.remove(cmd.name))),
                ]),
              ),
          ]),
        ),
      ),
      actions: [Btn('Done', kind: BtnKind.primary, onTap: () => Navigator.pop(context))],
    ),
  );

  Widget _tree(BuildContext context, CodeSession s) {
    final c = context.c;
    final files = s.tree, status = s.status, expanded = s.expanded;
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
    final activePath = s.activeFile?.path;
    return ListView.builder(
      itemExtent: 22,
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (path, name, depth, dir) = rows[i];
        final letter = status[path];
        final color = switch (letter) { 'U' || 'A' => const Color(0xFF73C991), 'M' || 'R' => const Color(0xFFE2C08D), 'D' => c.danger, _ => c.text };
        final sel = path == activePath;
        return GestureDetector(
          onTap: () => dir ? s.toggleFolder(path) : _guard(() => s.openFile(path)),
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

/// An editor tab: ✕ closes it (middle-click too); unsaved shows a dot
/// that turns into ✕ on hover.
class _EditorTab extends StatefulWidget {
  const _EditorTab({required this.name, required this.active, required this.dirty, required this.onTap, required this.onClose});
  final String name;
  final bool active;
  final bool dirty;
  final VoidCallback onTap;
  final VoidCallback onClose;
  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Listener(
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) widget.onClose();
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            color: widget.active ? c.window : (hover ? c.inner.withValues(alpha: 0.4) : Colors.transparent),
            padding: const EdgeInsets.only(left: 12, right: 6),
            child: Row(children: [
              Icon(LucideIcons.fileCode, size: 13, color: c.accentIcon),
              const SizedBox(width: 6),
              Text(widget.name, style: context.t(12, color: widget.active ? c.text : c.text2)),
              const SizedBox(width: 4),
              SizedBox(
                width: 18,
                child: widget.dirty && !hover
                    ? Center(child: Dot(c.text2, size: 7))
                    : (widget.active || hover)
                    ? IconBtn(LucideIcons.x, size: 11, tooltip: 'Close', onTap: widget.onClose)
                    : null,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A terminal tab in the panel header.
class _TermTabChip extends StatelessWidget {
  const _TermTabChip({required this.label, required this.takeover, required this.exited, required this.active, required this.onTap, required this.onClose});
  final String label;
  final bool takeover;
  final bool exited;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Hoverable(
        onTap: onTap,
        selected: active,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, right: 2),
          child: Row(children: [
            Icon(takeover ? LucideIcons.hand : LucideIcons.squareTerminal, size: 12, color: exited ? c.text3 : (takeover ? c.warning : c.accentIcon)),
            const SizedBox(width: 5),
            Text(label, style: context.t(11.5, color: active ? c.text : c.text2)),
            const SizedBox(width: 2),
            IconBtn(LucideIcons.x, size: 10, tooltip: 'Kill terminal', onTap: onClose),
          ]),
        ),
      ),
    );
  }
}

/// Name + command for a saved terminal command.
class _CommandDialog extends StatefulWidget {
  const _CommandDialog({this.editing});
  final ({String name, String command})? editing;
  @override
  State<_CommandDialog> createState() => _CommandDialogState();
}

class _CommandDialogState extends State<_CommandDialog> {
  late final name = TextEditingController(text: widget.editing?.name);
  late final command = TextEditingController(text: widget.editing?.command);

  @override
  void dispose() {
    name.dispose();
    command.dispose();
    super.dispose();
  }

  void _done() {
    final cmd = command.text.trim();
    if (cmd.isEmpty) return;
    final n = name.text.trim();
    Navigator.pop(context, (name: n.isEmpty ? cmd : n, command: cmd));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.editing == null ? 'Save a terminal command' : 'Edit command', style: context.t(14, w: FontWeight.w600)),
    content: SizedBox(
      width: 420,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Name', style: context.t(12, color: context.c.text2)),
        const SizedBox(height: 4),
        FieldInput(controller: name, hint: 'Run the tests', autofocus: true),
        const SizedBox(height: 12),
        Text('Command', style: context.t(12, color: context.c.text2)),
        const SizedBox(height: 4),
        FieldInput(controller: command, hint: 'pnpm test --watch', mono: true, onSubmitted: (_) => _done()),
      ]),
    ),
    actions: [
      Btn('Cancel', onTap: () => Navigator.pop(context)),
      Btn('Save', kind: BtnKind.primary, onTap: _done),
    ],
  );
}
