import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'daemon_launcher.dart';

enum ConnStatus { connecting, connected, failed }

class ConnState {
  const ConnState(this.status, {this.client, this.message});
  final ConnStatus status;
  final RelayClient? client;
  final String? message;
}

/// The connection to relayd. Reconnects (and restarts relayd) on loss.
class ConnectionNotifier extends Notifier<ConnState> {
  @override
  ConnState build() {
    Future.microtask(connect);
    return const ConnState(ConnStatus.connecting, message: 'Connecting to relayd…');
  }

  Future<void> connect() async {
    state = const ConnState(ConnStatus.connecting, message: 'Connecting to relayd…');
    try {
      final client = await DaemonLauncher().connect(onStatus: (m) => state = ConnState(ConnStatus.connecting, message: m));
      state = ConnState(ConnStatus.connected, client: client);
      unawaited(client.done.then((_) {
        if (state.client == client) {
          state = const ConnState(ConnStatus.connecting, message: 'relayd went away, reconnecting…');
          Future<void>.delayed(const Duration(seconds: 1), connect);
        }
      }));
    } catch (e) {
      state = ConnState(ConnStatus.failed, message: '$e');
    }
  }
}

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
  List<RoutingRule> get rules => all<RoutingRule>(Kind.rule).toList()..sort((a, b) => a.order.compareTo(b.order));
  Project? projectOf(Task t) => get<Project>(Kind.project, t.projectId);
  String keyOf(Task t) => t.displayKey(projectOf(t)?.key ?? '?');
  Run? activeRun(Task t) => get<Run>(Kind.run, t.data['activeRunId'] as String?);
}

class DataNotifier extends Notifier<DataSnapshot> {
  StreamSubscription<RelayEvent>? _sub;
  String _device = '';

  /// Repos carry checkout paths per device; expose this Mac's as `localPath`.
  Map<String, Object?> _withLocal(String kind, Map<String, Object?> data) {
    if (kind != Kind.repo) return data;
    final path = (data['paths'] as Map?)?[_device] as String?;
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
        final merged = (kind == Kind.agent || kind == Kind.run) && prev != null ? {...prev.data, ...data} : data;
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
