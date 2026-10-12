import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../data/relay_data.dart';
import 'term_hub.dart';

/// A file open in an editor tab.
class OpenFile {
  OpenFile(this.path, String text, {this.readOnly = false}) : controller = CodeLineEditingController.fromText(text), _saved = text {
    _lines = controller.codeLines;
    controller.addListener(_changed);
  }

  /// Relative to the Code view's folder.
  final String path;
  final CodeLineEditingController controller;
  final bool readOnly;
  String _saved;
  Object? _lines;
  bool dirty = false;
  VoidCallback? onDirty;

  // The controller also notifies for caret and selection moves; only a new
  // set of lines can change the text.
  void _changed() {
    if (identical(controller.codeLines, _lines)) return;
    _lines = controller.codeLines;
    final d = controller.text != _saved;
    if (d != dirty) {
      dirty = d;
      onDirty?.call();
    }
  }

  void _markSaved() {
    _saved = controller.text;
    dirty = false;
  }

  void dispose() => controller.dispose();
}

/// A terminal tab in the panel.
class TermTab {
  TermTab(this.id, this.label, {this.runId});
  final String id;
  final String label;

  /// Set for a Take over shell in an agent's workspace.
  final String? runId;
  Map<String, Object?> toJson() => {'id': id, 'label': label, 'runId': ?runId};
}

/// What one project's Code view has open: the folder, editor tabs,
/// terminals and the panel's layout. It lives while the app runs, so
/// leaving the view and coming back finds everything as it was, and it is
/// kept in relayd (`ui.code.<project>`) for the next launch. Terminals keep
/// running in relayd either way.
class CodeSession extends ChangeNotifier {
  CodeSession(this.projectId, this._client, this._hub);
  final String projectId;
  final RelayClient _client;
  final TermHub _hub;

  String? rootPath;
  List<String> tree = [];
  Map<String, String> status = {};
  final expanded = <String>{''};
  final files = <OpenFile>[];
  int active = -1;

  final terms = <TermTab>[];
  int activeTerm = -1;
  bool panelOpen = true;

  /// Bumped when the terminal should take keyboard focus: a new terminal,
  /// Take over, a tab clicked, the panel opened by hand. Never on its own,
  /// so opening the Code view doesn't steal keys from the app.
  final termFocus = ValueNotifier(0);

  bool _restoring = false;
  bool restored = false;
  Timer? _saveTimer;

  OpenFile? get activeFile => active >= 0 && active < files.length ? files[active] : null;
  TermTab? get activeTab => activeTerm >= 0 && activeTerm < terms.length ? terms[activeTerm] : null;
  String get _key => 'code.$projectId';

  // ------------------------------------------------------------- restore

  /// Puts back what was open last time; [roots] are the folders that still
  /// exist. Runs once per session.
  Future<void> restore(List<String> roots, {String? prefer}) async {
    if (restored || _restoring) return;
    _restoring = true;
    Map<String, Object?> saved = const {};
    try {
      final raw = await _client.call<String?>(M.uiGet, {'key': _key});
      if (raw != null) saved = (jsonDecode(raw) as Map).cast<String, Object?>();
    } on Object catch (_) {
      // Nothing usable saved.
    }
    panelOpen = saved['panelOpen'] as bool? ?? true;
    expanded.addAll((saved['expanded'] as List? ?? const []).cast<String>());

    for (final t in (saved['terms'] as List? ?? const []).cast<Map>()) {
      final s = await _hub.attach('${t['id']}');
      if (s != null && !s.exited) terms.add(TermTab(s.id, '${t['label']}', runId: t['runId'] as String?));
    }
    activeTerm = terms.isEmpty ? -1 : ((saved['activeTerm'] as num?)?.toInt() ?? 0).clamp(0, terms.length - 1);

    final last = saved['root'] as String?;
    final root = prefer != null && roots.contains(prefer) ? prefer : (last != null && roots.contains(last) ? last : roots.firstOrNull);
    if (root != null) {
      await _loadRoot(root);
      if (root == last) {
        for (final f in (saved['files'] as List? ?? const []).cast<String>()) {
          await openFile(f, quiet: true);
        }
        if (files.isNotEmpty) active = ((saved['active'] as num?)?.toInt() ?? 0).clamp(0, files.length - 1);
      }
    }
    restored = true;
    _restoring = false;
    notifyListeners();
  }

