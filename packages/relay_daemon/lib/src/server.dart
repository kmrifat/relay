import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:relay_agents/relay_agents.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_git/relay_git.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'api.dart';
import 'context.dart';
import 'repo_inspect.dart';
import 'channels.dart';
import 'notifier.dart';
import 'supervisor.dart';
import 'sync_service.dart';
import 'terminals.dart';
import 'workspaces.dart';

const relayVersion = '0.1.2';

class AlreadyRunning implements Exception {
  AlreadyRunning(this.pid);
  final int pid;
  @override
  String toString() => 'relayd is already running (pid $pid)';
}

/// The Demo agent speaks Claude Code's protocol through `relay demo-agent`.
class DemoAdapter extends ClaudeCodeAdapter {
  @override
  String get id => 'demo';
  @override
  String get name => 'Demo agent';
  @override
  List<String> get binaries => const [];
  @override
  String get color => '#0A64D8';
  @override
  String get letter => 'D';

  @override
  Future<AgentSession> start(RunSpec spec) async {
    final process = await Process.start(
      spec.binary ?? Platform.resolvedExecutable,
      ['demo-agent', ...ClaudeCodeAdapter.argsFor(spec)],
      workingDirectory: spec.cwd,
      environment: spec.environment,
    );
    final s = ClaudeSession(process);
    s.sendUser(spec.prompt);
    return s;
  }
}

/// relayd: owns the store, agents, terminals, and the local socket.
class RelayDaemon {
  RelayDaemon(this.paths, {this.relayBinary, this.ptyHelper, this.detectOnStart = true, this.resolveShellEnv = true});

  final RelayPaths paths;
  final String? relayBinary;
  final String? ptyHelper;
  final bool detectOnStart;
  final bool resolveShellEnv;

  late final DaemonContext ctx;
  late final Supervisor supervisor;
  late final Workspaces workspaces;
  late final Terminals terminals;
  late final SyncService sync;
  late final Channels channels;
  late final Notifier notifier;
  Timer? _statsTimer;
  late final Api api;
  ServerSocket? _server;
  final _clients = <_Client>{};
  late final String token;
  final startedAt = DateTime.now();
  final _stopped = Completer<void>();

  Future<void> get stopped => _stopped.future;

