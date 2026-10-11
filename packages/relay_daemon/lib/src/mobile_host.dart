import 'dart:async';
import 'dart:io';

import 'package:relay_agents/relay_agents.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_git/relay_git.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'channels.dart';
import 'context.dart';
import 'live.dart';
import 'notifier.dart';
import 'server.dart' show relayVersion;
import 'sync_service.dart';

/// Relay on a phone (M8-02): no agents, no git, no terminals. The phone is a
/// team device paired with one Mac. It keeps the board in its own store
/// (synced through the team Worker), streams runs from the live room, and
/// asks its Mac to act — answer a permission, reply to a question, steer —
/// with commands signed by the pairing key.
///
/// It serves the same JSON-RPC methods the app already uses, in-process, so
/// the app's data layer is the same on Mac and iPhone.
class MobileHost {
  MobileHost(this.paths);

  final RelayPaths paths;
  late final DaemonContext ctx;
  late final SyncService sync;
  late final Channels channels;
  late final Notifier notifier;
  final _subs = <StreamSubscription<Object?>>[];
  RpcPeer? _peer;
  final _entities = <String, Entity>{};
  final _runEvents = <String, List<RunEvent>>{};
  bool _flushQueued = false;

  Store get store => ctx.store;
  String? get mac => sync.secrets.pairing?.mac;

