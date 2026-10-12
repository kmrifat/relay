import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'daemon_launcher.dart';
import 'daemon_upgrade.dart';

enum ConnStatus { connecting, connected, failed }

class ConnState {
  const ConnState(this.status, {this.client, this.message});
  final ConnStatus status;
  final RelayClient? client;
  final String? message;
}

/// The connection to relayd. Reconnects (and restarts relayd) on loss, and
/// replaces a relayd older than this app (daemon_upgrade.dart).
class ConnectionNotifier extends Notifier<ConnState> {
  /// What restarting relayd touches; tests swap in a fake.
  static DaemonHost Function() host = () => SystemDaemonHost(DaemonLauncher());

  /// Set while this app stops relayd on purpose: no reconnect for that.
  bool _replacing = false;

  /// Once per app session, so a relayd that comes back old isn't restarted
  /// again and again.
  bool _upgraded = false;
  Timer? _waitForRuns;

  @override
  ConnState build() {
    ref.onDispose(() => _waitForRuns?.cancel());
    Future.microtask(connect);
    return const ConnState(ConnStatus.connecting, message: 'Connecting to relayd…');
  }

  Future<void> connect() async {
    state = const ConnState(ConnStatus.connecting, message: 'Connecting to relayd…');
    try {
      final client = await DaemonLauncher().connect(onStatus: (m) => state = ConnState(ConnStatus.connecting, message: m));
      _connected(client);
      if (!isMobile) unawaited(_checkVersion(client));
    } catch (e) {
      state = ConnState(ConnStatus.failed, message: '$e');
    }
  }

  void _connected(RelayClient client) {
    state = ConnState(ConnStatus.connected, client: client);
    unawaited(client.done.then((_) {
      if (state.client == client && !_replacing) {
        state = const ConnState(ConnStatus.connecting, message: 'relayd went away, reconnecting…');
        Future<void>.delayed(const Duration(seconds: 1), connect);
      }
    }));
  }

  Future<void> _checkVersion(RelayClient client) async {
    if (_upgraded) return;
    final DaemonUpgrade? u;
    try {
      u = await DaemonUpdater(host()).check(client);
    } catch (_) {
      return;
    }
    if (u == null) {
      // Replaced by someone else while waiting for runs (a reconnect).
      if (ref.read(upgradeProvider)?.error == null) ref.read(upgradeProvider.notifier).set(null);
      return;
    }
    if (state.client == client) await _replace(client, u);
  }

  /// Stops [client]'s relayd and starts the bundled one; while agent runs
  /// are active (and not [force]), waits for them and says so in
  /// [upgradeProvider].
  Future<void> _replace(RelayClient client, DaemonUpgrade u, {bool force = false}) async {
    _waitForRuns?.cancel();
    if (state.client != client || _replacing) return;
    final pending = ref.read(upgradeProvider.notifier);
    _replacing = true;
    try {
      final next = await DaemonUpdater(host()).restart(client, u, force: force, onStopping: () {
        pending.set(null);
        state = ConnState(ConnStatus.connecting, message: 'Updating relayd ${u.running} → ${u.bundled}…');
      });
      _upgraded = true;
      _replacing = false;
      _connected(next);
      final now = next.hello['version'] as String? ?? '';
      if ((compareVersions(now, u.bundled) ?? 0) < 0) {
        pending.set(UpgradeState(u, error: 'relayd $now started instead of ${u.bundled}. Quit Relay, stop relayd, and open Relay again.'));
      }
    } on RpcError catch (e) {
      _replacing = false;
      if (e.code != RpcError.busy) {
        _upgraded = true;
        pending.set(UpgradeState(u, error: 'Could not stop relayd ${u.running}: ${e.message}'));
        return;
      }
      // Agent runs are active: try again once they have finished.
      pending.set(UpgradeState(u, activeRuns: ((e.data as Map?)?['activeRuns'] as num?)?.toInt() ?? 1));
      _waitForRuns = Timer(const Duration(seconds: 15), () => _replace(client, u));
    } catch (e) {
      _upgraded = true;
      _replacing = false;
      pending.set(UpgradeState(u, error: 'Could not restart relayd: $e'));
      // relayd may be stopped by now: connecting starts the bundled one.
      if (state.client != client || client.peer.isClosed) await connect();
    }
  }

