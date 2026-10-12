import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:relay_core/relay_core.dart' show AgentCap, AgentProfile, RunStatus, TaskStatus;
import 'package:relay_protocol/relay_protocol.dart';

/// `relay mcp`: an MCP server (stdio) that talks to relayd.
///
/// With `--run <id>`, which is how Relay starts its agents, the tools are
/// about that run's task. Without one (a person's own Claude Code, after
/// `claude mcp add relay -- relay mcp`) they work across projects: list
/// projects and tasks, create a task, check on one.
Future<int> runMcpServer(String? runId, RelayPaths paths) async {
  final peer = RpcPeer(stdin, stdout, name: 'mcp');
  final tools = RelayTools(paths, runId);

  peer.registerMethod('initialize', (p) => {
    'protocolVersion': p['protocolVersion'] ?? '2025-06-18',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'relay', 'version': '0.1.0'},
  });
  peer.onNotification('notifications/initialized', (_) {});
  peer.registerMethod('ping', (_) => {});
  peer.registerMethod('tools/list', (_) async => {'tools': await tools.list()});
  peer.registerMethod('tools/call', (p) async {
    final name = p['name'] as String? ?? '';
    final a = (p['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
    try {
      return {
        'content': [
          {'type': 'text', 'text': await tools.call(name, a)},
        ],
      };
    } catch (e) {
      return {
        'content': [
          {'type': 'text', 'text': 'Relay error: ${e is RpcError ? e.message : e}'},
        ],
        'isError': true,
      };
    }
  });
  await peer.done;
  await tools.close();
  return 0;
}

/// `relay tool <name> [json]`: the same tools from a shell, for agent CLIs
/// without MCP. RELAY_RUN (set for every run) says whose they are.
Future<int> runToolCli(String? runId, RelayPaths paths, List<String> args) async {
  final tools = RelayTools(paths, runId);
  try {
    if (args.isEmpty) {
      for (final t in await tools.list()) {
        stdout.writeln('${t['name']}: ${t['description']}');
      }
      return 0;
    }
    final params = args.length > 1 ? (jsonDecode(args.sublist(1).join(' ')) as Map).cast<String, Object?>() : const <String, Object?>{};
    stdout.writeln(await tools.call(args.first, params));
    return 0;
  } on Object catch (e) {
    stderr.writeln('relay tool: ${e is RpcError ? e.message : e}');
    return 1;
  } finally {
    await tools.close();
  }
}

/// The tools, for one run (`runId`) or for a person's own agent.
class RelayTools {
  RelayTools(this.paths, String? runId) : runId = runId == null || runId.isEmpty ? null : runId;
  final RelayPaths paths;
  final String? runId;
  bool get forRun => runId != null;
  RelayClient? _client;
  Map<String, Object?>? _run;

  List<Map<String, Object?>> get _tools => forRun ? _runTools : _personTools;

  Future<RelayClient> _relay() async {
    _client ??= await RelayClient.connect(paths, client: 'mcp');
    if (forRun) _run ??= await _client!.map(M.runsGet, {'id': runId});
    return _client!;
  }

  String _taskId() => _run!['taskId'] as String;
  String _agentId() => _run!['agentId'] as String;

  /// What the run's agent may do (design P02 "Allowed to"); null for a person.
  Future<Set<String>?> _caps() async {
    if (!forRun) return null;
    final c = await _relay();
    final a = (await c.list(M.agentsList)).where((x) => x['id'] == _agentId()).firstOrNull;
    return a == null ? null : AgentProfile(a).caps;
  }

  /// An agent sees the tools its role allows.
  Future<List<Map<String, Object?>>> list() async {
    final allowed = await _caps();
    return [for (final t in _tools) if (allowed == null || _allowed(t['name'] as String, allowed)) t];
  }

  Future<String> call(String name, Map<String, Object?> a) async {
    if (!_tools.any((t) => t['name'] == name)) throw RpcError(RpcError.methodNotFound, 'No tool $name');
    final c = await _relay();
    final allowed = await _caps();
    if (allowed != null && !_allowed(name, allowed)) throw RpcError(RpcError.invalidParams, 'Your role may not use $name.');
    if (!forRun) {
      return switch (name) {
        'relay_projects' => await _projects(c),
        'relay_tasks' => await _tasks(c, a['project'] as String?, a['status'] as String?),
        'relay_create_task' => await _createTask(c, a),
        'relay_task_status' => await _taskStatus(c, a['task'] as String? ?? ''),
        'relay_update_task' => await _updateTask(c, a),
        _ => throw RpcError(RpcError.methodNotFound, 'No tool $name'),
      };
    }
    final (task, agent) = (_taskId(), _agentId());
    return switch (name) {
      'relay_task' => await _taskText(c, task),
      'relay_progress' => await _post(c, task, agent, a['text'] as String? ?? ''),
      'relay_ask' => await _ask(c, task, agent, a['question'] as String? ?? ''),
      'relay_message_agent' => await _message(c, task, agent, a['agent'] as String? ?? '', a['text'] as String? ?? ''),
      'relay_check' => await _check(c, task, int.tryParse('${a['index']}') ?? -1, '${a['done'] ?? true}' != 'false'),
      'relay_create_task' => await _agentTask(c, task, agent, a, allowed ?? AgentCap.defaults),
      'relay_post' => await _postChannel(c, task, agent, a),
      'relay_wait' => await _wait(c, agent, a),
      'relay_report' => await _report(c, task, agent, a),
      'relay_propose_plan' => await _proposePlan(c, task, agent, a),
      'relay_team' => await _team(c, agent),
      _ => throw RpcError(RpcError.methodNotFound, 'No tool $name'),
    };
  }

  Future<void> close() async => _client?.close();
}

/// Tools for an agent Relay started, about its own task.
final _runTools = <Map<String, Object?>>[
  _tool('relay_task', 'Read your Relay task: title, brief, "done when" checklist, discussion and repos.', {}),
  _tool('relay_progress', 'Post a short progress note on the task for your team.', {'text': _str('The note')}, required: ['text']),
  _tool('relay_ask', 'Ask the people on this task a question. They answer in the task thread; their reply reaches you.',
      {'question': _str('The question')}, required: ['question']),
  _tool('relay_message_agent',
      'Message another agent, by id, name or role ("Bram", "QA", "backend"). It arrives now if that agent is working, '
          'else at its next run; an idle agent is woken to reply. Use relay_wait to wait for the answer.',
      {'agent': _str('Who: id, name or role'), 'text': _str('The message')}, required: ['agent', 'text']),
  _tool('relay_check', 'Tick (or untick) an item of the task\'s "done when" checklist.',
      {'index': _int('Zero-based item number'), 'done': _bool('true or false')}, required: ['index']),
  _tool(
    'relay_create_task',
    'Create a task in this project. Without assignee or queue it is a follow-up in Backlog after this task. '
        'With assignee (id, name or role) and queue: true it goes to that agent; after lists task keys it waits for.',
    {
      'title': _str('Title'),
      'brief': _str('What needs doing, enough for an agent to start'),
      'doneWhen': _list('Checks that say when it is done'),
      'assignee': _str('Who does it: id, name or role'),
      'after': _list('Task keys it waits for, e.g. KT-12'),
      'queue': _bool('true to start it when its agent is free'),
    },
    required: ['title'],
  ),
  _tool('relay_post', 'Post in a team channel (the project\'s channel unless you name one), e.g. a status update or a nightly report.',
      {'text': _str('The message'), 'channel': _str('Channel name, optional')}, required: ['text']),
  _tool('relay_wait', 'Wait for a reply to your message, or for a task to finish. Returns what arrived, or that it timed out.',
      {'for': _str('reply or task'), 'task': _str('For task: its key, e.g. KT-12'), 'minutes': _int('How long to wait, at most 10 (default 5)')}),
  _tool('relay_report', 'Report a check of this task: tests or a review. A failure sends the task back to whoever built it.',
      {'kind': _str('test or review'), 'passed': _int('How many passed'), 'failed': _int('How many failed'), 'details': _str('What failed and where')},
      required: ['passed', 'failed']),
  _tool(
    'relay_propose_plan',
    'Propose a plan as tasks for your team. They wait for the person\'s OK (unless the team skips that), then start in order.',
    {
      'summary': _str('One or two sentences: the approach'),
      'tasks': {
        'type': 'array',
        'description': 'The tasks, in order',
        'items': {
          'type': 'object',
          'properties': {
            'title': _str('Title'),
            'brief': _str('What needs doing'),
            'doneWhen': _list('Checks'),
            'assignee': _str('Who: id, name or role'),
            'after': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'Zero-based numbers of earlier tasks in this plan it waits for'},
          },
          'required': ['title'],
        },
      },
    },
    required: ['tasks'],
  ),
  _tool('relay_team', 'Your team: who is on it, their roles and what each is doing now, and what you may do.', {}),
];

