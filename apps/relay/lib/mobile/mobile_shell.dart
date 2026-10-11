import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../app/theme.dart' show hexColor;
import '../data/notifications.dart';
import '../data/relay_data.dart';
import 'channel_screen.dart';
import 'glass.dart';
import 'mobile_data.dart';
import 'pair_screen.dart';
import 'run_screen.dart';
import 'sheets.dart';

/// The iPhone app (I01–I05): four tabs under a floating glass tab bar.
class MobileShell extends ConsumerStatefulWidget {
  const MobileShell({super.key});
  @override
  ConsumerState<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends ConsumerState<MobileShell> {
  int tab = 0;
  String? projectId;
  bool _registered = false;
  int _badge = -1;

  @override
  void initState() {
    super.initState();
    NativeNotifications.instance
      ..init()
      ..onOpen = (info) {
        if (!mounted) return;
        if (info['taskId'] is String) openTask(context, info['taskId'] as String);
        if (info['channelId'] is String && info['taskId'] == null) {
          Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => ChannelScreen(channelId: info['channelId'] as String)));
        }
      }
      ..onToken = (token, sandbox) async {
        try {
          await ref.read(clientProvider).call(M.pushRegister, {'token': token, 'sandbox': sandbox});
        } on RpcError {
          // The team has no Worker push yet; the Mac's Settings sets it up.
        }
      };
  }

  static const tabs = [
    (LucideIcons.inbox, 'Inbox'),
    (LucideIcons.layoutGrid, 'Board'),
    (LucideIcons.bot, 'Agents'),
    (LucideIcons.messageSquare, 'Chat'),
  ];

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final sync = ref.watch(syncStatusProvider);
    if (sync.isEmpty) return const Scaffold(backgroundColor: MC.bg);
    if (!view.paired) return const PairScreen();
    if (!_registered) {
      _registered = true;
      NativeNotifications.instance.registerForPush();
    }
    // While open (or just backgrounded), relayd's notify events become local
    // notifications; when the app is gone, the Mac pushes through APNs.
    ref.listen(notifyProvider, (_, next) {
      final n = next.value;
      if (n == null) return;
      NativeNotifications.instance.post(
        id: '${n['kind']}-${n['taskId'] ?? n['messageId'] ?? DateTime.now().microsecondsSinceEpoch}',
        title: '${n['title']}',
        body: '${n['body']}',
        info: {'taskId': ?n['taskId'], 'channelId': ?n['channelId']},
      );
    });
    final asks = view.asks.length;
    if (asks != _badge) {
      _badge = asks;
      NativeNotifications.instance.badge(asks);
    }
    final projects = view.data.projects;
    final pid = projects.any((p) => p.id == projectId) ? projectId : projects.firstOrNull?.id;
    final pages = [
      const InboxTab(),
      BoardTab(projectId: pid, onPickProject: (id) => setState(() => projectId = id)),
      const AgentsTab(),
      const ChatTab(),
    ];
    final bottom = MediaQuery.of(context).padding.bottom;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
      backgroundColor: MC.bg,
      body: BackdropGroup(
        child: Stack(children: [
          Positioned.fill(child: IndexedStack(index: tab, children: pages)),
          Positioned(
            left: 16,
            right: 16,
            bottom: bottom > 0 ? bottom - 6 : 14,
            child: GlassTabBar(
              index: tab,
              tabs: tabs,
              onTap: (i) => setState(() => tab = i),
              onSearch: () => showSearchSheet(context, ref),
            ),
          ),
        ]),
      ),
    ),
    );
  }
}

/// A tab's scrolling page: toolbar pills, large title, subtitle, content.
class TabPage extends StatelessWidget {
  const TabPage({super.key, this.left, this.right, required this.title, this.subtitle, required this.children});
  final Widget? left;
  final Widget? right;
  final String title;
  final String? subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Stack(children: [
      ListView(
        padding: EdgeInsets.fromLTRB(16, top + 62, 16, 120),
        children: [
          Text(title, style: mt(34, w: FontWeight.w700)),
          if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2, bottom: 12), child: Text(subtitle!, style: mt(15, color: MC.text2))),
          ...children,
        ],
      ),
      Positioned(
        top: top + 6,
        left: 16,
        right: 16,
        child: Row(children: [?left, const Spacer(), ?right]),
      ),
    ]);
  }
}