  /// "Restart now": stops the agent runs too.
  Future<void> replaceNow() async {
    final client = state.client;
    final u = ref.read(upgradeProvider)?.upgrade;
    if (client != null && u != null) await _replace(client, u, force: true);
  }
}

/// relayd is older than this app: waiting for [activeRuns] to finish before
/// restarting it, or [error] when it couldn't be replaced.
class UpgradeState {
  const UpgradeState(this.upgrade, {this.activeRuns = 0, this.error});
  final DaemonUpgrade upgrade;
  final int activeRuns;
  final String? error;
}

class UpgradeNotifier extends Notifier<UpgradeState?> {
  @override
  UpgradeState? build() => null;

  void set(UpgradeState? s) => state = s;
}

final upgradeProvider = NotifierProvider<UpgradeNotifier, UpgradeState?>(UpgradeNotifier.new);

final connectionProvider = NotifierProvider<ConnectionNotifier, ConnState>(ConnectionNotifier.new);

/// The connected client. Only read it below the connection gate.
final clientProvider = Provider<RelayClient>((ref) {
  final c = ref.watch(connectionProvider).client;
  if (c == null) throw StateError('Not connected');
  return c;
});

/// Every record relayd knows, kept in sync from `entity.changed` events.
class DataSnapshot {
  const DataSnapshot(this.byKind, this.rev);
  final Map<String, Map<String, Entity>> byKind;
  final int rev;

  Iterable<T> all<T extends Entity>(String kind) => (byKind[kind]?.values ?? const <Entity>[]).cast<T>();
  T? get<T extends Entity>(String kind, String? id) => id == null ? null : byKind[kind]?[id] as T?;

  List<Project> get projects => all<Project>(Kind.project).toList()..sort((a, b) => a.position.compareTo(b.position));
  List<AgentProfile> get agents => all<AgentProfile>(Kind.agent).toList()..sort((a, b) => a.name.compareTo(b.name));
  List<Repo> reposOf(String projectId) => all<Repo>(Kind.repo).where((r) => r.projectId == projectId).toList()
    ..sort((a, b) {
      final s = a.mergeStep.compareTo(b.mergeStep);
      return s != 0 ? s : a.name.compareTo(b.name);
    });
  List<Task> tasksOf(String? projectId) => all<Task>(Kind.task).where((t) => projectId == null || t.projectId == projectId).toList();
  List<Run> runsOf(String taskId) => all<Run>(Kind.run).where((r) => r.taskId == taskId).toList()..sort((a, b) => a.id.compareTo(b.id));
  List<ChangeEntry> changesOf(String taskId) => all<ChangeEntry>(Kind.change).where((c) => c.taskId == taskId).toList();
  /// Team devices (this Mac included), most recently seen first.
  List<DeviceInfo> get devices => all<DeviceInfo>(Kind.device).where((d) => !d.revoked).toList()
    ..sort((a, b) => (b.lastSeen ?? DateTime(2000)).compareTo(a.lastSeen ?? DateTime(2000)));
  /// Devices that are online: in the Worker's room when there is one,
  /// otherwise seen in the last 10 minutes.
  Set<String> onlineDevices(Map<String, Object?> sync, String me) {
    final live = ((sync['online'] as List?) ?? const []).cast<String>().toSet();
    if (sync['live'] == true) return {...live, me};
    final recent = DateTime.now().subtract(const Duration(minutes: 10));
    return {me, for (final d in devices) if (d.lastSeen != null && d.lastSeen!.isAfter(recent)) d.id};
  }

