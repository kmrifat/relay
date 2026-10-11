import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'context.dart';

/// How agents work together (M14): messages between them, the plans a PM
/// proposes, handing finished work along the team, and the limits that
/// keep a team from running away.
class Collab {
  Collab(this.ctx);
  final DaemonContext ctx;
  Store get store => ctx.store;

  /// Steers a live run of an agent; set by the supervisor.
  late bool Function(String agentId, String text, String from) deliverLive;

  /// Starts work; set by the supervisor.
  late void Function() tick;

  // ------------------------------------------------------------ agents

  /// An agent by id, name or role ("pria", "Pria", "QA", "backend").
  AgentProfile? find(String who, {AgentProfile? near}) {
    final w = who.trim().toLowerCase().replaceFirst('@', '');
    if (w.isEmpty) return null;
    final all = store.list<AgentProfile>(Kind.agent).where((a) => a.enabled).toList();
    // Teammates first, so "QA" means my team's QA.
    if (near?.teamId != null) all.sort((a, b) => (a.teamId == near!.teamId ? 0 : 1).compareTo(b.teamId == near.teamId ? 0 : 1));
    return all.where((a) => a.id == w).firstOrNull ??
        all.where((a) => a.name.toLowerCase() == w).firstOrNull ??
        all.where((a) => a.role.toLowerCase() == w).firstOrNull ??
        all.where((a) => a.role.toLowerCase().contains(w)).firstOrNull;
  }

  List<AgentProfile> teammates(AgentProfile a) {
    final t = a.teamId == null ? null : store.get<Team>(Kind.team, a.teamId!);
    return [for (final id in t?.members ?? const <String>[]) if (id != a.id) ?ctx.agent(id)];
  }

  /// The team's PM: whoever may assign work.
  AgentProfile? pmOf(AgentProfile a) => teammates(a).where((x) => x.can(AgentCap.assign)).firstOrNull;

  Team? teamOf(AgentProfile a) => a.teamId == null ? null : store.get<Team>(Kind.team, a.teamId!);

  // ------------------------------------------------------------ mailbox

  /// Sends [text] from [from] to [to]. A live run gets it now; otherwise it
  /// waits for the agent's next run, and an idle agent is woken with a
  /// small task. Returns what happened, for the sender.
  String message(String from, String to, String text, {String? taskId}) {
    final sender = ctx.agent(from);
    final target = find(to, near: sender) ?? (throw RpcError(RpcError.notFound, 'No agent "$to". Use relay_team to see who is on your team.'));
    if (target.id == from) throw RpcError(RpcError.invalidParams, 'That is you.');
    _guardPingPong(from, target.id);
    final c = store.create<Comment>(Kind.comment, {
      'taskId': ?taskId,
      'authorKind': 'agent',
      'author': sender?.name ?? from,
      'agentId': from,
      'to': target.id,
      'body': text,
      'delivered': false,
    });
    if (!ctx.boolSetting('agentMessages', true)) return 'Saved on the task; agent messages are off.';
    final where = taskId == null ? '' : ' (on ${_key(taskId)})';
    if (deliverLive(target.id, '${sender?.name ?? from}$where says: $text', from)) {
      store.patch<Comment>(Kind.comment, c.id, {'delivered': true});
      return 'Delivered to ${target.name} while it works.';
    }
    if (_busy(target.id)) return '${target.name} gets it when its next run starts.';
    // Idle: wake it with a task that carries the message.
    final project = taskId == null ? null : store.get<Task>(Kind.task, taskId)?.projectId;
    final projectId = project ?? teamOf(target)?.projectIds.firstOrNull ?? store.list<Project>(Kind.project).firstOrNull?.id;
    if (projectId == null) return '${target.name} gets it when its next run starts.';
    final t = store.createTask(projectId, {
      'title': 'Reply to ${sender?.name ?? from}: ${_clip(text, 60)}',
      'brief': '${sender?.name ?? from}${taskId == null ? '' : ' (working on ${_key(taskId)})'} sent you:\n\n$text\n\nReply with relay_message, or do what it asks.',
      'status': TaskStatus.queued,
      'assigneeKind': 'agent',
      'assignee': target.id,
      'tags': ['message'],
      'createdOn': ctx.deviceId,
      'runOn': ctx.deviceId,
      'depth': _depthOf(taskId) + 1,
    });
    store.patch<Comment>(Kind.comment, c.id, {'delivered': true, 'wokeTask': t.id});
    tick();
    return '${target.name} was idle; Relay started ${ctx.taskKey(t)} for it to reply.';
  }

  bool _busy(String agentId) =>
      store.list<Run>(Kind.run).any((r) => r.agentId == agentId && RunStatus.isActive(r.status)) ||
      store.list<Task>(Kind.task).any((t) => t.assignee == agentId && t.status == TaskStatus.queued);

