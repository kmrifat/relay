import 'dart:async';
import 'dart:io';

import 'package:relay_protocol/relay_protocol.dart';

/// `relay mcp`: an MCP server (stdio) that talks to relayd.
///
/// With `--run <id>`, which is how Relay starts its agents, the tools are
/// about that run's task. Without one (a person's own Claude Code, after
/// `claude mcp add relay -- relay mcp`) they work across projects: list
/// projects and tasks, create a task, check on one.
Future<int> runMcpServer(String? runId, RelayPaths paths) async {
  final peer = RpcPeer(stdin, stdout, name: 'mcp');
  final forRun = runId != null && runId.isNotEmpty;
  final tools = forRun ? _runTools : _personTools;
  RelayClient? client;
  Map<String, Object?>? run;

  Future<RelayClient> relay() async {
    client ??= await RelayClient.connect(paths, client: 'mcp');
    if (forRun) run ??= await client!.map(M.runsGet, {'id': runId});
    return client!;
  }

  String taskId() => run!['taskId'] as String;
  String agentId() => run!['agentId'] as String;

  peer.registerMethod('initialize', (p) => {
    'protocolVersion': p['protocolVersion'] ?? '2025-06-18',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'relay', 'version': '0.1.0'},
  });
  peer.onNotification('notifications/initialized', (_) {});
  peer.registerMethod('ping', (_) => {});
  peer.registerMethod('tools/list', (_) => {'tools': tools});
  peer.registerMethod('tools/call', (p) async {
    final name = p['name'] as String? ?? '';
    final a = (p['arguments'] as Map?)?.cast<String, Object?>() ?? const {};
    try {
      if (!tools.any((t) => t['name'] == name)) throw RpcError(RpcError.methodNotFound, 'No tool $name');
      final c = await relay();
      final text = switch (name) {
        'relay_task' => await _taskText(c, taskId()),
        'relay_progress' => await _post(c, taskId(), agentId(), a['text'] as String? ?? ''),
        'relay_ask' => await _ask(c, taskId(), agentId(), a['question'] as String? ?? ''),
        'relay_message_agent' => await _message(c, taskId(), agentId(), a['agent'] as String? ?? '', a['text'] as String? ?? ''),
        'relay_check' => await _check(c, taskId(), int.tryParse('${a['index']}') ?? -1, '${a['done'] ?? true}' != 'false'),
        'relay_create_task' when forRun => await _createFollowUp(c, taskId(), a['title'] as String? ?? '', a['brief'] as String? ?? ''),
        'relay_projects' => await _projects(c),
        'relay_tasks' => await _tasks(c, a['project'] as String?, a['status'] as String?),
        'relay_create_task' => await _createTask(c, a),
        'relay_task_status' => await _taskStatus(c, a['task'] as String? ?? ''),
        _ => throw RpcError(RpcError.methodNotFound, 'No tool $name'),
      };
      return {
        'content': [
          {'type': 'text', 'text': text},
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
  await client?.close();
  return 0;
}

/// Tools for an agent Relay started, about its own task.
final _runTools = <Map<String, Object?>>[
  _tool('relay_task', 'Read your Relay task: title, brief, "done when" checklist, discussion and repos.', {}),
  _tool('relay_progress', 'Post a short progress note on the task for your team.', {'text': _str('The note')}, required: ['text']),
  _tool('relay_ask', 'Ask the people on this task a question. They answer in the task thread; their reply reaches you.',
      {'question': _str('The question')}, required: ['question']),
  _tool('relay_message_agent', 'Send a message to another agent working on this task (e.g. "codex" or "claude-code").',
      {'agent': _str('Agent id'), 'text': _str('The message')}, required: ['agent', 'text']),
  _tool('relay_check', 'Tick (or untick) an item of the task\'s "done when" checklist.',
      {'index': _int('Zero-based item number'), 'done': _bool('true or false')}, required: ['index']),
  _tool('relay_create_task', 'Create a follow-up task in the same project (lands in Backlog).',
      {'title': _str('Title'), 'brief': _str('What needs doing')}, required: ['title']),
];

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

Future<String> _taskStatus(RelayClient c, String key) async {
  final m = RegExp(r'^\s*([A-Za-z0-9]+)-(\d+)\s*$').firstMatch(key);
  if (m == null) throw RpcError(RpcError.invalidParams, 'Pass a task key like GA-3.');
  final project = await _project(c, m.group(1));
  final number = int.parse(m.group(2)!);
  final task = (await c.list(M.tasksList, {'projectId': project['id']})).where((t) => t['number'] == number).firstOrNull;
  if (task == null) throw RpcError(RpcError.notFound, 'No task $key.');
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
  await c.call(M.commentsPost, {'taskId': taskId, 'body': q, 'authorKind': 'agent', 'author': await _agentName(c, agentId), 'question': true});
  await c.call(M.tasksUpdate, {'id': taskId, 'fields': {'attention': 'question', 'question': q}});
  return 'Asked. Keep working on anything that does not depend on the answer; the reply will reach you as a message.';
}

Future<String> _message(RelayClient c, String taskId, String from, String to, String text) async {
  await c.call(M.agentsMessage, {'taskId': taskId, 'from': from, 'to': to, 'text': text});
  return 'Sent to $to.';
}

Future<String> _check(RelayClient c, String taskId, int index, bool done) async {
  final t = (await c.map(M.tasksGet, {'id': taskId}))['task'] as Map;
  final items = ((t['doneWhen'] as List?) ?? const []).map((e) => Map<String, Object?>.of((e as Map).cast())).toList();
  if (index < 0 || index >= items.length) return 'No item $index (there are ${items.length}).';
  items[index]['done'] = done;
  await c.call(M.tasksUpdate, {'id': taskId, 'fields': {'doneWhen': items}});
  return 'Updated item $index.';
}

Future<String> _createFollowUp(RelayClient c, String taskId, String title, String brief) async {
  final t = (await c.map(M.tasksGet, {'id': taskId}))['task'] as Map;
  final created = await c.map(M.tasksCreate, {
    'projectId': t['projectId'],
    'fields': {'title': title, 'brief': brief, 'tags': ['from-agent'], 'dependsOn': [taskId]},
  });
  return 'Created task #${created['number']}.';
}

Future<String> _agentName(RelayClient c, String agentId) async {
  final agents = await c.list(M.agentsList);
  return agents.firstWhere((a) => a['id'] == agentId, orElse: () => {'name': agentId})['name'] as String;
}