void openTask(BuildContext context, String taskId) =>
    Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => RunScreen(taskId: taskId)));

// ------------------------------------------------------------------ Inbox

class InboxTab extends ConsumerStatefulWidget {
  const InboxTab({super.key});
  @override
  ConsumerState<InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends ConsumerState<InboxTab> {
  String filter = 'asks';
  bool _loaded = false;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final myName = view.myName;
    if (!_loaded && view.data.channels.isNotEmpty) {
      _loaded = true;
      for (final ch in view.data.channels) {
        ref.read(dataProvider.notifier).loadMessages(ch.id);
      }
    }
    final asks = view.asks;
    final review = view.review;
    final mentions = view.mentions(myName);
    final team = view.sync['teamName'] as String? ?? 'Relay';
    return TabPage(
      left: GlassTitlePill(leading: const Tile(Icon(LucideIcons.listChecks, size: 16, color: Colors.white)), title: team, chevron: false),
      right: GlassPill(items: [(LucideIcons.listFilter, null, 'Filter'), (LucideIcons.plus, () => showNewTaskSheet(context, ref), 'New task')]),
      title: 'Inbox',
      subtitle: '${view.runningCount} agent${view.runningCount == 1 ? '' : 's'} running · ${asks.length} need${asks.length == 1 ? 's' : ''} you',
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _Chip('Asks you', asks.length, filter == 'asks', () => setState(() => filter = 'asks')),
            _Chip('Review', review.length, filter == 'review', () => setState(() => filter = 'review')),
            _Chip('Mentions', mentions.length, filter == 'mentions', () => setState(() => filter = 'mentions')),
          ]),
        ),
        const SizedBox(height: 12),
        if (asks.isEmpty && review.isEmpty && mentions.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 40), child: Center(child: Text('Nothing needs you right now.', style: mt(15, color: MC.text2)))),
        if (filter == 'asks' || asks.isNotEmpty) for (final t in asks.take(filter == 'asks' ? 10 : 1)) Padding(padding: const EdgeInsets.only(bottom: 12), child: AskCard(task: t)),
        if (review.isNotEmpty && filter != 'mentions') ...[
          const MSection('Ready for review'),
          MCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final (i, t) in review.take(filter == 'review' ? 20 : 4).indexed) ...[
                if (i > 0) const Padding(padding: EdgeInsets.only(left: 64), child: Divider(height: 1, color: MC.separator)),
                _ReviewRow(t),
              ],
            ]),
          ),
        ],
        if (mentions.isNotEmpty) ...[
          const MSection('Mentions'),
          MCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final (i, m) in mentions.take(filter == 'mentions' ? 20 : 3).indexed) ...[
                if (i > 0) const Padding(padding: EdgeInsets.only(left: 64), child: Divider(height: 1, color: MC.separator)),
                _MentionRow(m),
              ],
            ]),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.count, this.selected, this.onTap);
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(color: selected ? MC.text : MC.fill, borderRadius: BorderRadius.circular(999)),
      child: Text('$label  $count', style: mt(15, w: FontWeight.w500, color: selected ? Colors.white : MC.text)),
    ),
  );
}

/// "Claude Code asks …" with one-tap answers, or a permission request.
class AskCard extends ConsumerStatefulWidget {
  const AskCard({super.key, required this.task});
  final Task task;
  @override
  ConsumerState<AskCard> createState() => _AskCardState();
}

class _AskCardState extends ConsumerState<AskCard> {
  final reply = TextEditingController();
  bool busy = false;