  List<RoutingRule> get rules => all<RoutingRule>(Kind.rule).toList()..sort((a, b) => a.order.compareTo(b.order));
  Project? projectOf(Task t) => get<Project>(Kind.project, t.projectId);
  String keyOf(Task t) => t.displayKey(projectOf(t)?.key ?? '?');
  List<Channel> get channels => all<Channel>(Kind.channel).toList()
    ..sort((a, b) => (a.id == Channel.general ? '' : a.name).compareTo(b.id == Channel.general ? '' : b.name));
  List<Message> messagesOf(String channelId) => all<Message>(Kind.message).where((m) => m.channelId == channelId).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  Run? activeRun(Task t) => get<Run>(Kind.run, t.data['activeRunId'] as String?);
}

class DataNotifier extends Notifier<DataSnapshot> {
  StreamSubscription<RelayEvent>? _sub;
  String _device = '';

  /// Repos carry checkout paths per device; expose this Mac's as `localPath`.
  Map<String, Object?> _withLocal(String kind, Map<String, Object?> data) {
    if (kind != Kind.repo) return data;
    final path = data['path@$_device'] as String? ?? (data['paths'] as Map?)?[_device] as String?;
    return {...data, 'localPath': path};
  }

  @override
  DataSnapshot build() {
    final client = ref.watch(clientProvider);
    _device = client.hello['deviceId'] as String? ?? '';
    _sub?.cancel();
    _sub = client.events.listen(_onEvent);
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(() => reload(client));
    return const DataSnapshot({}, 0);
  }

  Future<void> reload(RelayClient client) async {
    final kinds = {
      Kind.project: M.projectsList,
      Kind.repo: M.reposList,
      Kind.task: M.tasksList,
      Kind.agent: M.agentsList,
      Kind.rule: M.rulesList,
      Kind.run: M.runsList,
      Kind.device: M.devicesList,
      Kind.channel: M.channelsList,
    };
    final next = <String, Map<String, Entity>>{for (final k in Kind.all) k: {}};
    for (final e in kinds.entries) {
      for (final j in await client.list(e.value)) {
        next[e.key]![j['id'] as String] = entityFrom(e.key, _withLocal(e.key, j));
      }
    }
    for (final ws in await client.list(M.workspacesList)) {
      for (final c in (ws['changes'] as List)) {
        final j = (c as Map).cast<String, Object?>();
        next[Kind.change]![j['id'] as String] = ChangeEntry(j);
      }
    }
    state = DataSnapshot(next, state.rev + 1);
  }

  /// Loads a channel's recent messages (later ones arrive as events).
  Future<void> loadMessages(String channelId) async {
    final list = await ref.read(clientProvider).list(M.messagesList, {'channelId': channelId});
    final next = Map.of(state.byKind);
    final map = next[Kind.message] = Map.of(next[Kind.message] ?? {});
    for (final j in list) {
      map[j['id'] as String] = Message(j);
    }
    state = DataSnapshot(next, state.rev + 1);
  }

  void _onEvent(RelayEvent e) {
    if (e.method != E.entity) return;
    final items = (e.params['items'] as List?) ?? const [];
    if (items.isEmpty) return;
    final next = Map.of(state.byKind);
    for (final it in items) {
      final m = (it as Map).cast<String, Object?>();
      final kind = m['kind'] as String;
      final data = (m['data'] as Map).cast<String, Object?>();
      final map = next[kind] = Map.of(next[kind] ?? {});
      if (data['deleted'] == true) {
        map.remove(data['id']);
      } else {
        // agents.list adds live fields (active, today); keep them across updates.
        final prev = map[data['id']];
        final merged = (kind == Kind.agent || kind == Kind.run || kind == Kind.channel) && prev != null ? {...prev.data, ...data} : data;
        map[data['id'] as String] = entityFrom(kind, _withLocal(kind, merged));
      }
    }
    state = DataSnapshot(next, state.rev + 1);
  }
}

final dataProvider = NotifierProvider<DataNotifier, DataSnapshot>(DataNotifier.new);

