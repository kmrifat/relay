import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_core/relay_core.dart';
import 'package:relay_git/relay_git.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'context.dart';
import 'repo_inspect.dart';
import 'supervisor.dart';
import 'sync_service.dart';
import 'terminals.dart';
import 'workspaces.dart';

/// Registers every request method on a client connection.
class Api {
  Api(this.ctx, this.supervisor, this.workspaces, this.terminals, this.sync, {required this.startedAt});

  final DaemonContext ctx;
  final Supervisor supervisor;
  final Workspaces workspaces;
  final Terminals terminals;
  final SyncService sync;
  final DateTime startedAt;

  Store get store => ctx.store;

  static String _s(Map<String, Object?> p, String k) =>
      p[k] as String? ?? (throw RpcError(RpcError.invalidParams, 'Missing "$k"'));

  static Map<String, Object?> _m(Map<String, Object?> p, String k) => (p[k] as Map?)?.cast<String, Object?>() ?? const {};

  List<Map<String, Object?>> _json(Iterable<Entity> es) => [for (final e in es) e.toJson()];

  void register(RpcPeer peer) {
    final methods = <String, RpcHandler>{
      M.status: (_) => status(),

      // ------------------------------------------------------------ projects
      M.projectsList: (_) => _json(store.list<Project>(Kind.project)..sort((a, b) => a.position.compareTo(b.position))),
      M.projectsCreate: (p) {
        final key = (_s(p, 'key')).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (key.isEmpty) throw RpcError(RpcError.invalidParams, 'The key needs letters or digits.');
        if (store.list<Project>(Kind.project).any((x) => x.key == key)) {
          throw RpcError(RpcError.invalidParams, 'A project already uses the key $key.');
        }
        return store.create<Project>(Kind.project, {
          'key': key,
          'name': _s(p, 'name'),
          'color': p['color'] ?? _palette[store.list<Project>(Kind.project).length % _palette.length],
          'position': store.list<Project>(Kind.project).length,
          'nextNumber': 1,
        }).toJson();
      },
      M.projectsUpdate: (p) => store.patch<Project>(Kind.project, _s(p, 'id'), _m(p, 'fields')).toJson(),

      // ------------------------------------------------------------ repos
      M.reposList: (p) => [
        for (final r in p['projectId'] == null ? store.list<Repo>(Kind.repo) : ctx.reposOf(_s(p, 'projectId')))
          {...r.toJson(), 'localPath': r.pathOn(ctx.deviceId), 'cloned': r.pathOn(ctx.deviceId) != null && Directory(r.pathOn(ctx.deviceId)!).existsSync()},
      ],
      M.reposInspect: (p) => inspectRepo(ctx.git, _s(p, 'path')),
      M.reposAdd: (p) async {
        final projectId = _s(p, 'projectId');
        ctx.project(projectId);
        final path = p['path'] as String?;
        Map<String, Object?> info = const {};
        if (path != null) {
          info = await inspectRepo(ctx.git, path);
          if (info['isRepo'] != true) throw RpcError(RpcError.invalidParams, '$path is not a git repository.');
        }
        final existing = ctx.reposOf(projectId);
        final fields = _m(p, 'fields');
        return store.create<Repo>(Kind.repo, {
          'projectId': projectId,
          'name': fields['name'] ?? info['name'] ?? 'repo',
          'role': fields['role'] ?? info['role'] ?? '',
          'stack': fields['stack'] ?? info['stack'] ?? '',
          'baseBranch': fields['baseBranch'] ?? info['defaultBranch'] ?? 'main',
          'testCommand': fields['testCommand'] ?? info['testCommand'],
          'remoteUrl': fields['remoteUrl'] ?? info['remoteUrl'],
          'contractPaths': fields['contractPaths'] ?? info['contractPaths'] ?? const [],
          'mergeStep': fields['mergeStep'] ?? 0,
          'dependsOn': fields['dependsOn'] ?? const [],
          'color': fields['color'] ?? _palette[(existing.length + 1) % _palette.length],
          if (info['topLevel'] != null) Repo.pathField(ctx.deviceId): info['topLevel'],
        }).toJson();
      },
      M.reposUpdate: (p) {
        final fields = Map.of(_m(p, 'fields'));
        if (fields.containsKey('localPath')) {
          fields[Repo.pathField(ctx.deviceId)] = fields.remove('localPath');
        }
        return store.patch<Repo>(Kind.repo, _s(p, 'id'), fields).toJson();
      },
      M.reposRemove: (p) {
        store.delete(Kind.repo, _s(p, 'id'));
        return true;
      },
      M.reposClone: (params) async {
        final repo = ctx.repo(_s(params, 'id'));
        final url = repo.remoteUrl ?? (throw RpcError(RpcError.invalidParams, '${repo.name} has no remote URL.'));
        final dest = params['dest'] as String? ??
            p.join(ctx.env['HOME'] ?? ctx.paths.home, 'code', ctx.project(repo.projectId).key.toLowerCase(), repo.name);
        await ctx.git.clone(url, dest);
        return store.patch<Repo>(Kind.repo, repo.id, {Repo.pathField(ctx.deviceId): dest}).toJson();
      },

      // ------------------------------------------------------------ tasks
      M.tasksList: (p) => _json(store.list<Task>(Kind.task, projectId: p['projectId'] as String?)),
      M.tasksGet: (p) {
        final t = ctx.task(_s(p, 'id'));
        return {
          'task': t.toJson(),
          'comments': _json(store.list<Comment>(Kind.comment, taskId: t.id)),
          'runs': _json(store.list<Run>(Kind.run, taskId: t.id)),
          'changes': _json(workspaces.changesOf(t.id)),
          'workspace': workspaces.folderFor(t),
        };
      },
      M.tasksCreate: (p) {
        final fields = Map.of(_m(p, 'fields'));
        // A task runs on the device that queued it unless it names a
        // teammate's device (their agents, with their consent).
        fields['runOn'] ??= ctx.deviceId;
        fields['createdOn'] = ctx.deviceId;
        final t = store.createTask(_s(p, 'projectId'), fields);
        if (t.status == TaskStatus.queued) supervisor.tick();
        return t.toJson();
      },
      M.tasksUpdate: (p) {
        final t = store.patch<Task>(Kind.task, _s(p, 'id'), _m(p, 'fields'));
        if (t.status == TaskStatus.queued) supervisor.tick();
        return t.toJson();
      },
      M.tasksMove: (p) {
        final id = _s(p, 'id');
        final status = _s(p, 'status');
        final position = (p['position'] as num?)?.toDouble();
        final t = store.patch<Task>(Kind.task, id, {'status': status, 'position': ?position, if (status != TaskStatus.review) 'attention': null});
        if (status == TaskStatus.queued) supervisor.tick();
        return t.toJson();
      },
      M.tasksDelete: (p) {
        store.delete(Kind.task, _s(p, 'id'));
        return true;
      },
      M.tasksSuggestRepos: (p) => suggestRepos(ctx, _s(p, 'projectId'), p['text'] as String? ?? '', (p['repoIds'] as List?)?.cast<String>() ?? const []),

      // ------------------------------------------------------------ comments
      M.commentsList: (p) => _json(store.list<Comment>(Kind.comment, taskId: _s(p, 'taskId'))),
      M.commentsPost: (p) {
        final taskId = _s(p, 'taskId');
        final body = _s(p, 'body');
        final c = store.create<Comment>(Kind.comment, {
          'taskId': taskId,
          'authorKind': p['authorKind'] ?? 'person',
          'author': p['author'] ?? ctx.setting('userName', 'You'),
          'body': body,
          'question': ?p['question'],
        });
        final task = ctx.task(taskId);
        final fromPerson = (p['authorKind'] ?? 'person') == 'person';
        // A person's reply to an agent's question goes straight to that agent.
        if (fromPerson && task.data['attention'] == 'question') {
          store.patch<Task>(Kind.task, taskId, {'attention': null, 'question': null});
          for (final r in store.list<Run>(Kind.run, taskId: taskId)) {
            if (supervisor.isLive(r.id) && supervisor.session(r.id)!.canSteer) {
              supervisor.steer(r.id, 'Answer from ${c.author}: $body');
            }
          }
          return c.toJson();
        }
        // "@agent" in a comment reaches that agent's active run.
        for (final a in store.list<AgentProfile>(Kind.agent)) {
          if (body.contains('@${a.id}') || body.toLowerCase().contains('@${a.name.toLowerCase().replaceAll(' ', '-')}')) {
            for (final r in store.list<Run>(Kind.run, taskId: taskId)) {
              if (r.agentId == a.id && supervisor.isLive(r.id) && supervisor.session(r.id)!.canSteer) {
                supervisor.steer(r.id, body);
                store.appendEvent(r.id, RunEventType.steer, {'text': body, 'from': 'comment'});
              }
            }
          }
        }
        return c.toJson();
      },

      // ------------------------------------------------------------ runs
      M.runsList: (p) {
        final runs = store.list<Run>(Kind.run, taskId: p['taskId'] as String?);
        final active = p['active'] == true;
        return [
          for (final r in runs)
            if (!active || RunStatus.isActive(r.status)) {...r.toJson(), 'live': supervisor.isLive(r.id), 'canSteer': supervisor.session(r.id)?.canSteer ?? false},
        ];
      },
      M.runsGet: (p) {
        final r = ctx.run(_s(p, 'id'));
        return {...r.toJson(), 'live': supervisor.isLive(r.id), 'canSteer': supervisor.session(r.id)?.canSteer ?? false};
      },
      M.agentsMessage: (p) {
        supervisor.messageAgent(_s(p, 'taskId'), _s(p, 'from'), _s(p, 'to'), _s(p, 'text'));
        return true;
      },
      M.runsEvents: (p) {
        final runId = _s(p, 'runId');
        final events = store.events(runId, after: (p['after'] as num?)?.toInt() ?? 0, limit: (p['limit'] as num?)?.toInt());
        // A teammate's run: ask its device for what we haven't seen; it
        // arrives as run.events like a local run's.
        final run = store.get<Run>(Kind.run, runId);
        if (run?.deviceId != null && run!.deviceId != ctx.deviceId && sync.live.connected) {
          sync.live.want(runId, store.events(runId).lastOrNull?.seq ?? 0);
        }
        return [for (final e in events) e.toJson()];
      },
      M.runsStart: (p) async {
        // Starting a run by hand takes the task to this device, unless a
        // teammate's device is running it right now.
        final t = ctx.task(_s(p, 'taskId'));
        final active = t.data['activeRunId'] is String ? store.get<Run>(Kind.run, t.data['activeRunId'] as String) : null;
        if (active != null && RunStatus.isActive(active.status) && active.deviceId != null && active.deviceId != ctx.deviceId) {
          final where = store.get<DeviceInfo>(Kind.device, active.deviceId!)?.name ?? 'another device';
          throw RpcError(RpcError.invalidParams, '${ctx.taskKey(t)} is running on $where.');
        }
        if (t.str('runOn') != ctx.deviceId) store.patch<Task>(Kind.task, t.id, {'runOn': ctx.deviceId, 'attention': null});
        return (await supervisor.startRun(t.id, agentId: p['agentId'] as String?, extraPrompt: p['note'] as String?)).toJson();
      },
      M.runsSteer: (p) {
        supervisor.steer(_s(p, 'runId'), _s(p, 'text'));
        return true;
      },
      M.runsPause: (p) {
        supervisor.pause(_s(p, 'runId'));
        return true;
      },
      M.runsResume: (p) {
        supervisor.resume(_s(p, 'runId'));
        return true;
      },
      M.runsStop: (p) async {
        await supervisor.stop(_s(p, 'runId'));
        return true;
      },
      M.runsHandoff: (p) async => (await supervisor.handoff(_s(p, 'runId'), _s(p, 'agentId'), note: p['note'] as String?)).toJson(),
      M.permissionsAnswer: (p) {
        supervisor.answerPermission(_s(p, 'runId'), _s(p, 'requestId'), _s(p, 'answer'));
        return true;
      },

      // ------------------------------------------------------------ agents
      M.agentsList: (_) {
        final usage = supervisor.usageToday();
        return [
          for (final a in store.list<AgentProfile>(Kind.agent))
            {...a.toJson(), 'active': supervisor.activeRuns(a.id), 'today': usage[a.id] ?? const {}},
        ];
      },
      M.agentsDetect: (_) async {
        final found = await detectAgents(ctx);
        sync.publishDevice();
        return found;
      },
      M.agentsUpdate: (p) {
        final a = store.patch<AgentProfile>(Kind.agent, _s(p, 'id'), _m(p, 'fields'));
        sync.publishDevice();
        return a.toJson();
      },
      M.rulesList: (_) => _json(store.list<RoutingRule>(Kind.rule)..sort((a, b) => a.order.compareTo(b.order))),
      M.rulesSave: (p) {
        final fields = _m(p, 'fields');
        final id = p['id'] as String?;
        return (id == null ? store.create<RoutingRule>(Kind.rule, fields) : store.patch<RoutingRule>(Kind.rule, id, fields)).toJson();
      },
      M.rulesDelete: (p) {
        store.delete(Kind.rule, _s(p, 'id'));
        return true;
      },
      M.settingsGet: (_) => ctx.allSettings(),
      M.settingsSet: (p) {
        for (final e in _m(p, 'values').entries) {
          store.setMeta('settings.${e.key}', '${e.value}');
        }
        supervisor.tick();
        sync.settingsChanged();
        return ctx.allSettings();
      },

      // ------------------------------------------------------------ change sets
      M.changesList: (p) => [
        for (final c in workspaces.changesOf(_s(p, 'taskId'))) {...c.toJson(), 'repo': store.get<Repo>(Kind.repo, c.repoId)?.toJson()},
      ],
      M.changesMerge: (p) async {
        final task = ctx.task(_s(p, 'taskId'));
        await workspaces.refresh(task);
        return await workspaces.merge(task, repoId: p['repoId'] as String?);
      },
      M.changesPush: (p) async => workspaces.push(ctx.task(_s(p, 'taskId')), repoId: p['repoId'] as String?),
      M.workspacesList: (p) => workspaceList(),

      // ------------------------------------------------------------ sync
      M.syncStatus: (_) => sync.status(),
      M.syncTest: (p) async => {'problems': await sync.testParams(_m(p, 'storage'))},
      M.syncCreateTeam: (p) async => sync.createTeamFrom(_s(p, 'name'), _m(p, 'storage')),
      M.syncInvite: (_) async => {'code': await sync.invite()},
      M.syncJoin: (p) async => sync.join(_s(p, 'code')),
      M.syncNow: (_) async => sync.syncNow(),
      M.syncRevoke: (p) async => sync.revoke(_s(p, 'deviceId')),
      M.syncLeave: (_) async => sync.leave(),
      M.devicesList: (_) => _json(store.list<DeviceInfo>(Kind.device)),

      // ------------------------------------------------------------ git
      M.gitLog: (p) async {
        final dir = _dir(p);
        final commits = await ctx.git.log(dir, limit: (p['limit'] as num?)?.toInt() ?? 300, grep: p['grep'] as String?);
        final rows = layoutGraph([for (final c in commits) (c.hash, c.parents)]);
        return [for (var i = 0; i < commits.length; i++) {...commits[i].toJson(), 'graph': rows[i].toJson()}];
      },
      M.gitShow: (p) async => ctx.git.show(_dir(p), _s(p, 'hash')),
      M.gitDiff: (p) async => ctx.git.diff(_dir(p), base: p['base'] as String?, path: p['file'] as String?),
      M.gitStatus: (p) async => [for (final s in await ctx.git.status(_dir(p))) s.toJson()],
      M.gitBranches: (p) async {
        final dir = _dir(p);
        return {'current': await ctx.git.currentBranch(dir), 'local': await ctx.git.localBranches(dir)};
      },
      M.gitWorktrees: (p) async => [for (final w in await ctx.git.worktrees(_dir(p))) w.toJson()],

      // ------------------------------------------------------------ files
      M.fsList: (params) async {
        final dir = _dir(params);
        if (await ctx.git.isRepo(dir)) return {'root': dir, 'files': (await ctx.git.listFiles(dir)).take(20000).toList()};
        // A task workspace: every repo folder inside it, plus its own files.
        final files = <String>[];
        for (final e in Directory(dir).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path))) {
          final name = p.basename(e.path);
          if (e is File) files.add(name);
          if (e is Directory && await ctx.git.isRepo(e.path)) {
            files.addAll((await ctx.git.listFiles(e.path)).map((f) => '$name/$f'));
          }
        }
        return {'root': dir, 'files': files.isEmpty ? _walk(dir) : files.take(20000).toList()};
      },
      M.fsRead: (p) {
        final path = _file(p);
        final f = File(path);
        if (!f.existsSync()) throw RpcError(RpcError.notFound, 'No file $path');
        final len = f.lengthSync();
        if (len > 2 * 1024 * 1024) return {'path': path, 'tooLarge': true, 'size': len};
        final bytes = f.readAsBytesSync();
        if (bytes.take(8000).contains(0)) return {'path': path, 'binary': true, 'size': len};
        return {'path': path, 'text': utf8.decode(bytes, allowMalformed: true), 'size': len};
      },
      M.fsWrite: (p) {
        final path = _file(p);
        File(path).writeAsStringSync(_s(p, 'text'));
        return true;
      },

