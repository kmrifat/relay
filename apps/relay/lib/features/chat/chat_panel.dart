import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/breadcrumbs.dart';
import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/markdown.dart';
import '../../ui/platform.dart';
import '../../ui/widgets.dart';
import '../agents/model_picker.dart';

/// The chat panel on the right of every page: open or not, the chat on
/// show, and the agent (with model and effort) the next message goes to.
class ChatState {
  const ChatState({this.open = false, this.agentId, this.chatId, this.model, this.effort, this.focus = 0});
  final bool open;
  final String? agentId;

  /// The chat on show; null for a new one.
  final String? chatId;
  final String? model, effort;

  /// Bumped to put the cursor in the composer.
  final int focus;

  ChatState copyWith({bool? open, String? agentId, String? chatId, bool newChat = false, String? model, String? effort, bool clearModel = false, int? focus}) => ChatState(
        open: open ?? this.open,
        agentId: agentId ?? this.agentId,
        chatId: newChat ? null : (chatId ?? this.chatId),
        model: clearModel ? null : (model ?? this.model),
        effort: clearModel ? null : (effort ?? this.effort),
        focus: focus ?? this.focus,
      );
}

class ChatNotifier extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  void toggle() => state = state.copyWith(open: !state.open, focus: state.focus + 1);
  void close() => state = state.copyWith(open: false);

  /// Opens the panel on a new chat with [agentId].
  void openWith(String agentId) => state = state.copyWith(open: true, agentId: agentId, newChat: true, clearModel: true, focus: state.focus + 1);
  void newChat() => state = state.copyWith(newChat: true, focus: state.focus + 1);
  void show(String chatId, String? agentId) => state = state.copyWith(chatId: chatId, agentId: agentId, clearModel: true);

  /// Opens the panel on an earlier chat.
  void reopen(String chatId, String agentId) => state = state.copyWith(open: true, chatId: chatId, agentId: agentId, clearModel: true, focus: state.focus + 1);
  void agent(String id) => state = state.copyWith(agentId: id, clearModel: true);
  void modelEffort(String? model, String? effort) => state = ChatState(open: state.open, agentId: state.agentId, chatId: state.chatId, model: model, effort: effort, focus: state.focus);
  void started(String chatId) => state = state.copyWith(chatId: chatId);
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);

/// The agents a chat can go to: every one installed here, CLIs first.
List<AgentProfile> chatAgents(DataSnapshot data) =>
    [...data.clis, ...data.agents.where((a) => a.isRole)].where((a) => a.binaryPath != null && a.enabled).toList();