  Future<void> _do(Future<Object?> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
      reply.clear();
    } on RpcError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final client = ref.read(clientProvider);
    final t = widget.task;
    final run = view.data.activeRun(t);
    final agent = view.agent(run?.agentId ?? t.assignee, deviceId: run?.deviceId);
    final isPermission = t.data['attention'] == 'permission';
    final pending = run == null ? null : pendingPermission(ref.watch(runEventsProvider(run.id)));
    final question = t.str('question') ?? '';
    final choices = choicesIn(question);
    return MCard(
      onTap: () => openTask(context, t.id),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          AgentSquare(letter: agent.letter, color: agent.color, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${agent.name} ${isPermission ? 'wants to run' : 'asks'}', style: mt(17, w: FontWeight.w600)),
              Text('${view.data.keyOf(t)} · on ${view.whereRuns(t.str('runOn'))}', style: mt(14, color: MC.text2)),
            ]),
          ),
          MPill(shortAgo(t.updatedAt), fg: MC.orange, bg: MC.orangeWash),
        ]),
        const SizedBox(height: 12),
        if (isPermission) ...[
          Text(pending?.data['summary'] as String? ?? 'A command needs your OK.', style: mt(17)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: MButton('Deny', destructive: true, onTap: busy || pending == null ? null : () => _do(() => client.call(M.permissionsAnswer, {'runId': run!.id, 'requestId': pending.data['id'], 'answer': 'deny'})))),
            const SizedBox(width: 10),
            Expanded(child: MButton('Allow once', primary: true, onTap: busy || pending == null ? null : () => _do(() => client.call(M.permissionsAnswer, {'runId': run!.id, 'requestId': pending.data['id'], 'answer': 'allow_once'})))),
          ]),
        ] else ...[
          Text(question, style: mt(17)),
          const SizedBox(height: 14),
          if (choices != null) ...[
            Row(children: [
              Expanded(child: MButton(choices.$1, primary: true, onTap: busy ? null : () => _do(() => client.call(M.commentsPost, {'taskId': t.id, 'body': choices.$1})))),
              const SizedBox(width: 10),
              Expanded(child: MButton(choices.$2, onTap: busy ? null : () => _do(() => client.call(M.commentsPost, {'taskId': t.id, 'body': choices.$2})))),
            ]),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(color: MC.bg, borderRadius: BorderRadius.circular(999)),
            child: Row(children: [
              const Icon(LucideIcons.messageSquare, size: 16, color: MC.text3),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: reply,
                  style: mt(16),
                  cursorOpacityAnimates: false,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (v) => v.trim().isEmpty ? null : _do(() => client.call(M.commentsPost, {'taskId': t.id, 'body': v.trim()})),
                  decoration: InputDecoration(border: InputBorder.none, hintText: 'Reply in your own words', hintStyle: mt(16, color: MC.text3)),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// The newest permission request of a run that has no answer yet.
RunEvent? pendingPermission(List<RunEvent> events) {
  final answered = {for (final e in events.where((e) => e.type == RunEventType.permissionAnswer)) e.data['id']};
  return events.where((e) => e.type == RunEventType.permission && !answered.contains(e.data['id'])).lastOrNull;
}

class _ReviewRow extends ConsumerWidget {
  const _ReviewRow(this.t);
  final Task t;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(phoneViewProvider);
    final run = view.data.runsOf(t.id).lastOrNull;
    final agent = view.agent(run?.agentId ?? t.assignee, deviceId: run?.deviceId);
    final changes = view.data.changesOf(t.id);
    final adds = changes.fold<int>(0, (a, c) => a + ((c.data['additions'] as num?)?.toInt() ?? 0));
    final dels = changes.fold<int>(0, (a, c) => a + ((c.data['deletions'] as num?)?.toInt() ?? 0));
    final failing = t.data['attention'] == 'failed';
    return GestureDetector(
      onTap: () => openTask(context, t.id),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          AgentSquare(letter: agent.letter, color: agent.color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(17, w: FontWeight.w500)),
              Text.rich(TextSpan(style: mt(14, color: MC.text2), children: [
                if (changes.isNotEmpty) ...[
                  TextSpan(text: '+$adds ', style: mt(14, color: MC.green)),
                  TextSpan(text: '−$dels', style: mt(14, color: MC.red)),
                  const TextSpan(text: ' · '),
                ],
                TextSpan(text: failing ? 'failed' : view.data.keyOf(t), style: failing ? mt(14, color: MC.red) : null),
              ])),
            ]),
          ),
          const Icon(LucideIcons.chevronRight, color: MC.text3),
        ]),
      ),
    );
  }
}