/// Which capability a run tool needs (none: every agent has it).
bool _allowed(String tool, Set<String> caps) => switch (tool) {
  'relay_message_agent' || 'relay_wait' => caps.contains(AgentCap.message),
  'relay_create_task' => caps.contains(AgentCap.createTasks),
  'relay_post' => caps.contains(AgentCap.postChannel),
  'relay_propose_plan' => caps.contains(AgentCap.assign),
  _ => true,
};

/// Tools for a person's own agent session, across projects.
final _personTools = <Map<String, Object?>>[
  _tool('relay_projects', 'List Relay projects with their keys and repos, and the agents that can take tasks.', {}),
  _tool('relay_tasks', 'List the tasks of a Relay project: key (e.g. GA-3), status and title.', {
    'project': _str('Project key, e.g. GA. Optional when there is one project.'),
    'status': _str('Only tasks with this status: backlog, queued, running, review or done.'),
  }),
  _tool(
    'relay_create_task',
    'Create a task in Relay. It lands in Backlog, or in the queue for an agent to pick up with queue: true. '
        'Call relay_projects first for project keys, repo names and agent ids.',
    {
      'project': _str('Project key, e.g. GA. Optional when there is one project.'),
      'title': _str('Short title'),
      'brief': _str('What needs doing, with enough context for an agent to start'),
      'doneWhen': _list('Checklist items that say when the task is done'),
      'repos': _list('Names of the repos the task changes. Left out: Relay suggests them from the title and brief.'),
      'agent': _str('Agent id to assign (e.g. claude-code, codex), or "auto" to let Relay route it'),
      'queue': _bool('true to queue it now instead of leaving it in Backlog'),
    },
    required: ['title'],
  ),
  _tool('relay_task_status', 'Check on a Relay task: status, latest run, checklist, open question and discussion.',
      {'task': _str('Task key, e.g. GA-3')}, required: ['task']),
  _tool(
    'relay_update_task',
    'Update a Relay task you are working on yourself: move it (backlog, running, review, done), tick "done when" '
        'items, add items, or post a note in its discussion. Use running for "I am on it"; queued hands it to Relay\'s agents.',
    {
      'task': _str('Task key, e.g. GA-3'),
      'status': _str('New status: backlog, queued, running, review or done'),
      'check': _list('Zero-based "done when" item numbers to tick, or "all"'),
      'uncheck': _list('Zero-based "done when" item numbers to untick'),
      'addDoneWhen': _list('New "done when" items to add'),
      'note': _str('A note for the task discussion'),
      'from': _str('Who the note is from, e.g. "Claude Code". Defaults to Claude Code.'),
    },
    required: ['task'],
  ),
];