/// The right-hand chat: pick any agent, ask about your work or tell it what
/// to do. It sees the page you are on; task keys in its answers are links.
class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key});
  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final text = TextEditingController();
  final focus = FocusNode(debugLabel: 'chat');
  bool sending = false;
  String? error;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
    focus.onKeyEvent = (node, e) {
      if (e is! KeyDownEvent) return KeyEventResult.ignored;
      if (e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
        _send();
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        ref.read(chatProvider.notifier).close();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => focus.requestFocus());
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  /// What the person is looking at, for the agent: the breadcrumb, and the
  /// open task's title.
  String _context(DataSnapshot data, NavState nav) {
    final path = crumbsFor(nav, data).map((c) => c.label).join(' › ');
    final task = data.get<Task>(Kind.task, nav.taskId);
    return task == null ? path : '$path (${task.title})';
  }

  Future<void> _send([String? preset]) async {
    final body = (preset ?? text.text).trim();
    if (body.isEmpty || sending) return;
    final data = ref.read(dataProvider);
    final nav = ref.read(navProvider);
    final s = ref.read(chatProvider);
    final agent = _agent(data, s);
    if (agent == null) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final r = await ref.read(clientProvider).map(M.chatsSend, {
        'chatId': ?s.chatId,
        'agentId': agent.id,
        'text': body,
        'context': _context(data, nav),
        'projectId': ?(nav.projectId ?? data.get<Task>(Kind.task, nav.taskId)?.projectId),
        'model': ?s.model,
        'effort': ?s.effort,
      });
      ref.read(chatProvider.notifier).started(r['chatId'] as String);
      if (preset == null) text.clear();
    } on RpcError catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => sending = false);
    }
    focus.requestFocus();
  }

  AgentProfile? _agent(DataSnapshot data, ChatState s) {
    final agents = chatAgents(data);
    return agents.where((a) => a.id == s.agentId).firstOrNull ??
        agents.where((a) => a.id == 'claude-code').firstOrNull ??
        agents.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final nav = ref.watch(navProvider);
    final s = ref.watch(chatProvider);
    ref.listen(chatProvider.select((s) => s.focus), (_, _) => focus.requestFocus());
    final agent = _agent(data, s);
    final chat = data.get<Task>(Kind.task, s.chatId);
    final runs = chat == null ? const <Run>[] : data.runsOf(chat.id);
    final live = runs.where((r) => RunStatus.isActive(r.status)).lastOrNull;

    return Container(
      color: c.window,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _header(context, data, s, chat),
        Container(height: 1, color: c.separator),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _AgentPick(agent: agent, onPick: (id) => ref.read(chatProvider.notifier).agent(id)),
            if (agent != null && (agent.models.isNotEmpty || agent.efforts.isNotEmpty))
              ModelEffortPicker(agent: agent, model: s.model, effort: s.effort, inherited: s.model == null && s.effort == null ? 'its default' : null, onChanged: ref.read(chatProvider.notifier).modelEffort),
          ]),
        ),
        Container(height: 1, color: c.separator),
        Expanded(
          child: chat == null
              ? _Welcome(agent: agent, onAsk: _send)
              : ListView(reverse: true, padding: const EdgeInsets.fromLTRB(14, 14, 14, 6), children: [
                  for (final r in runs.reversed) _Turn(run: r),
                ]),
        ),
        _composer(context, data, nav, agent, live),
      ]),
    );
  }

  Widget _header(BuildContext context, DataSnapshot data, ChatState s, Task? chat) {
    final c = context.c;
    final n = ref.read(chatProvider.notifier);
    final past = data.all<Task>(Kind.task).where((t) => t.data['ask'] == 'chat').toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Container(
      height: 52,
      color: c.toolbar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Icon(LucideIcons.sparkles, size: 15, color: c.accentIcon),
        const SizedBox(width: 8),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Chat', style: context.t(13, w: FontWeight.w700)),
            Text(chat == null ? 'New chat' : chat.title.replaceFirst('Chat: ', ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.text2)),
          ]),
        ),
        if (past.isNotEmpty)
          Builder(builder: (context) => IconBtn(LucideIcons.history, tooltip: 'Earlier chats', onTap: () async {
            final box = context.findRenderObject() as RenderBox;
            final id = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
              for (final t in past.take(15)) (t.id, '${t.title.replaceFirst('Chat: ', '')}  ·  ${ago(t.createdAt)}', null),
            ]);
            if (id != null) n.show(id, data.get<Task>(Kind.task, id)?.assignee);
          })),
        IconBtn(LucideIcons.squarePen, tooltip: 'New chat', onTap: n.newChat),
        IconBtn(LucideIcons.panelRightClose, tooltip: 'Hide chat  ${Desk.isMac ? '⌘J' : 'Ctrl+J'}', onTap: n.close),
      ]),
    );
  }

  Widget _composer(BuildContext context, DataSnapshot data, NavState nav, AgentProfile? agent, Run? live) {
    final c = context.c;
    final where = crumbsFor(nav, data).map((c) => c.label).join(' › ');
    final ready = agent != null && text.text.trim().isNotEmpty && !sending;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (error != null)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(error!, style: context.t(11, color: c.danger))),
        Container(
          decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(8), border: Border.all(color: focus.hasFocus ? c.accentIcon : c.fieldStroke)),
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              controller: text,
              focusNode: focus,
              minLines: 1,
              maxLines: 8,
              cursorOpacityAnimates: false,
              style: context.t(13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: agent == null ? 'No agent installed' : (live != null ? 'Add to what ${agent.name} is doing…' : 'Ask ${agent.name} anything, or tell it what to do'),
                hintStyle: context.t(13, color: c.text3),
              ),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Icon(LucideIcons.eye, size: 11, color: c.text3),
              const SizedBox(width: 4),
              Expanded(child: Tooltip(message: 'The agent is told which page you are on', child: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(10.5, color: c.text3)))),
              if (live != null)
                IconBtn(LucideIcons.square, size: 13, tooltip: 'Stop', onTap: () => ref.read(clientProvider).call(M.runsStop, {'runId': live.id})),
              Tooltip(
                message: '↵ sends · ⇧↵ new line',
                child: Pressable(
                  onTap: ready ? _send : null,
                  builder: (context, hover, f) => Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(color: ready ? c.accent : c.inner, borderRadius: BorderRadius.circular(6)),
                    child: sending
                        ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                        : Icon(LucideIcons.arrowUp, size: 13, color: ready ? Colors.white : c.text3),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Which agent the chat goes to: its tile and name; click to switch.
class _AgentPick extends ConsumerWidget {
  const _AgentPick({required this.agent, required this.onPick});
  final AgentProfile? agent;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final agents = chatAgents(ref.watch(dataProvider));
    return Pressable(
      onTap: agents.length < 2
          ? null
          : () async {
              final box = context.findRenderObject() as RenderBox;
              final id = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
                for (final a in agents) (a.id, a.isRole && a.role.isNotEmpty ? '${a.name} · ${a.role}' : a.name, a.id == agent?.id ? LucideIcons.check : null),
              ]);
              if (id != null) onPick(id);
            },
      builder: (context, hover, focus) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        foregroundDecoration: focusRing(context, focus, 5),
        decoration: BoxDecoration(color: hover ? c.control : c.inner, borderRadius: BorderRadius.circular(5)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AgentTile(agent: agent, size: 14),
          const SizedBox(width: 6),
          Text(agent?.name ?? 'No agent', style: context.t(11.5, w: FontWeight.w600)),
          if (agents.length > 1) ...[const SizedBox(width: 4), Icon(LucideIcons.chevronDown, size: 11, color: c.text2)],
        ]),
      ),
    );
  }
}

