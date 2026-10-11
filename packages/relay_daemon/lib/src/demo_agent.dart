import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// `relay demo-agent`: a stand-in agent that speaks Claude Code's
/// stream-json protocol, so Relay can be tried (and tested end to end)
/// without any AI account. It reads the workspace, asks permission once,
/// writes a small notes file per repo it may change, and answers steering.
///
/// It honours the Claude Code flags that change what it may do (like the
/// real CLI: without `--permission-prompt-tool` nobody is asked and writes
/// are denied; `--add-dir` makes PROJECT.md readable) and ignores the rest.
Future<int> runDemoAgent(List<String> args) async {
  final out = stdout;
  void emit(Map<String, Object?> j) => out.writeln(jsonEncode(j));
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
  final queue = StreamIterator(lines);
  final steering = <String>[];
  final bypass = args.contains('bypassPermissions');
  final hostAsks = args.contains('--permission-prompt-tool');
  final addDirs = [
    for (var i = 0; i + 1 < args.length; i++)
      if (args[i] == '--add-dir') args[i + 1],
  ];
  // `--disallowedTools Edit Write …`: a question, so it reads and answers.
  final i = args.indexOf('--disallowedTools');
  final readOnly = i >= 0 && args.skip(i + 1).takeWhile((a) => !a.startsWith('--')).contains('Write');
  final delay = Duration(milliseconds: int.tryParse(Platform.environment['RELAY_DEMO_DELAY_MS'] ?? '') ?? 600);

  Future<Map<String, Object?>?> next() async {
    if (!await queue.moveNext()) return null;
    try {
      return (jsonDecode(queue.current) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  final first = await next();
  if (first == null) return 0;
  final prompt = _text(first);
  final cwd = Directory.current.path;
  final session = 'demo-${DateTime.now().millisecondsSinceEpoch}';
  emit({'type': 'system', 'subtype': 'init', 'cwd': cwd, 'session_id': session, 'model': 'demo', 'tools': ['Read', 'Write', 'Bash']});
  await Future<void>.delayed(delay);

  final title = RegExp(r'^# (.+)$', multiLine: true).firstMatch(prompt)?.group(1) ?? 'the task';
  emit(_assistant([
    {'type': 'text', 'text': 'I\'ll look at the workspace for "$title" first.'},
    {'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'ls'}},
  ]));
  await Future<void>.delayed(delay);
  final entries = Directory(cwd).listSync().map((e) => p.basename(e.path)).where((n) => !n.startsWith('.')).toList()..sort();
  emit(_toolResult('t1', entries.join('\n')));
  await Future<void>.delayed(delay);

  // The repo map sits in the workspace around a single repo.
  for (final dir in addDirs) {
    final map = File(p.join(dir, 'PROJECT.md'));
    if (!map.existsSync()) continue;
    emit(_assistant([
      {'type': 'tool_use', 'id': 'r1', 'name': 'Read', 'input': {'file_path': map.path}},
    ]));
    emit(_toolResult('r1', map.readAsLinesSync().take(3).join('\n')));
    await Future<void>.delayed(delay);
  }

  if (readOnly) {
    final answer = 'From a look around: the workspace has ${entries.isEmpty ? 'nothing yet' : entries.join(', ')}. '
        'A real agent would answer "$title" from the code here.';
    emit(_assistant([
      {'type': 'text', 'text': answer},
    ]));
    emit(_result(session, answer));
    while (await next() != null) {}
    return 0;
  }

  // Repos it may change: subfolders that are git worktrees (not links), or cwd itself.
  final targets = <String>[];
  for (final e in Directory(cwd).listSync(followLinks: false)) {
    // Repos this task may change are writable worktrees; the rest are
    // read-only snapshots.
    if (e is Directory && File(p.join(e.path, '.git')).existsSync() && !File(p.join(e.path, '.relay-snapshot')).existsSync()) targets.add(e.path);
  }
  if (targets.isEmpty) targets.add(cwd);

  var turn = 1;
  for (final target in targets) {
    final rel = target == cwd ? 'RELAY_DEMO.md' : '${p.basename(target)}/RELAY_DEMO.md';
    final id = 'w$turn';
    final input = {'file_path': rel, 'content': '…'};
    emit(_assistant([
      {'type': 'tool_use', 'id': id, 'name': 'Write', 'input': input},
    ]));
    var allowed = true;
    if (!bypass && !hostAsks) {
      allowed = false;
    } else if (!bypass) {
      emit({
        'type': 'control_request',
        'request_id': 'perm-$id',
        'request': {'subtype': 'can_use_tool', 'tool_name': 'Write', 'input': input},
      });
      // Wait for the answer; collect steering messages that arrive meanwhile.
      while (true) {
        final msg = await next();
        if (msg == null) return 1;
        if (msg['type'] == 'control_response') {
          final resp = ((msg['response'] as Map?)?['response'] as Map?) ?? const {};
          allowed = resp['behavior'] == 'allow';
          break;
        }
        if (msg['type'] == 'user') steering.add(_text(msg));
      }
    }
    if (allowed) {
      File('$cwd/$rel').writeAsStringSync('# ${title.trim()}\n\nNotes from Relay\'s demo agent, '
          '${DateTime.now().toIso8601String()}.\n\nA real agent would change code here.\n');
      emit(_toolResult(id, 'Wrote $rel'));
    } else {
      emit(_toolResult(id, hostAsks ? 'The user denied this write.' : 'Claude requested permissions to use Write, but you haven\'t granted it yet.', error: true));
    }
    await Future<void>.delayed(delay);
    turn++;
  }

  // Answer steering received so far, then any that arrive before stdin closes.
  var results = 0;
  Future<void> reply(String text) async {
    emit(_assistant([
      {'type': 'text', 'text': 'Noted: "$text". I\'ve taken that into account.'},
    ]));
    await Future<void>.delayed(delay);
    emit(_result(session, 'Noted.'));
    results++;
  }

  emit(_assistant([
    {'type': 'text', 'text': 'Done. I wrote RELAY_DEMO.md in ${targets.length} repo(s) for "$title".'},
  ]));
  emit(_result(session, 'Done.'));
  results++;
  for (final s in steering) {
    await reply(s);
  }
  while (true) {
    final msg = await next();
    if (msg == null) break;
    if (msg['type'] == 'user') await reply(_text(msg));
  }
  return results > 0 ? 0 : 1;
}

String _text(Map<String, Object?> userMsg) {
  final content = (userMsg['message'] as Map?)?['content'];
  if (content is String) return content;
  if (content is List) return content.whereType<Map>().map((b) => b['text'] ?? '').join('\n');
  return '';
}

Map<String, Object?> _assistant(List<Map<String, Object?>> content) => {
  'type': 'assistant',
  'message': {'role': 'assistant', 'content': content, 'usage': {'input_tokens': 50, 'output_tokens': 20}},
};

Map<String, Object?> _toolResult(String id, String content, {bool error = false}) => {
  'type': 'user',
  'message': {
    'role': 'user',
    'content': [
      {'type': 'tool_result', 'tool_use_id': id, 'content': content, 'is_error': error},
    ],
  },
};

Map<String, Object?> _result(String session, String text) => {
  'type': 'result',
  'subtype': 'success',
  'is_error': false,
  'result': text,
  'session_id': session,
  'total_cost_usd': 0,
  'usage': {'input_tokens': 300, 'output_tokens': 80},
};