      // ------------------------------------------------------------ terminals
      M.termOpen: (p) async => terminals.open(
        cwd: _dir(p),
        cols: (p['cols'] as num?)?.toInt() ?? 100,
        rows: (p['rows'] as num?)?.toInt() ?? 30,
        runId: p['runId'] as String?,
      ),
      M.termInput: (p) {
        terminals.input(_s(p, 'termId'), text: p['text'] as String?, data: p['data'] as String?);
        return true;
      },
      M.termResize: (p) {
        terminals.resize(_s(p, 'termId'), (p['cols'] as num).toInt(), (p['rows'] as num).toInt());
        return true;
      },
      M.termClose: (p) async {
        await terminals.close(_s(p, 'termId'));
        return true;
      },
      M.termTakeover: (p) async {
        // Pause the agent and open a shell in its workspace.
        final run = ctx.run(_s(p, 'runId'));
        if (supervisor.isLive(run.id)) supervisor.pause(run.id);
        final cwd = run.workspacePath ?? (throw RpcError(RpcError.invalidParams, 'Run has no workspace'));
        return terminals.open(cwd: cwd, runId: run.id, cols: (p['cols'] as num?)?.toInt() ?? 100, rows: (p['rows'] as num?)?.toInt() ?? 30);
      },
    };
    for (final e in methods.entries) {
      peer.registerMethod(e.key, e.value);
    }
  }

  Map<String, Object?> status() => {
    'version': ctx.version,
    'protocol': protocolVersion,
    'pid': pid,
    'deviceId': ctx.deviceId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'uptimeSeconds': DateTime.now().difference(startedAt).inSeconds,
    'activeRuns': supervisor.totalActive,
    'rssBytes': ProcessInfo.currentRss,
    'home': ctx.paths.home,
    'terminals': terminals.list().length,
  };

  /// Every folder relayd will read or write: repo checkouts and workspaces.
  List<String> _roots() => [
    ctx.paths.workspaces,
    for (final r in store.list<Repo>(Kind.repo))
      if (r.pathOn(ctx.deviceId) != null) r.pathOn(ctx.deviceId)!,
  ];

  bool _allowed(String path) {
    final norm = p.normalize(p.absolute(path));
    return _roots().any((root) => norm == p.normalize(root) || p.isWithin(p.normalize(root), norm));
  }

  String _dir(Map<String, Object?> params) {
    final d = _s(params, 'path');
    if (!_allowed(d)) throw RpcError(RpcError.unauthorized, 'Relay only opens folders of your repos and workspaces.');
    return d;
  }

  String _file(Map<String, Object?> params) {
    final f = _s(params, 'path');
    if (!_allowed(f)) throw RpcError(RpcError.unauthorized, 'Relay only opens files in your repos and workspaces.');
    return f;
  }

  List<String> _walk(String dir) {
    final out = <String>[];
    for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
      if (e is File) out.add(p.relative(e.path, from: dir));
      if (out.length > 20000) break;
    }
    return out..sort();
  }

  List<Map<String, Object?>> workspaceList() {
    final out = <Map<String, Object?>>[];
    for (final t in store.list<Task>(Kind.task)) {
      final changes = workspaces.changesOf(t.id);
      if (changes.isEmpty) continue;
      out.add({
        'taskId': t.id,
        'key': ctx.taskKey(t),
        'title': t.title,
        'folder': workspaces.folderFor(t),
        'changes': [
          for (final c in changes) {...c.toJson(), 'repoName': store.get<Repo>(Kind.repo, c.repoId)?.name},
        ],
      });
    }
    return out;
  }
}

