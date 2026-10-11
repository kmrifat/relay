import 'dart:async';

/// Everything an adapter needs to start one run.
class RunSpec {
  RunSpec({
    required this.prompt,
    required this.cwd,
    this.binary,
    this.model,
    this.resumeSessionId,
    this.extraArgs = const [],
    this.argsTemplate,
    this.environment = const {},
    this.mcpConfigPath,
    this.autoApprove = false,
  });

  final String prompt;
  final String cwd;

  /// Full path to the CLI (from detection); defaults to the adapter's name.
  final String? binary;
  final String? model;
  final String? resumeSessionId;
  final List<String> extraArgs;

  /// For generic adapters: argv with `{prompt}`, `{cwd}` and `{model}`.
  final List<String>? argsTemplate;
  final Map<String, String> environment;

  /// An MCP config file giving the agent the `relay` tools.
  final String? mcpConfigPath;

  /// Skip Relay's permission prompts (the user chose "Always" for everything).
  final bool autoApprove;
}

/// A normalised event from any agent. `type` is one of `RunEventType`.
class AgentEvent {
  AgentEvent(this.type, [this.data = const {}]);
  final String type;
  final Map<String, Object?> data;
  @override
  String toString() => 'AgentEvent($type, $data)';
}

/// Answers to a permission request.
abstract final class PermissionAnswer {
  static const allowOnce = 'allow_once';
  static const allowAlways = 'allow_always';
  static const deny = 'deny';
}

/// A running agent process.
abstract class AgentSession {
  /// Normalised events, in order. Closes when the process exits.
  Stream<AgentEvent> get events;

  /// The CLI's own session id, once known (for resume).
  String? get sessionId;

  /// Whether this agent accepts messages while it works.
  bool get canSteer;

  /// Sends a message from a person into the running conversation.
  void steer(String text);

  /// Answers a permission request raised as a `permission` event.
  void answerPermission(String requestId, String answer, {String? message});

  /// Whether [pause] works here: it freezes the process tree with
  /// SIGSTOP, which Windows doesn't have.
  bool get canPause;

  void pause();
  void resume();

  /// Ends the run. The process gets a polite signal, then a hard kill.
  Future<void> stop();

  /// Tells the agent no more messages are coming, so it can exit when done.
  void finish();

  Future<int> get exitCode;
}

/// What detection found about a CLI on this device.
class DetectedAgent {
  DetectedAgent({required this.adapter, required this.binaryPath, this.version});
  final String adapter;
  final String binaryPath;
  final String? version;
  Map<String, Object?> toJson() => {'adapter': adapter, 'binaryPath': binaryPath, 'version': version};
}

/// One coding-agent CLI.
abstract class AgentAdapter {
  String get id;
  String get name;

  /// Executable names to look for on PATH.
  List<String> get binaries;

  /// Brand-neutral tile colour and letter for the UI.
  String get color;
  String get letter;

  /// What the agent is usually good at (shown on the fleet screen).
  List<String> get goodAt => const [];

  Future<AgentSession> start(RunSpec spec);
}

/// Shortens a tool call to one line for the run view.
String summarizeTool(String tool, Map<String, Object?> input) {
  String? s(String k) => input[k] is String ? input[k] as String : null;
  final v = switch (tool) {
    'Read' || 'Write' || 'Edit' || 'MultiEdit' || 'NotebookEdit' => s('file_path') ?? s('path'),
    'Bash' => s('command'),
    'Grep' => s('pattern'),
    'Glob' => s('pattern'),
    'WebFetch' => s('url'),
    'WebSearch' => s('query'),
    'Task' || 'Agent' => s('description'),
    'TodoWrite' => 'update todo list',
    _ => s('command') ?? s('file_path') ?? s('path') ?? s('query') ?? s('description'),
  };
  final text = v ?? (input.isEmpty ? '' : input.toString());
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length > 160 ? '${oneLine.substring(0, 157)}…' : oneLine;
}

/// Finds "resets at 3pm" / "try again in 2 hours" in a limit message.
DateTime? parseLimitReset(String text, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final lower = text.toLowerCase();
  if (!(lower.contains('limit') || lower.contains('quota'))) return null;
  final inMatch = RegExp(r'(?:in|after)\s+(\d+)\s*(minute|min|hour|hr|h|m)s?').firstMatch(lower);
  if (inMatch != null) {
    final amount = int.parse(inMatch.group(1)!);
    final unit = inMatch.group(2)!;
    return n.add(unit.startsWith('h') ? Duration(hours: amount) : Duration(minutes: amount));
  }
  final at = RegExp(r'resets?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?').firstMatch(lower);
  if (at != null) {
    var hour = int.parse(at.group(1)!);
    final minute = int.tryParse(at.group(2) ?? '0') ?? 0;
    final ampm = at.group(3);
    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;
    var t = DateTime(n.year, n.month, n.day, hour, minute);
    if (!t.isAfter(n)) t = t.add(const Duration(days: 1));
    return t;
  }
  return n.add(const Duration(hours: 1));
}
