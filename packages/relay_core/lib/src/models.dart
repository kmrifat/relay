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
  static const device = 'device';
  static const channel = 'channel';
  static const message = 'message';
  static const team = 'team';

  static const all = [project, repo, task, comment, run, agent, change, rule, device, channel, message, team];

  /// Kinds shared with the team. Agent profiles, agent teams and routing
  /// rules describe this device's CLIs and preferences, so they stay local.
  static const synced = {project, repo, task, comment, run, change, device, channel, message};
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
  Kind.device => DeviceInfo(data),
  Kind.channel => Channel(data),
  Kind.message => Message(data),
  Kind.team => Team(data),
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

  /// What the product is for right now (design P01), e.g. "Checkout v1".
  String get goal => str('goal') ?? '';

  /// The milestone being worked towards: tasks with this [Task.milestone]
  /// count towards it.
  String get milestone => str('milestone') ?? '';
  DateTime? get milestoneDue => _date(data['milestoneDue']);
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

  /// Where [deviceId] has the repo checked out. Each device sets its own
  /// `path@<device>` field, so two devices never overwrite each other's
  /// path when their ops merge. (`paths` is the pre-sync form.)
  String? pathOn(String deviceId) => data['path@$deviceId'] as String? ?? (data['paths'] as Map?)?[deviceId] as String?;

  static String pathField(String deviceId) => 'path@$deviceId';

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

  /// How the board names them (design P03); the stored values stay.
  static String label(String s) => switch (s) {
    backlog => 'Backlog',
    queued => 'Ready',
    running => 'In progress',
    review => 'Review · QA',
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
    this.model,
    this.effort,
  });

  factory PipelineStep.fromJson(Map<String, Object?> j) => PipelineStep(
    name: j['name'] as String? ?? '',
    assigneeKind: j['assigneeKind'] as String? ?? 'agent',
    assignee: j['assignee'] as String? ?? '',
    note: j['note'] as String? ?? '',
    status: j['status'] as String? ?? 'pending',
    model: j['model'] as String?,
    effort: j['effort'] as String?,
  );

  final String name;

  /// `agent` or `person`.
  final String assigneeKind;
  final String assignee;
  final String note;

  /// `pending`, `running`, `done`, `failed`, `skipped`.
  final String status;

  /// Model and effort for this step's agent, over the task's and agent's.
  final String? model, effort;

  PipelineStep withStatus(String s) => PipelineStep(
    name: name,
    assigneeKind: assigneeKind,
    assignee: assignee,
    note: note,
    status: s,
    model: model,
    effort: effort,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'assigneeKind': assigneeKind,
    'assignee': assignee,
    'note': note,
    'status': status,
    'model': ?model,
    'effort': ?effort,
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

  /// Model and effort for whoever runs it, over the agent's defaults. A
  /// model name belongs to one CLI ([modelFor], an adapter id); another
  /// CLI ignores it.
  String? get model => str('model');
  String? get modelFor => str('modelFor');
  String? get effort => str('effort');

  /// The epic this task belongs to (a task with [isEpic]).
  String? get parentId => str('parentId');
  bool get isEpic => boolOr('epic', false);

  /// The project milestone it counts towards (by name).
  String? get milestone => str('milestone');

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

  /// What the CLI was started with; null means its own default.
  String? get model => str('model');
  String? get effort => str('effort');
}

/// What an agent may do (design P02 "Allowed to"). The MCP tools and the
/// CLI's own tool switches follow them.
abstract final class AgentCap {
  static const editCode = 'editCode';
  static const runShell = 'runShell';
  static const createTasks = 'createTasks';
  static const assign = 'assign';
  static const postChannel = 'postChannel';
  static const message = 'message';
  static const merge = 'merge';

  static const all = [editCode, runShell, createTasks, assign, postChannel, message, merge];

  /// An agent nobody has set up: it codes, and files follow-ups as before.
  static const defaults = {editCode, runShell, createTasks, message};

  static String label(String c) => switch (c) {
    editCode => 'Edit code',
    runShell => 'Run shell',
    createTasks => 'Create tasks',
    assign => 'Assign teammates',
    postChannel => 'Post in channels',
    message => 'Message agents',
    merge => 'Merge PRs',
    _ => c,
  };
}

