import 'dart:convert';
import 'dart:io';

/// Bumped when a method or event changes shape. The UI and relayd compare
/// it in `hello`; a newer relayd keeps answering older UIs where it can.
const protocolVersion = 1;

/// Compares two `major.minor.patch` versions (a `-pre` or `+build`
/// suffix is ignored): negative when [a] is older than [b], zero when the
/// same, positive when newer. Null when either doesn't parse, so callers
/// can leave an unknown relayd alone.
int? compareVersions(String a, String b) {
  List<int>? parse(String v) {
    final core = v.trim().split(RegExp(r'[-+]')).first.split('.');
    if (core.isEmpty || core.length > 3) return null;
    final n = [for (final x in core) int.tryParse(x)];
    if (n.any((x) => x == null)) return null;
    return [...n.cast<int>(), ...List.filled(3 - n.length, 0)];
  }

  final x = parse(a), y = parse(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i].compareTo(y[i]);
  }
  return 0;
}

/// Request methods (client → relayd). See docs/protocol.md.
abstract final class M {
  static const hello = 'hello';
  static const status = 'status';

  /// Stops relayd cleanly (an updated app replacing an older relayd).
  /// Refused while agent runs are active unless `force` is set.
  static const shutdown = 'shutdown';

  static const projectsList = 'projects.list';
  static const projectsCreate = 'projects.create';
  static const projectsUpdate = 'projects.update';

  static const reposList = 'repos.list';
  static const reposAdd = 'repos.add';
  static const reposUpdate = 'repos.update';
  static const reposRemove = 'repos.remove';
  static const reposClone = 'repos.clone';
  static const reposInspect = 'repos.inspect';

  static const tasksList = 'tasks.list';
  static const tasksGet = 'tasks.get';
  static const tasksCreate = 'tasks.create';
  static const tasksUpdate = 'tasks.update';
  static const tasksMove = 'tasks.move';
  static const tasksDelete = 'tasks.delete';
  static const tasksSuggestRepos = 'tasks.suggestRepos';

  static const commentsList = 'comments.list';
  static const commentsPost = 'comments.post';

  static const runsList = 'runs.list';
  static const runsGet = 'runs.get';
  static const runsEvents = 'runs.events';
  static const runsStart = 'runs.start';
  static const runsSteer = 'runs.steer';
  static const runsPause = 'runs.pause';
  static const runsResume = 'runs.resume';
  static const runsStop = 'runs.stop';
  static const runsHandoff = 'runs.handoff';
  static const permissionsAnswer = 'permissions.answer';

  static const agentsList = 'agents.list';
  static const agentsDetect = 'agents.detect';
  static const agentsUpdate = 'agents.update';
  static const agentsMessage = 'agents.message';
  static const rulesList = 'rules.list';
  static const rulesSave = 'rules.save';
  static const rulesDelete = 'rules.delete';
  static const settingsGet = 'settings.get';
  static const settingsSet = 'settings.set';

  static const changesList = 'changes.list';
  static const changesMerge = 'changes.merge';
  static const changesPush = 'changes.push';

  static const gitLog = 'git.log';
  static const gitShow = 'git.show';
  static const gitDiff = 'git.diff';
  static const gitStatus = 'git.status';
  static const gitBranches = 'git.branches';
  static const gitWorktrees = 'git.worktrees';

  static const fsList = 'fs.list';
  static const fsRead = 'fs.read';
  static const fsWrite = 'fs.write';
  static const workspacesList = 'workspaces.list';

  static const termOpen = 'term.open';
  static const termInput = 'term.input';
  static const termResize = 'term.resize';
  static const termClose = 'term.close';
  static const termTakeover = 'term.takeover';
  static const termList = 'term.list';
  static const termAttach = 'term.attach';

  /// Small bits of this device's UI state (open tabs, saved commands),
  /// kept by relayd so they outlive the app. Never synced.
  static const uiGet = 'ui.get';
  static const uiSet = 'ui.set';

  static const syncStatus = 'sync.status';
  static const syncTest = 'sync.test';
  static const syncCreateTeam = 'sync.createTeam';
  static const syncInvite = 'sync.invite';
  static const syncJoin = 'sync.join';
  static const syncNow = 'sync.now';
  static const syncRevoke = 'sync.revoke';
  static const syncLeave = 'sync.leave';
  static const syncPairPhone = 'sync.pairPhone';
  static const syncPair = 'sync.pair';
  static const pushConfig = 'push.config';
  static const pushStatus = 'push.status';
  static const pushRegister = 'push.register';
  static const devicesList = 'devices.list';

