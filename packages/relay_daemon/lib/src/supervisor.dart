import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_agents/relay_agents.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'collab.dart';
import 'context.dart';
import 'sync_service.dart';
import 'workspaces.dart';

/// Starts agent runs, turns their events into run events and task status,
/// and keeps the queue moving: slots per agent, plan limits, routing rules,
/// dependencies, start times and pipelines.
class Supervisor {
  /// Messages, plans and handoffs between agents (M14).
  late final collab = Collab(ctx)
    ..deliverLive = _deliverLive
    ..tick = () => unawaited(tick());

  Supervisor(this.ctx, this.workspaces) {
    workspaces.contractListeners.add(_onContractChanged);
  }

  final DaemonContext ctx;
  final Workspaces workspaces;

  /// Set by the daemon; used to publish this device's agent use.
  SyncService? sync;
  final _sessions = <String, AgentSession>{}; // runId → session
  final _deadlines = <String, Timer>{}; // runId → stop-after timer
  final _pumps = <String, Future<void>>{}; // runId → its event pump
  Timer? _timer;
  bool _ticking = false;

  void startScheduler({Duration every = const Duration(seconds: 2)}) {
    _recoverInterruptedRuns();
    _timer = Timer.periodic(every, (_) => tick());
  }

  /// relayd is stopping: its runs end as if it had restarted (stopped, the
  /// task queued again), and their pumps finish before the store closes.
  Future<void> dispose() async {
    _timer?.cancel();
    for (final t in _deadlines.values) {
      t.cancel();
    }
    for (final MapEntry(key: runId, value: s) in _sessions.entries.toList()) {
      final run = ctx.store.get<Run>(Kind.run, runId);
      if (run != null && RunStatus.isActive(run.status)) {
        ctx.store.patch<Run>(Kind.run, runId, {
          'status': RunStatus.stopped,
          'endedAt': DateTime.now().toUtc().toIso8601String(),
          'error': 'relayd stopped while this run was active',
        });
        ctx.store.appendEvent(runId, RunEventType.status, {'status': 'stopped', 'detail': 'relayd stopped'});
        final t = ctx.store.get<Task>(Kind.task, run.taskId);
        if (t != null && t.status == TaskStatus.running) {
          ctx.store.patch<Task>(Kind.task, t.id, {'status': TaskStatus.queued, 'attention': null, 'activeRunId': null});
        }
      }
      await s.stop();
    }
    await Future.wait(_pumps.values).timeout(const Duration(seconds: 10), onTimeout: () => []);
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
    // "Pause new work" (menu bar, phone): running work goes on, nothing new starts.
    if (ctx.boolSetting('schedulerPaused', false)) return;
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
        if (_needsApproval(t)) continue;
        final agentId = pickAgent(t);
        if (agentId != null && _teamPaused(agentId)) continue;
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
    // My own phone queuing work on my Mac is me, not a teammate.
    final mine = from == null || from == ctx.deviceId || ctx.store.get<DeviceInfo>(Kind.device, from)?.data['companionOf'] == ctx.deviceId;
    if (!mine && !ctx.boolSetting('shareAgents', false)) {
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
      setLimited(a.id, null);
      return false;
    }
    return true;
  }

  /// "Pause team" holds back new work for every agent on the team.
  bool _teamPaused(String agentId) {
    final a = ctx.agent(agentId);
    return a != null && a.teamId != null && ctx.store.get<Team>(Kind.team, a.teamId!)?.data['paused'] == true;
  }

  /// A message for [agentId] goes into its live run, if it has one that
  /// takes messages.
  bool _deliverLive(String agentId, String text, String from) {
    var delivered = false;
    for (final e in _sessions.entries) {
      final run = ctx.store.get<Run>(Kind.run, e.key);
      if (run?.agentId != agentId || !e.value.canSteer) continue;
      e.value.steer(text);
      ctx.store.appendEvent(e.key, RunEventType.steer, {'text': text, 'from': from});
      delivered = true;
    }
    return delivered;
  }

  /// A plan limit belongs to the CLI's account, so it holds back every
  /// agent running on that CLI, and clears for all of them.
  void setLimited(String agentId, DateTime? until) {
    final runtime = ctx.agent(agentId)?.runtimeId ?? agentId;
    for (final a in ctx.store.list<AgentProfile>(Kind.agent).where((a) => a.runtimeId == runtime)) {
      ctx.store.patch<AgentProfile>(Kind.agent, a.id, {'limitedUntil': until?.toUtc().toIso8601String()});
    }
  }

