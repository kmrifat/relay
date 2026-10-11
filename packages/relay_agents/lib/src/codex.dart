import 'dart:convert';

import 'adapter.dart';
import 'launch.dart';
import 'process_session.dart';

/// OpenAI Codex CLI in non-interactive mode with JSON Lines output:
///
///   `codex exec --json --sandbox workspace-write [--model m] PROMPT`
///
/// Events are `thread.started`, `turn.started`, `item.started`,
/// `item.completed` (agent_message, reasoning, command_execution,
/// file_change, mcp_tool_call, web_search), `turn.completed` (usage),
/// `turn.failed` and `error`. The shape is checked by transcript tests;
/// re-verify with each Codex release (it is not installed on the dev Mac).
class CodexAdapter extends AgentAdapter {
  @override
  String get id => 'codex';
  @override
  String get name => 'Codex';
  @override
  List<String> get binaries => const ['codex'];
  @override
  String get color => '#5A5A5E';
  @override
  String get letter => 'X';
  @override
  List<String> get goodAt => const ['code review', 'bug fixes'];

  static List<String> argsFor(RunSpec spec) => [
    'exec',
    if (spec.resumeSessionId != null) ...['resume', spec.resumeSessionId!],
    '--json',
    '--skip-git-repo-check',
    '--sandbox',
    spec.autoApprove ? 'danger-full-access' : 'workspace-write',
    if (spec.model != null) ...['--model', spec.model!],
    ...spec.extraArgs,
    spec.prompt,
  ];

  @override
  Future<AgentSession> start(RunSpec spec) async {
    final process = await Launch.start(
      spec.binary ?? 'codex',
      argsFor(spec),
      workingDirectory: spec.cwd,
      environment: spec.environment,
    );
    await process.stdin.close();
    return CodexSession(process);
  }
}

class CodexSession extends ProcessSession {
  CodexSession(super.process);

  String? _thread;
  bool _sawEnd = false;

  @override
  String? get sessionId => _thread;

  @override
  bool get canSteer => false;

  @override
  void steer(String text) {}

  @override
  void answerPermission(String requestId, String answer, {String? message}) {}

  @override
  void onLine(String line) {
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(line) as Map).cast();
    } catch (_) {
      emit('output', {'text': line});
      return;
    }
    final item = (j['item'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    switch (j['type']) {
      case 'thread.started':
        _thread = j['thread_id'] as String?;
        emit('status', {'status': 'running', 'sessionId': _thread, 'detail': 'Started'});
      case 'item.started':
        if (item['type'] == 'command_execution') {
          emit('tool_use', {
            'id': item['id'],
            'tool': 'Bash',
            'summary': summarizeTool('Bash', {'command': item['command']}),
            'input': {'command': item['command']},
          });
        }
      case 'item.completed':
        switch (item['type']) {
          case 'agent_message':
            final text = (item['text'] as String? ?? '').trim();
            if (text.isNotEmpty) emit('message', {'text': text});
          case 'command_execution':
            final out = (item['aggregated_output'] as String? ?? '').trim().split('\n').take(2).join(' · ');
            emit('tool_result', {
              'id': item['id'],
              'ok': (item['exit_code'] as num?)?.toInt() == 0,
              'summary': out.length > 160 ? '${out.substring(0, 157)}…' : out,
            });
          case 'file_change':
            final changes = ((item['changes'] as List?) ?? const []).whereType<Map>().toList();
            final paths = changes.map((c) => c['path']).join(', ');
            emit('tool_use', {'id': item['id'], 'tool': 'Edit', 'summary': paths, 'input': {'changes': changes}});
            emit('tool_result', {'id': item['id'], 'ok': item['status'] != 'failed', 'summary': '${changes.length} file(s)'});
          case 'mcp_tool_call':
            emit('tool_use', {'id': item['id'], 'tool': '${item['server']}.${item['tool']}', 'summary': '', 'input': const {}});
          case 'web_search':
            emit('tool_use', {'id': item['id'], 'tool': 'WebSearch', 'summary': item['query'] ?? '', 'input': const {}});
          case 'error':
            emit('error', {'text': item['message'] ?? 'Codex error'});
        }
      case 'turn.completed':
        _sawEnd = true;
        final u = (j['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        emit('usage', {
          'tokensIn': ((u['input_tokens'] as num?)?.toInt() ?? 0) + ((u['cached_input_tokens'] as num?)?.toInt() ?? 0),
          'tokensOut': (u['output_tokens'] as num?)?.toInt() ?? 0,
        });
        emit('status', {'status': 'turn_done'});
      case 'turn.failed':
        _sawEnd = true;
        final msg = ((j['error'] as Map?)?['message'] as String?) ?? 'Turn failed';
        emit('status', {'status': 'failed', 'detail': msg, 'limitedUntil': ?parseLimitReset(msg)?.toIso8601String()});
      case 'error':
        final msg = j['message'] as String? ?? 'Codex error';
        emit('error', {'text': msg});
    }
  }

  @override
  void onExit(int code) {
    if (!_sawEnd && !stopping) {
      final err = stderrText.trim();
      emit('status', {'status': code == 0 ? 'turn_done' : 'failed', 'detail': err.isEmpty ? 'Codex exited with $code' : err});
    }
  }
}
