import 'dart:convert';

import 'adapter.dart';
import 'launch.dart';
import 'process_session.dart';

/// Claude Code, driven in print mode with streaming JSON in and out.
///
///   claude -p --input-format stream-json --output-format stream-json --verbose
///
/// Prompts and steering messages go in as `{"type":"user",…}` lines.
/// Permission requests come out as `control_request` / `can_use_tool` and
/// are answered with a `control_response`. That takes
/// `--permission-prompt-tool stdio` as well as `--permission-prompts host`:
/// without it there is no host to ask, and anything that would prompt is
/// denied with "permissions not granted" (seen with 2.1.278).
///
/// Relay's own MCP tools are allowed up front, and the task workspace is
/// added with `--add-dir` when the agent starts inside one of its repos, so
/// PROJECT.md and the read-only snapshots are readable without asking.
/// Verified against the CLI (2.1.x); live transcripts are covered by test
/// fixtures because the CLI's JSON shape can change.
class ClaudeCodeAdapter extends AgentAdapter {
  @override
  String get id => 'claude-code';
  @override
  String get name => 'Claude Code';
  @override
  List<String> get binaries => const ['claude'];
  @override
  String get color => '#D97757';
  @override
  String get letter => 'C';
  @override
  List<String> get goodAt => const ['planning', 'refactors', 'multi-file changes'];

  /// Aliases, so each keeps meaning the newest model of its family.
  @override
  List<ModelOption> get models => const [
    ModelOption('fable', 'Fable', note: 'deepest'),
    ModelOption('opus', 'Opus', note: 'strong'),
    ModelOption('sonnet', 'Sonnet', note: 'balanced'),
    ModelOption('haiku', 'Haiku', note: 'fast, cheap'),
  ];

  /// `--effort` (seen in 2.1.278's help).
  @override
  List<String> get efforts => const ['low', 'medium', 'high', 'xhigh', 'max'];

  /// Arguments for a run (exposed for tests).
  static List<String> argsFor(RunSpec spec) => [
    '-p',
    '--input-format',
    'stream-json',
    '--output-format',
    'stream-json',
    '--verbose',
    if (spec.model != null) ...['--model', spec.model!],
    if (spec.effort != null) ...['--effort', spec.effort!],
    if (spec.resumeSessionId != null) ...['--resume', spec.resumeSessionId!],
    if (spec.mcpConfigPath != null) ...['--mcp-config', spec.mcpConfigPath!, '--allowedTools', 'mcp__${relayMcpServer}__*'],
    for (final dir in spec.addDirs) ...['--add-dir', dir],
    if (spec.readOnly || spec.disallowedTools.isNotEmpty)
      ...['--disallowedTools', if (spec.readOnly) ...['Edit', 'Write', 'MultiEdit', 'NotebookEdit'], ...spec.disallowedTools],
    if (spec.autoApprove)
      ...['--permission-mode', 'bypassPermissions']
    else
      ...['--permission-prompts', 'host', '--permission-prompt-tool', 'stdio'],
    ...spec.extraArgs,
  ];

  @override
  Future<AgentSession> start(RunSpec spec) async {
    final process = await Launch.start(
      spec.binary ?? 'claude',
      argsFor(spec),
      workingDirectory: spec.cwd,
      environment: spec.environment,
    );
    final s = ClaudeSession(process);
    s.sendUser(spec.prompt);
    return s;
  }
}

class ClaudeSession extends ProcessSession {
  ClaudeSession(super.process);

  String? _sessionId;
  int _sent = 0;
  int _results = 0;
  final _alwaysAllowed = <String>{};
  final _pendingInputs = <String, Map<String, Object?>>{};
  final _toolNames = <String, String>{};
  bool _finished = false;

  @override
  String? get sessionId => _sessionId;

  @override
  bool get canSteer => true;