/// A new chat: what it is for, and a few things to ask for this page.
class _Welcome extends ConsumerWidget {
  const _Welcome({required this.agent, required this.onAsk});
  final AgentProfile? agent;
  final ValueChanged<String> onAsk;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final nav = ref.watch(navProvider);
    final task = data.get<Task>(Kind.task, nav.taskId);
    final onAgent = nav.page == AppPage.agent ? data.get<AgentProfile>(Kind.agent, nav.agentId) : null;
    final project = nav.page == AppPage.project ? data.get<Project>(Kind.project, nav.projectId) : null;
    final ideas = [
      if (task != null) 'Where is ${data.keyOf(task)} at, and what is left?',
      if (onAgent != null) 'What is ${onAgent.name} working on?',
      if (project != null && task == null) 'How is ${project.name} going?',
      'What needs me right now?',
      'What did the agents finish today?',
    ];
    return ListView(padding: const EdgeInsets.all(18), children: [
      Text(agent == null ? 'No agent to chat with' : 'Chat with ${agent!.name}', style: context.t(15, w: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(
        agent == null
            ? 'Relay found no agent CLI on this Mac. Install one, then press Find CLIs on the Agents page.'
            : 'Ask about your projects, tasks and agents, or tell it what to do: move tasks, make new ones, explain code. '
                'It runs on your own ${agent!.name} and knows which page you are on.',
        style: context.t(12, color: c.text2, height: 1.4),
      ),
      if (agent != null) ...[
        const SizedBox(height: 16),
        Text('Try', style: context.label),
        const SizedBox(height: 6),
        for (final idea in ideas)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Hoverable(
              onTap: () => onAsk(idea),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: c.boxStroke), borderRadius: BorderRadius.circular(6)),
                child: Row(children: [
                  Expanded(child: Text(idea, style: context.t(12))),
                  Icon(LucideIcons.arrowUpRight, size: 12, color: c.text3),
                ]),
              ),
            ),
          ),
      ],
    ]);
  }
}