Map<String, Object?> _tool(String name, String description, Map<String, Map<String, Object?>> props, {List<String> required = const []}) => {
  'name': name,
  'description': description,
  'inputSchema': {'type': 'object', 'properties': props, 'required': required},
};

Map<String, Object?> _str(String d) => {'type': 'string', 'description': d};
Map<String, Object?> _int(String d) => {'type': 'integer', 'description': d};
Map<String, Object?> _bool(String d) => {'type': 'boolean', 'description': d};
Map<String, Object?> _list(String d) => {'type': 'array', 'items': {'type': 'string'}, 'description': d};

/// A list argument; models sometimes send "a, b" for ["a", "b"].
List<String> _strings(Object? v) => switch (v) {
  List() => [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()],
  String() => [for (final e in v.split(',')) if (e.trim().isNotEmpty) e.trim()],
  _ => const [],
};

// ------------------------------------------------------------------ person

Future<String> _projects(RelayClient c) async {
  final projects = await c.list(M.projectsList);
  if (projects.isEmpty) return 'No projects yet. Create one in Relay (or with `relay project add`).';
  final repos = await c.list(M.reposList);
  final b = StringBuffer();
  for (final p in projects) {
    b.writeln('${p['key']} · ${p['name']}');
    final mine = repos.where((r) => r['projectId'] == p['id']).toList();
    b.writeln(mine.isEmpty
        ? '  repos: none yet'
        : '  repos: ${mine.map((r) => '${r['name']}${(r['stack'] as String? ?? '').isEmpty ? '' : ' (${r['stack']})'}').join(', ')}');
  }
  final agents = (await c.list(M.agentsList)).where((a) => a['enabled'] != false && a['binaryPath'] != null).toList();
  b.writeln();
  b.writeln(agents.isEmpty ? 'No agents found on this computer.' : 'Agents: ${agents.map((a) => '${a['id']} (${a['name']})').join(', ')}');
  return b.toString();
}

