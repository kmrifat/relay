import 'dart:async';
import 'dart:io';

import 'package:relay_protocol/relay_protocol.dart';

/// `relay mcp --run <id>`: an MCP server (stdio) that agents use to talk to
/// Relay about the task they're working on. Each tool call goes to relayd.
Future<int> runMcpServer(String runId, RelayPaths paths) async {
  final peer = RpcPeer(stdin, stdout, name: 'mcp');
  RelayClient? client;
  Map<String, Object?>? run;

  Future<RelayClient> relay() async {
    client ??= await RelayClient.connect(paths, client: 'mcp');
    run ??= await client!.map(M.runsGet, {'id': runId});
    return client!;
  }

  String taskId() => run!['taskId'] as String;
  String agentId() => run!['agentId'] as String;

  final tools = <Map<String, Object?>>[
    _tool('relay_task', 'Read your Relay task: title, brief, "done when" checklist, discussion and repos.', {}),
    _tool('relay_progress', 'Post a short progress note on the task for your team.', {'text': 'The note'}, required: ['text']),
    _tool('relay_ask', 'Ask the people on this task a question. They answer in the task thread; their reply reaches you.',
        {'question': 'The question'}, required: ['question']),
    _tool('relay_message_agent', 'Send a message to another agent working on this task (e.g. "codex" or "claude-code").',
        {'agent': 'Agent id', 'text': 'The message'}, required: ['agent', 'text']),
    _tool('relay_check', 'Tick (or untick) an item of the task\'s "done when" checklist.',
        {'index': 'Zero-based item number', 'done': 'true or false'}, required: ['index']),
    _tool('relay_create_task', 'Create a follow-up task in the same project (lands in Backlog).',
        {'title': 'Title', 'brief': 'What needs doing'}, required: ['title']),
  ];

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
      final c = await relay();
      final text = switch (name) {
        'relay_task' => await _taskText(c, taskId()),
        'relay_progress' => await _post(c, taskId(), agentId(), a['text'] as String? ?? ''),
        'relay_ask' => await _ask(c, taskId(), agentId(), a['question'] as String? ?? ''),
        'relay_message_agent' => await _message(c, taskId(), agentId(), a['agent'] as String? ?? '', a['text'] as String? ?? ''),
        'relay_check' => await _check(c, taskId(), int.tryParse('${a['index']}') ?? -1, '${a['done'] ?? true}' != 'false'),
        'relay_create_task' => await _createTask(c, taskId(), a['title'] as String? ?? '', a['brief'] as String? ?? ''),
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
          {'type': 'text', 'text': 'Relay error: $e'},
        ],
        'isError': true,
      };
    }
  });
  await peer.done;
  await client?.close();
  return 0;
}

Map<String, Object?> _tool(String name, String description, Map<String, String> props, {List<String> required = const []}) => {
  'name': name,
  'description': description,
  'inputSchema': {
    'type': 'object',
    'properties': {for (final e in props.entries) e.key: {'type': e.key == 'index' ? 'integer' : (e.key == 'done' ? 'boolean' : 'string'), 'description': e.value}},
    'required': required,
  },
};

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

Future<String> _createTask(RelayClient c, String taskId, String title, String brief) async {
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