/// Live events of one run: history first, then appended as they stream in.
class RunEventsNotifier extends Notifier<List<RunEvent>> {
  RunEventsNotifier(this.runId);
  final String runId;
  StreamSubscription<RelayEvent>? _sub;

  @override
  List<RunEvent> build() {
    final client = ref.watch(clientProvider);
    _sub = client.events.where((e) => e.method == E.runEvents && e.params['runId'] == runId).listen((e) {
      final add = (e.params['events'] as List).map((x) => RunEvent.fromJson((x as Map).cast())).toList();
      final last = state.isEmpty ? 0 : state.last.seq;
      state = [...state, ...add.where((x) => x.seq > last)];
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(() async {
      final hist = (await client.list(M.runsEvents, {'runId': runId})).map(RunEvent.fromJson).toList();
      final seen = {for (final e in state) e.seq};
      state = [...hist.where((e) => !seen.contains(e.seq)), ...state]..sort((a, b) => a.seq.compareTo(b.seq));
    });
    return const [];
  }
}

final runEventsProvider = NotifierProvider.family<RunEventsNotifier, List<RunEvent>, String>(RunEventsNotifier.new);

/// Comments of one task, refreshed when comment entities change.
final commentsProvider = FutureProvider.family<List<Comment>, String>((ref, taskId) async {
  ref.watch(dataProvider.select((d) => d.byKind[Kind.comment]?.values.where((c) => (c as Comment).taskId == taskId).length));
  final client = ref.watch(clientProvider);
  return (await client.list(M.commentsList, {'taskId': taskId})).map(Comment.new).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
});

/// Notices from relayd (toasts).
final noticesProvider = StreamProvider<Map<String, Object?>>((ref) {
  final client = ref.watch(clientProvider);
  return client.events.where((e) => e.method == E.notice).map((e) => e.params);
});

/// Team sync state: `sync.status`, then every `sync.state` event.
class SyncStatusNotifier extends Notifier<Map<String, Object?>> {
  @override
  Map<String, Object?> build() {
    final client = ref.watch(clientProvider);
    final sub = client.events.where((e) => e.method == E.syncState).listen((e) => state = e.params);
    ref.onDispose(sub.cancel);
    Future.microtask(refresh);
    return const {};
  }

  Future<void> refresh() async => state = await ref.read(clientProvider).map(M.syncStatus);

  void set(Map<String, Object?> s) => state = s;
}

final syncStatusProvider = NotifierProvider<SyncStatusNotifier, Map<String, Object?>>(SyncStatusNotifier.new);

/// Unread counts per channel (`channels.list`), refreshed when messages
/// change and when a channel is read.
class UnreadNotifier extends Notifier<Map<String, int>> {
  Timer? _debounce;

  @override
  Map<String, int> build() {
    final client = ref.watch(clientProvider);
    final sub = client.events.where((e) => e.method == E.entity && ((e.params['items'] as List?) ?? const []).any((i) => (i as Map)['kind'] == Kind.message)).listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), refresh);
    });
    ref.onDispose(() {
      sub.cancel();
      _debounce?.cancel();
    });
    Future.microtask(refresh);
    return const {};
  }

  Future<void> refresh() async {
    final list = await ref.read(clientProvider).list(M.channelsList);
    state = {for (final c in list) c['id'] as String: (c['unread'] as num?)?.toInt() ?? 0};
  }

  Future<void> markRead(String channelId) async {
    if ((state[channelId] ?? 0) == 0) return;
    state = {...state, channelId: 0};
    await ref.read(clientProvider).call(M.channelsRead, {'channelId': channelId});
  }
}

final unreadProvider = NotifierProvider<UnreadNotifier, Map<String, int>>(UnreadNotifier.new);

/// `notify` events from relayd (system notifications).
final notifyProvider = StreamProvider<Map<String, Object?>>((ref) {
  final client = ref.watch(clientProvider);
  return client.events.where((e) => e.method == E.notify).map((e) => e.params);
});