Future<Map<String, Object?>> _project(RelayClient c, String? key) async {
  final projects = await c.list(M.projectsList);
  String keys() => projects.map((p) => p['key']).join(', ');
  if (projects.isEmpty) throw RpcError(RpcError.notFound, 'No projects yet. Create one in Relay first.');
  if (key == null || key.trim().isEmpty) {
    if (projects.length == 1) return projects.single;
    throw RpcError(RpcError.invalidParams, 'Which project? Pass project: one of ${keys()}.');
  }
  return projects.firstWhere(
    (p) => (p['key'] as String).toLowerCase() == key.trim().toLowerCase(),
    orElse: () => throw RpcError(RpcError.notFound, 'No project $key. Projects: ${keys()}.'),
  );
}

Future<String> _tasks(RelayClient c, String? key, String? status) async {
  final project = await _project(c, key);
  final tasks = (await c.list(M.tasksList, {'projectId': project['id']}))
      .where((t) => t['ask'] == null) // questions asked in channels
      .where((t) => status == null || status.isEmpty || t['status'] == status)
      .toList()
    ..sort((a, b) => (a['number'] as num).compareTo(b['number'] as num));
  if (tasks.isEmpty) return 'No ${status == null || status.isEmpty ? '' : '$status '}tasks in ${project['key']}.';
  return [
    for (final t in tasks)
      '${project['key']}-${t['number']}  ${t['status']}${t['attention'] == null ? '' : ' (${t['attention']})'}  ${t['title']}',
  ].join('\n');
}

Future<String> _createTask(RelayClient c, Map<String, Object?> a) async {
  final title = (a['title'] as String? ?? '').trim();
  if (title.isEmpty) throw RpcError(RpcError.invalidParams, 'A task needs a title.');
  final brief = (a['brief'] as String? ?? '').trim();
  final project = await _project(c, a['project'] as String?);
  final repos = await c.list(M.reposList, {'projectId': project['id']});
  final names = _strings(a['repos']);
  final repoIds = <Object?>[];
  for (final n in names) {
    final r = repos.where((r) => (r['name'] as String).toLowerCase() == n.toLowerCase()).firstOrNull;
    if (r == null) throw RpcError(RpcError.invalidParams, 'No repo $n in ${project['key']}. Repos: ${repos.map((r) => r['name']).join(', ')}.');
    repoIds.add(r['id']);
  }
  if (repoIds.isEmpty && repos.isNotEmpty) {
    final suggested = await c.list(M.tasksSuggestRepos, {'projectId': project['id'], 'text': '$title\n$brief', 'repoIds': <String>[]});
    repoIds.addAll(suggested.map((s) => s['repoId']));
  }
  final agent = (a['agent'] as String?)?.trim();
  if (agent != null && agent.isNotEmpty && agent != 'auto') {
    final agents = await c.list(M.agentsList);
    if (!agents.any((x) => x['id'] == agent)) {
      throw RpcError(RpcError.invalidParams, 'No agent $agent. Agents: ${agents.map((x) => x['id']).join(', ')}.');
    }
  }
  final queue = a['queue'] == true || a['queue'] == 'true';
  final t = await c.map(M.tasksCreate, {
    'projectId': project['id'],
    'fields': {
      'title': title,
      'brief': brief,
      'doneWhen': [for (final d in _strings(a['doneWhen'])) {'text': d, 'done': false}],
      if (agent != null && agent.isNotEmpty) ...{'assigneeKind': 'agent', 'assignee': agent},
      'repoIds': repoIds,
      'status': queue ? 'queued' : 'backlog',
    },
  });
  final repoNames = [for (final r in repos) if (repoIds.contains(r['id'])) r['name']];
  return 'Created ${project['key']}-${t['number']} · $title, in ${queue ? 'the queue' : 'Backlog'}'
      '${agent == null || agent.isEmpty ? '' : ', for $agent'}'
      '${repoNames.isEmpty ? '' : ', changing ${repoNames.join(', ')}'}.';
}

