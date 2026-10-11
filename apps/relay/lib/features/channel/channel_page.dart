
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../../ui/platform.dart';
import '../task/task_bits.dart';

/// An agent you can @mention: this Mac's, or a teammate's shared one.
typedef ChannelAgent = ({String id, String name, String color, String letter, String deviceId, String owner, bool mine});

/// The team's agents as `@handles`, this Mac's first.
List<ChannelAgent> channelAgents(DataSnapshot data, String me, String myName) => [
  for (final a in data.agents.where((a) => a.binaryPath != null && a.enabled))
    (id: a.id, name: a.name, color: a.color, letter: a.letter, deviceId: me, owner: myName, mine: true),
  for (final d in data.devices.where((d) => d.id != me && d.shareAgents))
    for (final a in d.agents)
      (id: '${a['id']}', name: '${a['name']}', color: '${a['color'] ?? ''}', letter: '${a['letter'] ?? '?'}', deviceId: d.id, owner: d.person.isEmpty ? d.name : d.person, mine: false),
];

/// T04 · a team channel.
class ChannelPage extends ConsumerStatefulWidget {
  const ChannelPage({super.key, required this.channelId});
  final String channelId;
  @override
  ConsumerState<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends ConsumerState<ChannelPage> {
  final scroll = ScrollController();
  final search = TextEditingController();
  String query = '';

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(ChannelPage old) {
    super.didUpdateWidget(old);
    if (old.channelId != widget.channelId) _open();
  }

  Future<void> _open() async {
    await ref.read(dataProvider.notifier).loadMessages(widget.channelId);
    await ref.read(unreadProvider.notifier).markRead(widget.channelId);
    _toBottom();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final ch = data.get<Channel>(Kind.channel, widget.channelId);
    if (ch == null) return const Center(child: Text('No such channel'));
    final client = ref.read(clientProvider);
    final me = client.hello['deviceId'] as String? ?? '';
    final myName = client.hello['userName'] as String? ?? 'You';
    final all = data.messagesOf(ch.id);
    final shown = query.isEmpty ? all : all.where((m) => '${m.author} ${m.body}'.toLowerCase().contains(query.toLowerCase())).toList();
    final project = ch.projectId == null ? null : data.get<Project>(Kind.project, ch.projectId);
    final people = data.devices.map((d) => d.person).where((p) => p.isNotEmpty).toSet();
    final agents = channelAgents(data, me, myName);

    // New messages while open: keep at the bottom, keep it read.
    ref.listen(dataProvider.select((d) => d.messagesOf(widget.channelId).length), (a, b) {
      if ((b) > (a ?? 0)) {
        final atEnd = !scroll.hasClients || scroll.position.pixels >= scroll.position.maxScrollExtent - 80;
        if (atEnd) _toBottom();
        ref.read(unreadProvider.notifier).markRead(widget.channelId);
      }
    });

    // "Claude Code is replying in TM-44…": channel tasks with an active run.
    final replying = [
      for (final t in data.tasksOf(null).where((t) => t.str('channelId') == ch.id))
        if (data.activeRun(t) case final r? when RunStatus.isActive(r.status)) (data.get<AgentProfile>(Kind.agent, r.agentId)?.name ?? r.agentId, data.keyOf(t)),
    ];

    return Column(children: [
      Toolbar(
        leading: Icon(LucideIcons.hash, size: 16, color: c.text2),
        title: ch.name,
        subtitle: [
          '${people.isEmpty ? 1 : people.length} ${people.length == 1 ? 'person' : 'people'}',
          '${agents.length} agent${agents.length == 1 ? '' : 's'}',
          if (project != null) 'linked to ${project.name} board' else if (ch.topic.isNotEmpty) ch.topic,
        ].join(' · '),
        actions: [
          SizedBox(
            width: 240,
            child: TextField(
              controller: search,
              onChanged: (v) => setState(() => query = v.trim()),
              cursorOpacityAnimates: false,
              style: context.t(12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search in channel',
                hintStyle: context.t(12, color: c.text3),
                prefixIcon: Icon(LucideIcons.search, size: 13, color: c.text3),
                prefixIconConstraints: const BoxConstraints(minWidth: 28),
                filled: true,
                fillColor: c.toolbarField,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
              ),
            ),
          ),
          Pill('${people.length + agents.length}', icon: LucideIcons.users, bg: c.control),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Column(children: [
              Expanded(
                child: shown.isEmpty
                    ? Center(child: Text(query.isEmpty ? 'No messages yet. Say hi, or try /task @agent …' : 'Nothing matches.', style: context.t(12, color: c.text3)))
                    : ListView.builder(
                        controller: scroll,
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final m = shown[i];
                          final prev = i == 0 ? null : shown[i - 1];
                          final day = _day(m.createdAt.toLocal());
                          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            if (prev == null || _day(prev.createdAt.toLocal()) != day) _DaySeparator(day),
                            _MessageRow(m, channel: ch, me: me),
                          ]);
                        },
                      ),
              ),
              if (replying.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(62, 0, 20, 6),
                  child: Row(children: [
                    Container(width: 12, height: 12, decoration: BoxDecoration(color: c.warning.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(3))),
                    const SizedBox(width: 8),
                    Text('${replying.first.$1} is replying in ${replying.first.$2}…${replying.length > 1 ? ' (+${replying.length - 1} more)' : ''}',
                        style: context.t(11, color: c.text2)),
                  ]),
                ),
              _Composer(channel: ch, agents: agents, onSent: _toBottom),
            ]),
          ),
          Container(width: 1, color: c.separator),
          SizedBox(width: 264, child: _SidePanel(channel: ch, agents: agents, me: me)),
        ]),
      ),
    ]);
  }

  static String _day(DateTime t) {
    final now = DateTime.now();
    final d = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[t.month - 1]} ${t.day}${t.year == now.year ? '' : ', ${t.year}'}';
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(children: [
      Expanded(child: Container(height: 1, color: context.c.separator)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(label, style: context.t(11, w: FontWeight.w600, color: context.c.text2))),
      Expanded(child: Container(height: 1, color: context.c.separator)),
    ]),
  );
}

