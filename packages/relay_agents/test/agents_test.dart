import 'dart:convert';
import 'dart:io';

import 'package:relay_agents/relay_agents.dart';
import 'package:test/test.dart';

String fixture(String name) => '${Directory.current.path}/test/fixtures/$name';

void main() {
  test('Claude Code: transcript → events, permission round trip, finish', () async {
    final log = File('${Directory.systemTemp.createTempSync('fake_claude_').path}/stdin.log');
    final session = await ClaudeCodeAdapter().start(RunSpec(
      prompt: 'Build the R2 adapter',
      cwd: Directory.systemTemp.path,
      binary: fixture('fake_claude.sh'),
      environment: {'FAKE_LOG': log.path},
    ));
    final events = <AgentEvent>[];
    await for (final e in session.events) {
      events.add(e);
      if (e.type == 'permission') {
        session.answerPermission(e.data['id'] as String, PermissionAnswer.allowOnce);
      }
    }
    expect(await session.exitCode, 0);
    expect(session.sessionId, 'sess-123');

    final types = events.map((e) => e.type).toList();
    expect(types.first, 'status');
    expect(types, containsAllInOrder(['message', 'tool_use', 'tool_result', 'tool_use', 'permission', 'permission_answer', 'tool_result', 'message', 'usage', 'status']));

    final read = events.firstWhere((e) => e.type == 'tool_use');
    expect(read.data['tool'], 'Read');
    expect(read.data['summary'], 'lib/sync/op_log.dart');

    final perm = events.firstWhere((e) => e.type == 'permission');
    expect(perm.data['summary'], 'npx wrangler r2 bucket create relay-sync-dev');

    final usage = events.lastWhere((e) => e.type == 'usage');
    expect(usage.data['tokensIn'], 2500);
    expect(usage.data['costUsd'], 0.0123);
    expect(events.last.data['status'], 'turn_done');

    // What Relay wrote to the CLI: the prompt, then an allow with the input.
    final lines = log.readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
    expect(lines.first['type'], 'user');
    expect(((lines.first['message'] as Map)['content'] as List).first['text'], 'Build the R2 adapter');
    final resp = lines.firstWhere((l) => l['type'] == 'control_response')['response'] as Map;
    expect(resp['request_id'], 'req_1');
    expect((resp['response'] as Map)['behavior'], 'allow');
    expect(((resp['response'] as Map)['updatedInput'] as Map)['command'], contains('wrangler'));
  }, testOn: '!windows'); // fixtures are sh scripts; Windows launching is in launch_test

  test('Claude Code: deny sends a deny message', () async {
    final log = File('${Directory.systemTemp.createTempSync('fake_claude_').path}/stdin.log');
    final session = await ClaudeCodeAdapter().start(RunSpec(
      prompt: 'x',
      cwd: Directory.systemTemp.path,
      binary: fixture('fake_claude.sh'),
      environment: {'FAKE_LOG': log.path},
    ));
    await for (final e in session.events) {
      if (e.type == 'permission') session.answerPermission(e.data['id'] as String, PermissionAnswer.deny);
    }
    final resp = log.readAsLinesSync().map((l) => jsonDecode(l) as Map).firstWhere((l) => l['type'] == 'control_response');
    expect(((resp['response'] as Map)['response'] as Map)['behavior'], 'deny');
  }, testOn: '!windows'); // fixtures are sh scripts; Windows launching is in launch_test

  test('Claude Code args', () {
    final args = ClaudeCodeAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/', model: 'opus', resumeSessionId: 's1'));
    expect(args, containsAllInOrder(['-p', '--input-format', 'stream-json', '--output-format', 'stream-json']));
    expect(args, containsAllInOrder(['--model', 'opus']));
    expect(args, containsAllInOrder(['--resume', 's1']));
    // Without a prompt tool nobody is asked: prompts are denied as "permissions not granted".
    expect(args, containsAllInOrder(['--permission-prompts', 'host', '--permission-prompt-tool', 'stdio']));
    expect(args, isNot(contains('--allowedTools')));
    expect(args, isNot(contains('--add-dir')));
    final auto = ClaudeCodeAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/', autoApprove: true));
    expect(auto, containsAllInOrder(['--permission-mode', 'bypassPermissions']));
    expect(auto, isNot(contains('--permission-prompt-tool')));
  });

  test('model and effort reach each CLI, and nothing is passed when unset', () {
    final claude = ClaudeCodeAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/', model: 'haiku', effort: 'low'));
    expect(claude, containsAllInOrder(['--model', 'haiku', '--effort', 'low']));
    expect(ClaudeCodeAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/')), isNot(contains('--effort')));
    expect(ClaudeCodeAdapter().efforts, ['low', 'medium', 'high', 'xhigh', 'max']);
    expect(ClaudeCodeAdapter().models.map((m) => m.id), containsAll(['opus', 'sonnet', 'haiku']));

    final codex = CodexAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/', model: 'gpt-5-codex', effort: 'high'));
    expect(codex, containsAllInOrder(['--model', 'gpt-5-codex', '-c', 'model_reasoning_effort="high"']));
    expect(codex.last, 'p');
    expect(CodexAdapter.argsFor(RunSpec(prompt: 'p', cwd: '/')), isNot(contains('-c')));

    // Generic templates drop a placeholder that has no value, with its flag.
    final aider = aiderAdapter();
    expect(GenericAdapter.fill(aider.defaultArgs, RunSpec(prompt: 'fix it', cwd: '/')),
        ['--message', 'fix it', '--yes-always', '--no-pretty', '--no-stream']);
    expect(GenericAdapter.fill(aider.defaultArgs, RunSpec(prompt: 'fix it', cwd: '/', model: 'deepseek', effort: 'high')),
        containsAllInOrder(['--model', 'deepseek', '--reasoning-effort', 'high']));
    expect(GenericAdapter.fill(geminiAdapter().defaultArgs, RunSpec(prompt: 'x', cwd: '/', model: 'gemini-pro')), ['-p', 'x', '--yolo', '-m', 'gemini-pro']);
    expect(GenericAdapter.fill(openCodeAdapter().defaultArgs, RunSpec(prompt: 'x', cwd: '/')), ['run', 'x']);
    expect(geminiAdapter().efforts, isEmpty);
  });

  test('Claude Code args: relay MCP tools are pre-allowed, the workspace is added', () {
    final args = ClaudeCodeAdapter.argsFor(RunSpec(
      prompt: 'p',
      cwd: '/ws/ga-3/app-admin',
      mcpConfigPath: '/relay/mcp/r1.json',
      addDirs: ['/ws/ga-3'],
    ));
    expect(args, containsAllInOrder(['--mcp-config', '/relay/mcp/r1.json', '--allowedTools', 'mcp__relay__*']));
    expect(args, containsAllInOrder(['--add-dir', '/ws/ga-3']));
    expect(args, containsAllInOrder(['--permission-prompts', 'host', '--permission-prompt-tool', 'stdio']));
    // --mcp-config, --allowedTools and --add-dir take several values: each must end at a flag.
    for (final flag in ['--mcp-config', '--allowedTools', '--add-dir']) {
      final i = args.indexOf(flag);
      expect(args[i + 2], startsWith('--'), reason: '$flag would swallow ${args[i + 2]}');
    }
  });

  test('Codex: transcript → events', () async {
    final session = await CodexAdapter().start(RunSpec(prompt: 'Profile drag', cwd: Directory.systemTemp.path, binary: fixture('fake_codex.sh')));
    final events = await session.events.toList();
    expect(session.sessionId, 'th_9');
    final types = events.map((e) => e.type).toList();
    expect(types, containsAllInOrder(['status', 'tool_use', 'tool_result', 'tool_use', 'tool_result', 'message', 'usage', 'status']));
    expect(events.firstWhere((e) => e.type == 'tool_use').data['summary'], 'flutter test test/board');
    expect(events.firstWhere((e) => e.type == 'usage').data['tokensIn'], 1000);
    expect(events.last.data['status'], 'turn_done');
  }, testOn: '!windows'); // fixtures are sh scripts; Windows launching is in launch_test

  test('Generic: output lines and final message', () async {
    final a = GenericAdapter(id: 'echo', name: 'Echo', binaries: const ['sh'], defaultArgs: const ['-c', 'echo working; echo "{prompt} done"'], color: '#000', letter: 'E');
    final session = await a.start(RunSpec(prompt: 'task', cwd: Directory.systemTemp.path, binary: '/bin/sh'));
    final events = await session.events.toList();
    expect(events.where((e) => e.type == 'output').map((e) => e.data['text']), ['working', 'task done']);
    expect(events.last.data['status'], 'turn_done');
  }, testOn: '!windows'); // fake CLIs are sh scripts

  test('Generic: failure with a limit message sets limitedUntil', () async {
    final a = GenericAdapter(id: 'x', name: 'X', binaries: const ['sh'], defaultArgs: const ['-c', 'echo "Usage limit reached, try again in 2 hours" >&2; exit 1'], color: '#000', letter: 'X');
    final session = await a.start(RunSpec(prompt: 'p', cwd: Directory.systemTemp.path, binary: '/bin/sh'));
    final last = (await session.events.toList()).last;
    expect(last.data['status'], 'failed');
    expect(last.data['limitedUntil'], isNotNull);
  }, testOn: '!windows'); // fake CLIs are sh scripts

  test('summarizeTool and parseLimitReset', () {
    expect(summarizeTool('Bash', {'command': 'flutter   test\n  sync/'}), 'flutter test sync/');
    expect(summarizeTool('Grep', {'pattern': 'TODO'}), 'TODO');
    final now = DateTime(2026, 10, 11, 9, 0);
    expect(parseLimitReset('Your limit resets at 3pm', now: now), DateTime(2026, 10, 11, 15, 0));
    expect(parseLimitReset('quota exceeded, try again in 30 minutes', now: now), DateTime(2026, 10, 11, 9, 30));
    expect(parseLimitReset('all good', now: now), isNull);
  });

  test('detection finds a CLI on PATH', () async {
    final dir = Directory.systemTemp.createTempSync('bin_');
    final f = File('${dir.path}/claude')..writeAsStringSync('#!/bin/sh\necho "9.9.9 (Claude Code)"\n');
    await Process.run('chmod', ['+x', f.path]);
    final found = await AgentRegistry().detect(env: {'PATH': dir.path});
    expect(found.single.adapter, 'claude-code');
    expect(found.single.version, '9.9.9 (Claude Code)');
  }, testOn: '!windows'); // fake CLIs are sh scripts

  test('signInHint spots signed-out CLIs and nothing else', () {
    expect(
      signInHint('claude-code', 'Claude Code', 'Failed to authenticate: OAuth session expired and could not be refreshed'),
      'Claude Code is signed out. Run `claude` in a terminal and type /login, then run the task again.',
    );
    expect(signInHint('codex', 'Codex', 'Error: Not logged in'), contains('codex login'));
    expect(signInHint('aider', 'Aider', 'Invalid API key provided'), contains('API key'));
    expect(signInHint('my-cli', 'Mine', 'authentication_error: 401'), 'Mine is signed out. Sign in to it in a terminal, then run the task again.');
    expect(signInHint('claude-code', 'Claude Code', 'exit code 1'), isNull);
    expect(signInHint('claude-code', 'Claude Code', 'Tests failed: 3 of 40'), isNull);
  });
}
