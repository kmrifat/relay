import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/commands.dart';
import '../../app/sidebar.dart' show inSmartList;
import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/split.dart';
import '../../ui/widgets.dart';
import '../task/new_task_sheet.dart';
import '../task/task_bits.dart';
import 'board_card.dart';
import 'board_peek.dart';

export 'board_card.dart' show TaskCard;

/// How the board groups its rows.
enum Lanes { none, epic, agent, repo }

/// The board (design P03): a filter bar, swimlanes, cards you can drag
/// between and within columns, and a side peek.
///
/// Keys while it has focus: arrows or H/J/K/L move, Space or a click
/// peeks, Enter opens, ⌥←/⌥→ moves the card a column, A assigns, R runs
/// now, Q queues, / filters, Esc closes the peek.
class BoardView extends ConsumerStatefulWidget {
  const BoardView({super.key, required this.projectId, this.repoFilter});
  final String projectId;
  final String? repoFilter;

  @override
  ConsumerState<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends ConsumerState<BoardView> {
  final _focus = FocusNode(debugLabel: 'board');
  final _filterFocus = FocusNode(debugLabel: 'board filter');
  final _filter = TextEditingController();
  final _selectedKey = GlobalKey();
  String? _selected;
  bool _peek = false;

  /// A second click on the same card soon after opens it. (A double-tap
  /// recognizer would hold every single click back for 300 ms.)
  (String, DateTime)? _lastClick;

  // Saved per product (relayd ui `board.<project>`).
  Lanes lanes = Lanes.epic;
  bool compact = false;
  bool doneFolded = true;
  final who = <String>{};
  String? tag;
  bool needsMe = false;

  @override
  void initState() {
    super.initState();
    focusContent.addListener(_takeFocus);
    _filter.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusIsIdle) _focus.requestFocus();
    });
    _load();
  }

  @override
  void didUpdateWidget(BoardView old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) {
      _selected = null;
      _peek = false;
      who.clear();
      tag = null;
      _load();
    }
  }

  @override
  void dispose() {
    focusContent.removeListener(_takeFocus);
    _focus.dispose();
    _filterFocus.dispose();
    _filter.dispose();
    super.dispose();
  }

  String get _uiKey => 'board.${widget.projectId}';

  Future<void> _load() async {
    try {
      final raw = await ref.read(clientProvider).call<String?>(M.uiGet, {'key': _uiKey});
      if (raw == null || !mounted) return;
      final o = (jsonDecode(raw) as Map).cast<String, Object?>();
      setState(() {
        lanes = Lanes.values.where((l) => l.name == o['lanes']).firstOrNull ?? lanes;
        compact = o['compact'] == true;
        doneFolded = o['doneFolded'] != false;
      });
    } on Object catch (_) {
      // Defaults.
    }
  }

  void _save() => ref
      .read(clientProvider)
      .call(M.uiSet, {'key': _uiKey, 'value': jsonEncode({'lanes': lanes.name, 'compact': compact, 'doneFolded': doneFolded})})
      .catchError((Object _) => true);

  void _takeFocus() {
    if (mounted) _focus.requestFocus();
  }

  void _select(String id, {bool peek = true}) {
    setState(() {
      _selected = id;
      if (peek) _peek = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final policy in [ScrollPositionAlignmentPolicy.keepVisibleAtEnd, ScrollPositionAlignmentPolicy.keepVisibleAtStart]) {
        final ctx = _selectedKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, alignmentPolicy: policy);
      }
    });
  }

  void _open(String id) => ref.read(navProvider.notifier).openTask(id);

  // ---------------------------------------------------------------- data

  List<Task> _visible(DataSnapshot data) {
    final words = _filter.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return data.tasksOf(widget.projectId).where((t) {
      if (widget.repoFilter != null && !t.repoIds.contains(widget.repoFilter)) return false;
      if (t.isEpic && lanes == Lanes.epic) return false; // epics are the lanes
      if (who.isNotEmpty && !who.contains(t.assignee)) return false;
      if (tag != null && !t.tags.contains(tag)) return false;
      if (needsMe && !inSmartList(AppPage.waiting, t) && t.status != TaskStatus.review) return false;
      if (words.isEmpty) return true;
      final hay = '${data.keyOf(t)} ${t.title} ${t.brief} ${t.tags.join(' ')}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
  }

  /// Rows of the board: a label and its tasks.
  List<_Lane> _lanes(DataSnapshot data, List<Task> tasks) {
    switch (lanes) {
      case Lanes.none:
        return [_Lane(null, null, tasks)];
      case Lanes.epic:
        final epics = data.tasksOf(widget.projectId).where((t) => t.isEpic).toList()..sort((a, b) => a.number.compareTo(b.number));
        return [
          for (final e in epics) _Lane(e.title, e, tasks.where((t) => t.parentId == e.id).toList()),
          _Lane(epics.isEmpty ? null : 'No epic', null, tasks.where((t) => t.parentId == null || !epics.any((e) => e.id == t.parentId)).toList()),
        ].where((l) => l.tasks.isNotEmpty || l.epic != null).toList();
      case Lanes.agent:
        final ids = {for (final t in tasks) t.assigneeKind == 'agent' || t.assigneeKind == 'person' ? t.assignee ?? '' : ''}.toList()..sort();
        return [
          for (final id in ids)
            _Lane(id.isEmpty ? 'Unassigned' : _who(data, id), null,
                tasks.where((t) => (t.assigneeKind == 'none' ? '' : t.assignee ?? '') == id).toList()),
        ];
      case Lanes.repo:
        final repos = data.reposOf(widget.projectId);
        return [
          for (final r in repos) _Lane(r.name, null, tasks.where((t) => t.repoIds.contains(r.id)).toList()),
          _Lane('No repo picked', null, tasks.where((t) => t.repoIds.isEmpty).toList()),
        ].where((l) => l.tasks.isNotEmpty).toList();
    }
  }

  // ---------------------------------------------------------------- keys

  KeyEventResult _key(KeyEvent e, List<List<Task>> cols) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isMetaPressed || kb.isControlPressed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.slash) {
      _filterFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _peek) {
      setState(() => _peek = false);
      return KeyEventResult.handled;
    }
    var ci = -1, ri = -1;
    for (var i = 0; i < cols.length && ci < 0; i++) {
      final j = cols[i].indexWhere((t) => t.id == _selected);
      if (j >= 0) (ci, ri) = (i, j);
    }
    const moves = [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyH, LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyK, LogicalKeyboardKey.keyL];
    if (ci < 0) {
      final first = cols.indexWhere((c) => c.isNotEmpty);
      if (first < 0 || !moves.contains(k)) return KeyEventResult.ignored;
      _select(cols[first].first.id, peek: false);
      return KeyEventResult.handled;
    }
    final task = cols[ci][ri];
    void column(int d) {
      for (var i = ci + d; i >= 0 && i < cols.length; i += d) {
        if (cols[i].isEmpty) continue;
        _select(cols[i][ri.clamp(0, cols[i].length - 1)].id, peek: _peek);
        return;
      }
    }

    void move(int d) {
      final to = ci + d;
      if (to < 0 || to >= TaskStatus.columns.length) return;
      final maxPos = cols[to].fold<double>(0, (m, t) => t.position > m ? t.position : m);
      ref.read(clientProvider).call(M.tasksMove, {'id': task.id, 'status': TaskStatus.columns[to], 'position': maxPos + 1});
    }

    Offset anchor() {
      final box = _selectedKey.currentContext?.findRenderObject() as RenderBox?;
      return box == null ? Offset.zero : box.localToGlobal(Offset(0, box.size.height));
    }

    final alt = kb.isAltPressed;
    switch (k) {
      case LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.keyH:
        alt ? move(-1) : column(-1);
      case LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.keyL:
        alt ? move(1) : column(1);
      case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.keyK:
        _select(cols[ci][(ri - 1).clamp(0, cols[ci].length - 1)].id, peek: _peek);
      case LogicalKeyboardKey.arrowDown || LogicalKeyboardKey.keyJ:
        _select(cols[ci][(ri + 1).clamp(0, cols[ci].length - 1)].id, peek: _peek);
      case LogicalKeyboardKey.space:
        setState(() => _peek = !_peek);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        _open(task.id);
      case LogicalKeyboardKey.keyA:
        assignMenu(context, ref, task, anchor());
      case LogicalKeyboardKey.keyR:
        runNow(context, ref, task);
      case LogicalKeyboardKey.keyQ:
        ref.read(clientProvider).call(M.tasksMove, {'id': task.id, 'status': TaskStatus.queued});
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final visible = _visible(data);
    final rows = _lanes(data, visible);
    List<Task> sorted(Iterable<Task> ts) => ts.toList()..sort((a, b) => a.position.compareTo(b.position));
    // Columns for the arrow keys: each status, lane after lane.
    final cols = [
      for (final s in TaskStatus.columns)
        if (s == TaskStatus.done && doneFolded) <Task>[] else [for (final l in rows) ...sorted(l.tasks.where((t) => t.status == s))],
    ];
    final peekTask = _peek ? data.get<Task>(Kind.task, _selected) : null;

    final board = Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) => _key(e, cols),
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, _) => LayoutBuilder(builder: (context, box) {
          final folded = doneFolded ? 44.0 : null;
          final open = TaskStatus.columns.length - (doneFolded ? 1 : 0);
          final w = ((box.maxWidth - 28 - (folded ?? 0) - (TaskStatus.columns.length - 1) * 10) / open).clamp(190.0, 340.0);
          final width = open * w + (folded ?? 0) + (TaskStatus.columns.length - 1) * 10 + 28;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width < box.maxWidth ? box.maxWidth : width,
              height: box.maxHeight,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final (i, s) in TaskStatus.columns.indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      SizedBox(width: s == TaskStatus.done && doneFolded ? folded : w, child: _header(context, data, s, visible)),
                    ],
                  ]),
                ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 16), children: [
                    for (final l in rows) ...[
                      if (l.label != null) _laneHeader(context, data, l),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final (i, s) in TaskStatus.columns.indexed) ...[
                          if (i > 0) const SizedBox(width: 10),
                          SizedBox(
                            width: s == TaskStatus.done && doneFolded ? folded : w,
                            child: s == TaskStatus.done && doneFolded
                                ? _FoldedDone(count: l.tasks.where((t) => t.status == s).length, onTap: () {
                                    setState(() => doneFolded = false);
                                    _save();
                                  })
                                : _Cell(
                                    status: s,
                                    tasks: sorted(l.tasks.where((t) => t.status == s)),
                                    epic: l.epic,
                                    selected: _selected,
                                    selectedKey: _selectedKey,
                                    showFocus: _focus.hasFocus,
                                    compact: compact,
                                    empty: rows.length == 1 || l.tasks.isEmpty,
                                    onSelect: (id) {
                                      final last = _lastClick;
                                      _lastClick = (id, DateTime.now());
                                      if (last != null && last.$1 == id && DateTime.now().difference(last.$2) < const Duration(milliseconds: 400)) {
                                        return _open(id);
                                      }
                                      _select(id);
                                      _focus.requestFocus();
                                    },
                                    onOpen: _open,
                                  ),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 12),
                    ],
                    if (visible.isEmpty && data.tasksOf(widget.projectId).isNotEmpty)
                      Padding(padding: const EdgeInsets.all(20), child: Center(child: Text('No task matches the filters.', style: context.t(13, color: c.text2)))),
                    _keyHints(context),
                  ]),
                ),
              ]),
            ),
          );
        }),
      ),
    );

    return Column(children: [
      _filterBar(context, data),
      Container(height: 1, color: c.separator),
      Expanded(
        child: ResizableSplit(
          id: 'board.peek',
          sized: SplitSide.second,
          initial: 380,
          min: 300,
          keepOther: 520,
          collapsedTo: peekTask == null ? 0 : null,
          first: board,
          second: peekTask == null
              ? const SizedBox.shrink()
              : TaskPeek(
                  key: ValueKey(peekTask.id),
                  taskId: peekTask.id,
                  onClose: () {
                    setState(() => _peek = false);
                    _focus.requestFocus();
                  },
                  onOpen: () => _open(peekTask.id),
                ),
        ),
      ),
    ]);
  }

  Widget _header(BuildContext context, DataSnapshot data, String s, List<Task> visible) {
    final c = context.c;
    final count = visible.where((t) => t.status == s).length;
    if (s == TaskStatus.done && doneFolded) {
      return Tooltip(
        message: 'Show Done',
        child: Pressable(
          onTap: () {
            setState(() => doneFolded = false);
            _save();
          },
          builder: (context, hover, focus) => Row(children: [
            Icon(statusIcon(s), size: 13, color: statusColor(context, s)),
            const SizedBox(width: 4),
            Text('$count', style: context.t(11, color: c.text3)),
          ]),
        ),
      );
    }
    // In progress counts against the agents' slots.
    final slots = s == TaskStatus.running ? data.agents.where((a) => a.enabled && a.binaryPath != null).fold<int>(0, (n, a) => n + a.slots) : 0;
    return Row(children: [
      Icon(statusIcon(s), size: 13, color: statusColor(context, s)),
      const SizedBox(width: 6),
      Flexible(child: Text(TaskStatus.label(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, w: FontWeight.w600))),
      const SizedBox(width: 6),
      Text(slots > 0 ? '$count / $slots' : '$count', style: context.t(11, color: c.text3)),
      const Spacer(),
      if (s == TaskStatus.backlog || s == TaskStatus.queued)
        IconBtn(LucideIcons.plus, size: 13, tooltip: 'New task', onTap: () => showNewTaskSheet(context, ref, status: s)),
      if (s == TaskStatus.done)
        IconBtn(LucideIcons.chevronsRight, size: 13, tooltip: 'Fold Done', onTap: () {
          setState(() => doneFolded = true);
          _save();
        }),
    ]);
  }

  Widget _laneHeader(BuildContext context, DataSnapshot data, _Lane l) {
    final c = context.c;
    final epic = l.epic;
    final all = epic == null ? l.tasks : data.tasksOf(widget.projectId).where((t) => t.parentId == epic.id).toList();
    final done = all.where((t) => t.status == TaskStatus.done).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: c.bar, borderRadius: BorderRadius.circular(5)),
      child: Row(children: [
        Text(l.label!, style: context.t(12, w: FontWeight.w700)),
        const SizedBox(width: 8),
        Text(epic == null ? '${l.tasks.length} task${l.tasks.length == 1 ? '' : 's'}' : 'epic · $done of ${all.length} done', style: context.t(11, color: c.text3)),
        if (all.isNotEmpty) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(minHeight: 4, value: done / all.length, backgroundColor: c.inner, color: c.success),
            ),
          ),
        ],
        const Spacer(),
        if (epic != null) IconBtn(LucideIcons.arrowUpRight, size: 12, tooltip: 'Open the epic', onTap: () => _open(epic.id)),
      ]),
    );
  }

  Widget _filterBar(BuildContext context, DataSnapshot data) {
    final c = context.c;
    final tasks = data.tasksOf(widget.projectId);
    final people = {
      for (final t in tasks)
        if ((t.assigneeKind == 'agent' || t.assigneeKind == 'person') && t.assignee != null && t.assignee != 'auto') t.assignee!,
    }.toList();
    final tags = {for (final t in tasks) ...t.tags}.toList()..sort();
    Widget menu(String label, String value, Future<void> Function(BuildContext) onTap) => Builder(
      builder: (context) => Pressable(
        onTap: () => onTap(context),
        builder: (context, hover, focus) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: hover ? c.control : c.inner, borderRadius: BorderRadius.circular(5)),
          foregroundDecoration: focusRing(context, focus, 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: context.t(11.5, color: c.text2)),
            const SizedBox(width: 4),
            Text(value, style: context.t(11.5)),
            Icon(LucideIcons.chevronDown, size: 11, color: c.text2),
          ]),
        ),
      ),
    );
    Offset below(BuildContext context) {
      final box = context.findRenderObject() as RenderBox;
      return box.localToGlobal(Offset(0, box.size.height));
    }

    return Container(
      height: 40,
      color: c.bar,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(children: [
        SizedBox(
          width: 200,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                _filter.clear();
                _focus.requestFocus();
              },
            },
            child: FieldInput(controller: _filter, focusNode: _filterFocus, size: 12, hint: 'Filter this board  /'),
          ),
        ),
        const SizedBox(width: 10),
        for (final id in people.take(8))
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Tooltip(
              message: _who(data, id),
              child: Pressable(
                onTap: () => setState(() => who.contains(id) ? who.remove(id) : who.add(id)),
                builder: (context, hover, focus) => Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: who.contains(id) ? c.accentIcon : Colors.transparent, width: 1.5),
                  ),
                  child: Opacity(
                    opacity: who.isEmpty || who.contains(id) ? 1 : 0.4,
                    child: data.get<AgentProfile>(Kind.agent, id) != null
                        ? AgentTile(agent: data.get<AgentProfile>(Kind.agent, id), size: 20)
                        : Avatar(id, size: 20),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(width: 8),
        if (tags.isNotEmpty) ...[
          menu('Tag', tag ?? 'any', (context) async {
            final v = await showMenuAt<String>(context, below(context), [('', 'Any tag', null), for (final t in tags) (t, '#$t', null)]);
            if (v != null) setState(() => tag = v.isEmpty ? null : v);
          }),
          const SizedBox(width: 6),
        ],
        Pressable(
          onTap: () => setState(() => needsMe = !needsMe),
          builder: (context, hover, focus) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: needsMe ? c.warningWash : c.inner, borderRadius: BorderRadius.circular(5)),
            foregroundDecoration: focusRing(context, focus, 5),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.hand, size: 11, color: needsMe ? c.warning : c.text2),
              const SizedBox(width: 4),
              Text('Needs me', style: context.t(11.5, color: needsMe ? c.warning : c.text)),
            ]),
          ),
        ),
        const Spacer(),
        menu('Lanes', switch (lanes) { Lanes.none => 'none', Lanes.epic => 'epic', Lanes.agent => 'assignee', Lanes.repo => 'repo' }, (context) async {
          final v = await showMenuAt<Lanes>(context, below(context), [
            (Lanes.epic, 'Epic', LucideIcons.layers),
            (Lanes.agent, 'Assignee', LucideIcons.users),
            (Lanes.repo, 'Repo', LucideIcons.gitBranch),
            (Lanes.none, 'No lanes', null),
          ]);
          if (v != null) {
            setState(() => lanes = v);
            _save();
          }
        }),
        const SizedBox(width: 6),
        Segmented<bool>(
          small: true,
          options: const [(false, 'Comfortable'), (true, 'Compact')],
          value: compact,
          onChanged: (v) {
            setState(() => compact = v);
            _save();
          },
        ),
      ]),
    );
  }

  Widget _keyHints(BuildContext context) {
    final c = context.c;
    Widget hint(String keys, String what) => Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: c.inner, borderRadius: BorderRadius.circular(3)),
          child: Text(keys, style: context.t(10.5)),
        ),
        const SizedBox(width: 4),
        Text(what, style: context.t(11, color: c.text3)),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(runSpacing: 6, children: [
        hint('← → ↑ ↓', 'move'),
        hint('Space', 'peek'),
        hint('↵', 'open'),
        hint('⌥← ⌥→', 'move card'),
        hint('A', 'assign'),
        hint('R', 'run now'),
        hint('/', 'filter'),
        hint('?', 'all keys'),
      ]),
    );
  }
}

