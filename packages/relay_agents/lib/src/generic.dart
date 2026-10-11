
import 'adapter.dart';
import 'launch.dart';
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
    this.models = const [],
    this.efforts = const [],
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
  @override
  final List<ModelOption> models;
  @override
  final List<String> efforts;

  /// argv with `{prompt}`, `{cwd}`, `{model}` and `{effort}` placeholders.
  final List<String> defaultArgs;

  /// The template filled in. A `{model}` or `{effort}` with no value is left
  /// out together with the flag in front of it (`-m {model}` → nothing).
  static List<String> fill(List<String> template, RunSpec spec) {
    final out = <String>[];
    for (final a in template) {
      final unset = (a == '{model}' && spec.model == null) || (a == '{effort}' && spec.effort == null);
      if (unset) {
        if (out.isNotEmpty && out.last.startsWith('-')) out.removeLast();
        continue;
      }
      out.add(a
          .replaceAll('{prompt}', spec.prompt)
          .replaceAll('{cwd}', spec.cwd)
          .replaceAll('{model}', spec.model ?? '')
          .replaceAll('{effort}', spec.effort ?? ''));
    }
    return [...out, ...spec.extraArgs];
  }

  @override
  Future<AgentSession> start(RunSpec spec) async {
    final process = await Launch.start(
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

/// Gemini CLI: `gemini -p <prompt> --yolo [-m model]` (non-interactive).
GenericAdapter geminiAdapter() => GenericAdapter(
  id: 'gemini',
  name: 'Gemini CLI',
  binaries: const ['gemini'],
  defaultArgs: const ['-p', '{prompt}', '--yolo', '-m', '{model}'],
  color: '#8944AB',
  letter: 'G',
  goodAt: const ['long context', 'docs'],
);

/// OpenCode (any provider, e.g. DeepSeek): `opencode run <prompt>
/// [--model provider/model]`.
GenericAdapter openCodeAdapter() => GenericAdapter(
  id: 'opencode',
  name: 'OpenCode',
  binaries: const ['opencode'],
  defaultArgs: const ['run', '{prompt}', '--model', '{model}'],
  color: '#4D6BFE',
  letter: 'O',
  goodAt: const ['tests', 'cheap bulk work'],
);

/// Aider: `aider --message <prompt> --yes-always --no-pretty`.
GenericAdapter aiderAdapter() => GenericAdapter(
  id: 'aider',
  name: 'Aider',
  binaries: const ['aider'],
  defaultArgs: const ['--message', '{prompt}', '--yes-always', '--no-pretty', '--no-stream', '--model', '{model}', '--reasoning-effort', '{effort}'],
  color: '#1F9D55',
  letter: 'A',
  goodAt: const ['small focused edits'],
  efforts: const ['low', 'medium', 'high'],
);
