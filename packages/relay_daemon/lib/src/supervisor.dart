import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_agents/relay_agents.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'context.dart';
import 'sync_service.dart';
import 'workspaces.dart';

/// Starts agent runs, turns their events into run events and task status,
/// and keeps the queue moving: slots per agent, plan limits, routing rules,
/// dependencies, start times and pipelines.
class Supervisor {
  Supervisor(this.ctx, this.workspaces) {
    workspaces.contractListeners.add(_onContractChanged);
  }

  final DaemonContext ctx;
  final Workspaces workspaces;

  /// Set by the daemon; used to publish this device's agent use.
  SyncService? sync;
  final _sessions = <String, AgentSession>{}; // runId → session
  final _deadlines = <String, Timer>{}; // runId → stop-after timer
  Timer? _timer;
  bool _ticking = false;

  void startScheduler({Duration every = const Duration(seconds: 2)}) {
    _recoverInterruptedRuns();
    _timer = Timer.periodic(every, (_) => tick());
  }

  Future<void> dispose() async {
    _timer?.cancel();
    for (final t in _deadlines.values) {
      t.cancel();
    }
    for (final s in _sessions.values.toList()) {
      await s.stop();
    }
  }

  int activeRuns(String agentId) => _sessions.keys.where((id) => ctx.store.get<Run>(Kind.run, id)?.agentId == agentId).length;
  int get totalActive => _sessions.length;
  bool isLive(String runId) => _sessions.containsKey(runId);
  AgentSession? session(String runId) => _sessions[runId];

  /// Runs that were active when relayd last stopped can't be reattached
  /// (their process is gone); mark them stopped so the task can be retried.
  void _recoverInterruptedRuns() {
    for (final r in ctx.store.list<Run>(Kind.run)) {
      // Teammates' runs are theirs to recover.
      if (r.deviceId != null && r.deviceId != ctx.deviceId) continue;
      if (RunStatus.isActive(r.status)) {
        ctx.store.patch<Run>(Kind.run, r.id, {
          'status': RunStatus.stopped,
          'endedAt': DateTime.now().toUtc().toIso8601String(),
          'error': 'relayd restarted while this run was active',
        });
        final t = ctx.store.get<Task>(Kind.task, r.taskId);
        if (t != null && t.status == TaskStatus.running) {
          ctx.store.patch<Task>(Kind.task, t.id, {'status': TaskStatus.queued, 'attention': null, 'activeRunId': null});
        }
      }
    }
  }

  // ---------------------------------------------------------------- scheduler

