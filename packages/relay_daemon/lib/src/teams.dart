import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'context.dart';

/// One role in a team template.
class RoleTemplate {
  const RoleTemplate({
    required this.key,
    required this.role,
    required this.names,
    required this.color,
    required this.caps,
    required this.responsibilities,
    this.model = const {},
    this.effort = const {},
    this.prefer = const ['claude-code'],
  });

  /// Stable within the template; edges use it.
  final String key;
  final String role;

  /// First free one is used, so a second squad gets new names.
  final List<String> names;
  final String color;
  final Set<String> caps;
  final String responsibilities;

  /// Per CLI adapter: which model and effort this role gets there.
  final Map<String, String> model, effort;

  /// CLIs to run on, best first; the first one installed wins.
  final List<String> prefer;
}

class TeamTemplate {
  const TeamTemplate(this.id, this.name, this.summary, this.roles, this.edges);
  final String id;
  final String name;
  final String summary;
  final List<RoleTemplate> roles;

  /// `(from, to)` role keys; `you` is the person.
  final List<(String, String)> edges;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'summary': summary, 'roles': [for (final r in roles) r.role]};
}

const _pm = RoleTemplate(
  key: 'pm',
  role: 'Project manager',
  names: ['Pria', 'Paz', 'Pell', 'Pim'],
  color: '#8944AB',
  caps: {AgentCap.createTasks, AgentCap.assign, AgentCap.postChannel, AgentCap.message},
  model: {'claude-code': 'opus', 'demo': 'opus'},
  effort: {'claude-code': 'high', 'demo': 'high', 'codex': 'high'},
  responsibilities: 'You own the product goal. Break requests into tasks small enough for one run, each with a brief and '
      '"done when" checks. Give backend work to the backend dev and UI work to the frontend dev, and send finished work to QA. '
      'Answer the team\'s product questions yourself when you can; ask the owner only for real product decisions.',
);

const _backend = RoleTemplate(
  key: 'backend',
  role: 'Sr backend dev',
  names: ['Bram', 'Bex', 'Bo', 'Bly'],
  color: '#0A64D8',
  caps: {AgentCap.editCode, AgentCap.runShell, AgentCap.createTasks, AgentCap.message},
  model: {'claude-code': 'sonnet', 'demo': 'sonnet'},
  effort: {'claude-code': 'high', 'demo': 'high', 'codex': 'high'},
  responsibilities: 'You build APIs, data and services. Keep shared contracts (OpenAPI, schemas) up to date first and tell the '
      'frontend dev when they change. Write tests with your code and leave the repo green.',
);

const _frontend = RoleTemplate(
  key: 'frontend',
  role: 'Sr frontend dev',
  names: ['Faye', 'Fin', 'Flo', 'Fen'],
  color: '#C77700',
  caps: {AgentCap.editCode, AgentCap.runShell, AgentCap.createTasks, AgentCap.message},
  model: {'claude-code': 'sonnet', 'demo': 'sonnet'},
  effort: {'claude-code': 'high', 'demo': 'high', 'codex': 'medium'},
  prefer: ['codex', 'claude-code'],
  responsibilities: 'You build the UI. Follow the design and the shared contracts; if the API you need is missing, message the '
      'backend dev instead of working around it. Keep components small and add widget or e2e tests.',
);

const _qa = RoleTemplate(
  key: 'qa',
  role: 'QA engineer',
  names: ['Quinn', 'Quill', 'Qi', 'Quin'],
  color: '#1F9D55',
  caps: {AgentCap.editCode, AgentCap.runShell, AgentCap.createTasks, AgentCap.postChannel, AgentCap.message},
  model: {'claude-code': 'haiku', 'demo': 'haiku'},
  effort: {'claude-code': 'low', 'demo': 'low', 'codex': 'low'},
  responsibilities: 'You check finished work against its "done when" list: run the tests, add missing ones, try the edge cases. '
      'Report what passed and what failed. File a task for each bug you find, for whoever built the work.',
);

const _builder = RoleTemplate(
  key: 'builder',
  role: 'Builder',
  names: ['Bea', 'Ben', 'Bay'],
  color: '#0A64D8',
  caps: {AgentCap.editCode, AgentCap.runShell, AgentCap.createTasks, AgentCap.message},
  model: {'claude-code': 'sonnet', 'demo': 'sonnet'},
  effort: {'claude-code': 'high', 'demo': 'high', 'codex': 'high'},
  responsibilities: 'You build what the task asks for, with tests, and leave the repo green.',
);