class _MentionRow extends ConsumerWidget {
  const _MentionRow(this.m);
  final Message m;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ch = ref.watch(dataProvider).get<Channel>(Kind.channel, m.channelId);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => ChannelScreen(channelId: m.channelId))),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          PersonDot(m.author, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m.author} in #${ch?.name ?? 'channel'}', style: mt(17, w: FontWeight.w500)),
              Text(m.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(14, color: MC.text2)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A person's initials in a coloured circle.
class PersonDot extends StatelessWidget {
  const PersonDot(this.name, {super.key, this.size = 32, this.color});
  final String name;
  final double size;
  final Color? color;
  static const palette = [Color(0xFFD48A0A), Color(0xFF2E9E58), Color(0xFF8E5BD8), Color(0xFFD9534F), Color(0xFF2A8FBD)];
  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
    final initials = parts.isEmpty ? '?' : (parts.length > 1 ? parts[0][0] + parts[1][0] : parts[0].substring(0, parts[0].length > 1 ? 2 : 1)).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color ?? palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % palette.length], shape: BoxShape.circle),
      child: Text(initials, style: mt(size * 0.36, w: FontWeight.w700, color: Colors.white)),
    );
  }
}

// ------------------------------------------------------------------ Board

class BoardTab extends ConsumerStatefulWidget {
  const BoardTab({super.key, required this.projectId, required this.onPickProject});
  final String? projectId;
  final ValueChanged<String> onPickProject;
  @override
  ConsumerState<BoardTab> createState() => _BoardTabState();
}

class _BoardTabState extends ConsumerState<BoardTab> {
  String column = TaskStatus.running;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final project = view.data.get<Project>(Kind.project, widget.projectId);
    if (project == null) {
      return TabPage(title: 'Board', subtitle: 'No projects yet. Make one on your Mac.', children: const []);
    }
    final tasks = view.data.tasksOf(project.id);
    int n(String s) => tasks.where((t) => t.status == s).length;
    final shown = tasks.where((t) => t.status == column).toList()
      ..sort((a, b) => (b.data['attention'] != null ? 1 : 0).compareTo(a.data['attention'] != null ? 1 : 0));
    final running = n(TaskStatus.running);
    return TabPage(
      left: GlassTitlePill(
        leading: Tile(Text(project.key.substring(0, 1)), color: hexColor(project.color, MC.accent)),
        title: 'Projects',
        onTap: () async {
          final id = await showProjectPicker(context, view.data.projects, project.id);
          if (id != null) widget.onPickProject(id);
        },
      ),
      right: GlassPill(items: [(LucideIcons.listTodo, null, 'List'), (LucideIcons.plus, () => showNewTaskSheet(context, ref, projectId: project.id), 'New task')]),
      title: project.name,
      subtitle: '${tasks.length} tasks · $running running now',
      children: [
        GlassSegments<String>(
          options: [
            (TaskStatus.queued, 'Queued ${n(TaskStatus.queued)}'),
            (TaskStatus.running, 'Running $running'),
            (TaskStatus.review, 'Review ${n(TaskStatus.review)}'),
          ],
          value: column,
          onChanged: (v) => setState(() => column = v),
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty) Padding(padding: const EdgeInsets.only(top: 30), child: Center(child: Text('Nothing here.', style: mt(15, color: MC.text2)))),
        for (final t in shown) Padding(padding: const EdgeInsets.only(bottom: 12), child: TaskCardM(t)),
      ],
    );
  }
}