  /// A repo set to "ask before agents work here" holds a task until a
  /// person says yes (Approve on the task, or starting it by hand).
  bool _needsApproval(Task t) {
    if (t.data['approved'] == true) return false;
    final asks = ctx.touchedRepos(t).where((r) => r.agentPolicy == 'ask').toList();
    if (asks.isEmpty) return false;
    if (t.data['attention'] != 'approval') {
      ctx.store.patch<Task>(Kind.task, t.id, {'attention': 'approval', 'question': '${asks.map((r) => r.name).join(', ')} ask before agents work there.'});
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
    // Role agents take the work their team gives them, not whatever is free.
    final agents = ctx.store.list<AgentProfile>(Kind.agent).where((a) => a.enabled && a.binaryPath != null && !a.isRole && !_limited(a)).toList();
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

  /// The model and effort a run starts with. Most specific first: this run
  /// ([model], [effort]), the pipeline step, the task, then the agent. A
  /// task's model counts only for the CLI it was picked for, and an effort
  /// the CLI doesn't have is skipped rather than passed as a bad flag.
  (String?, String?) modelFor(Task task, int step, AgentProfile agent, AgentAdapter adapter, {String? model, String? effort}) {
    String? pick(List<String?> xs) => xs.map((x) => x?.trim()).where((x) => x != null && x.isNotEmpty).firstOrNull;
    final s = step >= 0 ? task.pipeline[step] : null;
    final taskModel = task.modelFor == null || task.modelFor == agent.adapter ? task.model : null;
    final m = pick([model, s?.model, taskModel, agent.model]);
    final e = pick([for (final x in [effort, s?.effort, task.effort, agent.effort]) if (adapter.efforts.contains(x?.trim())) x]);
    return (m, e);
  }

  /// A message in a side-panel chat: a hidden task (`ask: chat`) whose
  /// every turn is a run. The first message starts the chat; a later one
  /// goes into the live run when the agent takes messages, or else resumes
  /// the agent's session in a new run. [context] is the page the person
  /// is looking at.
  Future<({String chatId, String runId})> chat({
    String? chatId,
    required String agentId,
    required String text,
    String? context,
    String? projectId,
    String? model,
    String? effort,
  }) async {
    final agent = ctx.agent(agentId) ?? (throw RpcError(RpcError.notFound, 'No agent $agentId'));
    final message = context == null || context.trim().isEmpty ? text.trim() : '${text.trim()}\n\n(They are looking at: ${context.trim()})';
    Task task;
    if (chatId != null) {
      task = ctx.task(chatId);
      final active = task.str('activeRunId');
      if (active != null && isLive(active)) {
        final run = ctx.run(active);
        if (run.agentId != agentId || !_sessions[active]!.canSteer) {
          throw RpcError(RpcError.invalidParams, '${ctx.agent(run.agentId)?.name ?? 'The agent'} is still answering. Wait for it, or stop it.');
        }
        steer(active, text.trim());
        return (chatId: task.id, runId: active);
      }
    } else {
      final pid = projectId ?? ctx.store.list<Project>(Kind.project).firstOrNull?.id ?? (throw RpcError(RpcError.invalidParams, 'Add a project first.'));
      final title = text.trim().replaceAll(RegExp(r'\s+'), ' ');
      // Not createTask: a chat takes no number, so the project's task keys
      // don't skip.
      if (ctx.store.get<Project>(Kind.project, pid) == null) throw RpcError(RpcError.notFound, 'No project $pid');
      task = ctx.store.create<Task>(Kind.task, {
        'projectId': pid,
        'number': 0,
        'title': 'Chat: ${title.length > 60 ? '${title.substring(0, 59)}…' : title}',
        'ask': 'chat',
        'assigneeKind': 'agent',
        'assignee': agent.id,
        'status': TaskStatus.backlog,
        'runOn': ctx.deviceId,
        'createdOn': ctx.deviceId,
      });
    }
    final run = await startRun(task.id, agentId: agent.id, extraPrompt: '## Their message\n$message', model: model, effort: effort, chatText: text.trim(), resumeWith: message);
    return (chatId: task.id, runId: run.id);
  }

  /// [chatText] is what the person typed, shown in the chat. [resumeWith]
  /// replaces the whole prompt when the agent's session resumes (a chat's
  /// next turn), since the session already has the rest.
  Future<Run> startRun(String taskId, {String? agentId, String? extraPrompt, String? model, String? effort, String? chatText, String? resumeWith}) async {
    final task = ctx.task(taskId);
    final chosen = agentId ?? pickAgent(task);
    if (chosen == null) throw RpcError(RpcError.invalidParams, 'No agent available for ${ctx.taskKey(task)}');
    final agent = ctx.agent(chosen) ?? (throw RpcError(RpcError.notFound, 'No agent $chosen'));
    final adapter = ctx.registry[agent.adapter] ?? (throw RpcError(RpcError.notFound, 'No adapter ${agent.adapter}'));
    final step = _currentStep(task);
    final (useModel, useEffort) = modelFor(task, step, agent, adapter, model: model, effort: effort);

    final cwd = await workspaces.prepare(task);
    final previous = ctx.store
        .list<Run>(Kind.run, taskId: task.id)
        .where((r) => r.agentId == agent.id && r.sessionId != null)
        .toList();
    final resumeId = extraPrompt != null && previous.isNotEmpty ? previous.last.sessionId : null;
    final prompt = resumeId != null && resumeWith != null ? resumeWith : buildPrompt(task, step, cwd, agent, extra: extraPrompt, mail: collab.takeMail(agent.id));
    final run = ctx.store.create<Run>(Kind.run, {
      'taskId': task.id,
      'projectId': task.projectId,
      'agentId': agent.id,
      'status': RunStatus.starting,
      'deviceId': ctx.deviceId,
      'workspacePath': cwd,
      'prompt': prompt,
      'pipelineStep': step,
      'model': ?useModel,
      'effort': ?useEffort,
      'chatText': ?chatText,
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
    final AgentSession session;
    try {
      session = await adapter.start(RunSpec(
        prompt: prompt,
        cwd: cwd,
        binary: agent.binaryPath,
        model: useModel,
        effort: useEffort,
        environment: {...ctx.env, 'RELAY_RUN': run.id, 'RELAY_TASK': ctx.taskKey(task), 'RELAY_HOME': ctx.paths.home},
        mcpConfigPath: mcpPath,
        relayMcp: ctx.relayBinary == null ? null : McpServer(ctx.relayBinary!, ['mcp', '--run', run.id], env: {'RELAY_HOME': ctx.paths.home}),
        // A single-repo task starts in its repo; the workspace around it
        // holds PROJECT.md and the other repos' snapshots.
        addDirs: [if (!p.equals(workspaces.folderFor(task), cwd)) workspaces.folderFor(task)],
        argsTemplate: (agent.data['argsTemplate'] as List?)?.cast<String>(),
        resumeSessionId: resumeId,
        autoApprove: !ctx.boolSetting('askBeforeShell', true),
        readOnly: task.str('ask') != null || !agent.can(AgentCap.editCode),
        disallowedTools: [if (!agent.can(AgentCap.runShell)) 'Bash'],
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
    final using = [?useModel, if (useEffort != null) 'effort $useEffort'].join(', ');
    ctx.store.appendEvent(run.id, RunEventType.status, {'status': 'running', 'detail': 'Started ${agent.name}${using.isEmpty ? '' : ' ($using)'} in $cwd'});
    // A pump error stays uncaught, as it was before dispose() waited on it.
    final pump = _pumps[run.id] = _pump(run.id, session).catchError((Object e, StackTrace st) => Zone.current.handleUncaughtError(e, st));
    unawaited(pump.whenComplete(() => _pumps.remove(run.id)));
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

  String buildPrompt(Task task, int step, String cwd, AgentProfile agent, {String? extra, List<Comment> mail = const []}) {
    final project = ctx.project(task.projectId);
    final key = task.displayKey(project.key);
    final touched = ctx.touchedRepos(task);
    final others = ctx.reposOf(task.projectId).where((r) => !touched.contains(r)).toList();
    final chat = task.str('ask') == 'chat';
    if (chat) return _chatPrompt(task, project, cwd, agent, extra);
    final b = StringBuffer()
      ..writeln('You are ${agent.name}${agent.role.isEmpty ? '' : ', ${agent.role}'}, working on task $key in project "${project.name}", assigned through Relay.')
      ..writeln();
    if (agent.responsibilities.trim().isNotEmpty || !agent.can(AgentCap.editCode)) {
      b..writeln('## Your role')..writeln(agent.responsibilities.trim());
      if (!agent.can(AgentCap.editCode)) b.writeln('In this role you don\'t change code: read, decide, and hand work on.');
      b.writeln();
    }
    b.writeln('# ${task.title}');
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
      if (touched.isNotEmpty) {
        b.writeln('Repos you may change (worktrees on branch `${task.branchName(project.key)}`): '
            '${touched.map((r) => '`${r.name}/`').join(', ')}.');
      }
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
    final ask = task.str('ask');
    if (ask != null) {
      b
        ..writeln()
        ..writeln('## This is a question, not a change')
        ..writeln('Every repo here is a read-only copy. Read what you need; don\'t edit files or commit.')
        ..writeln(switch (ask) {
          'plan' when agent.can(AgentCap.assign) =>
            'Propose the plan with relay_propose_plan: tasks in order, each with a title, brief, "done when" checks and the teammate who does it. '
                'It starts when the person approves it. Then reply with one line saying what you proposed.',
          'plan' => 'Reply with a plan: the steps in order, which repo each touches, and the tasks you would make, each with a title and "done when" checks.',
          _ => 'Reply with the answer in your final message; it is posted in the channel. Keep it short and point to files by path.',
        });
    } else if (!agent.can(AgentCap.editCode)) {
      b
        ..writeln()
        ..writeln('## When you finish')
        ..writeln('Reply with a two-sentence summary of what you decided and who you handed work to.');
    } else {
      b
        ..writeln()
        ..writeln('## When you finish')
        ..writeln('Commit your changes in each repo you changed, with a message ending in:')
        ..writeln('Relay-Task: $key')
        ..writeln('Relay-Agent: ${agent.id}')
        ..writeln('Then reply with a two-sentence summary of what you did.');
    }
    if (ctx.relayBinary != null) {
      final generic = ctx.registry[agent.adapter] is GenericAdapter;
      b.writeln(generic
          ? 'Reach Relay from the shell: `"${ctx.relayBinary}" tool` lists the tools, and `"${ctx.relayBinary}" tool relay_progress \'{"text":"…"}\'` calls one '
              '(post progress, ask a question, message a teammate, report test results).'
          : 'You have `relay` MCP tools to post progress, ask a question, message a teammate (relay_message_agent), report test results (relay_report) and see your team (relay_team).');
    }
    if (task.str('handoffNote') case final note? when note.isNotEmpty) b..writeln()..writeln('## Handed to you')..writeln(note);
    if (mail.isNotEmpty) {
      b..writeln()..writeln('## Messages for you');
      for (final m in mail) {
        b.writeln('- ${m.author}: ${m.body.replaceAll('\n', ' ')}');
      }
    }
    if (extra != null && extra.trim().isNotEmpty) b..writeln()..writeln(extra.trim());
    return b.toString();
  }

  /// A chat's first turn, or a turn whose agent can't resume: who they
  /// are talking to, what Relay is, the conversation so far and the message.
  String _chatPrompt(Task task, Project project, String cwd, AgentProfile agent, String? extra) {
    final b = StringBuffer()
      ..writeln('You are ${agent.name}${agent.role.isEmpty ? '' : ', ${agent.role}'}, chatting with a person in the side panel of Relay, '
          'the task manager where they run coding agents like you on their projects. The chat started in project "${project.name}".')
      ..writeln()
      ..writeln('## How to help')
      ..writeln('Answer questions about their projects, tasks, agents and code, and do what they ask in Relay. '
          'Look things up with the relay tools (relay_projects, relay_tasks, relay_task_status) rather than guessing, and change things with them '
          'when asked: relay_update_task moves a task (backlog, queued, running, review, done), ticks its checks or adds a note; relay_create_task makes one.')
      ..writeln('Name tasks by key (e.g. ${project.key}-3); Relay turns keys into links. Keep replies short: a few sentences or a short list.')
      ..writeln('You are in `$cwd`, where every repo of the project is a read-only copy. Read code when it helps; don\'t edit files or commit.');
    final turns = ctx.store.list<Run>(Kind.run, taskId: task.id).where((r) => r.str('chatText') != null && RunStatus.isFinished(r.status)).toList();
    if (turns.isNotEmpty) {
      b..writeln()..writeln('## The conversation so far');
      for (final r in turns.skip(turns.length > 12 ? turns.length - 12 : 0)) {
        b.writeln('Person: ${r.str('chatText')!.replaceAll('\n', ' ')}');
        if (r.summary != null) b.writeln('${ctx.agent(r.agentId)?.name ?? r.agentId}: ${r.summary!.replaceAll('\n', ' ')}');
      }
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
      setLimited(run.agentId, limitedUntil);
      ctx.notice('${ctx.agent(run.agentId)?.name} hit its limit until ${limitedUntil.toLocal()}', level: 'warning');
    }
    final ok = failure == null && (turnDone || code == 0);
    await _finish(runId, ok ? RunStatus.done : RunStatus.failed, summary: lastMessage, error: ok ? null : (failure ?? 'exit code $code'), requeue: limitedUntil != null);
  }

  Future<void> _finish(String runId, String status, {String? summary, String? error, bool requeue = false}) async {
    final run = ctx.run(runId);
    // A signed-out CLI fails every task the same way: say how to fix it,
    // and keep what the CLI said on the run.
    final profile = ctx.agent(run.agentId);
    final hint = error == null ? null : signInHint(profile?.adapter ?? run.agentId, profile?.name ?? run.agentId, error);
    final rawError = hint == null ? null : error;
    if (hint != null) {
      error = hint;
      ctx.notice(hint, level: 'warning');
    }
    ctx.store.patch<Run>(Kind.run, runId, {
      'status': status,
      'endedAt': DateTime.now().toUtc().toIso8601String(),
      'summary': ?summary,
      'error': ?error,
      'rawError': ?rawError,
    });
    ctx.store.appendEvent(runId, RunEventType.status, {'status': status, 'detail': rawError != null ? '$error\n$rawError' : error ?? summary ?? ''});
    final task = ctx.store.get<Task>(Kind.task, run.taskId);
    _broadcastAgentState();
    if (task == null) return;
    try {
      await workspaces.refresh(task, agentId: run.agentId, commit: status == RunStatus.done, settle: true);
    } catch (e) {
      ctx.notice('Could not refresh ${ctx.taskKey(task)}: $e', level: 'warning');
    }
    final fresh = ctx.task(task.id);
    // A question is over once answered (or not): it never waits for review.
    if (fresh.str('ask') != null && !requeue) {
      if (status == RunStatus.done && summary != null) {
        ctx.store.create<Comment>(Kind.comment, {'taskId': task.id, 'authorKind': 'agent', 'author': ctx.agent(run.agentId)?.name ?? run.agentId, 'agentId': run.agentId, 'body': summary});
      }
      ctx.store.patch<Task>(Kind.task, task.id, {'status': TaskStatus.done, 'activeRunId': null, 'attention': null, 'lastError': status == RunStatus.done ? null : error});
      unawaited(tick());
      return;
    }
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
        final agent = ctx.agent(run.agentId);
        final changed = workspaces.changesOf(task.id).any((ch) => ch.additions + ch.deletions + ch.filesChanged > 0);
        final next = agent == null ? null : collab.afterDone(fresh, agent, changed: changed);
        if (next != null) {
          ctx.store.patch<Task>(Kind.task, task.id, {'activeRunId': null, 'attention': null, ...next});
          final to = ctx.agent(next['assignee'] as String? ?? '');
          if (to != null && next['status'] == TaskStatus.queued) {
            ctx.store.create<Comment>(Kind.comment, {'taskId': task.id, 'authorKind': 'system', 'author': 'Relay', 'body': 'Handed to ${to.name}: ${next['handoffNote'] ?? ''}'});
          }
        } else {
          ctx.store.patch<Task>(Kind.task, task.id, {'status': TaskStatus.review, 'activeRunId': null, 'attention': null});
        }
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
    final s = _live(runId);
    if (!s.canPause) {
      throw RpcError(RpcError.invalidParams, 'Pausing an agent isn\'t available on Windows yet. Stop it instead; its work so far stays in the workspace.');
    }
    s.pause();
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
  String messageAgent(String taskId, String fromAgent, String toAgent, String text) => collab.message(fromAgent, toAgent, text, taskId: taskId);

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
