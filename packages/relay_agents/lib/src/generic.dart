import 'dart:io';

import 'adapter.dart';
import 'process_session.dart';

/// Agents without a machine-readable mode (or whose mode isn't wired up yet):
/// run once with the prompt, show their output line by line.
///
/// The command line comes from [defaultArgs] or the profile's own template,
/// so a user can fix flags for a new CLI version without a Relay update.
class GenericAdapter extends AgentAdapter {
  GenericAdapter({
    required this.id,
    required this.name,
    required this.binaries,
    required this.defaultArgs,
    required this.color,
    required this.letter,
    this.goodAt = const [],
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final List<String> binaries;
  @override
  final String color;
  @override
  final String letter;
  @override
  final List<String> goodAt;

  /// argv with `{prompt}`, `{cwd}` and `{model}` placeholders.
  final List<String> defaultArgs;

  static List<String> fill(List<String> template, RunSpec spec) => [
    for (final a in template)
      if (!(a == '{model}' && spec.model == null))
        a.replaceAll('{prompt}', spec.prompt).replaceAll('{cwd}', spec.cwd).replaceAll('{model}', spec.model ?? ''),
    ...spec.extraArgs,
  ];

  @override
  Future<AgentSession> start(RunSpec spec) async {
    final process = await Process.start(
      spec.binary ?? binaries.first,
      fill(spec.argsTemplate ?? defaultArgs, spec),
      workingDirectory: spec.cwd,
      environment: {'NO_COLOR': '1', ...spec.environment},
    );
    await process.stdin.close();
    return GenericSession(process, name);
  }
}

class GenericSession extends ProcessSession {
  GenericSession(super.process, this.name) {
    emit('status', {'status': 'running', 'detail': 'Started $name'});
  }

  final String name;
  final _tail = <String>[];

  @override
  String? get sessionId => null;
  @override
  bool get canSteer => false;
  @override
  void steer(String text) {}
  @override
  void answerPermission(String requestId, String answer, {String? message}) {}

  static final _ansi = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

  @override
  void onLine(String line) {
    final clean = line.replaceAll(_ansi, '');
    _tail.add(clean);
    if (_tail.length > 20) _tail.removeAt(0);
    emit('output', {'text': clean});
  }

  @override
  void onExit(int code) {
    if (stopping) return;
    final text = _tail.where((l) => l.trim().isNotEmpty).toList();
    final last = text.isEmpty ? '' : text.last;
    if (code == 0) {
      if (last.isNotEmpty) emit('message', {'text': last});
      emit('status', {'status': 'turn_done'});
    } else {
      final err = stderrText.trim().isEmpty ? last : stderrText.trim();
      emit('status', {
        'status': 'failed',
        'detail': err.isEmpty ? '$name exited with $code' : err,
        'limitedUntil': ?parseLimitReset(err)?.toIso8601String(),
      });
    }
  }
}

/// Gemini CLI: `gemini -p <prompt> --yolo` (non-interactive).
GenericAdapter geminiAdapter() => GenericAdapter(
  id: 'gemini',
  name: 'Gemini CLI',
  binaries: const ['gemini'],
  defaultArgs: const ['-p', '{prompt}', '--yolo'],
  color: '#8944AB',
  letter: 'G',
  goodAt: const ['long context', 'docs'],
);

/// OpenCode (any provider, e.g. DeepSeek): `opencode run <prompt>`.
GenericAdapter openCodeAdapter() => GenericAdapter(
  id: 'opencode',
  name: 'OpenCode',
  binaries: const ['opencode'],
  defaultArgs: const ['run', '{prompt}'],
  color: '#4D6BFE',
  letter: 'O',
  goodAt: const ['tests', 'cheap bulk work'],
);

/// Aider: `aider --message <prompt> --yes-always --no-pretty`.
GenericAdapter aiderAdapter() => GenericAdapter(
  id: 'aider',
  name: 'Aider',
  binaries: const ['aider'],
  defaultArgs: const ['--message', '{prompt}', '--yes-always', '--no-pretty', '--no-stream'],
  color: '#1F9D55',
  letter: 'A',
  goodAt: const ['small focused edits'],
);
