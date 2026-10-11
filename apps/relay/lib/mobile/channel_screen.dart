import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../data/relay_data.dart';
import 'glass.dart';
import 'mobile_data.dart';
import 'mobile_shell.dart' show PersonDot, openTask;

/// I05 · a channel on the phone: bubbles, agent task cards, the digest,
/// and a composer that understands `/task @agent …`.
class ChannelScreen extends ConsumerStatefulWidget {
  const ChannelScreen({super.key, required this.channelId});
  final String channelId;
  @override
  ConsumerState<ChannelScreen> createState() => _ChannelScreenState();
}

class _ChannelScreenState extends ConsumerState<ChannelScreen> {
  final text = TextEditingController();
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(dataProvider.notifier).loadMessages(widget.channelId);
      await ref.read(unreadProvider.notifier).markRead(widget.channelId);
      _toEnd();
    });
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });

  Future<void> _send() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    text.clear();
    try {
      await ref.read(clientProvider).call(M.messagesPost, {'channelId': widget.channelId, 'body': body});
      _toEnd();
    } on RpcError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(phoneViewProvider);
    final ch = view.data.get<Channel>(Kind.channel, widget.channelId);
    final messages = view.data.messagesOf(widget.channelId);
    ref.listen(dataProvider.select((d) => d.messagesOf(widget.channelId).length), (a, b) {
      if (b > (a ?? 0)) {
        _toEnd();
        ref.read(unreadProvider.notifier).markRead(widget.channelId);
      }
    });
    final people = view.data.devices.map((d) => d.person).where((p) => p.isNotEmpty).toSet().length;
    final agents = view.data.agents.length + view.sharedAgents.length;
    final replying = [
      for (final t in view.data.tasksOf(null).where((t) => t.str('channelId') == widget.channelId))
        if (view.data.activeRun(t) case final r? when RunStatus.isActive(r.status)) view.agent(r.agentId, deviceId: r.deviceId),
    ];
    final top = MediaQuery.of(context).padding.top;
    final bottom = MediaQuery.of(context).padding.bottom;
    final myDevice = view.me;

    return Scaffold(
      backgroundColor: MC.bg,
      body: BackdropGroup(
        child: Stack(children: [
          ListView.builder(
            controller: scroll,
            padding: EdgeInsets.fromLTRB(16, top + 66, 16, bottom + 90),
            itemCount: messages.length + (replying.isEmpty ? 0 : 1),
            itemBuilder: (context, i) {
              if (i == messages.length) {
                final a = replying.first;
                return Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Row(children: [
                    Container(width: 12, height: 12, decoration: BoxDecoration(color: a.color, borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 8),
                    Text('${a.name} is replying…', style: mt(14, color: MC.text2)),
                  ]),
                );
              }
              final m = messages[i];
              final mine = m.authorKind == 'person' && (m.deviceId == myDevice || m.deviceId == view.macId);
              if (m.tag == 'digest') return _DigestBubble(m);
              if (mine) return _Mine(m);
              return _Theirs(m, view: view, showName: i == 0 || messages[i - 1].author != m.author);
            },
          ),
          Positioned(
            top: top + 6,
            left: 16,
            right: 16,
            child: Row(children: [
              GlassCircle(icon: LucideIcons.chevronLeft, onTap: () => Navigator.of(context).pop(), semantics: 'Back'),
              const Spacer(),
              SizedBox(
                height: 50,
                child: Glass(
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('# ${ch?.name ?? ''}', style: mt(16, w: FontWeight.w600)),
                    Text('$people people · $agents agents', style: mt(11, color: MC.text2)),
                  ]),
                ),
              ),
              const Spacer(),
              const GlassCircle(icon: LucideIcons.users, semantics: 'People'),
            ]),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: bottom + 8,
            child: Row(children: [
              GlassCircle(icon: LucideIcons.plus, onTap: () => text.text = '/task ', semantics: 'Make a task'),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 50,
                  child: Glass(
                    padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          controller: text,
                          style: mt(16),
                          cursorOpacityAnimates: false,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(border: InputBorder.none, hintText: 'Message or /task @agent …', hintStyle: mt(16, color: MC.text3)),
                        ),
                      ),
                      GestureDetector(
                        onTap: _send,
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: const BoxDecoration(color: MC.accent, shape: BoxShape.circle),
                          child: const Icon(LucideIcons.arrowUp, color: Colors.white, size: 20),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Message text with @mentions and /task in blue.
class _Rich extends StatelessWidget {
  const _Rich(this.text, {this.color = MC.text});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in RegExp(r'@[A-Za-z0-9_.-]+|^/task\b').allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(0), style: TextStyle(color: color == MC.text ? MC.accent : Colors.white, fontWeight: FontWeight.w600)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(TextSpan(style: mt(16, color: color, height: 1.3), children: spans));
  }
}

class _DigestBubble extends StatelessWidget {
  const _DigestBubble(this.m);
  final Message m;
  @override
  Widget build(BuildContext context) {
    final t = m.createdAt.toLocal();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: MCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Tile(Icon(LucideIcons.listChecks, size: 14, color: Colors.white), size: 26),
            const SizedBox(width: 10),
            Text('Overnight', style: mt(16, w: FontWeight.w600)),
            const SizedBox(width: 8),
            Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}', style: mt(14, color: MC.text2)),
          ]),
          const SizedBox(height: 8),
          Text(m.body.replaceFirst('Overnight: ', ''), style: mt(16)),
        ]),
      ),
    );
  }
}