  void sendUser(String text) {
    _sent++;
    writeLine({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      },
    });
  }

  @override
  void steer(String text) {
    if (_finished) return;
    sendUser(text);
    emit('steer', {'text': text});
  }

  @override
  void finish() {
    _finished = true;
    super.finish();
  }

  @override
  void answerPermission(String requestId, String answer, {String? message}) {
    final input = _pendingInputs.remove(requestId) ?? const {};
    if (answer == PermissionAnswer.allowAlways) {
      final tool = _toolNames[requestId];
      if (tool != null) _alwaysAllowed.add(tool);
    }
    final allow = answer != PermissionAnswer.deny;
    writeLine({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': allow
            ? {'behavior': 'allow', 'updatedInput': input}
            : {'behavior': 'deny', 'message': message ?? 'The user denied this in Relay.'},
      },
    });
    emit('permission_answer', {'id': requestId, 'answer': answer});
  }

  @override
  void onLine(String line) {
    final Map<String, Object?> j;
    try {
      j = (jsonDecode(line) as Map).cast();
    } catch (_) {
      emit('output', {'text': line});
      return;
    }
    switch (j['type']) {
      case 'system':
        if (j['subtype'] == 'init') {
          _sessionId = j['session_id'] as String?;
          emit('status', {
            'status': 'running',
            'sessionId': _sessionId,
            'model': j['model'],
            'detail': 'Started ${j['model'] ?? ''}'.trim(),
          });
        }
      case 'assistant':
        final msg = (j['message'] as Map?)?.cast<String, Object?>() ?? const {};
        for (final block in (msg['content'] as List?) ?? const []) {
          final b = (block as Map).cast<String, Object?>();
          switch (b['type']) {
            case 'text':
              final text = (b['text'] as String? ?? '').trim();
              if (text.isNotEmpty) emit('message', {'text': text});
            case 'tool_use':
              final input = (b['input'] as Map?)?.cast<String, Object?>() ?? const {};
              final tool = b['name'] as String? ?? 'tool';
              _toolNames[b['id'] as String? ?? ''] = tool;
              emit('tool_use', {
                'id': b['id'],
                'tool': tool,
                'summary': summarizeTool(tool, input),
                'input': input,
              });
          }
        }
        final usage = (msg['usage'] as Map?)?.cast<String, Object?>();
        if (usage != null && usage.isNotEmpty) {
          emit('usage', {
            'tokensIn': (usage['input_tokens'] as num?)?.toInt() ?? 0,
            'tokensOut': (usage['output_tokens'] as num?)?.toInt() ?? 0,
            'partial': true,
          });
        }
      case 'user':
        final msg = (j['message'] as Map?)?.cast<String, Object?>() ?? const {};
        final content = msg['content'];
        if (content is List) {
          for (final block in content) {
            final b = (block as Map).cast<String, Object?>();
            if (b['type'] != 'tool_result') continue;
            emit('tool_result', {
              'id': b['tool_use_id'],
              'ok': b['is_error'] != true,
              'summary': _resultSummary(b['content']),
            });
          }
        }
      case 'control_request':
        final req = (j['request'] as Map?)?.cast<String, Object?>() ?? const {};
        final id = j['request_id'] as String? ?? '';
        if (req['subtype'] == 'can_use_tool') {
          final tool = req['tool_name'] as String? ?? 'tool';
          final input = (req['input'] as Map?)?.cast<String, Object?>() ?? const {};
          _pendingInputs[id] = input;
          _toolNames[id] = tool;
          if (_alwaysAllowed.contains(tool)) {
            answerPermission(id, PermissionAnswer.allowOnce);
            return;
          }
          emit('permission', {'id': id, 'tool': tool, 'summary': summarizeTool(tool, input), 'input': input});
        } else {
          writeLine({
            'type': 'control_response',
            'response': {'subtype': 'error', 'request_id': id, 'error': 'Relay does not handle ${req['subtype']}'},
          });
        }
      case 'result':
        _results++;
        final usage = (j['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        emit('usage', {
          'tokensIn': ((usage['input_tokens'] as num?)?.toInt() ?? 0) +
              ((usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0) +
              ((usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0),
          'tokensOut': (usage['output_tokens'] as num?)?.toInt() ?? 0,
          'costUsd': (j['total_cost_usd'] as num?)?.toDouble() ?? 0,
        });
        final isError = j['is_error'] == true || (j['subtype'] as String? ?? '').startsWith('error');
        final text = j['result'] as String? ?? '';
        final limit = isError ? parseLimitReset(text) : null;
        emit('status', {
          'status': isError ? 'failed' : 'turn_done',
          'detail': text,
          'limitedUntil': ?limit?.toIso8601String(),
        });
        if (_results >= _sent) finish();
      default:
        // stream_event, rate-limit notices and newer types are ignored.
        break;
    }
  }

  @override
  void onExit(int code) {
    if (code != 0 && !stopping && _results == 0) {
      final err = stderrText.trim();
      emit('error', {'text': err.isEmpty ? 'Claude Code exited with code $code' : err});
    }
  }
}

String _resultSummary(Object? content) {
  String text;
  if (content is String) {
    text = content;
  } else if (content is List) {
    text = content
        .whereType<Map>()
        .map((m) => m['text'] is String ? m['text'] as String : '')
        .where((s) => s.isNotEmpty)
        .join(' ');
  } else {
    text = '';
  }
  final firstLines = text.split('\n').where((l) => l.trim().isNotEmpty).take(2).join(' · ');
  return firstLines.length > 160 ? '${firstLines.substring(0, 157)}…' : firstLines;
}