/// I02's task card: key, live pill, title, progress, current step, agent.
class TaskCardM extends ConsumerWidget {
  const TaskCardM(this.t, {super.key});
  final Task t;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(phoneViewProvider);
    final run = view.data.activeRun(t);
    final agent = view.agent(run?.agentId ?? t.assignee, deviceId: run?.deviceId ?? t.str('runOn'));
    final waiting = t.data['attention'] == 'question' || t.data['attention'] == 'permission';
    final live = run != null && RunStatus.isActive(run.status) && !waiting;
    final steps = (run?.data['toolCalls'] as num?)?.toInt() ?? 0;
    final pipeline = t.maps('pipeline');
    final stepNo = pipeline.indexWhere((s) => s['status'] != 'done');
    final assignee = t.assigneeKind == 'person' ? (t.assignee ?? '') : agent.name;
    return MCard(
      border: waiting ? const Color(0xFFF5C26B) : null,
      onTap: () => openTask(context, t.id),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(view.data.keyOf(t), style: mt(14, color: MC.text2, family: 'Menlo')),
          const Spacer(),
          if (live) MPill('Live · ${shortAgo(run.createdAt)}', dot: true),
          if (waiting) MPill(t.data['attention'] == 'permission' ? 'Needs your OK' : 'Waiting for an answer', fg: MC.orange, bg: MC.orangeWash),
        ]),
        const SizedBox(height: 8),
        Text(t.title, style: mt(18, w: FontWeight.w600)),
        if (live) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pipeline.isNotEmpty ? (stepNo < 0 ? 1 : stepNo / pipeline.length) : (steps / (steps + 6)).clamp(0.05, 0.9),
              minHeight: 5,
              backgroundColor: MC.fill,
              color: MC.green,
            ),
          ),
          if (run.data['currentStep'] != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              const Icon(LucideIcons.refreshCw, size: 14, color: MC.accent),
              const SizedBox(width: 8),
              Expanded(child: Text('${run.data['currentStep']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(14, color: MC.text2, family: 'Menlo'))),
            ]),
          ],
        ],
        const SizedBox(height: 10),
        Row(children: [
          if (t.assigneeKind == 'person') PersonDot(assignee, size: 20) else AgentSquare(letter: agent.letter, color: agent.color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('$assignee · ${view.whereRuns(t.str('runOn'))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mt(15, color: MC.text2))),
          if (waiting) Text('Answer', style: mt(15, w: FontWeight.w600, color: MC.accent))
          else if (pipeline.isNotEmpty && stepNo >= 0) Text('step ${stepNo + 1} of ${pipeline.length}', style: mt(14, color: MC.text2)),
        ]),
      ]),
    );
  }
}

// ------------------------------------------------------------------ Agents

class AgentsTab extends ConsumerWidget {
  const AgentsTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(phoneViewProvider);
    final runs = view.data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status) && r.deviceId == view.macId).length;
    final queued = view.data.tasksOf(null).where((t) => t.status == TaskStatus.queued && (t.str('runOn') ?? view.macId) == view.macId).length;
    final agents = view.data.agents;
    return TabPage(
      right: GlassPill(items: [(LucideIcons.circlePause, () => pauseAll(context, ref), 'Pause new work'), (LucideIcons.plus, () => showNewTaskSheet(context, ref), 'New task')]),
      title: 'Agents',
      subtitle: 'Your plans, running on your Mac',
      children: [
        MCard(
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: const Color(0xFFE6EFFC), borderRadius: BorderRadius.circular(12)),
              child: const Icon(LucideIcons.laptop, color: MC.accent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(view.macName, style: mt(17, w: FontWeight.w600)),
                Text('${view.macOnline ? 'Online' : 'Offline'} · $runs running · $queued queued', style: mt(14, color: MC.text2)),
              ]),
            ),
            view.macOnline ? const MPill('Awake', dot: true) : const MPill('Asleep', fg: MC.text2, bg: MC.fill),
          ]),
        ),
        const SizedBox(height: 12),
        if (agents.isNotEmpty)
          MCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (final (i, a) in agents.indexed) ...[
                if (i > 0) const Padding(padding: EdgeInsets.only(left: 68), child: Divider(height: 1, color: MC.separator)),
                _AgentRow(a),
              ],
            ]),
          ),
        if (view.sharedAgents.isNotEmpty) ...[
          const MSection('Shared by teammates'),
          MCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (final (i, (d, a)) in view.sharedAgents.indexed) ...[
                if (i > 0) const Padding(padding: EdgeInsets.only(left: 68), child: Divider(height: 1, color: MC.separator)),
                Builder(builder: (context) {
                  final busy = view.data.all<Run>(Kind.run).where((r) => r.deviceId == d.id && r.agentId == a['id'] && RunStatus.isActive(r.status)).firstOrNull;
                  final task = busy == null ? null : view.data.get<Task>(Kind.task, busy.taskId);
                  final who = d.person.isEmpty ? d.name : d.person.split(' ').first;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(children: [
                      AgentSquare(letter: '${a['letter'] ?? '?'}', color: hexColor(a['color'] as String?)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text("$who's ${a['name']}", style: mt(17, w: FontWeight.w500)),
                          Text(task == null ? 'Idle' : 'Working on ${view.data.keyOf(task)}', style: mt(14, color: MC.text2)),
                        ]),
                      ),
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: view.online.contains(d.id) ? MC.green : MC.text3, shape: BoxShape.circle)),
                    ]),
                  );
                }),
              ],
            ]),
          ),
        ],
      ],
    );
  }

  Future<void> pauseAll(BuildContext context, WidgetRef ref) async {
    final client = ref.read(clientProvider);
    final agents = ref.read(dataProvider).agents;
    final anyOn = agents.any((a) => a.enabled);
    try {
      for (final a in agents) {
        await client.call(M.agentsUpdate, {'id': a.id, 'fields': {'enabled': !anyOn}});
      }
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(anyOn ? 'No new work starts on your Mac.' : 'Agents take new work again.')));
    } on RpcError catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}