class _Lane {
  _Lane(this.label, this.epic, this.tasks);
  final String? label;
  final Task? epic;
  final List<Task> tasks;
}

/// The cards of one status in one lane. Dropping on the cell moves a task
/// to the end; dropping on a card puts it before that card.
class _Cell extends ConsumerWidget {
  const _Cell({
    required this.status,
    required this.tasks,
    required this.epic,
    required this.selected,
    required this.selectedKey,
    required this.showFocus,
    required this.compact,
    required this.empty,
    required this.onSelect,
    required this.onOpen,
  });
  final String status;
  final List<Task> tasks;
  final Task? epic;
  final String? selected;
  final GlobalKey selectedKey;
  final bool showFocus, compact, empty;
  final ValueChanged<String> onSelect, onOpen;

  void _drop(WidgetRef ref, Task t, double position) => ref.read(clientProvider).call(M.tasksMove, {'id': t.id, 'status': status, 'position': position});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final last = tasks.fold<double>(0, (m, t) => t.position > m ? t.position : m);
    return DragTarget<Task>(
      onWillAcceptWithDetails: (d) => d.data.status != status || !tasks.contains(d.data),
      onAcceptWithDetails: (d) => _drop(ref, d.data, last + 1),
      builder: (context, candidates, _) => Container(
        constraints: const BoxConstraints(minHeight: 40),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty ? c.accent.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, t) in tasks.indexed)
            DragTarget<Task>(
              onWillAcceptWithDetails: (d) => d.data.id != t.id,
              onAcceptWithDetails: (d) {
                final before = i == 0 ? t.position - 1 : tasks[i - 1].position;
                _drop(ref, d.data, (before + t.position) / 2);
              },
              builder: (context, over, _) => Padding(
                padding: EdgeInsets.only(bottom: 8, top: over.isNotEmpty ? 3 : 0),
                child: Container(
                  decoration: over.isNotEmpty ? BoxDecoration(border: Border(top: BorderSide(color: c.accentIcon, width: 2))) : null,
                  child: KeyedSubtree(
                    key: t.id == selected ? selectedKey : ValueKey(t.id),
                    child: _DraggableCard(
                      task: t,
                      focused: t.id == selected && showFocus,
                      selected: t.id == selected,
                      compact: compact,
                      onSelect: () => onSelect(t.id),
                      onOpen: () => onOpen(t.id),
                    ),
                  ),
                ),
              ),
            ),
          if (tasks.isEmpty && empty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(switch (status) {
                TaskStatus.backlog => 'Nothing planned',
                TaskStatus.queued => 'Nothing ready',
                TaskStatus.running => 'No one is working',
                TaskStatus.review => 'Nothing to review',
                _ => 'Nothing done yet',
              }, textAlign: TextAlign.center, style: context.t(11, color: c.text3)),
            ),
        ]),
      ),
    );
  }
}