const _reviewer = RoleTemplate(
  key: 'reviewer',
  role: 'Reviewer',
  names: ['Rue', 'Rho', 'Ray'],
  color: '#D49BF5',
  caps: {AgentCap.createTasks, AgentCap.message},
  model: {'claude-code': 'opus', 'demo': 'opus'},
  effort: {'claude-code': 'medium', 'demo': 'medium', 'codex': 'medium'},
  responsibilities: 'You review finished work: correctness, edge cases, naming, tests. Send precise change requests to the '
      'builder; file a task for anything bigger.',
);

const _triager = RoleTemplate(
  key: 'triager',
  role: 'Triager',
  names: ['Tess', 'Tal', 'Tam'],
  color: '#8944AB',
  caps: {AgentCap.createTasks, AgentCap.assign, AgentCap.postChannel, AgentCap.message},
  model: {'claude-code': 'haiku', 'demo': 'haiku'},
  effort: {'claude-code': 'medium', 'demo': 'medium', 'codex': 'low'},
  responsibilities: 'You turn bug reports into tasks: reproduce from the code, find the likely cause, write a brief with the '
      'steps and the files, and give it to the fixer.',
);

const _fixer = RoleTemplate(
  key: 'fixer',
  role: 'Fixer',
  names: ['Fox', 'Fia', 'Fay'],
  color: '#0A64D8',
  caps: {AgentCap.editCode, AgentCap.runShell, AgentCap.createTasks, AgentCap.message},
  model: {'claude-code': 'sonnet', 'demo': 'sonnet'},
  effort: {'claude-code': 'high', 'demo': 'high', 'codex': 'high'},
  responsibilities: 'You fix the bug in the brief with a test that fails before and passes after. Keep the change small.',
);

const teamTemplates = [
  TeamTemplate('product-squad', 'Product squad', 'PM · backend · frontend · QA', [_pm, _backend, _frontend, _qa], [
    ('you', 'pm'),
    ('pm', 'backend'),
    ('pm', 'frontend'),
    ('backend', 'qa'),
    ('frontend', 'qa'),
    ('qa', 'you'),
  ]),
  TeamTemplate('solo-builder', 'Solo builder', 'one dev agent + reviewer', [_builder, _reviewer], [
    ('you', 'builder'),
    ('builder', 'reviewer'),
    ('reviewer', 'you'),
  ]),
  TeamTemplate('bug-crew', 'Bug crew', 'triager · fixer · QA', [_triager, _fixer, _qa], [
    ('you', 'triager'),
    ('triager', 'fixer'),
    ('fixer', 'qa'),
    ('qa', 'you'),
  ]),
];

/// Teams of role agents (M13).
class Teams {
  Teams(this.ctx);
  final DaemonContext ctx;
  Store get store => ctx.store;

  /// Makes [name] from [templateId]: one role agent per role, on the best
  /// CLI that is installed (or on [runtime] for all of them).
  Team create(String name, {String? templateId, List<String> projectIds = const [], String? runtime}) {
    final clean = name.trim();
    if (clean.isEmpty) throw RpcError(RpcError.invalidParams, 'Name the team.');
    final template = templateId == null
        ? null
        : teamTemplates.where((t) => t.id == templateId).firstOrNull ?? (throw RpcError(RpcError.notFound, 'No template $templateId'));
    final team = store.create<Team>(Kind.team, {
      'name': clean,
      'projectIds': projectIds,
      'members': <String>[],
      'edges': <Map<String, Object?>>[],
      'template': ?templateId,
    });
    if (template == null) return team;
    final ids = <String, String>{'you': 'you'};
    for (final r in template.roles) {
      final cli = runtime ?? _runtimeFor(r);
      ids[r.key] = createAgent({
        'name': _freeName(r.names),
        'role': r.role,
        'runtime': cli,
        'color': r.color,
        'caps': r.caps.toList(),
        'responsibilities': r.responsibilities,
        'model': ?r.model[ctx.agent(cli)?.adapter ?? cli],
        'effort': ?r.effort[ctx.agent(cli)?.adapter ?? cli],
        'teamId': team.id,
        'slots': r.key == 'pm' || r.key == 'triager' ? 1 : 2,
      }).id;
    }
    return store.patch<Team>(Kind.team, team.id, {
      'members': [for (final r in template.roles) ids[r.key]],
      'edges': [for (final (from, to) in template.edges) {'from': ids[from], 'to': ids[to]}],
    });
  }