/// The project and task for a key like GA-3.
Future<(Map<String, Object?>, Map<String, Object?>)> _byKey(RelayClient c, String key) async {
  final m = RegExp(r'^\s*([A-Za-z0-9]+)-(\d+)\s*$').firstMatch(key);
  if (m == null) throw RpcError(RpcError.invalidParams, 'Pass a task key like GA-3.');
  final project = await _project(c, m.group(1));
  final number = int.parse(m.group(2)!);
  final task = (await c.list(M.tasksList, {'projectId': project['id']})).where((t) => t['number'] == number).firstOrNull;
  if (task == null) throw RpcError(RpcError.notFound, 'No task $key.');
  return (project, task);
}

Future<String> _updateTask(RelayClient c, Map<String, Object?> a) async {
  final (project, task) = await _byKey(c, a['task'] as String? ?? '');
  final key = '${project['key']}-${task['number']}';
  final id = task['id'] as String;
  final done = [...?(task['doneWhen'] as List?)].map((e) => Map<String, Object?>.of((e as Map).cast())).toList();
  final said = <String>[];
  int index(String v) {
    final i = int.tryParse(v) ?? -1;
    if (i < 0 || i >= done.length) throw RpcError(RpcError.invalidParams, 'No "done when" item $v on $key (there are ${done.length}).');
    return i;
  }

  var changed = false;
  final check = a['check'] == 'all' ? [for (var i = 0; i < done.length; i++) '$i'] : _strings(a['check']);
  for (final v in check) {
    done[index(v)]['done'] = true;
    changed = true;
  }
  for (final v in _strings(a['uncheck'])) {
    done[index(v)]['done'] = false;
    changed = true;
  }
  for (final text in _strings(a['addDoneWhen'])) {
    done.add({'text': text, 'done': false});
    changed = true;
  }
  if (changed) {
    await c.call(M.tasksUpdate, {'id': id, 'fields': {'doneWhen': done}});
    said.add('checklist ${done.where((d) => d['done'] == true).length}/${done.length}');
  }
  final note = (a['note'] as String? ?? '').trim();
  if (note.isNotEmpty) {
    final from = (a['from'] as String? ?? '').trim();
    await c.call(M.commentsPost, {'taskId': id, 'body': note, 'authorKind': 'agent', 'author': from.isEmpty ? 'Claude Code' : from});
    said.add('note posted');
  }
  final status = (a['status'] as String? ?? '').trim().toLowerCase();
  if (status.isNotEmpty) {
    if (!TaskStatus.columns.contains(status)) {
      throw RpcError(RpcError.invalidParams, 'Status must be one of ${TaskStatus.columns.join(', ')}.');
    }
    await c.call(M.tasksMove, {'id': id, 'status': status});
    said.add('moved to $status');
  }
  if (said.isEmpty) return 'Nothing to change on $key. Pass status, check, uncheck, addDoneWhen or note.';
  return '$key: ${said.join(', ')}.';
}