class _FoldedDone extends StatelessWidget {
  const _FoldedDone({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Show Done',
    child: Pressable(
      onTap: onTap,
      builder: (context, hover, focus) => Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: hover ? context.c.inner : context.c.bar, borderRadius: BorderRadius.circular(7)),
        child: Text('$count', style: context.t(11, color: context.c.text3)),
      ),
    ),
  );
}

class _DraggableCard extends StatelessWidget {
  const _DraggableCard({required this.task, this.focused = false, this.selected = false, this.compact = false, this.onSelect, this.onOpen});
  final Task task;
  final bool focused, selected, compact;
  final VoidCallback? onSelect, onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Draggable<Task>(
      data: task,
      feedback: Material(color: Colors.transparent, child: SizedBox(width: box.maxWidth, child: Opacity(opacity: 0.9, child: TaskCard(task: task, compact: compact)))),
      childWhenDragging: Opacity(opacity: 0.35, child: TaskCard(task: task, compact: compact)),
      child: TaskCard(task: task, focused: focused, selected: selected, compact: compact, onSelect: onSelect, onOpen: onOpen),
    ),
  );
}

/// An agent's name and role, or a person's name.
String _who(DataSnapshot data, String id) {
  final a = data.get<AgentProfile>(Kind.agent, id);
  return a == null ? id : agentLabel(a);
}