  /// A role agent on [fields]['runtime'], with the CLI's install copied in.
  AgentProfile createAgent(Map<String, Object?> fields) {
    final runtimeId = fields['runtime'] as String? ?? (throw RpcError(RpcError.invalidParams, 'Which CLI does it run on? Pass runtime.'));
    final cli = ctx.agent(runtimeId);
    final name = (fields['name'] as String? ?? '').trim();
    if (name.isEmpty) throw RpcError(RpcError.invalidParams, 'Name the agent.');
    final agent = store.create<AgentProfile>(Kind.agent, {
      'id': _freeId(name),
      'enabled': true,
      'slots': 2,
      ...fields,
      'name': name,
      'letter': name.substring(0, 1).toUpperCase(),
      'adapter': cli?.adapter ?? runtimeId,
      'binaryPath': cli?.binaryPath,
      'version': cli?.version,
      'models': cli?.models ?? const [],
      'efforts': cli?.efforts ?? const [],
      'plan': cli?.plan ?? '',
      'limitedUntil': cli?.data['limitedUntil'],
    });
    final teamId = agent.teamId;
    final team = teamId == null ? null : store.get<Team>(Kind.team, teamId);
    if (team != null && !team.members.contains(agent.id)) {
      store.patch<Team>(Kind.team, team.id, {'members': [...team.members, agent.id]});
    }
    return agent;
  }

  /// Removes a role agent (not a CLI) and takes it out of its team.
  void deleteAgent(String id) {
    final a = ctx.agent(id) ?? (throw RpcError(RpcError.notFound, 'No agent $id'));
    if (!a.isRole) throw RpcError(RpcError.invalidParams, '${a.name} is a CLI found on this computer; turn it off instead.');
    for (final t in store.list<Team>(Kind.team).where((t) => t.members.contains(id))) {
      store.patch<Team>(Kind.team, t.id, {
        'members': [...t.members.where((m) => m != id)],
        'edges': [...t.edges.where((e) => e['from'] != id && e['to'] != id)],
      });
    }
    store.delete(Kind.agent, id);
  }

  /// Deletes the team, and its agents unless [keepAgents].
  void delete(String id, {bool keepAgents = false}) {
    final t = store.get<Team>(Kind.team, id) ?? (throw RpcError(RpcError.notFound, 'No team $id'));
    for (final m in t.members) {
      final a = ctx.agent(m);
      if (a == null) continue;
      if (keepAgents) {
        store.patch<AgentProfile>(Kind.agent, m, {'teamId': null});
      } else if (a.isRole) {
        store.delete(Kind.agent, m);
      }
    }
    store.delete(Kind.team, id);
  }

  /// Copies a CLI's install onto its role agents after detection.
  void syncRuntimes() {
    final agents = store.list<AgentProfile>(Kind.agent);
    for (final a in agents.where((a) => a.isRole)) {
      final cli = agents.where((x) => x.id == a.runtime).firstOrNull;
      final fields = {
        'adapter': cli?.adapter ?? a.adapter,
        'binaryPath': cli?.binaryPath,
        'version': cli?.version,
        'models': cli?.models ?? const [],
        'efforts': cli?.efforts ?? const [],
      };
      if (fields.entries.any((e) => !_same(a.data[e.key], e.value))) store.patch<AgentProfile>(Kind.agent, a.id, fields);
    }
  }

  static bool _same(Object? a, Object? b) => a is List && b is List ? a.length == b.length && a.indexed.every((e) => '${e.$2}' == '${b[e.$1]}') : a == b;

  String _runtimeFor(RoleTemplate r) {
    final installed = ctx.store.list<AgentProfile>(Kind.agent).where((a) => !a.isRole && a.binaryPath != null && a.enabled).map((a) => a.id).toSet();
    for (final p in r.prefer) {
      if (installed.contains(p)) return p;
    }
    // Nothing preferred is installed: any real CLI, then the demo agent.
    return installed.where((i) => i != 'demo').firstOrNull ?? (installed.contains('demo') ? 'demo' : r.prefer.first);
  }

  String _freeName(List<String> names) {
    final taken = {for (final a in store.list<AgentProfile>(Kind.agent)) a.name.toLowerCase()};
    for (final n in names) {
      if (!taken.contains(n.toLowerCase())) return n;
    }
    for (var i = 2;; i++) {
      final n = '${names.first} $i';
      if (!taken.contains(n.toLowerCase())) return n;
    }
  }

  /// `@handle` ids: "Pria" → `pria`, unique among agents.
  String _freeId(String name) {
    final base = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final stem = base.isEmpty ? 'agent' : base;
    var id = stem;
    for (var i = 2; ctx.agent(id) != null; i++) {
      id = '$stem-$i';
    }
    return id;
  }
}
