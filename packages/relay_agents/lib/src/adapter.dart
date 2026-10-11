import 'dart:async';

/// Everything an adapter needs to start one run.
class RunSpec {
  RunSpec({
    required this.prompt,
    required this.cwd,
    this.binary,
    this.model,
    this.effort,
    this.resumeSessionId,
    this.extraArgs = const [],
    this.argsTemplate,
    this.environment = const {},
    this.mcpConfigPath,
    this.addDirs = const [],
    this.autoApprove = false,
    this.readOnly = false,
  });

  final String prompt;
  final String cwd;

  /// Full path to the CLI (from detection); defaults to the adapter's name.
  final String? binary;
  final String? model;

  /// Reasoning effort, one of the adapter's [AgentAdapter.efforts].
  final String? effort;
  final String? resumeSessionId;
  final List<String> extraArgs;

  /// For generic adapters: argv with `{prompt}`, `{cwd}`, `{model}` and
  /// `{effort}`.
  final List<String>? argsTemplate;
  final Map<String, String> environment;

  /// An MCP config file giving the agent the `relay` tools.
  final String? mcpConfigPath;

  /// Folders besides [cwd] the agent may use: the task workspace (PROJECT.md,
  /// the read-only snapshots) when the agent starts in one of its repos.
  final List<String> addDirs;

  /// Skip Relay's permission prompts (the user chose "Always" for everything).
  final bool autoApprove;

  /// A question, not a change: the CLI's own editing tools are switched off
  /// where it has a way to (the workspace is read-only copies anyway).
  final bool readOnly;
}

/// The name of Relay's MCP server in the config `mcpConfigJson` writes; its
/// tools are `mcp__relay__…` in Claude Code.
const relayMcpServer = 'relay';

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

/// A model a CLI accepts, by the name passed to it (an alias like `opus`
/// keeps pointing at the newest one).
class ModelOption {
  const ModelOption(this.id, this.label, {this.note = ''});
  final String id;
  final String label;

  /// A hint for pickers: "deepest", "fast, cheap".
  final String note;
  Map<String, Object?> toJson() => {'id': id, 'label': label, if (note.isNotEmpty) 'note': note};
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

  /// Models offered in pickers. Any other name the CLI takes can be typed.
  List<ModelOption> get models => const [];

  /// Reasoning effort levels the CLI takes, lowest first; empty when it has
  /// no such setting.
  List<String> get efforts => const [];

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

/// When a failed run's error means the CLI isn't signed in to its account
/// ("OAuth session expired", "Not logged in", "Invalid API key"), what the
/// person should do about it. Null for any other failure.
String? signInHint(String adapter, String agentName, String error) {
  final lower = error.toLowerCase();
  const signs = [
    'failed to authenticate',
    'authentication_error',
    'authentication failed',
    'not logged in',
    'not signed in',
    'please run /login',
    'please log in',
    'oauth session',
    'oauth token',
    'invalid api key',
    'invalid x-api-key',
    'incorrect api key',
    'missing api key',
    'no api key',
    'api key not',
  ];
  if (!signs.any(lower.contains)) return null;
  final fix = switch (adapter) {
    'claude-code' => 'Run `claude` in a terminal and type /login',
    'codex' => 'Run `codex login` in a terminal',
    'gemini' => 'Run `gemini` in a terminal and sign in',
    'opencode' => 'Run `opencode auth login` in a terminal',
    'aider' => 'Set its API key (for example ANTHROPIC_API_KEY or OPENAI_API_KEY) in your shell profile',
    _ => 'Sign in to it in a terminal',
  };
  return '$agentName is signed out. $fix, then run the task again.';
}