  /// Messages waiting for [agentId]; they are marked delivered.
  List<Comment> takeMail(String agentId) {
    final mail = store.list<Comment>(Kind.comment).where((c) => c.to == agentId && c.data['delivered'] == false).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final c in mail) {
      store.patch<Comment>(Kind.comment, c.id, {'delivered': true});
    }
    return mail;
  }

  /// Messages to [agentId] after [since] (for relay_wait).
  List<Comment> mailSince(String agentId, DateTime since) =>
      store.list<Comment>(Kind.comment).where((c) => c.to == agentId && c.createdAt.isAfter(since)).toList();

  /// Two agents writing back and forth without anything else happening
  /// are stuck; stop them and ask the person.
  void _guardPingPong(String a, String b) {
    final since = DateTime.now().toUtc().subtract(const Duration(minutes: 30));
    final between = store.list<Comment>(Kind.comment).where((c) =>
        c.createdAt.isAfter(since) && c.to != null && ((c.data['agentId'] == a && c.to == b) || (c.data['agentId'] == b && c.to == a)));
    final limit = ctx.intSetting('maxAgentExchanges', 12);
    if (between.length >= limit) {
      ctx.notice('${ctx.agent(a)?.name ?? a} and ${ctx.agent(b)?.name ?? b} sent $limit messages in 30 minutes; Relay stopped them.', level: 'warning');
      throw RpcError(RpcError.invalidParams,
          'You and ${ctx.agent(b)?.name ?? b} have exchanged $limit messages in 30 minutes. Stop messaging; ask the person with relay_ask.');
    }
  }

  // ------------------------------------------------------------ tasks

  /// A task an agent makes, inside the team's limits.
  Task createTask(AgentProfile agent, Task from, Map<String, Object?> fields) {
    final hour = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final limit = ctx.intSetting('maxAgentTasksPerHour', 20);
    final made = store.list<Task>(Kind.task).where((t) => t.str('createdBy') == agent.id && t.createdAt.isAfter(hour)).length;
    if (made >= limit) throw RpcError(RpcError.invalidParams, 'You made $limit tasks in the last hour, the limit. Finish some first, or ask the person.');
    final depth = _depthOf(from.id) + 1;
    final maxDepth = ctx.intSetting('maxAgentTaskDepth', 3);
    if (depth > maxDepth) {
      throw RpcError(RpcError.invalidParams, 'Tasks made by agents can go $maxDepth levels deep; this would be $depth. Ask the person instead.');
    }
    return store.createTask(from.projectId, {
      'createdBy': agent.id,
      'createdOn': ctx.deviceId,
      'runOn': ctx.deviceId,
      'depth': depth,
      'tags': ['from-agent'],
      ...fields,
    });
  }

  int _depthOf(String? taskId) => taskId == null ? 0 : (store.get<Task>(Kind.task, taskId)?.intOr('depth', 0) ?? 0);

  // ------------------------------------------------------------ plans

  /// A PM's plan: draft tasks in Backlog that wait for the person's OK (or
  /// start now when the team doesn't ask), and a plan card in the channel.
  Map<String, Object?> proposePlan(AgentProfile pm, Task from, String summary, List<Map<String, Object?>> steps) {
    if (steps.isEmpty) throw RpcError(RpcError.invalidParams, 'A plan needs at least one task.');
    final planId = 'plan-${DateTime.now().microsecondsSinceEpoch}';
    final made = <Task>[];
    for (final s in steps) {
      final who = (s['assignee'] as String?)?.trim();
      final assignee = who == null || who.isEmpty ? null : (find(who, near: pm) ?? (throw RpcError(RpcError.notFound, 'No agent "$who" for "${s['title']}".')));
      final after = [for (final i in _ints(s['after'])) if (i >= 0 && i < made.length) made[i].id];
      made.add(createTask(pm, from, {
        'title': '${s['title'] ?? ''}'.trim(),
        'brief': '${s['brief'] ?? ''}'.trim(),
        'doneWhen': [for (final d in _strs(s['doneWhen'])) {'text': d, 'done': false}],
        if (assignee != null) ...{'assigneeKind': 'agent', 'assignee': assignee.id},
        'dependsOn': after,
        'status': TaskStatus.backlog,
        // The plan belongs to the epic it was made for, and to the
        // milestone the product is working towards.
        'parentId': from.isEpic ? from.id : from.parentId,
        if (ctx.project(from.projectId).milestone.isNotEmpty) 'milestone': ctx.project(from.projectId).milestone,
        'planId': planId,
        'draft': true,
      }));
    }
    final team = teamOf(pm);
    final channelId = Channel.idFor(from.projectId);
    if (store.get<Channel>(Kind.channel, channelId) != null) {
      store.create<Message>(Kind.message, {
        'id': planId,
        'channelId': channelId,
        'authorKind': 'agent',
        'author': pm.name,
        'deviceId': ctx.deviceId,
        'body': summary.trim().isEmpty ? 'Here is the plan.' : summary.trim(),
        'tag': 'plan',
        'planId': planId,
        'taskId': from.id,
        'items': [
          for (final t in made)
            {'taskId': t.id, 'key': ctx.taskKey(t), 'title': t.title, 'agent': ctx.agent(t.assignee ?? '')?.name, 'after': [for (final d in t.dependsOn) made.indexWhere((m) => m.id == d)]},
        ],
        'planState': 'proposed',
      });
    }
    if (team != null && !team.planApproval) {
      approvePlan(planId);
      return {'planId': planId, 'tasks': made.length, 'approved': true};
    }
    return {'planId': planId, 'tasks': made.length, 'approved': false};
  }

  /// The person's OK: the plan's drafts are queued (dependencies keep the
  /// order).
  int approvePlan(String planId) {
    final drafts = store.list<Task>(Kind.task).where((t) => t.str('planId') == planId && t.data['draft'] == true).toList();
    for (final t in drafts) {
      store.patch<Task>(Kind.task, t.id, {'draft': null, 'status': t.assigneeKind == 'agent' ? TaskStatus.queued : TaskStatus.backlog});
    }
    if (store.get<Message>(Kind.message, planId) != null) store.patch<Message>(Kind.message, planId, {'planState': 'approved'});
    tick();
    return drafts.length;
  }

  /// Turns a plan down: its drafts are deleted.
  void rejectPlan(String planId) {
    for (final t in store.list<Task>(Kind.task).where((t) => t.str('planId') == planId && t.data['draft'] == true)) {
      store.delete(Kind.task, t.id);
    }
    if (store.get<Message>(Kind.message, planId) != null) store.patch<Message>(Kind.message, planId, {'planState': 'rejected'});
  }

  // ------------------------------------------------------------ handoffs

  /// Where a finished run's task goes, following the team (null: the usual
  /// review). A planning-only task is done; a builder's goes to the next
  /// agent on the team's edges (QA) on the same branch; a QA fail goes back
  /// to the builder, three rounds at most.
  Map<String, Object?>? afterDone(Task task, AgentProfile agent, {required bool changed}) {
    if (!agent.isRole) return null;
    if (!changed && !agent.can(AgentCap.editCode)) {
      return {'status': TaskStatus.done};
    }
    final handoffs = task.strings('handoffs');
    if (task.str('verdict') == 'failed') {
      final builder = task.str('handedBy');
      final rounds = task.intOr('rounds', 0) + 1;
      if (builder == null) return null;
      if (rounds >= 3) {
        return {'verdict': null, 'attention': 'question', 'question': 'QA failed ${ctx.taskKey(task)} three times. How should we go on?'};
      }
      return {
        'verdict': null,
        'rounds': rounds,
        'status': TaskStatus.queued,
        'assigneeKind': 'agent',
        'assignee': builder,
        'handoffs': [...handoffs.where((h) => h != agent.id)],
        'handoffNote': '${agent.name} found problems; fix them (see the discussion).',
      };
    }
    final team = teamOf(agent);
    final next = team?.edges.where((e) => e['from'] == agent.id && e['to'] != 'you' && !handoffs.contains(e['to'])).map((e) => ctx.agent('${e['to']}')).firstOrNull;
    if (next == null || !changed) return null;
    return {
      'status': TaskStatus.queued,
      'assigneeKind': 'agent',
      'assignee': next.id,
      'handedBy': agent.id,
      'handoffs': [...handoffs, agent.id, next.id],
      'handoffNote': '${agent.name} finished; check it against "done when" and report with relay_report.',
    };
  }

  // ------------------------------------------------------------ helpers

  String _key(String taskId) {
    final t = store.get<Task>(Kind.task, taskId);
    return t == null ? taskId : ctx.taskKey(t);
  }

  static String _clip(String s, int n) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= n ? one : '${one.substring(0, n - 1)}…';
  }

  static List<int> _ints(Object? v) => switch (v) {
    List() => [for (final e in v) ?int.tryParse('$e')],
    String() => [for (final e in v.split(',')) ?int.tryParse(e.trim())],
    num() => [v.toInt()],
    _ => const [],
  };

  static List<String> _strs(Object? v) => switch (v) {
    List() => [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()],
    String() => [for (final e in v.split('\n')) if (e.trim().isNotEmpty) e.trim()],
    _ => const [],
  };
}