  static const channelsList = 'channels.list';
  static const channelsCreate = 'channels.create';
  static const channelsUpdate = 'channels.update';
  static const channelsRead = 'channels.read';
  static const channelsPin = 'channels.pin';
  static const messagesList = 'messages.list';
  static const messagesPost = 'messages.post';
  static const messagesReact = 'messages.react';
  static const messagesDelete = 'messages.delete';
  static const filesGet = 'files.get';
}

/// Events (relayd → client), sent as JSON-RPC notifications.
abstract final class E {
  /// `{entity: {kind, data}}` after any record changes.
  static const entity = 'entity.changed';

  /// `{runId, events: [RunEvent…]}`, batched (≤ 30 per second per client).
  static const runEvents = 'run.events';

  /// `{termId, data(base64)}`, batched.
  static const termOutput = 'term.output';

  /// `{termId, code}`.
  static const termExit = 'term.exit';

  /// `{root, paths}` files changed in a watched worktree.
  static const fsChanged = 'fs.changed';

  /// `{agents: [...]}` live slot use and limits.
  static const agentState = 'agent.state';

  /// `{text, level}` something the user should see (toast).
  static const notice = 'notice';

  /// sync.status's shape, after every sync pass.
  static const syncState = 'sync.state';

  /// `{kind, title, body, taskId?, channelId?, messageId?}` worth a system
  /// notification: kind is ask, review, failed, mention or consent.
  static const notify = 'notify';
}

/// Where relayd keeps its socket, database and state.
class RelayPaths {
  RelayPaths(this.home, {this.runtimeDir});

  /// Linux's per-user `XDG_RUNTIME_DIR`, a private place for the socket
  /// when the home path is too long for one.

  /// `$RELAY_HOME`, or the platform's per-user app data folder.
  factory RelayPaths.resolve([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final override = e['RELAY_HOME'];
    if (override != null && override.isNotEmpty) return RelayPaths(override);
    if (Platform.isWindows) {
      // USERPROFILE first: Git Bash sets a HOME of its own.
      final home = e['USERPROFILE'] ?? e['HOME'] ?? '.';
      return RelayPaths('${e['APPDATA'] ?? '$home\\AppData\\Roaming'}\\Relay');
    }
    final home = e['HOME'] ?? '.';
    if (Platform.isMacOS) return RelayPaths('$home/Library/Application Support/Relay');
    final xdg = e['XDG_DATA_HOME'];
    return RelayPaths('${xdg ?? '$home/.local/share'}/relay', runtimeDir: e['XDG_RUNTIME_DIR']);
  }

  final String home;
  final String? runtimeDir;

  String _join(String name) => '$home${Platform.pathSeparator}$name';

  /// The Unix socket path. macOS and Linux cap these at about 104 bytes,
  /// so a long home folder falls back to a short path in /tmp named after
  /// it. The socket still needs the token from daemon.json (mode 0600).
  String get socket {
    final p = '$home/relay.sock';
    if (utf8.encode(p).length <= 100) return p;
    var h = 0x811c9dc5;
    for (final b in utf8.encode(home)) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    final dir = runtimeDir != null && runtimeDir!.isNotEmpty ? runtimeDir! : '/tmp';
    return '$dir/relay-${h.toRadixString(16)}.sock';
  }

  String get database => _join('relay.db');

  /// `{pid, version, protocol, socket|port, token, startedAt}` written by relayd.
  String get daemonInfo => _join('daemon.json');
  String get workspaces => _join('workspaces');
  String get logs => _join('logs');

  /// Whether this OS uses a Unix socket (else loopback TCP + token).
  static bool get usesUnixSocket => !Platform.isWindows;
}

/// What relayd writes to [RelayPaths.daemonInfo] so clients can find it.
class DaemonInfo {
  DaemonInfo({
    required this.pid,
    required this.version,
    required this.protocol,
    required this.token,
    this.socket,
    this.port,
    required this.startedAt,
  });

  factory DaemonInfo.fromJson(Map<String, Object?> j) => DaemonInfo(
    pid: (j['pid'] as num).toInt(),
    version: j['version'] as String,
    protocol: (j['protocol'] as num).toInt(),
    token: j['token'] as String,
    socket: j['socket'] as String?,
    port: (j['port'] as num?)?.toInt(),
    startedAt: DateTime.parse(j['startedAt'] as String),
  );

  static DaemonInfo? read(RelayPaths paths) {
    try {
      final f = File(paths.daemonInfo);
      if (!f.existsSync()) return null;
      return DaemonInfo.fromJson((jsonDecode(f.readAsStringSync()) as Map).cast());
    } catch (_) {
      return null;
    }
  }

  final int pid;
  final String version;
  final int protocol;
  final String token;
  final String? socket;
  final int? port;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'version': version,
    'protocol': protocol,
    'token': token,
    'socket': ?socket,
    'port': ?port,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };
}