Future<String> _taskStatus(RelayClient c, String key) async {
  final (project, task) = await _byKey(c, key);
  final number = task['number'];
  final detail = await c.map(M.tasksGet, {'id': task['id']});
  final b = StringBuffer('${project['key']}-$number · status: ${task['status']}');
  if (task['attention'] != null) b.write(' (${task['attention']})');
  if (task['assigneeKind'] == 'agent' || task['assigneeKind'] == 'person') b.write(' · assigned to ${task['assignee']}');
  b.writeln();
  if (task['question'] != null && task['attention'] == 'question') b.writeln('Open question: ${task['question']}');
  if (task['lastError'] != null) b.writeln('Last error: ${task['lastError']}');
  final runs = ((detail['runs'] as List?) ?? const []).cast<Map>();
  if (runs.isNotEmpty) {
    final r = runs.last;
    b.write('Latest run: ${r['agentId']}, ${r['status']}');
    if (r['currentStep'] != null && r['status'] == 'running') b.write(', now: ${r['currentStep']}');
    if (r['summary'] != null) b.write('. Summary: ${r['summary']}');
    if (r['error'] != null) b.write('. Error: ${r['error']}');
    b.writeln();
  }
  b.writeln();
  b.write(await _taskText(c, task['id'] as String));
  return b.toString();
}

// ------------------------------------------------------------------ run

Future<String> _taskText(RelayClient c, String taskId) async {
  final t = await c.map(M.tasksGet, {'id': taskId});
  final task = (t['task'] as Map).cast<String, Object?>();
  final b = StringBuffer('# ${task['title']}\n\n${task['brief'] ?? ''}\n');
  final done = (task['doneWhen'] as List?) ?? const [];
  if (done.isNotEmpty) {
    b.writeln('\nDone when:');
    for (var i = 0; i < done.length; i++) {
      final d = done[i] as Map;
      b.writeln('$i. [${d['done'] == true ? 'x' : ' '}] ${d['text']}');
    }
  }
  final comments = (t['comments'] as List?) ?? const [];
  if (comments.isNotEmpty) {
    b.writeln('\nDiscussion:');
    for (final c in comments) {
      b.writeln('- ${(c as Map)['author']}: ${c['body']}');
    }
  }
  final changes = (t['changes'] as List?) ?? const [];
  if (changes.isNotEmpty) b.writeln('\nWorkspace: ${t['workspace']}');
  return b.toString();
}

Future<String> _post(RelayClient c, String taskId, String agentId, String text) async {
  await c.call(M.commentsPost, {'taskId': taskId, 'body': text, 'authorKind': 'agent', 'author': await _agentName(c, agentId)});
  return 'Posted.';
}

Future<String> _ask(RelayClient c, String taskId, String agentId, String q) async {
  // On a team, the PM answers first; it asks the person if it must.
  final agents = await c.list(M.agentsList);
  final me = agents.where((a) => a['id'] == agentId).map(AgentProfile.new).firstOrNull;
  final pm = me?.teamId == null || me!.can(AgentCap.assign)
      ? null
      : agents.map(AgentProfile.new).where((a) => a.teamId == me.teamId && a.id != me.id && a.can(AgentCap.assign) && a.enabled).firstOrNull;
  if (pm != null) {
    final r = await c.call<String>(M.agentsMessage, {'taskId': taskId, 'from': agentId, 'to': pm.id, 'text': 'Question: $q'});
    return 'Asked ${pm.name}, your PM. $r Keep working on what doesn\'t depend on the answer; relay_wait waits for it.';
  }
  await c.call(M.commentsPost, {'taskId': taskId, 'body': q, 'authorKind': 'agent', 'author': await _agentName(c, agentId), 'question': true});
  await c.call(M.tasksUpdate, {'id': taskId, 'fields': {'attention': 'question', 'question': q}});
  return 'Asked. Keep working on anything that does not depend on the answer; the reply will reach you as a message.';
}

Future<String> _message(RelayClient c, String taskId, String from, String to, String text) async =>
    await c.call<String>(M.agentsMessage, {'taskId': taskId, 'from': from, 'to': to, 'text': text});