/// One message: avatar, name, tag, time, body with @mentions, then a digest,
/// task card, files and reactions. Hover for react / pin / delete.
class _MessageRow extends ConsumerStatefulWidget {
  const _MessageRow(this.m, {required this.channel, required this.me});
  final Message m;
  final Channel channel;
  final String me;
  @override
  ConsumerState<_MessageRow> createState() => _MessageRowState();
}

class _MessageRowState extends ConsumerState<_MessageRow> {
  bool hover = false;

  static const quick = ['👍', '✅', '👀', '🎉', 'noted'];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = widget.m;
    final data = ref.watch(dataProvider);
    final client = ref.read(clientProvider);
    final myName = client.hello['userName'] as String? ?? 'You';
    final device = m.deviceId == null ? null : data.get<DeviceInfo>(Kind.device, m.deviceId);
    final isMine = m.authorKind == 'person' && m.deviceId == widget.me;
    final t = m.createdAt.toLocal();
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    Widget avatar;
    String? tag;
    switch (m.authorKind) {
      case 'agent':
        final local = data.agents.where((a) => a.name == m.author).firstOrNull;
        final remote = device?.agents.where((a) => a['name'] == m.author).firstOrNull;
        avatar = AgentTile(agent: local ?? (remote == null ? null : AgentProfile(remote)), agentId: m.author, size: 32);
        tag = 'AGENT · ${m.deviceId == widget.me ? 'THIS MAC' : ((device?.person.isNotEmpty ?? false) ? "${device!.person.split(' ').first.toUpperCase()}'S MAC" : (device?.name.toUpperCase() ?? 'TEAMMATE'))}';
      case 'system':
        avatar = Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(8)),
          child: const Icon(LucideIcons.listChecks, size: 16, color: Colors.white),
        );
        tag = m.tag == 'digest' ? 'DIGEST' : null;
      default:
        avatar = Avatar(m.author, size: 32, color: isMine ? c.accent : _personColor(m.author));
    }

    final pinned = widget.channel.pins.contains(m.id);
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(color: hover ? c.inner.withValues(alpha: 0.5) : Colors.transparent, borderRadius: BorderRadius.circular(8)),
        child: Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            avatar,
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(isMine ? myName : m.author, style: context.t(13, w: FontWeight.w700)),
                  if (tag != null) ...[const SizedBox(width: 6), Pill(tag, radius: 3)],
                  const SizedBox(width: 6),
                  Text(time, style: context.t(11, color: c.text3)),
                  if (pinned) ...[const SizedBox(width: 6), Icon(LucideIcons.pin, size: 11, color: c.text3)],
                ]),
                const SizedBox(height: 3),
                if (m.tag == 'digest') _Digest(m) else if (m.body.isNotEmpty) _Body(m.body),
                if (m.taskId != null && m.tag != 'digest') ...[const SizedBox(height: 8), _TaskCard(m.taskId!)],
                for (final f in m.files) ...[const SizedBox(height: 8), _FileCard(m, f)],
                if (m.reactions.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final MapEntry(key: emoji, value: who) in m.reactions.entries)
                      Tooltip(
                        message: who.join(', '),
                        child: GestureDetector(
                          onTap: () => client.call(M.messagesReact, {'messageId': m.id, 'emoji': emoji, 'on': !who.contains(myName.replaceAll('.', ''))}),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: who.contains(myName.replaceAll('.', '')) ? c.accent.withValues(alpha: 0.18) : c.inner,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(color: who.contains(myName.replaceAll('.', '')) ? c.accent.withValues(alpha: 0.5) : c.boxStroke),
                            ),
                            child: Text('$emoji  ${who.length}', style: context.t(11)),
                          ),
                        ),
                      ),
                  ]),
                ],
              ]),
            ),
          ]),
          if (hover)
            Positioned(
              right: 0,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(6), border: Border.all(color: c.boxStroke)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  for (final e in quick.take(3))
                    IconButtonText(e, onTap: () => client.call(M.messagesReact, {'messageId': m.id, 'emoji': e})),
                  Builder(builder: (context) => IconBtn(LucideIcons.smilePlus, size: 13, tooltip: 'React', onTap: () async {
                    final box = context.findRenderObject() as RenderBox;
                    final e = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [for (final q in quick) (q, q, null)]);
                    if (e != null) await client.call(M.messagesReact, {'messageId': m.id, 'emoji': e});
                  })),
                  IconBtn(pinned ? LucideIcons.pinOff : LucideIcons.pin, size: 13, tooltip: pinned ? 'Unpin' : 'Pin',
                      onTap: () => client.call(M.channelsPin, {'channelId': widget.channel.id, 'messageId': m.id, 'on': !pinned})),
                  if (isMine) IconBtn(LucideIcons.trash2, size: 13, tooltip: 'Delete', onTap: () => client.call(M.messagesDelete, {'id': m.id})),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  static Color _personColor(String name) {
    const palette = [Color(0xFFD48A0A), Color(0xFF2E9E58), Color(0xFF8E5BD8), Color(0xFFD9534F), Color(0xFF2A8FBD), Color(0xFF6E6E73)];
    return palette[name.codeUnits.fold<int>(0, (a, b) => a + b) % palette.length];
  }
}

