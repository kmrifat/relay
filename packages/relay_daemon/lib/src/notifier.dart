import 'dart:async';

import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'context.dart';

/// Decides what deserves a system notification (M7-04) and sends it to the
/// apps as `notify` events: an agent waiting for you, work ready for your
/// review, a teammate mentioning you, a teammate's task waiting for your
/// consent. The app posts it (macOS: UNUserNotificationCenter).
class Notifier {
  Notifier(this.ctx);
  final DaemonContext ctx;

  /// Also called for each notification (relayd: push to paired phones).
  Future<void> Function(Map<String, Object?> note)? onNotify;
  Store get store => ctx.store;

  StreamSubscription<EntityChange>? _sub;
  final _seen = <String, String>{}; // taskId → "status|attention"
  final _sent = <String>{};

  void start() {
    for (final t in store.list<Task>(Kind.task)) {
      _seen[t.id] = _state(t);
    }
    _sub = store.changes.listen((c) {
      final e = c.entity;
      if (e is Task) _onTask(e);
      if (e is Message && e.data['deleted'] != true) _onMessage(e);
    });
  }

  Future<void> dispose() async => _sub?.cancel();

  static String _state(Task t) => '${t.status}|${t.data['attention'] ?? ''}';

  void _onTask(Task t) {
    final before = _seen[t.id];
    final now = _state(t);
    _seen[t.id] = now;
    if (before == now) return;
    final attention = t.data['attention'] as String?;
    // A phone and its Mac are one person: the Mac's tasks are the phone's,
    // and work queued from the phone is the Mac's.
    final runsHere = _isMe(t.str('runOn') ?? ctx.deviceId);
    final mine = _isMe(t.str('createdOn') ?? t.str('runOn') ?? ctx.deviceId);
    final key = _key(t);
    if (attention == 'permission' && runsHere) {
      _notify('ask', '$key needs your OK', _agentLine(t, 'wants to run a command'), taskId: t.id);
    } else if (attention == 'question' && runsHere) {
      _notify('ask', '$key has a question', t.str('question') ?? 'The agent is waiting for an answer.', taskId: t.id);
    } else if (attention == 'not-shared' && runsHere) {
      _notify('consent', 'A teammate queued $key on your agents', 'Turn on Share my agents in Settings → Team to run it.', taskId: t.id);
    } else if (attention == 'failed' && mine) {
      _notify('failed', '$key failed', t.str('lastError') ?? t.title, taskId: t.id);
    } else if (t.status == TaskStatus.review && (before == null || !before.startsWith('${TaskStatus.review}|')) && mine) {
      _notify('review', '$key is ready for review', t.title, taskId: t.id);
    }
  }

  bool _isMe(String deviceId) {
    if (deviceId == ctx.deviceId) return true;
    if (deviceId == store.meta('settings.companionOf')) return true;
    return store.get<DeviceInfo>(Kind.device, deviceId)?.data['companionOf'] == ctx.deviceId;
  }

  void _onMessage(Message m) {
    if (m.authorKind == 'person' && m.deviceId != null && _isMe(m.deviceId!)) return; // my own
    if (_sent.contains('m:${m.id}')) return;
    final me = ctx.setting('userName', '').trim().toLowerCase();
    if (me.isEmpty || me == 'you') return;
    final handles = {me.replaceAll(' ', ''), me.split(' ').first, me.replaceAll(' ', '-')};
    final mentioned = m.mentions.map((h) => h.toLowerCase()).any((h) => handles.contains(h) || h == 'everyone' || h == 'here');
    if (!mentioned) return;
    _sent.add('m:${m.id}');
    final ch = store.get<Channel>(Kind.channel, m.channelId);
    _notify('mention', '${m.author} in #${ch?.name ?? 'channel'}', m.body, channelId: m.channelId, messageId: m.id);
  }

  String _key(Task t) {
    final p = store.get<Project>(Kind.project, t.projectId);
    return t.displayKey(p?.key ?? '?');
  }

  String _agentLine(Task t, String what) {
    final run = store.get<Run>(Kind.run, t.data['activeRunId'] as String? ?? '');
    final agent = run == null ? null : store.get<AgentProfile>(Kind.agent, run.agentId);
    final step = run?.data['currentStep'] as String?;
    return '${agent?.name ?? 'The agent'} $what${step == null ? '' : ': $step'}';
  }

  void _notify(String kind, String title, String body, {String? taskId, String? channelId, String? messageId}) {
    final note = <String, Object?>{
      'kind': kind,
      'title': title,
      'body': body.length > 240 ? '${body.substring(0, 239)}…' : body,
      'taskId': ?taskId,
      'channelId': ?channelId,
      'messageId': ?messageId,
    };
    final hook = onNotify;
    if (hook != null) unawaited(hook(note).catchError((_) {}));
    ctx.broadcast(E.notify, {
      'kind': kind,
      'title': title,
      'body': body.length > 240 ? '${body.substring(0, 239)}…' : body,
      'taskId': ?taskId,
      'channelId': ?channelId,
      'messageId': ?messageId,
    });
  }
}