Future<String> _check(RelayClient c, String taskId, int index, bool done) async {
  final t = (await c.map(M.tasksGet, {'id': taskId}))['task'] as Map;
  final items = ((t['doneWhen'] as List?) ?? const []).map((e) => Map<String, Object?>.of((e as Map).cast())).toList();
  if (index < 0 || index >= items.length) return 'No item $index (there are ${items.length}).';
  items[index]['done'] = done;
  await c.call(M.tasksUpdate, {'id': taskId, 'fields': {'doneWhen': items}});
  return 'Updated item $index.';
}

Future<String> _createFollowUp(RelayClient c, String taskId, String agentId, String title, String brief) async {
  final created = await c.map(M.agentsCreateTask, {
    'agentId': agentId,
    'fromTask': taskId,
    'fields': {'title': title, 'brief': brief, 'dependsOn': [taskId]},
  });
  return 'Created task #${created['number']}.';
}

Future<String> _agentName(RelayClient c, String agentId) async {
  final agents = await c.list(M.agentsList);
  return agents.firstWhere((a) => a['id'] == agentId, orElse: () => {'name': agentId})['name'] as String;
}

/// A key like KT-12 to its task id.
Future<String> _idOf(RelayClient c, String key) async => (await _byKey(c, key)).$2['id'] as String;

Future<String> _agentTask(RelayClient c, String taskId, String agentId, Map<String, Object?> a, Set<String> caps) async {
  final title = (a['title'] as String? ?? '').trim();
  if (title.isEmpty) throw RpcError(RpcError.invalidParams, 'A task needs a title.');
  final who = (a['assignee'] as String? ?? '').trim();
  final queue = a['queue'] == true || a['queue'] == 'true';
  final after = _strings(a['after']);
  // The plain form: a follow-up in Backlog, after this task.
  if (who.isEmpty && !queue && after.isEmpty) return _createFollowUp(c, taskId, agentId, title, a['brief'] as String? ?? '');
  String? assignee;
  if (who.isNotEmpty) {
    final agents = (await c.list(M.agentsList)).map(AgentProfile.new).toList();
    final w = who.toLowerCase();
    final found = agents.where((x) => x.id == w || x.name.toLowerCase() == w || x.role.toLowerCase().contains(w)).firstOrNull;
    if (found == null) throw RpcError(RpcError.notFound, 'No agent "$who". relay_team lists your team.');
    if (found.id != agentId && !caps.contains(AgentCap.assign)) {
      throw RpcError(RpcError.invalidParams, 'Your role may not assign work to others. Message your PM instead.');
    }
    assignee = found.id;
  }
  final t = await c.map(M.agentsCreateTask, {
    'agentId': agentId,
    'fromTask': taskId,
    'fields': {
      'title': title,
      'brief': (a['brief'] as String? ?? '').trim(),
      'doneWhen': [for (final d in _strings(a['doneWhen'])) {'text': d, 'done': false}],
      if (assignee != null) ...{'assigneeKind': 'agent', 'assignee': assignee},
      'dependsOn': [for (final k in after) await _idOf(c, k)],
      'status': queue && assignee != null ? TaskStatus.queued : TaskStatus.backlog,
    },
  });
  final project = (await c.list(M.projectsList)).firstWhere((p) => p['id'] == t['projectId']);
  return 'Created ${project['key']}-${t['number']}${assignee == null ? '' : ' for $assignee'}, ${t['status'] == TaskStatus.queued ? 'queued' : 'in Backlog'}.';
}

Future<String> _postChannel(RelayClient c, String taskId, String agentId, Map<String, Object?> a) async {
  final text = (a['text'] as String? ?? '').trim();
  if (text.isEmpty) throw RpcError(RpcError.invalidParams, 'Write something.');
  final t = (await c.map(M.tasksGet, {'id': taskId}))['task'] as Map;
  final channels = await c.list(M.channelsList);
  final name = (a['channel'] as String? ?? '').trim().replaceFirst('#', '');
  final ch = name.isEmpty
      ? channels.where((x) => x['projectId'] == t['projectId']).firstOrNull
      : channels.where((x) => x['name'] == name).firstOrNull;
  if (ch == null) throw RpcError(RpcError.notFound, name.isEmpty ? 'This project has no channel.' : 'No channel #$name.');
  await c.call(M.agentsPost, {'agentId': agentId, 'channelId': ch['id'], 'text': text, 'taskId': taskId});
  return 'Posted in #${ch['name']}.';
}