  void _save() {
    if (!restored) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      final state = {
        'root': rootPath,
        'files': [for (final f in files) f.path],
        'active': active,
        'expanded': [for (final e in expanded) if (e.isNotEmpty) e],
        'terms': [for (final t in terms) t.toJson()],
        'activeTerm': activeTerm,
        'panelOpen': panelOpen,
      };
      _client.call(M.uiSet, {'key': _key, 'value': jsonEncode(state)}).catchError((Object _) => true);
    });
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  // ------------------------------------------------------------- folder

  Future<void> _loadRoot(String path) async {
    final list = await _client.map(M.fsList, {'path': path});
    final st = await _client.list(M.gitStatus, {'path': path});
    rootPath = path;
    tree = (list['files'] as List).cast<String>();
    status = {for (final s in st) s['path'] as String: s['letter'] as String};
  }

  /// Opens another folder. Editor tabs belong to a folder and close
  /// (unsaved ones are the caller's to ask about); terminals stay.
  Future<void> pick(String path) async {
    if (path == rootPath) return refresh();
    for (final f in files) {
      f.dispose();
    }
    files.clear();
    active = -1;
    expanded
      ..clear()
      ..add('');
    await _loadRoot(path);
    _changed();
  }

  Future<void> refresh() async {
    final path = rootPath;
    if (path == null) return;
    await _loadRoot(path);
    _changed();
  }

  void toggleFolder(String path) {
    expanded.contains(path) ? expanded.remove(path) : expanded.add(path);
    _changed();
  }

  // ------------------------------------------------------------- editor

  Future<void> openFile(String rel, {bool quiet = false}) async {
    final i = files.indexWhere((f) => f.path == rel);
    if (i >= 0) {
      active = i;
      return _changed();
    }
    final Map<String, Object?> res;
    try {
      res = await _client.map(M.fsRead, {'path': p.join(rootPath!, rel)});
    } on RpcError {
      if (quiet) return;
      rethrow;
    }
    final binary = res['binary'] == true, tooLarge = res['tooLarge'] == true;
    final text = binary
        ? '(binary file, ${res['size']} bytes)'
        : (tooLarge ? '(file too large to open here: ${res['size']} bytes)' : res['text'] as String);
    final f = OpenFile(rel, text, readOnly: binary || tooLarge)..onDirty = notifyListeners;
    files.add(f);
    active = files.length - 1;
    if (!quiet) _changed();
  }

  void select(int i) {
    active = i;
    _changed();
  }

  Future<void> save([int? index]) async {
    final i = index ?? active;
    if (i < 0 || i >= files.length || files[i].readOnly) return;
    final f = files[i];
    await _client.call(M.fsWrite, {'path': p.join(rootPath!, f.path), 'text': f.controller.text});
    f._markSaved();
    notifyListeners();
  }

  /// Closes a tab without asking; the view asks first if it is unsaved.
  void closeFile(int i) {
    if (i < 0 || i >= files.length) return;
    files.removeAt(i).dispose();
    if (active > i || active >= files.length) active--;
    if (active < 0 && files.isNotEmpty) active = 0;
    _changed();
  }

  // ------------------------------------------------------------- terminals

  Future<void> newTerminal(String shellName, {int cols = 100, int rows = 30}) async {
    final cwd = rootPath;
    if (cwd == null) return;
    final s = await _hub.open(cwd, cols: cols, rows: rows);
    final n = terms.where((t) => t.runId == null).length + 1;
    terms.add(TermTab(s.id, n == 1 ? shellName : '$shellName $n'));
    activeTerm = terms.length - 1;
    panelOpen = true;
    _changed();
  }

  Future<void> takeover(String runId, String agentName) async {
    final s = await _hub.takeover(runId);
    terms.add(TermTab(s.id, 'Took over $agentName', runId: runId));
    activeTerm = terms.length - 1;
    panelOpen = true;
    _changed();
  }

  /// The Take over shell for [runId], if one is open.
  TermTab? takeoverFor(String runId) => terms.where((t) => t.runId == runId).firstOrNull;

  void selectTerm(int i) {
    activeTerm = i;
    _changed();
  }

  Future<void> closeTerminal(int i) async {
    if (i < 0 || i >= terms.length) return;
    final t = terms.removeAt(i);
    if (activeTerm > i || activeTerm >= terms.length) activeTerm--;
    if (activeTerm < 0 && terms.isNotEmpty) activeTerm = 0;
    _changed();
    await _hub.close(t.id);
  }

  void togglePanel() {
    panelOpen = !panelOpen;
    _changed();
  }

  /// Set until the Code view has given the terminal focus; it may not be
  /// on screen yet when asked (⌃` from another view).
  bool wantsTermFocus = false;

  void focusTerminal() {
    wantsTermFocus = true;
    termFocus.value++;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    termFocus.dispose();
    for (final f in files) {
      f.dispose();
    }
    super.dispose();
  }
}

/// One per project, kept while the app runs.
final codeSessionProvider = Provider.family<CodeSession, String>((ref, projectId) {
  final s = CodeSession(projectId, ref.watch(clientProvider), ref.watch(termHubProvider));
  ref.onDispose(s.dispose);
  return s;
});

/// Commands someone keeps for the terminal: `{name, command}`, on this
/// device (relayd `ui.terminal.commands`).
class SavedCommands extends ChangeNotifier {
  SavedCommands(this._client) {
    ready = _load();
  }
  final RelayClient _client;

  /// Done once what was saved has loaded.
  late final Future<void> ready;
  List<({String name, String command})> items = [];

  Future<void> _load() async {
    try {
      final raw = await _client.call<String?>(M.uiGet, {'key': 'terminal.commands'});
      if (raw == null) return;
      items = [
        for (final m in (jsonDecode(raw) as List).cast<Map>()) (name: '${m['name']}', command: '${m['command']}'),
      ];
      notifyListeners();
    } on Object catch (_) {
      // None saved yet.
    }
  }

  Future<void> _store() async {
    notifyListeners();
    await _client.call(M.uiSet, {
      'key': 'terminal.commands',
      'value': jsonEncode([for (final c in items) {'name': c.name, 'command': c.command}]),
    });
  }

  Future<void> add(String name, String command) {
    items = [...items.where((c) => c.name != name), (name: name, command: command)];
    return _store();
  }

  Future<void> remove(String name) {
    items = items.where((c) => c.name != name).toList();
    return _store();
  }
}

final savedCommandsProvider = Provider<SavedCommands>((ref) {
  final s = SavedCommands(ref.watch(clientProvider));
  ref.onDispose(s.dispose);
  return s;
});