/// A coding-agent CLI the user has on this device, and how Relay uses it.
///
/// It is either the CLI itself (id = adapter id, found by detection), or a
/// role on top of one ([runtime] names that CLI's profile): its own name,
/// role, model, effort, responsibilities and capabilities, sharing the
/// CLI's install and its plan limits. Detection copies the CLI's path,
/// version and offers onto its role agents.
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

  /// Default reasoning effort, one of [efforts].
  String? get effort => str('effort');

  /// What the CLI offers (from its adapter, refreshed at detection): models
  /// as {id, label, note} and effort levels, lowest first.
  List<Map<String, Object?>> get models => maps('models');
  List<String> get efforts => strings('efforts');
  List<String> get goodAt => strings('goodAt');

  /// For API-key agents: daily spend cap in USD (0 = none).
  double get dailyCapUsd => dblOr('dailyCapUsd', 0);

  /// When the plan's limit resets after being hit (ISO time), if known.
  DateTime? get limitedUntil => _date(data['limitedUntil']);

  /// For a role agent: the CLI profile it runs on (e.g. `claude-code`).
  String? get runtime => str('runtime');
  bool get isRole => runtime != null;

  /// The profile whose plan and limits this agent uses.
  String get runtimeId => runtime ?? id;

  /// "Project manager", "Sr backend dev"; empty for a plain CLI.
  String get role => str('role') ?? '';

  /// Added to every run's prompt.
  String get responsibilities => str('responsibilities') ?? '';
  String? get teamId => str('teamId');

  Set<String> get caps => data['caps'] is List ? strings('caps').toSet() : AgentCap.defaults;
  bool can(String cap) => caps.contains(cap);
}

/// A group of agents that work on some projects together (design P02):
/// who hands work to whom, and whether its plans wait for your OK.
class Team extends Entity {
  const Team(super.data);
  @override
  String get kind => Kind.team;

  String get name => str('name') ?? '';
  String get color => str('color') ?? '#0A64D8';

  /// Agent ids, in the order the team page lists them.
  List<String> get members => strings('members');
  List<String> get projectIds => strings('projectIds');

  /// Handoffs: `{from, to}` agent ids; `you` is the person.
  List<Map<String, Object?>> get edges => maps('edges');

  /// The PM's plan waits for your OK before its tasks start (M14).
  bool get planApproval => boolOr('planApproval', true);

  /// The template it was made from, if any.
  String? get template => str('template');
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

/// A device in the team (a teammate's Mac), published by the device itself.
class DeviceInfo extends Entity {
  const DeviceInfo(super.data);
  @override
  String get kind => Kind.device;

  /// e.g. "Rifat's MacBook Pro".
  String get name => str('name') ?? id;

  /// The person who uses it.
  String get person => str('person') ?? '';

  /// The agent CLIs on it: `[{id, name, color, letter, slots, version}]`.
  List<Map<String, Object?>> get agents => maps('agents');

  /// Whether teammates may assign work to this device's agents.
  bool get shareAgents => boolOr('shareAgents', false);
  DateTime? get lastSeen => _date(data['lastSeen']);
  bool get revoked => boolOr('revoked', false);
}

/// A team chat channel, optionally linked to a project's board.
class Channel extends Entity {
  const Channel(super.data);
  @override
  String get kind => Kind.channel;

  /// Without the `#`, e.g. `general`, `taskmanager`.
  String get name => str('name') ?? id;
  String get topic => str('topic') ?? '';

  /// The project whose board `/task` adds to.
  String? get projectId => str('projectId');

  /// Pinned message ids. Stored as `pin.<messageId>: true` fields so pins
  /// from two devices merge.
  List<String> get pins => [
    for (final e in data.entries)
      if (e.key.startsWith('pin.') && e.value == true) e.key.substring(4),
  ];

  /// The deterministic id of a project's channel (no duplicates when two
  /// devices create it).
  static String idFor(String projectId) => 'ch-$projectId';
  static const general = 'ch-general';
}

/// A message in a channel. Reactions are `react.<emoji>.<person>: true`
/// fields, so concurrent reactions merge field by field.
class Message extends Entity {
  const Message(super.data);
  @override
  String get kind => Kind.message;

  String get channelId => str('channelId')!;

  /// `person`, `agent` or `system` (Relay: digests, notices).
  String get authorKind => str('authorKind') ?? 'person';
  String get author => str('author') ?? '';

  /// The device it was sent from (agents: the device they run on).
  String? get deviceId => str('deviceId');
  String get body => str('body') ?? '';

  /// A thread reply's parent message.
  String? get replyTo => str('replyTo');

  /// A task this message created or reports on (shows a task card).
  String? get taskId => str('taskId');

  /// `digest` for the morning digest.
  String? get tag => str('tag');

  /// `[{id, name, size, mime}]`; the bytes are sealed in storage under
  /// `files/<id>` (docs/format/sync.md).
  List<Map<String, Object?>> get files => maps('files');

  /// emoji → people who reacted with it.
  Map<String, List<String>> get reactions {
    final out = <String, List<String>>{};
    for (final e in data.entries) {
      if (!e.key.startsWith('react.') || e.value != true) continue;
      final rest = e.key.substring(6);
      final dot = rest.lastIndexOf('.');
      if (dot <= 0) continue;
      (out[rest.substring(0, dot)] ??= []).add(rest.substring(dot + 1));
    }
    return out;
  }

  static String reactionField(String emoji, String person) => 'react.$emoji.${person.replaceAll('.', '')}';

  /// `@handles` in the body, without the `@`.
  List<String> get mentions => [for (final m in RegExp(r'@([A-Za-z0-9_.-]+)').allMatches(body)) m.group(1)!.replaceAll(RegExp(r'[.]+$'), '')];
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