class _AgentRow extends ConsumerWidget {
  const _AgentRow(this.a);
  final AgentProfile a;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = hexColor(a.color);
    final active = (a.data['active'] as num?)?.toInt() ?? 0;
    final cost = ((a.data['today'] as Map?)?['costUsd'] as num?)?.toDouble() ?? 0;
    final cap = a.dailyCapUsd;
    final until = a.limitedUntil;
    final limited = until != null && until.isAfter(DateTime.now());
    final (String big, String small, double value, String line) = limited
        ? ('100%', 'today', 1, 'Limit reached · back at ${until.toLocal().hour.toString().padLeft(2, '0')}:${until.toLocal().minute.toString().padLeft(2, '0')}')
        : cap > 0
        ? ('\$${cost.toStringAsFixed(2)}', 'of \$${cap.toStringAsFixed(0)} today', (cost / cap).clamp(0, 1).toDouble(), '$active of ${a.slots} slots busy')
        : ('${(active / a.slots * 100).round()}%', 'slots busy', active / a.slots, active == 0 ? 'idle' : '$active of ${a.slots} slots busy');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(children: [
        Row(children: [
          AgentSquare(letter: a.letter, color: color, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name, style: mt(17, w: FontWeight.w600)),
              Text(a.enabled ? line : 'Paused', style: mt(14, color: limited ? MC.orange : MC.text2)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(big, style: mt(17, w: FontWeight.w600, color: limited ? MC.orange : MC.text)),
            Text(small, style: mt(12, color: MC.text2)),
          ]),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(value: value.clamp(0.02, 1), minHeight: 5, backgroundColor: MC.fill, color: limited ? const Color(0xFFF5A623) : color),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ Chat

class ChatTab extends ConsumerWidget {
  const ChatTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final unread = ref.watch(unreadProvider);
    return TabPage(
      title: 'Chat',
      subtitle: '${data.channels.length} channels',
      children: [
        MCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final (i, ch) in data.channels.indexed) ...[
              if (i > 0) const Padding(padding: EdgeInsets.only(left: 60), child: Divider(height: 1, color: MC.separator)),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => ChannelScreen(channelId: ch.id))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(children: [
                    const Tile(Text('#'), color: Color(0xFF8E8E93), size: 32),
                    const SizedBox(width: 12),
                    Expanded(child: Text(ch.name, style: mt(17, w: FontWeight.w500))),
                    if ((unread[ch.id] ?? 0) > 0) MPill('${unread[ch.id]}', fg: Colors.white, bg: MC.accent),
                    const Icon(LucideIcons.chevronRight, color: MC.text3),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ],
    );
  }
}
