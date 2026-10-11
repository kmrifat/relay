import 'package:meta/meta.dart';

/// Entity kinds. Each kind is one table in the store and one `entity` value
/// in the op log.
abstract final class Kind {
  static const project = 'project';
  static const repo = 'repo';
  static const task = 'task';
  static const comment = 'comment';
  static const run = 'run';
  static const agent = 'agent';
  static const change = 'change';
  static const rule = 'rule';

  static const all = [project, repo, task, comment, run, agent, change, rule];
}

/// Base for every synced record: a JSON map with an `id`.
///
/// Records are maps rather than generated classes on purpose: every change
/// is a field-level patch (the op log stores patches, the newest timestamp
/// wins per field), and maps make that one code path for every kind.
@immutable
abstract class Entity {
  const Entity(this.data);

  final Map<String, Object?> data;

  String get kind;
  String get id => data['id'] as String;
  DateTime get createdAt => _date(data['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get updatedAt => _date(data['updatedAt']) ?? createdAt;

  String? str(String key) => data[key] as String?;
  int intOr(String key, int fallback) => (data[key] as num?)?.toInt() ?? fallback;
  double dblOr(String key, double fallback) => (data[key] as num?)?.toDouble() ?? fallback;
  bool boolOr(String key, bool fallback) => data[key] as bool? ?? fallback;
  List<String> strings(String key) => (data[key] as List?)?.cast<String>() ?? const [];
  List<Map<String, Object?>> maps(String key) =>
      (data[key] as List?)?.map((e) => (e as Map).cast<String, Object?>()).toList() ?? const [];

  Map<String, Object?> toJson() => data;

  @override
  bool operator ==(Object other) =>
      other is Entity && other.kind == kind && _deepEq(other.data, data);

  @override
  int get hashCode => Object.hash(kind, id);
}

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

bool _deepEq(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_deepEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

Entity entityFrom(String kind, Map<String, Object?> data) => switch (kind) {
  Kind.project => Project(data),
  Kind.repo => Repo(data),
  Kind.task => Task(data),
  Kind.comment => Comment(data),
  Kind.run => Run(data),
  Kind.agent => AgentProfile(data),
  Kind.change => ChangeEntry(data),
  Kind.rule => RoutingRule(data),
  _ => throw ArgumentError('Unknown kind $kind'),
};

/// A project: a board of tasks over one or more repos.
class Project extends Entity {
  const Project(super.data);
  @override
  String get kind => Kind.project;

  /// Short key used in task ids, e.g. `TM` in `TM-44`.
  String get key => str('key') ?? 'T';
  String get name => str('name') ?? '';
  String get color => str('color') ?? '#0A64D8';
  int get nextNumber => intOr('nextNumber', 1);

  /// Repo ids in merge order (first merges first). Repos in the same step
  /// share a [Repo.mergeStep].
  int get position => intOr('position', 0);
}

/// One git repository in a project.
class Repo extends Entity {
  const Repo(super.data);
  @override
  String get kind => Kind.repo;

  String get projectId => str('projectId')!;
  String get name => str('name') ?? '';
  String get role => str('role') ?? '';
  String get stack => str('stack') ?? '';
  String get baseBranch => str('baseBranch') ?? 'main';
  String? get testCommand => str('testCommand');
  String? get remoteUrl => str('remoteUrl');

  /// Where this device has the repo checked out. Device-local in practice;
  /// stored per device id under `paths`.
  String? pathOn(String deviceId) => (data['paths'] as Map?)?[deviceId] as String?;

  /// Merge order: lower steps merge first; equal steps can merge together.
  int get mergeStep => intOr('mergeStep', 0);

  /// Files that form a contract other repos depend on (e.g. `openapi.yaml`).
  List<String> get contractPaths => strings('contractPaths');

  /// Repo ids this repo depends on (for the repo map and contract notices).
  List<String> get dependsOn => strings('dependsOn');

  /// `allow` (agents run freely) or `ask` (each run needs approval).
  String get agentPolicy => str('agentPolicy') ?? 'allow';

  /// Colour of the repo's lane and chips.
  String get color => str('color') ?? '#4D9BFF';
}

abstract final class TaskStatus {
  static const backlog = 'backlog';
  static const queued = 'queued';
  static const running = 'running';
  static const review = 'review';
  static const done = 'done';

  static const columns = [backlog, queued, running, review, done];

  static String label(String s) => switch (s) {
    backlog => 'Backlog',
    queued => 'Queued',
    running => 'Running',
    review => 'Review',
    done => 'Done',
    _ => s,
  };
}

/// One step of a task's pipeline (plan → build → test → review).
@immutable
class PipelineStep {
  const PipelineStep({
    required this.name,
    required this.assigneeKind,
    required this.assignee,
    this.note = '',
    this.status = 'pending',
  });

  factory PipelineStep.fromJson(Map<String, Object?> j) => PipelineStep(
    name: j['name'] as String? ?? '',
    assigneeKind: j['assigneeKind'] as String? ?? 'agent',
    assignee: j['assignee'] as String? ?? '',
    note: j['note'] as String? ?? '',
    status: j['status'] as String? ?? 'pending',
  );

  final String name;

  /// `agent` or `person`.
  final String assigneeKind;
  final String assignee;
  final String note;

  /// `pending`, `running`, `done`, `failed`, `skipped`.
  final String status;

  PipelineStep withStatus(String s) => PipelineStep(
    name: name,
    assigneeKind: assigneeKind,
    assignee: assignee,
    note: note,
    status: s,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'assigneeKind': assigneeKind,
    'assignee': assignee,
    'note': note,
    'status': status,
  };
}

@immutable
class CheckItem {
  const CheckItem(this.text, {this.done = false});
  factory CheckItem.fromJson(Map<String, Object?> j) =>
      CheckItem(j['text'] as String? ?? '', done: j['done'] as bool? ?? false);
  final String text;
  final bool done;
  Map<String, Object?> toJson() => {'text': text, 'done': done};
}

class Task extends Entity {
  const Task(super.data);
  @override
  String get kind => Kind.task;

  String get projectId => str('projectId')!;
  int get number => intOr('number', 0);
  String get title => str('title') ?? '';
  String get brief => str('brief') ?? '';
  String get status => str('status') ?? TaskStatus.backlog;

  /// 1 (highest) to 3; 0 means none.
  int get priority => intOr('priority', 0);

  /// `agent`, `person` or `none`.
  String get assigneeKind => str('assigneeKind') ?? 'none';
  String? get assignee => str('assignee');
  List<String> get tags => strings('tags');
  List<CheckItem> get doneWhen => maps('doneWhen').map(CheckItem.fromJson).toList();
  List<String> get dependsOn => strings('dependsOn');

  /// Repos this task changes. Empty means the project's only/first repo.
  List<String> get repoIds => strings('repoIds');
  List<PipelineStep> get pipeline => maps('pipeline').map(PipelineStep.fromJson).toList();

  /// Order within a board column.
  double get position => dblOr('position', 0);

  /// When to start: `now`, `slot` (when a slot frees), or an ISO time.
  String get startAt => str('startAt') ?? 'slot';

  /// Branch used in every repo the task touches.
  String branchName(String projectKey) => '${projectKey.toLowerCase()}-$number';

  String displayKey(String projectKey) => '$projectKey-$number';
}

class Comment extends Entity {
  const Comment(super.data);
  @override
  String get kind => Kind.comment;

  String get taskId => str('taskId')!;

  /// `person`, `agent` or `system`.
  String get authorKind => str('authorKind') ?? 'person';
  String get author => str('author') ?? '';
  String get body => str('body') ?? '';

  /// For agent-to-agent messages: who it was addressed to.
  String? get to => str('to');
}

abstract final class RunStatus {
  static const queued = 'queued';
  static const starting = 'starting';
  static const running = 'running';
  static const waiting = 'waiting'; // needs a person (permission or question)
  static const paused = 'paused';
  static const done = 'done';
  static const failed = 'failed';
  static const stopped = 'stopped';

  static bool isActive(String s) => s == starting || s == running || s == waiting || s == paused;
  static bool isFinished(String s) => s == done || s == failed || s == stopped;
}

/// One agent working on one task (or one pipeline step of it).
class Run extends Entity {
  const Run(super.data);
  @override
  String get kind => Kind.run;

  String get taskId => str('taskId')!;
  String get agentId => str('agentId')!;
  String get status => str('status') ?? RunStatus.queued;
  int get step => intOr('step', 0);
  String? get workspacePath => str('workspacePath');
  String? get sessionId => str('sessionId');
  String? get deviceId => str('deviceId');
  String get prompt => str('prompt') ?? '';
  String? get summary => str('summary');
  String? get error => str('error');
  DateTime? get startedAt => _date(data['startedAt']);
  DateTime? get endedAt => _date(data['endedAt']);
  int get tokensIn => intOr('tokensIn', 0);
  int get tokensOut => intOr('tokensOut', 0);
  double get costUsd => dblOr('costUsd', 0);
  int get toolCalls => intOr('toolCalls', 0);

  /// Which pipeline step this run executes, or -1 when the task has none.
  int get pipelineStep => intOr('pipelineStep', -1);
}

/// A coding-agent CLI the user has on this device, and how Relay uses it.
class AgentProfile extends Entity {
  const AgentProfile(super.data);
  @override
  String get kind => Kind.agent;

  /// Adapter id, e.g. `claude-code`, `codex`, `gemini`, `opencode`, `aider`.
  String get adapter => str('adapter') ?? id;
  String get name => str('name') ?? id;
  String? get binaryPath => str('binaryPath');
  String? get version => str('version');
  bool get enabled => boolOr('enabled', true);
  int get slots => intOr('slots', 2);
  String get color => str('color') ?? '#5A5A5E';
  String get letter => str('letter') ?? name.substring(0, 1).toUpperCase();

  /// Free text describing the plan, e.g. "Claude Max 5×".
  String get plan => str('plan') ?? '';
  String? get model => str('model');
  List<String> get goodAt => strings('goodAt');

  /// For API-key agents: daily spend cap in USD (0 = none).
  double get dailyCapUsd => dblOr('dailyCapUsd', 0);

  /// When the plan's limit resets after being hit (ISO time), if known.
  DateTime? get limitedUntil => _date(data['limitedUntil']);
}

/// One repo's part of a task's change set.
class ChangeEntry extends Entity {
  const ChangeEntry(super.data);
  @override
  String get kind => Kind.change;

  String get taskId => str('taskId')!;
  String get repoId => str('repoId')!;
  String get branch => str('branch') ?? '';
  String? get worktreePath => str('worktreePath');

  /// `pending`, `running`, `ready`, `merged`, `failed`.
  String get status => str('status') ?? 'pending';
  String? get agentId => str('agentId');
  int get additions => intOr('additions', 0);
  int get deletions => intOr('deletions', 0);
  int get filesChanged => intOr('filesChanged', 0);
  String? get prUrl => str('prUrl');
  String? get checks => str('checks');
  String? get mergedBy => str('mergedBy');
}

/// "If tag is #tests then DeepSeek." Rules are checked top to bottom.
class RoutingRule extends Entity {
  const RoutingRule(super.data);
  @override
  String get kind => Kind.rule;

  /// `tag`, `step`, `limit` or `else`.
  String get when => str('when') ?? 'else';
  String get value => str('value') ?? '';
  String get agentId => str('agentId') ?? '';
  int get order => intOr('order', 0);
}

/// An event inside a run: agent text, a tool call, a tool result, a
/// permission request, usage, a status change. Append-only, so it is not
/// an [Entity] and is not synced field by field.
@immutable
class RunEvent {
  const RunEvent({
    required this.runId,
    required this.seq,
    required this.at,
    required this.type,
    this.data = const {},
  });

  factory RunEvent.fromJson(Map<String, Object?> j) => RunEvent(
    runId: j['runId'] as String,
    seq: (j['seq'] as num).toInt(),
    at: DateTime.parse(j['at'] as String),
    type: j['type'] as String,
    data: (j['data'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  final String runId;
  final int seq;
  final DateTime at;

  /// See [RunEventType].
  final String type;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
    'runId': runId,
    'seq': seq,
    'at': at.toUtc().toIso8601String(),
    'type': type,
    'data': data,
  };
}

abstract final class RunEventType {
  /// `{text}` from the agent.
  static const message = 'message';

  /// `{id, tool, summary, input}`.
  static const toolUse = 'tool_use';

  /// `{id, ok, summary}`.
  static const toolResult = 'tool_result';

  /// `{id, tool, summary, input}`; answered with `permissions.answer`.
  static const permission = 'permission';

  /// `{id, answer}` (allow_once, allow_always, deny).
  static const permissionAnswer = 'permission_answer';

  /// `{text}` from a person steering the run.
  static const steer = 'steer';

  /// `{status, detail}`.
  static const status = 'status';

  /// `{tokensIn, tokensOut, costUsd}`.
  static const usage = 'usage';

  /// `{text}` raw output that could not be parsed.
  static const output = 'output';

  /// `{text}`.
  static const error = 'error';
}