/// A small text button for the hover bar (quick reactions).
class IconButtonText extends StatelessWidget {
  const IconButtonText(this.text, {super.key, this.onTap});
  final String text;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3), child: Text(text, style: context.t(12))),
    ),
  );
}

/// Message text with @mentions highlighted.
class _Body extends StatelessWidget {
  const _Body(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in RegExp(r'@[A-Za-z0-9_.-]+|^/task\b').allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(0), style: TextStyle(color: c.accentIcon, fontWeight: FontWeight.w600)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return SelectableText.rich(TextSpan(style: context.t(13, color: c.text), children: spans));
  }
}

/// The morning digest: headline + one line per task.
class _Digest extends ConsumerWidget {
  const _Digest(this.m);
  final Message m;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final items = m.maps('items');
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.boxStroke)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(m.body, style: context.t(13, w: FontWeight.w700)),
        const SizedBox(height: 6),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Hoverable(
              onTap: () => ref.read(navProvider.notifier).openTask('${it['taskId']}'),
              child: Row(children: [
                Icon(it['ok'] == true ? LucideIcons.circleCheck : LucideIcons.x, size: 13, color: it['ok'] == true ? c.success : c.danger),
                const SizedBox(width: 8),
                Expanded(child: Text('${it['key']} ${it['title']} — ${it['agent']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12))),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// A task a message made or reports on: key, status, title, who and where.
class _TaskCard extends ConsumerWidget {
  const _TaskCard(this.taskId);
  final String taskId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final t = data.get<Task>(Kind.task, taskId);
    if (t == null) return Text('A task that is not on ${Desk.thisComputer} yet.', style: context.t(12, color: c.text3));
    final run = data.activeRun(t) ?? data.runsOf(t.id).lastOrNull;
    final device = data.get<DeviceInfo>(Kind.device, t.str('runOn'));
    final me = ref.read(clientProvider).hello['deviceId'];
    final remote = t.str('runOn') != null && t.str('runOn') != me;
    final where = !remote ? Desk.thisComputer : (device?.person.isNotEmpty ?? false) ? "${device!.person.split(' ').first}'s Mac" : (device?.name ?? 'a teammate\'s Mac');
    final agentName = t.assigneeKind != 'agent'
        ? (t.assignee ?? 'Unassigned')
        : remote
        ? '${device?.agents.where((a) => a['id'] == t.assignee).firstOrNull?['name'] ?? t.assignee ?? 'Any agent'}'
        : (data.get<AgentProfile>(Kind.agent, t.assignee)?.name ?? t.assignee ?? 'Any agent');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.boxStroke)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(data.keyOf(t), style: context.t(11, color: c.text2, family: mono)),
            const SizedBox(width: 8),
            const Spacer(),
            Icon(statusIcon(t.status), size: 12, color: statusColor(context, t.status)),
            const SizedBox(width: 4),
            Text(TaskStatus.label(t.status), style: context.t(11, color: statusColor(context, t.status))),
          ]),
          const SizedBox(height: 4),
          Text(t.title, style: context.t(13, w: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('$agentName · $where${run?.data['branch'] != null ? ' · branch ${run!.data['branch']}' : ''}', style: context.t(11, color: c.text2)),
          const SizedBox(height: 8),
          Row(children: [
            Btn('Open task', small: true, onTap: () => ref.read(navProvider.notifier).openTask(t.id)),
            if (run != null && RunStatus.isActive(run.status)) ...[
              const SizedBox(width: 6),
              Btn('Watch run', small: true, onTap: () => ref.read(navProvider.notifier).openTask(t.id)),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _FileCard extends ConsumerWidget {
  const _FileCard(this.m, this.f);
  final Message m;
  final Map<String, Object?> f;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final size = (f['size'] as num?)?.toInt() ?? 0;
    final where = f['stored'] == 'team' ? 'stored in your team storage · encrypted' : 'on ${Desk.thisComputer}';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Hoverable(
        onTap: () async {
          try {
            final path = (await ref.read(clientProvider).map(M.filesGet, {'messageId': m.id, 'fileId': f['id']}))['path'] as String;
            await Desk.open(path);
          } on RpcError catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.boxStroke)),
          child: Row(children: [
            Icon(LucideIcons.fileText, size: 18, color: c.accentIcon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${f['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, w: FontWeight.w600)),
                Text('${_size(size)} · $where', style: context.t(11, color: c.text3)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  static String _size(int b) => b < 1024 ? '$b B' : (b < 1 << 20 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / (1 << 20)).toStringAsFixed(1)} MB');
}

/// The message box: Enter sends, Shift+Enter breaks a line, `@` suggests
/// agents and people, `/task` makes a task.
class _Composer extends ConsumerStatefulWidget {
  const _Composer({required this.channel, required this.agents, required this.onSent});
  final Channel channel;
  final List<ChannelAgent> agents;
  final VoidCallback onSent;
  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final text = TextEditingController();
  final focus = FocusNode();
  final files = <String>[];
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    text.addListener(() => setState(() {}));
    focus.onKeyEvent = (node, e) {
      if (e is! KeyDownEvent) return KeyEventResult.ignored;
      final suggestions = _suggestions();
      if ((e.logicalKey == LogicalKeyboardKey.tab || e.logicalKey == LogicalKeyboardKey.enter) && suggestions.isNotEmpty) {
        _complete(suggestions.first.$1);
        return KeyEventResult.handled;
      }
      if (e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
        _send();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  /// The `@word` being typed at the cursor, if any.
  String? get _partial {
    final sel = text.selection.baseOffset;
    if (sel < 0) return null;
    final m = RegExp(r'(^|\s)@([A-Za-z0-9_.-]*)$').firstMatch(text.text.substring(0, sel));
    return m?.group(2);
  }

  List<(String handle, String label, Widget icon)> _suggestions() {
    final p = _partial?.toLowerCase();
    if (p == null) return const [];
    final data = ref.read(dataProvider);
    final out = <(String, String, Widget)>[];
    final seen = <String>{};
    for (final a in widget.agents) {
      if (!a.id.toLowerCase().startsWith(p) && !a.name.toLowerCase().startsWith(p)) continue;
      if (!seen.add(a.id)) continue;
      out.add((a.id, '${a.name} · ${a.mine ? Desk.thisComputer : "${a.owner}'s"}',
          AgentTile(agent: AgentProfile({'color': a.color, 'letter': a.letter}), size: 16)));
    }
    for (final person in data.devices.map((d) => d.person).where((x) => x.isNotEmpty).toSet()) {
      final handle = person.split(' ').first.toLowerCase();
      if (handle.startsWith(p) && seen.add(handle)) out.add((handle, person, Avatar(person, size: 16)));
    }
    return out.take(6).toList();
  }

  void _complete(String handle) {
    final sel = text.selection.baseOffset;
    final before = text.text.substring(0, sel).replaceFirst(RegExp(r'@[A-Za-z0-9_.-]*$'), '@$handle ');
    final after = text.text.substring(sel);
    text.value = TextEditingValue(text: before + after, selection: TextSelection.collapsed(offset: before.length));
  }

  Future<void> _send() async {
    final body = text.text.trim();
    if ((body.isEmpty && files.isEmpty) || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final res = await ref.read(clientProvider).map(M.messagesPost, {'channelId': widget.channel.id, 'body': body, 'files': files});
      text.clear();
      files.clear();
      widget.onSent();
      final made = res['task'] as Map?;
      if (made != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Made ${made['title']}'), duration: const Duration(seconds: 2)));
      }
    } on RpcError catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _attach() async {
    final picked = await openFiles();
    if (picked.isEmpty) return;
    setState(() => files.addAll(picked.map((f) => f.path)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isTask = text.text.trimLeft().startsWith('/task');
    final suggestions = _suggestions();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: c.box, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.boxStroke)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, (handle, label, icon)) in suggestions.indexed)
                Hoverable(
                  selected: i == 0,
                  onTap: () {
                    _complete(handle);
                    focus.requestFocus();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(children: [
                      icon,
                      const SizedBox(width: 8),
                      Text('@$handle', style: context.t(12, w: FontWeight.w600, color: i == 0 ? Colors.white : c.text)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: i == 0 ? Colors.white70 : c.text2))),
                    ]),
                  ),
                ),
            ]),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: c.field,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: focus.hasFocus ? c.accent : c.fieldStroke, width: focus.hasFocus ? 1.5 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (files.isNotEmpty)
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final f in files)
                  InputChip(
                    label: Text(Desk.base(f), style: context.t(11)),
                    onDeleted: () => setState(() => files.remove(f)),
                    visualDensity: VisualDensity.compact,
                  ),
              ]),
            TextField(
              controller: text,
              focusNode: focus,
              minLines: 1,
              maxLines: 6,
              cursorOpacityAnimates: false,
              style: context.t(13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Message #${widget.channel.name}',
                hintStyle: context.t(13, color: c.text3),
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              IconBtn(LucideIcons.paperclip, size: 14, tooltip: 'Attach files', onTap: _attach),
              IconBtn(LucideIcons.atSign, size: 14, tooltip: 'Mention an agent or teammate', onTap: () {
                final v = text.text;
                text.value = TextEditingValue(text: '$v${v.isEmpty || v.endsWith(' ') ? '' : ' '}@', selection: TextSelection.collapsed(offset: v.length + (v.isEmpty || v.endsWith(' ') ? 1 : 2)));
                focus.requestFocus();
              }),
              const SizedBox(width: 6),
              Expanded(
                child: Text(error ?? '/task makes a task · @agent assigns it · ↵ send',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: error != null ? c.danger : c.text3)),
              ),
              Btn(isTask ? 'Create task' : 'Send', kind: BtnKind.primary, small: true, icon: LucideIcons.send, onTap: busy ? null : _send),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// People, agents in this channel, pinned messages.
class _SidePanel extends ConsumerWidget {
  const _SidePanel({required this.channel, required this.agents, required this.me});
  final Channel channel;
  final List<ChannelAgent> agents;
  final String me;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final sync = ref.watch(syncStatusProvider);
    final online = data.onlineDevices(sync, me);
    final myName = ref.read(clientProvider).hello['userName'] as String? ?? 'You';
    final byPerson = <String, List<DeviceInfo>>{};
    for (final d in data.devices) {
      (byPerson[d.person.isEmpty ? d.name : d.person] ??= []).add(d);
    }
    if (byPerson.isEmpty) byPerson[myName] = [];
    final runs = data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).toList();
    final pinned = [for (final id in channel.pins) ?data.get<Message>(Kind.message, id)];

    Widget section(String label) => Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text(label, style: context.label));

    return Container(
      color: c.sidebar.withValues(alpha: 0.4),
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), children: [
        section('People'),
        for (final MapEntry(key: person, value: devices) in byPerson.entries)
          _PanelRow(
            leading: Avatar(person, size: 20, color: devices.any((d) => d.id == me) ? c.accent : null),
            title: devices.any((d) => d.id == me) ? '$person (you)' : person,
            trailing: Dot(devices.any((d) => online.contains(d.id)) || devices.isEmpty ? c.success : c.text3),
          ),
        section('Agents in this channel'),
        if (agents.isEmpty) Padding(padding: const EdgeInsets.all(4), child: Text('No agents yet. Teammates can share theirs in Settings → Team.', style: context.t(11, color: c.text3))),
        for (final a in agents)
          Builder(builder: (context) {
            final busy = runs.where((r) => r.agentId == a.id && (r.deviceId ?? me) == a.deviceId).length;
            final local = a.mine ? data.get<AgentProfile>(Kind.agent, a.id) : null;
            final limited = local?.limitedUntil != null && local!.limitedUntil!.isAfter(DateTime.now());
            final slots = local?.slots ?? (data.get<DeviceInfo>(Kind.device, a.deviceId)?.agents.where((x) => x['id'] == a.id).firstOrNull?['slots'] as num?)?.toInt() ?? 1;
            final until = limited ? local.limitedUntil!.toLocal() : null;
            return _PanelRow(
              leading: AgentTile(agent: AgentProfile({'color': a.color, 'letter': a.letter}), size: 20),
              title: '@${a.id}',
              subtitle: limited
                  ? 'limit · back ${until!.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')}'
                  : "${a.mine ? 'yours' : "${a.owner}'s"} · ${busy > 0 ? 'busy $busy/$slots' : 'free'}",
              subtitleColor: limited ? c.warning : null,
              trailing: Dot(limited ? c.warning : (a.mine || online.contains(a.deviceId) ? c.success : c.text3)),
            );
          }),
        if (pinned.isNotEmpty) ...[
          section('Pinned'),
          Box(
            child: Column(children: [
              for (final (i, m) in pinned.indexed) ...[
                if (i > 0) const Hairline(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(children: [
                    Icon(m.files.isNotEmpty ? LucideIcons.fileText : LucideIcons.pin, size: 13, color: c.accentIcon),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(m.files.isNotEmpty ? '${m.files.first['name']}' : m.body.split('\n').first,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12)),
                    ),
                  ]),
                ),
              ],
            ]),
          ),
        ],
      ]),
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.leading, required this.title, this.subtitle, this.subtitleColor, this.trailing});
  final Widget leading;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
    child: Row(children: [
      leading,
      const SizedBox(width: 9),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13)),
          if (subtitle != null) Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: subtitleColor ?? context.c.text2)),
        ]),
      ),
      ?trailing,
    ]),
  );
}