class _Mine extends StatelessWidget {
  const _Mine(this.m);
  final Message m;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 70),
    child: Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: MC.accent, borderRadius: BorderRadius.circular(20)),
        child: _Rich(m.body, color: Colors.white),
      ),
    ),
  );
}

class _Theirs extends ConsumerWidget {
  const _Theirs(this.m, {required this.view, required this.showName});
  final Message m;
  final PhoneView view;
  final bool showName;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAgent = m.authorKind == 'agent';
    final agent = isAgent ? view.agent(null, deviceId: m.deviceId) : null;
    final a = isAgent ? (view.data.agents.where((x) => x.name == m.author).firstOrNull) : null;
    final device = view.data.get<DeviceInfo>(Kind.device, m.deviceId);
    final remote = device?.agents.where((x) => x['name'] == m.author).firstOrNull;
    final letter = a?.letter ?? (remote?['letter'] as String?) ?? agent?.letter ?? m.author.substring(0, 1);
    final color = a != null || remote != null ? view.agent(a?.id ?? remote?['id'] as String?, deviceId: m.deviceId).color : const Color(0xFF5A5A5E);
    final label = isAgent ? '${m.author} · agent on ${view.whereRuns(m.deviceId)}' : m.author.split(' ').first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showName) Padding(padding: const EdgeInsets.only(left: 44, bottom: 4), child: Text(label, style: mt(13, color: MC.text2))),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          isAgent ? AgentSquare(letter: letter, color: color, size: 32) : PersonDot(m.author, size: 32),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: MC.card, borderRadius: BorderRadius.circular(20)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (m.taskId != null) _TaskBits(m.taskId!, view: view) else _Rich(m.body),
              ]),
            ),
          ),
        ]),
      ]),
    );
  }
}

/// An agent's task card inside a bubble (I05).
class _TaskBits extends StatelessWidget {
  const _TaskBits(this.taskId, {required this.view});
  final String taskId;
  final PhoneView view;
  @override
  Widget build(BuildContext context) {
    final t = view.data.get<Task>(Kind.task, taskId);
    if (t == null) return Text('A task', style: mt(16));
    final run = view.data.activeRun(t);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('${view.data.keyOf(t)} · ${run == null ? 'new task' : view.agent(run.agentId, deviceId: run.deviceId).name}', style: mt(13, color: MC.text2, family: 'Menlo')),
        const SizedBox(width: 16),
        Text(TaskStatus.label(t.status), style: mt(13, w: FontWeight.w600, color: MC.accent)),
      ]),
      const SizedBox(height: 4),
      Text(t.title, style: mt(16, w: FontWeight.w600)),
      const SizedBox(height: 8),
      GestureDetector(
        onTap: () => openTask(context, t.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(color: MC.bg, borderRadius: BorderRadius.circular(999)),
          child: Text(run == null ? 'Open task' : 'Watch run', style: mt(15, w: FontWeight.w600, color: MC.accent)),
        ),
      ),
    ]);
  }
}