const _palette = ['#0A64D8', '#1F9D55', '#D70015', '#C77700', '#8944AB', '#4D6BFE', '#F38020', '#D49BF5'];

/// Finds agent CLIs and records them as agent profiles.
Future<List<Map<String, Object?>>> detectAgents(DaemonContext ctx) async {
  final found = await ctx.registry.detect(env: ctx.env);
  for (final d in found) {
    final adapter = ctx.registry[d.adapter]!;
    final existing = ctx.agent(d.adapter);
    if (existing == null) {
      ctx.store.create<AgentProfile>(Kind.agent, {
        'id': d.adapter,
        'adapter': d.adapter,
        'name': adapter.name,
        'binaryPath': d.binaryPath,
        'version': d.version,
        'enabled': true,
        'slots': d.adapter == 'claude-code' ? 3 : 2,
        'color': adapter.color,
        'letter': adapter.letter,
        'goodAt': adapter.goodAt,
      });
    } else {
      ctx.store.patch<AgentProfile>(Kind.agent, d.adapter, {'binaryPath': d.binaryPath, 'version': d.version});
    }
  }
  // Agents no longer on PATH stay listed but can't start.
  for (final a in ctx.store.list<AgentProfile>(Kind.agent)) {
    if (a.adapter == 'demo') continue;
    if (!found.any((d) => d.adapter == a.adapter) && a.binaryPath != null) {
      ctx.store.patch<AgentProfile>(Kind.agent, a.id, {'binaryPath': null});
    }
  }
  return [for (final d in found) d.toJson()];
}