/// Waits for mail to this agent, or for a task to be done or in review.
Future<String> _wait(RelayClient c, String agentId, Map<String, Object?> a) async {
  final minutes = (int.tryParse('${a['minutes'] ?? 5}') ?? 5).clamp(1, 10);
  final end = DateTime.now().add(Duration(minutes: minutes));
  final since = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
  final forTask = a['for'] == 'task';
  final key = (a['task'] as String? ?? '').trim();
  if (forTask && key.isEmpty) throw RpcError(RpcError.invalidParams, 'Which task? Pass task, e.g. KT-12.');
  final id = forTask ? await _idOf(c, key) : null;
  while (DateTime.now().isBefore(end)) {
    if (forTask) {
      final t = (await c.map(M.tasksGet, {'id': id}))['task'] as Map;
      if (t['status'] == TaskStatus.done || t['status'] == TaskStatus.review) return '$key is ${t['status']}.';
    } else {
      final mail = await c.list(M.agentsMail, {'agentId': agentId, 'since': since.toIso8601String()});
      if (mail.isNotEmpty) return [for (final m in mail) '${m['author']}: ${m['body']}'].join('\n');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return 'Nothing yet after $minutes minutes. Carry on; it will reach you as a message.';
}

Future<String> _report(RelayClient c, String taskId, String agentId, Map<String, Object?> a) async {
  final failed = int.tryParse('${a['failed'] ?? 0}') ?? 0;
  final passed = int.tryParse('${a['passed'] ?? 0}') ?? 0;
  await c.call(M.agentsReport, {'taskId': taskId, 'agentId': agentId, 'kind': a['kind'] ?? 'test', 'passed': passed, 'failed': failed, 'details': a['details'] ?? ''});
  return failed > 0
      ? 'Reported $failed failing. When you finish, the task goes back to whoever built it with your report.'
      : 'Reported all $passed passing. When you finish, the task goes on for review.';
}

Future<String> _proposePlan(RelayClient c, String taskId, String agentId, Map<String, Object?> a) async {
  final tasks = (a['tasks'] as List?)?.map((e) => (e as Map).cast<String, Object?>()).toList() ?? const [];
  final r = await c.map(M.plansPropose, {'agentId': agentId, 'fromTask': taskId, 'summary': a['summary'] ?? '', 'tasks': tasks});
  return r['approved'] == true
      ? 'Your team starts plans on its own: ${r['tasks']} tasks are queued.'
      : 'Proposed ${r['tasks']} tasks; they start when the person approves the plan in the channel. Finish your run now.';
}

Future<String> _team(RelayClient c, String agentId) async {
  final agents = (await c.list(M.agentsList)).map(AgentProfile.new).toList();
  final me = agents.where((a) => a.id == agentId).firstOrNull;
  if (me == null) return 'Unknown agent.';
  final runs = await c.list(M.runsList);
  final teamId = me.teamId;
  final mates = teamId == null ? <AgentProfile>[] : agents.where((a) => a.teamId == teamId).toList();
  final b = StringBuffer();
  if (mates.isEmpty) {
    b.writeln('You are not on a team. Other agents: ${agents.where((a) => a.id != agentId && a.binaryPath != null).map((a) => a.id).join(', ')}.');
  } else {
    for (final a in mates) {
      final busy = runs.where((r) => r['agentId'] == a.id && RunStatus.isActive('${r['status']}')).length;
      b.writeln('- ${a.name} (id ${a.id})${a.role.isEmpty ? '' : ', ${a.role}'}${a.id == agentId ? ' (you)' : ''}: ${busy == 0 ? 'idle' : 'working'}');
    }
  }
  b.writeln('You may: ${me.caps.map(AgentCap.label).join(', ')}.');
  return b.toString();
}