  Future<void> start() async {
    Directory(paths.home).createSync(recursive: true);
    if (!Platform.isWindows) await Process.run('chmod', ['700', paths.home]);
    await _ensureSingleInstance();

    final deviceFile = File('${paths.home}${Platform.pathSeparator}device-id');
    if (!deviceFile.existsSync()) deviceFile.writeAsStringSync(newToken(12));
    final deviceId = deviceFile.readAsStringSync().trim();

    final store = Store.open(paths.database, deviceId: deviceId);
    final registry = AgentRegistry(adapters: [
      ClaudeCodeAdapter(),
      CodexAdapter(),
      geminiAdapter(),
      openCodeAdapter(),
      aiderAdapter(),
      DemoAdapter(),
    ]);
    ctx = DaemonContext(
      paths: paths,
      store: store,
      deviceId: deviceId,
      registry: registry,
      git: Git(),
      version: relayVersion,
      relayBinary: relayBinary,
      ptyHelper: ptyHelper,
    );
    if (resolveShellEnv) ctx.env = await ShellEnv.resolve();
    workspaces = Workspaces(ctx);
    supervisor = Supervisor(ctx, workspaces);
    terminals = Terminals(ctx);
    sync = SyncService(ctx);
    supervisor.sync = sync;
    channels = Channels(ctx, sync);
    notifier = Notifier(ctx)..onNotify = sync.pushToPhones;
    api = Api(ctx, supervisor, workspaces, terminals, sync, channels, startedAt: startedAt);
    sync.live.onCommand = api.invoke;
    sync.agentStats = () {
      final usage = supervisor.usageToday();
      return {
        for (final a in store.list<AgentProfile>(Kind.agent))
          a.id: {'active': supervisor.activeRuns(a.id), 'costToday': usage[a.id]?['costUsd'] ?? 0, 'limitedUntil': a.data['limitedUntil']},
      };
    };
    ensureDemoAgent(ctx);
    if (detectOnStart) {
      try {
        await detectAgents(ctx);
      } catch (_) {}
    }

    token = newToken(32);
    if (RelayPaths.usesUnixSocket) {
      final sock = File(paths.socket);
      if (sock.existsSync()) sock.deleteSync();
      _server = await ServerSocket.bind(InternetAddress(paths.socket, type: InternetAddressType.unix), 0);
    } else {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server!.listen(_accept);
    File(paths.daemonInfo).writeAsStringSync(jsonEncode(DaemonInfo(
      pid: pid,
      version: relayVersion,
      protocol: protocolVersion,
      token: token,
      socket: RelayPaths.usesUnixSocket ? paths.socket : null,
      port: RelayPaths.usesUnixSocket ? null : _server!.port,
      startedAt: startedAt,
    ).toJson()));
    if (!Platform.isWindows) {
      // daemon.json holds the token; only this user may read it.
      await Process.run('chmod', ['600', paths.daemonInfo]);
      if (RelayPaths.usesUnixSocket) await Process.run('chmod', ['600', paths.socket]);
    } else {
      // Windows: drop inherited access; only this user (and SYSTEM) may read it.
      final user = Platform.environment['USERNAME'];
      if (user != null) {
        await Process.run('icacls', [paths.daemonInfo, '/inheritance:r', '/grant:r', '$user:F', '/grant:r', 'SYSTEM:F']);
      }
    }

    supervisor.startScheduler();
    sync.start();
    channels.start();
    // Agent numbers on this device's record (the phone's Agents screen),
    // at most every 5 s.
    ctx.broadcasts.where((b) => b.$1 == E.agentState).listen((_) {
      _statsTimer ??= Timer(const Duration(seconds: 5), () {
        _statsTimer = null;
        sync.publishDevice();
      });
    });
    notifier.start();
    _wireEvents();
  }

  Future<void> _ensureSingleInstance() async {
    final info = DaemonInfo.read(paths);
    if (info == null) return;
    try {
      final c = await RelayClient.connect(paths, client: 'probe', timeout: const Duration(milliseconds: 800));
      await c.close();
      throw AlreadyRunning(info.pid);
    } on AlreadyRunning {
      rethrow;
    } catch (_) {
      // Stale daemon.json / socket: the previous relayd is gone.
    }
  }

  void _accept(Socket socket) {
    final peer = RpcPeer(socket, socket, name: 'client');
    final client = _Client(peer);
    var authed = false;
    peer.registerMethod(M.hello, (p) {
      if (p['token'] != token) throw RpcError(RpcError.unauthorized, 'Bad token');
      if (!authed) {
        authed = true;
        client.name = p['client'] as String? ?? 'client';
        api.register(peer);
        // Local clients only: not in Api.handlers, so a paired phone can't.
        peer.registerMethod(M.shutdown, _shutdown);
        _clients.add(client);
      }
      return {
        'version': relayVersion,
        'protocol': protocolVersion,
        'deviceId': ctx.deviceId,
        'pid': pid,
        'userName': ctx.setting('userName', 'You'),
      };
    });
    peer.done.then((_) {
      _clients.remove(client);
      client.dispose();
    });
  }

  /// An updated app replacing this relayd: answer, then stop. Stopping
  /// stops agent runs, so that needs `force`.
  Map<String, Object?> _shutdown(Map<String, Object?> p) {
    final active = supervisor.totalActive;
    if (active > 0 && p['force'] != true) {
      throw RpcError(RpcError.busy, '$active agent run${active == 1 ? ' is' : 's are'} active; stopping relayd stops them.', {'activeRuns': active});
    }
    // After the answer is written; stop() closes every connection.
    Timer.run(stop);
    return {'pid': pid, 'version': relayVersion, 'stoppedRuns': active};
  }

  void _wireEvents() {
    ctx.store.changes.listen((c) {
      for (final client in _clients) {
        client.queueEntity(c.entity);
      }
    });
    ctx.store.runEvents.listen((e) {
      for (final client in _clients) {
        client.queueRunEvent(e);
      }
    });
    ctx.notices.listen((n) {
      for (final client in _clients) {
        client.peer.notify(E.notice, n);
      }
    });
    ctx.broadcasts.listen((b) {
      for (final client in _clients) {
        client.peer.notify(b.$1, b.$2);
      }
    });
  }

  Future<void>? _stopping;

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    await supervisor.dispose();
    await sync.dispose();
    await channels.dispose();
    await notifier.dispose();
    await terminals.dispose();
    for (final c in _clients.toList()) {
      await c.peer.close();
    }
    await _server?.close();
    try {
      File(paths.daemonInfo).deleteSync();
    } catch (_) {}
    if (RelayPaths.usesUnixSocket) {
      try {
        File(paths.socket).deleteSync();
      } catch (_) {}
    }
    ctx.store.close();
    _stopped.complete();
  }
}

/// One connected client, with its outgoing event batches.
class _Client {
  _Client(this.peer);

  final RpcPeer peer;
  String name = 'client';
  final _entities = <String, Entity>{};
  final _runEvents = <String, List<RunEvent>>{};
  Timer? _flush;

  void queueEntity(Entity e) {
    _entities['${e.kind}:${e.id}'] = e;
    _schedule();
  }

  void queueRunEvent(RunEvent e) {
    (_runEvents[e.runId] ??= []).add(e);
    _schedule();
  }

  /// At most ~30 flushes a second, whatever the agents are doing.
  void _schedule() => _flush ??= Timer(const Duration(milliseconds: 33), _send);

  void _send() {
    _flush = null;
    if (peer.isClosed) return;
    if (_entities.isNotEmpty) {
      peer.notify(E.entity, {
        'items': [for (final e in _entities.values) {'kind': e.kind, 'data': e.toJson()}],
      });
      _entities.clear();
    }
    for (final MapEntry(:key, :value) in _runEvents.entries) {
      peer.notify(E.runEvents, {'runId': key, 'events': [for (final e in value) e.toJson()]});
    }
    _runEvents.clear();
  }

  void dispose() => _flush?.cancel();
}