  /// Opens the store, starts sync, and returns a client for the app.
  Future<RelayClient> start() async {
    Directory(paths.home).createSync(recursive: true);
    final deviceFile = File('${paths.home}/device-id');
    if (!deviceFile.existsSync()) deviceFile.writeAsStringSync(newToken(12));
    final deviceId = deviceFile.readAsStringSync().trim();
    final store = Store.open(paths.database, deviceId: deviceId);
    if (store.meta('settings.deviceKind') == null) store.setMeta('settings.deviceKind', 'phone');
    ctx = DaemonContext(paths: paths, store: store, deviceId: deviceId, registry: AgentRegistry(adapters: const []), git: Git(), version: relayVersion);
    sync = SyncService(ctx);
    channels = Channels(ctx, sync, postsDigests: false);
    notifier = Notifier(ctx);
    sync.start();
    channels.start();
    notifier.start();

    final toServer = StreamController<List<int>>();
    final toClient = StreamController<List<int>>();
    final peer = _peer = RpcPeer(toServer.stream, toClient.sink, name: 'relay-mobile');
    final token = newToken(16);
    peer.registerMethod(M.hello, (p) {
      if (p['token'] != token) throw RpcError(RpcError.unauthorized, 'Bad token');
      return hello();
    });
    for (final e in _methods().entries) {
      peer.registerMethod(e.key, e.value);
    }
    _subs
      ..add(store.changes.listen((c) => _queue(() => _entities['${c.entity.kind}/${c.entity.id}'] = c.entity)))
      ..add(store.runEvents.listen((e) => _queue(() => (_runEvents[e.runId] ??= []).add(e))))
      ..add(ctx.notices.listen((n) => peer.notify(E.notice, n)))
      ..add(ctx.broadcasts.listen((b) => peer.notify(b.$1, b.$2)));
    return RelayClient.attach(toClient.stream, toServer.sink, token: token, client: 'app');
  }

  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await notifier.dispose();
    await channels.dispose();
    await sync.dispose();
    store.close();
  }

  Map<String, Object?> hello() => {
    'version': relayVersion,
    'protocol': protocolVersion,
    'deviceId': ctx.deviceId,
    'userName': ctx.setting('userName', 'You'),
    'mobile': true,
    'mac': mac,
    'macName': sync.secrets.pairing?.macName,
  };

  // Entity and run events, batched per microtask like relayd's clients.
  void _queue(void Function() add) {
    add();
    if (_flushQueued) return;
    _flushQueued = true;
    scheduleMicrotask(() {
      _flushQueued = false;
      final peer = _peer;
      if (peer == null) return;
      if (_entities.isNotEmpty) {
        peer.notify(E.entity, {'items': [for (final e in _entities.values) {'kind': e.kind, 'data': _view(e)}]});
        _entities.clear();
      }
      for (final MapEntry(:key, :value) in _runEvents.entries) {
        peer.notify(E.runEvents, {'runId': key, 'events': [for (final e in value) e.toJson()]});
      }
      _runEvents.clear();
    });
  }

  /// Records as the app expects them (repos have no checkout here).
  Map<String, Object?> _view(Entity e) => e is Repo ? {...e.toJson(), 'localPath': null, 'cloned': false} : e.toJson();

  List<Map<String, Object?>> _json(Iterable<Entity> es) => [for (final e in es) _view(e)];

  static String _s(Map<String, Object?> p, String k) => p[k] as String? ?? (throw RpcError(RpcError.invalidParams, 'Missing "$k"'));

  /// Forwards [method] to the paired Mac.
  Future<Object?> _remote(String method, Map<String, Object?> p) async {
    if (mac == null) throw RpcError(RpcError.invalidParams, 'Pair this phone with your Mac first.');
    try {
      return await sync.live.command(method, p);
    } on CommandFailed catch (e) {
      throw RpcError(RpcError.internal, e.message);
    }
  }

  /// The Mac's agents, shaped like agents.list on the Mac.
  List<Map<String, Object?>> agents() {
    final d = mac == null ? null : store.get<DeviceInfo>(Kind.device, mac!);
    return [
      for (final a in d?.agents ?? const <Map<String, Object?>>[])
        {
          ...a,
          'binaryPath': 'remote',
          'enabled': true,
          'deviceId': d!.id,
          'active': a['active'] ?? 0,
          'today': {'costUsd': a['costToday'] ?? 0},
        },
    ];
  }

  Map<String, RpcHandler> _methods() => {
    M.status: (_) => {...hello(), 'home': paths.home, 'activeRuns': 0, 'terminals': 0},
    M.projectsList: (_) => _json(store.list<Project>(Kind.project)..sort((a, b) => a.position.compareTo(b.position))),
    M.reposList: (p) => _json(p['projectId'] == null ? store.list<Repo>(Kind.repo) : ctx.reposOf(_s(p, 'projectId'))),
    M.tasksList: (p) => _json(store.list<Task>(Kind.task, projectId: p['projectId'] as String?)),
    M.tasksGet: (p) {
      final t = ctx.task(_s(p, 'id'));
      return {
        'task': t.toJson(),
        'comments': _json(store.list<Comment>(Kind.comment, taskId: t.id)),
        'runs': _json(store.list<Run>(Kind.run, taskId: t.id)),
        'changes': _json(store.list<ChangeEntry>(Kind.change, taskId: t.id)),
        'workspace': null,
      };
    },
    M.tasksCreate: (p) {
      final fields = <String, Object?>{...?(p['fields'] as Map?)?.cast<String, Object?>()};
      // Work queued from the phone runs on its Mac.
      fields['runOn'] ??= mac ?? ctx.deviceId;
      fields['createdOn'] = ctx.deviceId;
      return store.createTask(_s(p, 'projectId'), fields).toJson();
    },
    M.tasksUpdate: (p) => store.patch<Task>(Kind.task, _s(p, 'id'), (p['fields'] as Map).cast()).toJson(),
    M.tasksMove: (p) => store.patch<Task>(Kind.task, _s(p, 'id'), {'status': _s(p, 'status'), 'position': ?p['position']}).toJson(),
    M.commentsList: (p) => _json(store.list<Comment>(Kind.comment, taskId: _s(p, 'taskId'))),
    // Through the Mac, so a reply to an agent's question reaches the agent.
    M.commentsPost: (p) => _remote(M.commentsPost, {...p, 'author': p['author'] ?? ctx.setting('userName', 'You')}),
    M.runsList: (p) => _json(store.list<Run>(Kind.run, taskId: p['taskId'] as String?)),
    M.runsEvents: (p) {
      final runId = _s(p, 'runId');
      if (sync.live.connected) sync.live.want(runId, store.events(runId).lastOrNull?.seq ?? 0);
      return [for (final e in store.events(runId, after: (p['after'] as num?)?.toInt() ?? 0)) e.toJson()];
    },
    for (final m in [M.runsStart, M.runsSteer, M.runsStop, M.runsPause, M.runsResume, M.permissionsAnswer, M.agentsUpdate]) m: (p) => _remote(m, p),
    M.agentsList: (_) => agents(),
    M.agentsDetect: (_) => agents(),
    M.rulesList: (_) => const [],
    M.workspacesList: (_) {
      final byTask = <String, List<Map<String, Object?>>>{};
      for (final c in store.list<ChangeEntry>(Kind.change)) {
        (byTask[c.taskId] ??= []).add(c.toJson());
      }
      return [for (final e in byTask.entries) {'taskId': e.key, 'changes': e.value}];
    },
    M.settingsGet: (_) => ctx.allSettings(),
    M.settingsSet: (p) {
      for (final e in (p['values'] as Map).entries) {
        store.setMeta('settings.${e.key}', '${e.value}');
      }
      sync.settingsChanged();
      return ctx.allSettings();
    },
    M.devicesList: (_) => _json(store.list<DeviceInfo>(Kind.device)),
    M.syncStatus: (_) => sync.status(),
    M.syncNow: (_) => sync.syncNow(),
    M.syncPair: (p) async => sync.pairWith(_s(p, 'code')),
    M.syncLeave: (_) => sync.leave(),
    M.pushRegister: (p) async {
      await sync.pushRegister(_s(p, 'token'), sandbox: p['sandbox'] == true);
      return true;
    },
    M.channelsList: (_) => channels.list(),
    M.channelsRead: (p) {
      channels.markRead(_s(p, 'channelId'));
      return true;
    },
    M.channelsPin: (p) {
      channels.pin(_s(p, 'channelId'), _s(p, 'messageId'), p['on'] != false);
      return true;
    },
    M.messagesList: (p) => _json(channels.messages(_s(p, 'channelId'))),
    M.messagesPost: (p) => channels.post(_s(p, 'channelId'), p['body'] as String? ?? '', replyTo: p['replyTo'] as String?),
    M.messagesReact: (p) {
      channels.react(_s(p, 'messageId'), _s(p, 'emoji'), p['on'] != false);
      return true;
    },
    M.messagesDelete: (p) {
      channels.delete(_s(p, 'id'));
      return true;
    },
    M.filesGet: (p) async => {'path': await channels.file(_s(p, 'messageId'), _s(p, 'fileId'))},
  };
}
