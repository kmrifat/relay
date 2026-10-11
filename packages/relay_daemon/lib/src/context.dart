import 'dart:async';
import 'dart:io';

import 'package:relay_agents/relay_agents.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_git/relay_git.dart';
import 'package:relay_protocol/relay_protocol.dart';

/// Shared services for every part of relayd.
class DaemonContext {
  DaemonContext({
    required this.paths,
    required this.store,
    required this.deviceId,
    required this.registry,
    required this.git,
    required this.version,
    this.relayBinary,
    this.ptyHelper,
  });

  final RelayPaths paths;
  final Store store;
  final String deviceId;
  final AgentRegistry registry;
  final Git git;
  final String version;

  /// Path of this binary (for `relay mcp` and the demo agent).
  final String? relayBinary;
  final String? ptyHelper;

  /// Login-shell environment for agent processes.
  Map<String, String> env = Platform.environment;

  final _notices = StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get notices => _notices.stream;

  void notice(String text, {String level = 'info'}) => _notices.add({'text': text, 'level': level});

  final _broadcast = StreamController<(String, Map<String, Object?>)>.broadcast();

  /// Ad-hoc events for every client: terminal output, fs changes, agent state.
  Stream<(String, Map<String, Object?>)> get broadcasts => _broadcast.stream;
  void broadcast(String method, Map<String, Object?> params) => _broadcast.add((method, params));

  // ---------------------------------------------------------------- settings

  String setting(String key, String fallback) => store.meta('settings.$key') ?? fallback;
  int intSetting(String key, int fallback) => int.tryParse(store.meta('settings.$key') ?? '') ?? fallback;
  bool boolSetting(String key, bool fallback) {
    final v = store.meta('settings.$key');
    return v == null ? fallback : v == 'true';
  }

  static const defaultSettings = {
    'maxConcurrent': '4',
    'askBeforeShell': 'true',
    'worktreePerRun': 'true',
    'agentMessages': 'true',
    'keepRunningWhenClosed': 'true',
    'userName': 'You',
  };

  /// Defaults overlaid with everything set (deviceName, shareAgents,
  /// schedulerPaused, …).
  Map<String, String> allSettings() => {...defaultSettings, ...store.metaWithPrefix('settings.')};

  // ---------------------------------------------------------------- lookups

  Project project(String id) =>
      store.get<Project>(Kind.project, id) ?? (throw RpcError(RpcError.notFound, 'No project $id'));
  Task task(String id) => store.get<Task>(Kind.task, id) ?? (throw RpcError(RpcError.notFound, 'No task $id'));
  Run run(String id) => store.get<Run>(Kind.run, id) ?? (throw RpcError(RpcError.notFound, 'No run $id'));
  Repo repo(String id) => store.get<Repo>(Kind.repo, id) ?? (throw RpcError(RpcError.notFound, 'No repo $id'));
  AgentProfile? agent(String id) => store.get<AgentProfile>(Kind.agent, id);

  List<Repo> reposOf(String projectId) =>
      store.list<Repo>(Kind.repo, projectId: projectId)..sort((a, b) {
        final s = a.mergeStep.compareTo(b.mergeStep);
        return s != 0 ? s : a.name.compareTo(b.name);
      });

  /// Repos a task changes: its own list, else the project's first repo.
  List<Repo> touchedRepos(Task t) {
    final all = reposOf(t.projectId);
    if (t.repoIds.isEmpty) return all.isEmpty ? const [] : [all.first];
    return all.where((r) => t.repoIds.contains(r.id)).toList();
  }

  String taskKey(Task t) => t.displayKey(project(t.projectId).key);
}
