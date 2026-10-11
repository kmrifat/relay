import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_sync/relay_sync.dart';

import 'context.dart';
import 'sync_service.dart';

/// Team channels (T04): messages, `/task`, `@agent` mentions that become
/// tasks, agents reporting back, the morning digest, and files sealed in
/// the team's storage. Channels and messages sync like any other record.
class Channels {
  Channels(this.ctx, this.sync, {this.postsDigests = true});

  final DaemonContext ctx;
  final SyncService sync;

  /// Phones leave the digest to the Macs.
  final bool postsDigests;
  Store get store => ctx.store;

  StreamSubscription<EntityChange>? _changes;
  Timer? _digestTimer;

  /// Largest file a message may carry.
  static const maxFileBytes = 25 << 20;

  void start() {
    _ensureDefaults();
    _changes = store.changes.listen((c) {
      final e = c.entity;
      if (e is Project && !c.remote) scheduleMicrotask(() => _ensureProjectChannel(e));
      if (e is Run) scheduleMicrotask(() => _maybeReport(e));
    });
    if (postsDigests) _digestTimer = Timer.periodic(const Duration(minutes: 1), (_) => postDigests());
  }

  Future<void> dispose() async {
    _digestTimer?.cancel();
    await _changes?.cancel();
  }

  String get me => ctx.setting('userName', 'You');

  // ------------------------------------------------------------ channels

  /// `#general`, and one channel per project; deterministic ids so two
  /// devices creating them end up with one.
  void _ensureDefaults() {
    if (store.get<Channel>(Kind.channel, Channel.general) == null) {
      store.create<Channel>(Kind.channel, {'id': Channel.general, 'name': 'general', 'topic': 'Everything else'});
    }
    for (final p in store.list<Project>(Kind.project)) {
      _ensureProjectChannel(p);
    }
  }

  void _ensureProjectChannel(Project p) {
    final id = Channel.idFor(p.id);
    if (store.get<Channel>(Kind.channel, id) != null) return;
    final slug = p.name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    store.create<Channel>(Kind.channel, {'id': id, 'name': slug.isEmpty ? p.key.toLowerCase() : slug, 'projectId': p.id});
  }