  /// Starts queued tasks that are ready. Safe to call any time.
  Future<void> tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final maxTotal = ctx.intSetting('maxConcurrent', 4);
      final queued = ctx.store.list<Task>(Kind.task).where((t) => t.status == TaskStatus.queued).toList()
        ..sort((a, b) {
          final pa = a.priority == 0 ? 9 : a.priority, pb = b.priority == 0 ? 9 : b.priority;
          return pa != pb ? pa.compareTo(pb) : a.position.compareTo(b.position);
        });
      for (final t in queued) {
        if (totalActive >= maxTotal) break;
        if (t.data['activeRunId'] != null) continue;
        if (!_runsHere(t)) continue;
        if (!_ready(t)) continue;
        final agentId = pickAgent(t);
        if (agentId == null) continue;
        final agent = ctx.agent(agentId);
        if (agent == null || !agent.enabled || agent.binaryPath == null) continue;
        if (_limited(agent)) continue;
        if (activeRuns(agentId) >= agent.slots) continue;
        try {
          await startRun(t.id, agentId: agentId);
        } catch (e) {
          ctx.store.patch<Task>(Kind.task, t.id, {'status': TaskStatus.review, 'attention': 'failed', 'lastError': '$e'});
          ctx.notice('${ctx.taskKey(t)} could not start: $e', level: 'error');
        }
      }
    } finally {
      _ticking = false;
    }
  }

  /// Whether this device should run [t]: it is the task's `runOn` device,
  /// and, if a teammate queued it here, this device shares its agents.
  bool _runsHere(Task t) {
    final runOn = t.str('runOn') ?? t.str('createdOn') ?? (sync?.inTeam ?? false ? null : ctx.deviceId);
    if (runOn != ctx.deviceId) return false;
    final from = t.str('createdOn');
    if (from != null && from != ctx.deviceId && !ctx.boolSetting('shareAgents', false)) {
      if (t.data['attention'] != 'not-shared') {
        ctx.store.patch<Task>(Kind.task, t.id, {'attention': 'not-shared'});
      }
      return false;
    }
    return true;
  }

  bool _ready(Task t) {
    for (final dep in t.dependsOn) {
      final d = ctx.store.get<Task>(Kind.task, dep);
      if (d != null && d.status != TaskStatus.done) return false;
    }
    final at = DateTime.tryParse(t.startAt);
    if (at != null && at.isAfter(DateTime.now())) return false;
    return true;
  }

  bool _limited(AgentProfile a) {
    if (a.dailyCapUsd > 0) {
      final spent = (usageToday()[a.id]?['costUsd'] as double?) ?? 0;
      if (spent >= a.dailyCapUsd) return true;
    }
    final until = a.limitedUntil;
    if (until == null) return false;
    if (until.isBefore(DateTime.now())) {
      ctx.store.patch<AgentProfile>(Kind.agent, a.id, {'limitedUntil': null});
      return false;
    }
    return true;
  }

  /// Who should run this task: the pipeline step's agent, the assignee, or
  /// the first routing rule that matches; a limited agent falls back to the
  /// `limit` rule's agent.
  String? pickAgent(Task t) {
    String? chosen;
    final steps = t.pipeline;
    final stepIndex = _currentStep(t);
    if (stepIndex >= 0) {
      final s = steps[stepIndex];
      if (s.assigneeKind == 'agent') chosen = s.assignee;
      if (s.assigneeKind == 'person') return null;
    } else if (t.assigneeKind == 'agent') {
      chosen = t.assignee;
    } else if (t.assigneeKind == 'person') {
      return null;
    }
    final rules = ctx.store.list<RoutingRule>(Kind.rule)..sort((a, b) => a.order.compareTo(b.order));
    if (chosen == null || chosen == 'auto') {
      chosen = null;
      for (final r in rules) {
        final match = switch (r.when) {
          'tag' => t.tags.contains(r.value.replaceFirst('#', '')),
          'step' => stepIndex >= 0 && steps[stepIndex].name.toLowerCase() == r.value.toLowerCase(),
          'else' => true,
          _ => false,
        };
        if (match) {
          chosen = r.agentId;
          break;
        }
      }
      chosen ??= _leastBusyAgent();
    }
    final a = chosen == null ? null : ctx.agent(chosen);
    if (a != null && _limited(a)) {
      for (final r in rules.where((r) => r.when == 'limit')) {
        final f = ctx.agent(r.agentId);
        if (f != null && f.enabled && !_limited(f)) return f.id;
      }
    }
    return chosen;
  }

  String? _leastBusyAgent() {
    final agents = ctx.store.list<AgentProfile>(Kind.agent).where((a) => a.enabled && a.binaryPath != null && !_limited(a)).toList();
    if (agents.isEmpty) return null;
    agents.sort((a, b) => (activeRuns(a.id) / a.slots).compareTo(activeRuns(b.id) / b.slots));
    return agents.first.id;
  }

  int _currentStep(Task t) {
    final steps = t.pipeline;
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].status != 'done' && steps[i].status != 'skipped') return i;
    }
    return -1;
  }

  // ---------------------------------------------------------------- runs

  Future<Run> startRun(String taskId, {String? agentId, String? extraPrompt}) async {
    final task = ctx.task(taskId);
    final chosen = agentId ?? pickAgent(task);
    if (chosen == null) throw RpcError(RpcError.invalidParams, 'No agent available for ${ctx.taskKey(task)}');
    final agent = ctx.agent(chosen) ?? (throw RpcError(RpcError.notFound, 'No agent $chosen'));
    final adapter = ctx.registry[agent.adapter] ?? (throw RpcError(RpcError.notFound, 'No adapter ${agent.adapter}'));
    final step = _currentStep(task);

    final cwd = await workspaces.prepare(task);
    final prompt = buildPrompt(task, step, cwd, agent, extra: extraPrompt);
    final run = ctx.store.create<Run>(Kind.run, {
      'taskId': task.id,
      'projectId': task.projectId,
      'agentId': agent.id,
      'status': RunStatus.starting,
      'deviceId': ctx.deviceId,
      'workspacePath': cwd,
      'prompt': prompt,
      'pipelineStep': step,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
    });
    ctx.store.patch<Task>(Kind.task, task.id, {
      'status': TaskStatus.running,
      'activeRunId': run.id,
      'attention': null,
      'lastError': null,
      if (step >= 0) 'pipeline': _setStep(task, step, 'running'),
    });
    await workspaces.markRunning(task, agent.id);

    final mcpPath = _writeMcpConfig(run.id);
    final previous = ctx.store
        .list<Run>(Kind.run, taskId: task.id)
        .where((r) => r.agentId == agent.id && r.sessionId != null && r.id != run.id)
        .toList();
    final AgentSession session;
    try {
      session = await adapter.start(RunSpec(
        prompt: prompt,
        cwd: cwd,
        binary: agent.binaryPath,
        model: agent.model,
        environment: {...ctx.env, 'RELAY_RUN': run.id, 'RELAY_TASK': ctx.taskKey(task)},
        mcpConfigPath: mcpPath,
        argsTemplate: (agent.data['argsTemplate'] as List?)?.cast<String>(),
        resumeSessionId: extraPrompt != null && previous.isNotEmpty ? previous.last.sessionId : null,
        autoApprove: !ctx.boolSetting('askBeforeShell', true),
      ));
    } catch (e) {
      await _finish(run.id, RunStatus.failed, error: 'Could not start ${agent.name}: $e');
      rethrow;
    }
    _sessions[run.id] = session;
    final limitSecs = task.intOr('stopAfterSeconds', task.intOr('stopAfterMinutes', 0) * 60);
    final limit = (limitSecs / 60).ceil();
    if (limitSecs > 0) {
      _deadlines[run.id] = Timer(Duration(seconds: limitSecs), () async {
        if (!_sessions.containsKey(run.id)) return;
        ctx.store.appendEvent(run.id, RunEventType.status, {'status': 'stopped', 'detail': 'Stopped after $limit minutes (the task\'s time limit)'});
        ctx.notice('${ctx.taskKey(task)} hit its $limit-minute limit and was stopped', level: 'warning');
        await stop(run.id);
      });
    }
    ctx.store.patch<Run>(Kind.run, run.id, {'status': RunStatus.running});
    ctx.store.appendEvent(run.id, RunEventType.status, {'status': 'running', 'detail': 'Started ${agent.name} in $cwd'});
    unawaited(_pump(run.id, session));
    _broadcastAgentState();
    return ctx.run(run.id);
  }

  String? _writeMcpConfig(String runId) {
    final bin = ctx.relayBinary;
    if (bin == null) return null;
    final dir = Directory(p.join(ctx.paths.home, 'mcp'))..createSync(recursive: true);
    final f = File(p.join(dir.path, '$runId.json'));
    f.writeAsStringSync(mcpConfigJson(relayBinary: bin, runId: runId, socket: ctx.paths.socket));
    return f.path;
  }

  List<Map<String, Object?>> _setStep(Task t, int index, String status) => [
    for (var i = 0; i < t.pipeline.length; i++) (i == index ? t.pipeline[i].withStatus(status) : t.pipeline[i]).toJson(),
  ];

  String buildPrompt(Task task, int step, String cwd, AgentProfile agent, {String? extra}) {
    final project = ctx.project(task.projectId);
    final key = task.displayKey(project.key);
    final touched = ctx.touchedRepos(task);
    final others = ctx.reposOf(task.projectId).where((r) => !touched.contains(r)).toList();
    final b = StringBuffer()
      ..writeln('You are ${agent.name}, working on task $key in project "${project.name}", assigned through Relay.')
      ..writeln()
      ..writeln('# ${task.title}');
    if (task.brief.trim().isNotEmpty) b..writeln()..writeln(task.brief.trim());
    if (task.doneWhen.isNotEmpty) {
      b..writeln()..writeln('## Done when');
      for (final c in task.doneWhen) {
        b.writeln('- [${c.done ? 'x' : ' '}] ${c.text}');
      }
    }
    if (step >= 0) {
      final steps = task.pipeline;
      b
        ..writeln()
        ..writeln('## Your step: ${steps[step].name} (${step + 1} of ${steps.length})');
      if (steps[step].note.isNotEmpty) b.writeln(steps[step].note);
      final prior = ctx.store
          .list<Run>(Kind.run, taskId: task.id)
          .where((r) => r.status == RunStatus.done && r.summary != null)
          .toList();
      if (prior.isNotEmpty) b.writeln('Previous step said: ${prior.last.summary}');
    }
    b
      ..writeln()
      ..writeln('## Workspace')
      ..writeln('You are in `$cwd`.');
    if (touched.length > 1 || others.isNotEmpty) {
      b.writeln('Repos you may change (worktrees on branch `${task.branchName(project.key)}`): '
          '${touched.map((r) => '`${r.name}/`').join(', ')}.');
      if (others.isNotEmpty) {
        b.writeln('Read-only for this task: ${others.map((r) => '`${r.name}/`').join(', ')}.');
      }
      b.writeln('PROJECT.md in the workspace folder maps the repos, their contracts and merge order.');
    }
    for (final r in touched) {
      if (r.testCommand != null && r.testCommand!.isNotEmpty) b.writeln('Tests for ${r.name}: `${r.testCommand}`.');
    }
    final comments = ctx.store.list<Comment>(Kind.comment, taskId: task.id);
    if (comments.isNotEmpty) {
      b..writeln()..writeln('## Discussion so far');
      for (final c in comments.skip(comments.length > 8 ? comments.length - 8 : 0)) {
        b.writeln('- ${c.author}: ${c.body.replaceAll('\n', ' ')}');
      }
    }
    b
      ..writeln()
      ..writeln('## When you finish')
      ..writeln('Commit your changes in each repo you changed, with a message ending in:')
      ..writeln('Relay-Task: $key')
      ..writeln('Relay-Agent: ${agent.id}')
      ..writeln('Then reply with a two-sentence summary of what you did.');
    if (ctx.relayBinary != null) {
      b.writeln('You have `relay` MCP tools to post progress, ask the team a question, or message another agent on this task.');
    }
    if (extra != null && extra.trim().isNotEmpty) b..writeln()..writeln(extra.trim());
    return b.toString();
  }

  Future<void> _pump(String runId, AgentSession session) async {
    String? lastMessage;
    String? failure;
    DateTime? limitedUntil;
    var tokensIn = 0, tokensOut = 0;
    var cost = 0.0;
    var tools = 0;
    var turnDone = false;
    await for (final e in session.events) {
      final data = Map.of(e.data);
      switch (e.type) {
        case 'status':
          final st = data['status'];
          if (data['sessionId'] != null) ctx.store.patch<Run>(Kind.run, runId, {'sessionId': data['sessionId']});
          if (st == 'turn_done') turnDone = true;
          if (st == 'failed') {
            failure = data['detail'] as String? ?? 'failed';
            limitedUntil = DateTime.tryParse(data['limitedUntil'] as String? ?? '');
          }
        case 'message':
          lastMessage = data['text'] as String?;
        case 'tool_use':
          tools++;
          data.remove('input');
          ctx.store.patch<Run>(Kind.run, runId, {'toolCalls': tools, 'currentStep': data['summary']});
        case 'permission':
          ctx.store.patch<Run>(Kind.run, runId, {'status': RunStatus.waiting});
          final run = ctx.run(runId);
          ctx.store.patch<Task>(Kind.task, run.taskId, {'attention': 'permission'});
          ctx.notice('${ctx.agent(run.agentId)?.name ?? 'Agent'} wants to run: ${data['summary']}', level: 'ask');
        case 'permission_answer':
          final run = ctx.run(runId);
          ctx.store.patch<Run>(Kind.run, runId, {'status': RunStatus.running});
          ctx.store.patch<Task>(Kind.task, run.taskId, {'attention': null});
        case 'usage':
          if (data['partial'] == true) {
            tokensOut += (data['tokensOut'] as num?)?.toInt() ?? 0;
          } else {
            tokensIn = (data['tokensIn'] as num?)?.toInt() ?? tokensIn;
            tokensOut = (data['tokensOut'] as num?)?.toInt() ?? tokensOut;
            cost += (data['costUsd'] as num?)?.toDouble() ?? 0;
          }
          ctx.store.patch<Run>(Kind.run, runId, {'tokensIn': tokensIn, 'tokensOut': tokensOut, 'costUsd': cost});
          continue; // usage is shown in the header, not the stream
        case 'error':
          failure ??= data['text'] as String?;
      }
      ctx.store.appendEvent(runId, e.type, data);
      if (e.type == 'tool_result' && (data['ok'] == true)) {
        final run = ctx.run(runId);
        final task = ctx.store.get<Task>(Kind.task, run.taskId);
        if (task != null) unawaited(workspaces.refresh(task, agentId: run.agentId).catchError((_) {}));
      }
    }
    final code = await session.exitCode;
    _sessions.remove(runId);
    _deadlines.remove(runId)?.cancel();
    final run = ctx.run(runId);
    if (run.status == RunStatus.stopped) {
      _broadcastAgentState();
      return;
    }
    if (limitedUntil != null) {
      ctx.store.patch<AgentProfile>(Kind.agent, run.agentId, {'limitedUntil': limitedUntil.toUtc().toIso8601String()});
      ctx.notice('${ctx.agent(run.agentId)?.name} hit its limit until ${limitedUntil.toLocal()}', level: 'warning');
    }
    final ok = failure == null && (turnDone || code == 0);
    await _finish(runId, ok ? RunStatus.done : RunStatus.failed, summary: lastMessage, error: ok ? null : (failure ?? 'exit code $code'), requeue: limitedUntil != null);
  }

  Future<void> _finish(String runId, String status, {String? summary, String? error, bool requeue = false}) async {
    final run = ctx.run(runId);
    ctx.store.patch<Run>(Kind.run, runId, {
      'status': status,
      'endedAt': DateTime.now().toUtc().toIso8601String(),
      'summary': ?summary,
      'error': ?error,
    });
    ctx.store.appendEvent(runId, RunEventType.status, {'status': status, 'detail': error ?? summary ?? ''});
    final task = ctx.store.get<Task>(Kind.task, run.taskId);
    _broadcastAgentState();
    if (task == null) return;
    try {
      await workspaces.refresh(task, agentId: run.agentId, commit: status == RunStatus.done, settle: true);
    } catch (e) {
      ctx.notice('Could not refresh ${ctx.taskKey(task)}: $e', level: 'warning');
    }
    final fresh = ctx.task(task.id);
    if (status == RunStatus.done) {
      if (summary != null) {
        ctx.store.create<Comment>(Kind.comment, {
          'taskId': task.id,
          'authorKind': 'agent',
          'author': ctx.agent(run.agentId)?.name ?? run.agentId,
          'agentId': run.agentId,
          'body': summary,
        });
      }
      final step = run.pipelineStep;
      if (step >= 0 && step < fresh.pipeline.length) {
        final steps = _setStep(fresh, step, 'done');
        final next = step + 1 < fresh.pipeline.length ? fresh.pipeline[step + 1] : null;
        final nextIsAgent = next != null && next.assigneeKind == 'agent';
        ctx.store.patch<Task>(Kind.task, task.id, {
          'pipeline': steps,
          'activeRunId': null,
          'status': nextIsAgent ? TaskStatus.queued : TaskStatus.review,
          'attention': null,
        });
      } else {
        ctx.store.patch<Task>(Kind.task, task.id, {'status': TaskStatus.review, 'activeRunId': null, 'attention': null});
      }
    } else if (requeue) {
      ctx.store.patch<Task>(Kind.task, task.id, {'status': TaskStatus.queued, 'activeRunId': null, 'attention': null});
    } else {
      ctx.store.patch<Task>(Kind.task, task.id, {
        'status': TaskStatus.review,
        'activeRunId': null,
        'attention': 'failed',
        'lastError': error,
      });
    }
    unawaited(tick());
  }

  // ---------------------------------------------------------------- controls

  AgentSession _live(String runId) =>
      _sessions[runId] ?? (throw RpcError(RpcError.invalidParams, 'That run is not active.'));

  void steer(String runId, String text) {
    final s = _live(runId);
    if (!s.canSteer) throw RpcError(RpcError.invalidParams, '${ctx.agent(ctx.run(runId).agentId)?.name} cannot take messages while it runs.');
    s.steer(text);
  }

  void answerPermission(String runId, String requestId, String answer) {
    _live(runId).answerPermission(requestId, answer);
  }

  void pause(String runId) {
    _live(runId).pause();
    ctx.store.patch<Run>(Kind.run, runId, {'status': RunStatus.paused});
    ctx.store.appendEvent(runId, RunEventType.status, {'status': 'paused', 'detail': 'Paused by ${ctx.setting('userName', 'you')}'});
  }

  void resume(String runId) {
    _live(runId).resume();
    ctx.store.patch<Run>(Kind.run, runId, {'status': RunStatus.running});
    ctx.store.appendEvent(runId, RunEventType.status, {'status': 'running', 'detail': 'Resumed'});
  }

  Future<void> stop(String runId) async {
    final s = _sessions[runId];
    final run = ctx.run(runId);
    ctx.store.patch<Run>(Kind.run, runId, {'status': RunStatus.stopped, 'endedAt': DateTime.now().toUtc().toIso8601String()});
    ctx.store.appendEvent(runId, RunEventType.status, {'status': 'stopped', 'detail': 'Stopped'});
    ctx.store.patch<Task>(Kind.task, run.taskId, {'status': TaskStatus.review, 'activeRunId': null, 'attention': null});
    if (s != null) await s.stop();
    _sessions.remove(runId);
    _deadlines.remove(runId)?.cancel();
    final task = ctx.store.get<Task>(Kind.task, run.taskId);
    if (task != null) await workspaces.refresh(task, agentId: run.agentId, settle: true);
    _broadcastAgentState();
  }

  /// Stops this run and queues the task for another agent with a note.
  Future<Run> handoff(String runId, String toAgentId, {String? note}) async {
    final run = ctx.run(runId);
    if (_sessions.containsKey(runId)) await stop(runId);
    final from = ctx.agent(run.agentId)?.name ?? run.agentId;
    return startRun(run.taskId, agentId: toAgentId, extraPrompt: 'This task was handed over from $from. '
        'Its work so far is committed in the workspace.${note == null ? '' : ' Note: $note'}');
  }

  void _onContractChanged(Task task, String text) {
    if (!ctx.boolSetting('agentMessages', true)) return;
    for (final r in ctx.store.list<Run>(Kind.run, taskId: task.id)) {
      final s = _sessions[r.id];
      if (s != null && s.canSteer) {
        s.steer('Relay: $text');
        ctx.store.appendEvent(r.id, RunEventType.steer, {'text': 'Relay: $text', 'from': 'contract'});
      }
    }
  }

  /// Delivers an agent-to-agent message: a comment on the task, and a
  /// message into the target agent's active run if it can take one.
  void messageAgent(String taskId, String fromAgent, String toAgent, String text) {
    ctx.store.create<Comment>(Kind.comment, {
      'taskId': taskId,
      'authorKind': 'agent',
      'author': ctx.agent(fromAgent)?.name ?? fromAgent,
      'agentId': fromAgent,
      'to': toAgent,
      'body': text,
    });
    if (!ctx.boolSetting('agentMessages', true)) return;
    for (final r in ctx.store.list<Run>(Kind.run, taskId: taskId)) {
      if (r.agentId != toAgent) continue;
      final s = _sessions[r.id];
      if (s != null && s.canSteer) {
        final msg = '${ctx.agent(fromAgent)?.name ?? fromAgent} asks: $text';
        s.steer(msg);
        ctx.store.appendEvent(r.id, RunEventType.steer, {'text': msg, 'from': fromAgent});
      }
    }
  }

  void _broadcastAgentState() {
    ctx.broadcast(E.agentState, {
      'agents': [
        for (final a in ctx.store.list<AgentProfile>(Kind.agent))
          {'id': a.id, 'active': activeRuns(a.id), 'slots': a.slots, 'limitedUntil': a.data['limitedUntil']},
      ],
    });
  }

  /// Today's usage per agent, from finished and active runs.
  Map<String, Map<String, Object?>> usageToday() {
    final start = DateTime.now();
    final day = DateTime(start.year, start.month, start.day);
    final out = <String, Map<String, Object?>>{};
    for (final r in ctx.store.list<Run>(Kind.run)) {
      final s = r.startedAt;
      if (s == null || s.toLocal().isBefore(day)) continue;
      final u = out.putIfAbsent(r.agentId, () => {'runs': 0, 'tokensIn': 0, 'tokensOut': 0, 'costUsd': 0.0});
      u['runs'] = (u['runs'] as int) + 1;
      u['tokensIn'] = (u['tokensIn'] as int) + r.tokensIn;
      u['tokensOut'] = (u['tokensOut'] as int) + r.tokensOut;
      u['costUsd'] = (u['costUsd'] as double) + r.costUsd;
    }
    return out;
  }
}