/// One turn: what the person said, then the agent's steps and reply.
class _Turn extends ConsumerWidget {
  const _Turn({required this.run});
  final Run run;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final events = ref.watch(runEventsProvider(run.id));
    final answered = {for (final e in events.where((e) => e.type == RunEventType.permissionAnswer)) e.data['id']};
    final results = {for (final e in events.where((e) => e.type == RunEventType.toolResult)) e.data['id']: e};
    final agent = data.get<AgentProfile>(Kind.agent, run.agentId);
    final active = RunStatus.isActive(run.status);
    final asked = run.data['chatText'] as String?;
    final shown = <Widget>[];
    for (final e in events) {
      final w = switch (e.type) {
        RunEventType.message => _reply(context, ref, '${e.data['text']}'),
        RunEventType.toolUse => _step(context, e, results[e.data['id']]),
        RunEventType.steer => _said(context, '${e.data['text']}'),
        RunEventType.permission => _permission(context, ref, e, pending: active && !answered.contains(e.data['id'])),
        RunEventType.error => Text('${e.data['text']}', style: context.t(11.5, color: c.danger)),
        RunEventType.status when e.data['status'] == 'failed' || e.data['status'] == 'stopped' =>
          Text(e.data['status'] == 'failed' ? 'Failed: ${e.data['detail'] ?? ''}' : 'Stopped', maxLines: 4, overflow: TextOverflow.ellipsis, style: context.t(11, color: e.data['status'] == 'failed' ? c.danger : c.text3)),
        _ => null,
      };
      if (w != null) shown.add(Padding(padding: const EdgeInsets.only(bottom: 8), child: w));
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (asked != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: _said(context, asked)),
        Row(children: [
          AgentTile(agent: agent, agentId: run.agentId, size: 14),
          const SizedBox(width: 6),
          Text(agent?.name ?? run.agentId, style: context.t(11, w: FontWeight.w600, color: c.text2)),
          if (run.model != null) Text('  ·  ${run.model}', style: context.t(11, color: c.text3)),
        ]),
        const SizedBox(height: 6),
        ...shown,
        if (active && run.status != RunStatus.waiting)
          Row(children: [
            SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.4, color: c.accentIcon)),
            const SizedBox(width: 8),
            Text('Working…', style: context.t(11, color: c.text3)),
          ]),
      ]),
    );
  }

  Widget _said(BuildContext context, String text) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(color: context.c.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
          child: SelectableText(text, style: context.t(12.5)),
        ),
      );

  Widget _reply(BuildContext context, WidgetRef ref, String text) {
    final data = ref.read(dataProvider);
    return Markdown(linkTaskKeys(text, data), style: context.md(12.5), onLink: (url) => openRelayLink(ref, url));
  }

  Widget _step(BuildContext context, RunEvent e, RunEvent? result) {
    final c = context.c;
    final ok = result?.data['ok'] != false;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: result == null
            ? Icon(LucideIcons.circleDashed, size: 11, color: c.accentIcon)
            : Icon(ok ? LucideIcons.check : LucideIcons.x, size: 11, color: ok ? c.text3 : c.danger),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text('${_tool('${e.data['tool']}')}  ${e.data['summary'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, family: mono, color: c.text3)),
      ),
    ]);
  }

  /// `mcp__relay__relay_tasks` reads better as `relay_tasks`.
  static String _tool(String t) => t.startsWith('mcp__') ? t.split('__').last : t;

  Widget _permission(BuildContext context, WidgetRef ref, RunEvent e, {required bool pending}) {
    final c = context.c;
    Future<void> answer(String a) => ref.read(clientProvider).call(M.permissionsAnswer, {'runId': run.id, 'requestId': e.data['id'], 'answer': a});
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pending ? c.warningWash : c.bar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: pending ? c.warning : c.inner),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(LucideIcons.shieldCheck, size: 13, color: pending ? c.warning : c.text3),
          const SizedBox(width: 6),
          Expanded(child: Text(pending ? 'Wants to use ${_tool('${e.data['tool']}')}' : 'Asked to use ${_tool('${e.data['tool']}')}', style: context.t(12, w: FontWeight.w700))),
        ]),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: c.codeBg, borderRadius: BorderRadius.circular(6)),
          child: SelectableText('${e.data['summary']}', maxLines: 6, style: context.t(11, family: mono)),
        ),
        if (pending) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            Btn('Allow', kind: BtnKind.primary, small: true, onTap: () => answer('allow_once')),
            Btn('Allow for this answer', small: true, onTap: () => answer('allow_always')),
            Btn('Deny', kind: BtnKind.danger, small: true, onTap: () => answer('deny')),
          ]),
        ],
      ]),
    );
  }
}

/// Task keys of known projects (e.g. RL-30) become `relay:task/RL-30`
/// links, unless they already are a link or inside code.
String linkTaskKeys(String text, DataSnapshot data) {
  final keys = data.projects.map((p) => RegExp.escape(p.key.toUpperCase())).where((k) => k.isNotEmpty).toList();
  if (keys.isEmpty) return text;
  final re = RegExp('(?<![\\[/`\\w-])((?:${keys.join('|')})-\\d+)(?![\\w\\]`-])');
  return text.replaceAllMapped(re, (m) => '[${m[1]}](relay:task/${m[1]})');
}

/// Opens a `relay:task/KEY` link in Relay, anything else in the browser.
void openRelayLink(WidgetRef ref, String url) {
  if (!url.startsWith('relay:task/')) return openWebLink(url);
  final key = url.substring('relay:task/'.length);
  final data = ref.read(dataProvider);
  final task = data.all<Task>(Kind.task).where((t) => data.keyOf(t) == key).firstOrNull;
  if (task != null) ref.read(navProvider.notifier).openTask(task.id);
}