  List<Map<String, Object?>> list() {
    final out = <Map<String, Object?>>[];
    for (final ch in store.list<Channel>(Kind.channel)) {
      final read = DateTime.tryParse(store.meta('chread.${ch.id}') ?? '') ?? DateTime(2000);
      final msgs = store.list<Message>(Kind.message, channelId: ch.id);
      final unread = msgs.where((m) => m.createdAt.isAfter(read) && !(m.authorKind == 'person' && m.author == me && m.deviceId == ctx.deviceId)).length;
      final last = msgs.isEmpty ? null : msgs.map((m) => m.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
      out.add({...ch.toJson(), 'unread': unread, 'lastAt': last?.toIso8601String()});
    }
    return out..sort((a, b) => (a['id'] == Channel.general ? '' : '${a['name']}').compareTo(b['id'] == Channel.general ? '' : '${b['name']}'));
  }

  Channel create(String name, {String? projectId, String topic = ''}) {
    final clean = name.trim().replaceFirst('#', '').toLowerCase().replaceAll(RegExp('[^a-z0-9-]+'), '-');
    if (clean.isEmpty) throw RpcError(RpcError.invalidParams, 'Name the channel.');
    if (store.list<Channel>(Kind.channel).any((c) => c.name == clean)) throw RpcError(RpcError.invalidParams, '#$clean exists.');
    return store.create<Channel>(Kind.channel, {'name': clean, 'projectId': ?projectId, 'topic': topic});
  }

  void markRead(String channelId) => store.setMeta('chread.$channelId', DateTime.now().toUtc().toIso8601String());

  // ------------------------------------------------------------ messages

  List<Message> messages(String channelId, {int limit = 300}) {
    final all = store.list<Message>(Kind.message, channelId: channelId)..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return all.length > limit ? all.sublist(all.length - limit) : all;
  }

  /// Posts [body] as this person. `/task [@agent] title` makes a task on
  /// the channel's board; `@agent` anywhere else asks that agent, which
  /// also becomes a task (it runs on the agent's device).
  Future<Map<String, Object?>> post(String channelId, String body, {String? replyTo, List<String> files = const []}) async {
    final ch = store.get<Channel>(Kind.channel, channelId) ?? (throw RpcError(RpcError.notFound, 'No channel $channelId'));
    final text = body.trim();
    if (text.isEmpty && files.isEmpty) throw RpcError(RpcError.invalidParams, 'Write something.');
    final attached = [for (final f in files) await _attach(f)];

    final command = RegExp(r'^/task\b\s*').firstMatch(text);
    if (command != null) {
      final rest = text.substring(command.end);
      final agents = [for (final h in _handles(rest)) ?resolveAgent(h)];
      final title = _stripMentions(rest);
      if (title.isEmpty) throw RpcError(RpcError.invalidParams, 'Usage: /task [@agent] what to do');
      final task = _makeTask(ch, title, brief: '', agent: agents.firstOrNull, status: agents.isEmpty ? TaskStatus.backlog : TaskStatus.queued);
      final m = _message(ch.id, text, taskId: task.id, replyTo: replyTo, files: attached);
      return {'message': m.toJson(), 'task': task.toJson()};
    }

    final m = _message(ch.id, text, replyTo: replyTo, files: attached);
    final tasks = <Map<String, Object?>>[];
    for (final h in _handles(text).toSet()) {
      final agent = resolveAgent(h);
      if (agent == null) continue;
      final task = _makeTask(ch, _titleFrom(text), brief: 'From #${ch.name}, $me wrote:\n\n$text', agent: agent, status: TaskStatus.queued, fromMessage: m.id);
      tasks.add(task.toJson());
      final where = agent.deviceId == ctx.deviceId ? '' : ' on ${_deviceName(agent.deviceId)}';
      _message(ch.id, 'Made a task from that$where — starting as soon as a slot frees.',
          authorKind: 'agent', author: agent.name, deviceId: agent.deviceId, taskId: task.id, replyTo: m.id);
    }
    return {'message': m.toJson(), 'tasks': tasks};
  }

  Message _message(
    String channelId,
    String body, {
    String authorKind = 'person',
    String? author,
    String? deviceId,
    String? taskId,
    String? replyTo,
    String? tag,
    String? id,
    List<Map<String, Object?>> files = const [],
    Map<String, Object?> extra = const {},
  }) {
    final m = store.create<Message>(Kind.message, {
      'id': ?id,
      'channelId': channelId,
      'authorKind': authorKind,
      'author': author ?? me,
      'deviceId': deviceId ?? ctx.deviceId,
      'body': body,
      'taskId': ?taskId,
      'replyTo': ?replyTo,
      'tag': ?tag,
      if (files.isNotEmpty) 'files': files,
      ...extra,
    });
    if (authorKind == 'person' && deviceId == null) markRead(channelId);
    return m;
  }

  void react(String messageId, String emoji, bool on) {
    store.get<Message>(Kind.message, messageId) ?? (throw RpcError(RpcError.notFound, 'No message'));
    if (emoji.isEmpty || emoji.length > 32 || emoji.contains('.')) throw RpcError(RpcError.invalidParams, 'Bad reaction');
    store.patch<Message>(Kind.message, messageId, {Message.reactionField(emoji, me): on ? true : null});
  }

  void pin(String channelId, String messageId, bool on) =>
      store.patch<Channel>(Kind.channel, channelId, {'pin.$messageId': on ? true : null});

  void delete(String messageId) {
    final m = store.get<Message>(Kind.message, messageId) ?? (throw RpcError(RpcError.notFound, 'No message'));
    if (m.authorKind != 'person' || m.author != me) throw RpcError(RpcError.invalidParams, 'You can only delete your own messages.');
    store.delete(Kind.message, messageId);
  }

  // ------------------------------------------------------------ agents

  /// An `@handle`: this Mac's agent with that id, or a teammate's shared one.
  ({String id, String name, String deviceId})? resolveAgent(String handle) {
    final h = handle.toLowerCase();
    final local = store.list<AgentProfile>(Kind.agent).where((a) => a.binaryPath != null && a.enabled && _matches(a.id, a.name, h)).firstOrNull;
    if (local != null) return (id: local.id, name: local.name, deviceId: ctx.deviceId);
    // On a phone, "my agents" are its Mac's, shared or not.
    final mac = store.meta('settings.companionOf');
    final devices = store.list<DeviceInfo>(Kind.device)..sort((a, b) => (a.id == mac ? 0 : 1).compareTo(b.id == mac ? 0 : 1));
    for (final d in devices) {
      if (d.id == ctx.deviceId || d.revoked || (!d.shareAgents && d.id != mac)) continue;
      for (final a in d.agents) {
        if (_matches('${a['id']}', '${a['name']}', h)) return (id: '${a['id']}', name: '${a['name']}', deviceId: d.id);
      }
    }
    return null;
  }

  static bool _matches(String id, String name, String h) =>
      id.toLowerCase() == h || name.toLowerCase().replaceAll(' ', '-') == h || name.toLowerCase().split(' ').first == h;

  Task _makeTask(Channel ch, String title, {required String brief, ({String id, String name, String deviceId})? agent, required String status, String? fromMessage}) {
    final projectId = ch.projectId ?? (throw RpcError(RpcError.invalidParams, '#${ch.name} is not linked to a project board. Use a project\'s channel.'));
    return store.createTask(projectId, {
      'title': title.length > 90 ? '${title.substring(0, 87)}…' : title,
      'brief': brief,
      'status': status,
      if (agent != null) ...{'assigneeKind': 'agent', 'assignee': agent.id, 'runOn': agent.deviceId} else 'runOn': ctx.deviceId,
      'createdOn': ctx.deviceId,
      'channelId': ch.id,
      'fromMessage': ?fromMessage,
    });
  }

  /// Run ended on this device for a task that came from a channel: the
  /// agent reports back there.
  void _maybeReport(Run run) {
    if (run.deviceId != ctx.deviceId || !RunStatus.isFinished(run.status)) return;
    if (run.data['channelReported'] == true) return;
    final task = store.get<Task>(Kind.task, run.taskId);
    final channelId = task?.str('channelId');
    if (task == null || channelId == null || store.get<Channel>(Kind.channel, channelId) == null) return;
    store.patch<Run>(Kind.run, run.id, {'channelReported': true});
    final agent = ctx.agent(run.agentId);
    final summary = (run.summary ?? run.error ?? '').trim();
    _message(
      channelId,
      switch (run.status) {
        RunStatus.done => summary.isEmpty ? 'Done with ${ctx.taskKey(task)}. It is ready for review.' : _clip(summary, 700),
        RunStatus.stopped => 'Stopped working on ${ctx.taskKey(task)}.',
        _ => '${ctx.taskKey(task)} failed: ${_clip(summary, 300)}',
      },
      authorKind: 'agent',
      author: agent?.name ?? run.agentId,
      deviceId: ctx.deviceId,
      taskId: task.id,
      replyTo: task.str('fromMessage'),
    );
  }

  // ------------------------------------------------------------ digest

  /// Once a day after `digestHour` (default 8): what agents did in the last
  /// 24 h, per project channel. One message id per channel per day, so
  /// several devices posting it merge into one.
  void postDigests({DateTime? now}) {
    final t = now ?? DateTime.now();
    if (t.hour < ctx.intSetting('digestHour', 8)) return;
    final day = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    if (store.meta('digest.$day') != null) return;
    store.setMeta('digest.$day', 'done');
    final since = t.toUtc().subtract(const Duration(hours: 24));
    final runs = store.list<Run>(Kind.run).where((r) => r.createdAt.isAfter(since) && !RunStatus.isActive(r.status)).toList();
    for (final ch in store.list<Channel>(Kind.channel).where((c) => c.projectId != null)) {
      final mine = runs.where((r) => store.get<Task>(Kind.task, r.taskId)?.projectId == ch.projectId).toList();
      if (mine.isEmpty) continue;
      final byTask = <String, Run>{};
      for (final r in mine..sort((a, b) => a.createdAt.compareTo(b.createdAt))) {
        byTask[r.taskId] = r;
      }
      final items = <Map<String, Object?>>[];
      var review = 0, failed = 0;
      for (final r in byTask.values) {
        final task = store.get<Task>(Kind.task, r.taskId);
        if (task == null) continue;
        if (task.status == TaskStatus.review) review++;
        if (r.status == RunStatus.failed) failed++;
        items.add({'taskId': task.id, 'key': ctx.taskKey(task), 'title': task.title, 'ok': r.status == RunStatus.done, 'agent': ctx.agent(r.agentId)?.name ?? r.agentId});
      }
      final head = ['${mine.length} run${mine.length == 1 ? '' : 's'}', if (review > 0) '$review ready for review', if (failed > 0) '$failed failed'].join(' · ');
      _message(ch.id, 'Overnight: $head', authorKind: 'system', author: 'Relay', tag: 'digest', id: 'dg-${ch.id}-$day', extra: {'items': items});
    }
  }

  // ------------------------------------------------------------ files

  /// Copies [path] into Relay's file store and, in a team, seals it into
  /// the team's storage (`files/<id>`).
  Future<Map<String, Object?>> _attach(String path) async {
    final f = File(path);
    if (!f.existsSync()) throw RpcError(RpcError.invalidParams, 'No file at $path');
    final size = f.lengthSync();
    if (size > maxFileBytes) throw RpcError(RpcError.invalidParams, '${f.uri.pathSegments.last} is over 25 MB.');
    final id = newId();
    final name = f.uri.pathSegments.last;
    final local = File('${_filesDir(id)}/$name')..parent.createSync(recursive: true);
    f.copySync(local.path);
    final engine = sync.engine;
    var stored = 'local';
    if (engine != null) {
      final key = '${engine.root}/files/$id.bin';
      final s = sync.secrets;
      final sealed = await RelayCrypto.seal(key: s.keyring[s.currentEpoch]!, teamId: s.teamId!, type: EnvelopeType.file, epoch: s.currentEpoch, objectKey: key, plain: f.readAsBytesSync());
      await engine.backend.put(key, Uint8List.fromList(sealed), condition: const WriteCondition.ifAbsent());
      stored = 'team';
    }
    return {'id': id, 'name': name, 'size': size, 'mime': _mime(name), 'stored': stored};
  }

  String _filesDir(String id) => '${ctx.paths.home}/files/$id';

  /// A local path for a message's file, fetching and opening it from the
  /// team's storage the first time.
  Future<String> file(String messageId, String fileId) async {
    final m = store.get<Message>(Kind.message, messageId) ?? (throw RpcError(RpcError.notFound, 'No message'));
    final meta = m.files.where((f) => f['id'] == fileId).firstOrNull ?? (throw RpcError(RpcError.notFound, 'No such file'));
    final name = '${meta['name']}'.replaceAll('/', '_');
    final local = File('${_filesDir(fileId)}/$name');
    if (local.existsSync()) return local.path;
    final engine = sync.engine ?? (throw RpcError(RpcError.invalidParams, 'This file is on the team\'s storage; join the team to open it.'));
    final key = '${engine.root}/files/$fileId.bin';
    final body = await engine.backend.get(key) ?? (throw RpcError(RpcError.notFound, 'The file is not in the team\'s storage (yet).'));
    final s = sync.secrets;
    final keyBytes = s.keyring[RelayCrypto.epochOf(body.bytes)] ?? (throw RpcError(RpcError.invalidParams, 'No key for this file.'));
    final plain = await RelayCrypto.open(key: keyBytes, teamId: s.teamId!, type: EnvelopeType.file, objectKey: key, bytes: body.bytes);
    local.parent.createSync(recursive: true);
    local.writeAsBytesSync(plain);
    return local.path;
  }

  // ------------------------------------------------------------ helpers

  static Iterable<String> _handles(String text) => Message({'body': text}).mentions;

  static String _stripMentions(String s) => s.replaceAll(RegExp(r'@[A-Za-z0-9_.-]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// A task title from a message: its sentences without the @mentions,
  /// minus short acknowledgements ("Go ahead.", "Thanks!").
  ///   "The board drag feels laggy. @demo can you profile it?"
  ///     → "The board drag feels laggy. Can you profile it?"
  ///   "Go ahead. @demo when TM-5 lands, check the README."
  ///     → "When TM-5 lands, check the README."
  static String _titleFrom(String text) {
    final sentences = [
      for (final s in text.split(RegExp(r'(?<=[.?!])\s+')))
        if (_stripMentions(s) case final t when t.isNotEmpty) t[0].toUpperCase() + t.substring(1),
    ];
    final kept = sentences.length > 1 ? sentences.where((s) => s.split(' ').length > 3).toList() : sentences;
    final t = (kept.isEmpty ? sentences : kept).join(' ');
    return t.isEmpty ? 'Request from the channel' : t;
  }

  static String _clip(String s, int n) => s.length > n ? '${s.substring(0, n - 1)}…' : s;

  String _deviceName(String deviceId) {
    final d = store.get<DeviceInfo>(Kind.device, deviceId);
    return d == null ? 'another Mac' : (d.person.isEmpty ? d.name : '${d.person}\'s Mac');
  }

  static String _mime(String name) => switch (name.split('.').last.toLowerCase()) {
    'md' => 'text/markdown',
    'txt' || 'log' => 'text/plain',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'pdf' => 'application/pdf',
    'json' => 'application/json',
    _ => 'application/octet-stream',
  };
}
