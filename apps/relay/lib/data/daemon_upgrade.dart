import 'dart:async';
import 'dart:io';

import 'package:relay_daemon/relay_daemon.dart' show relayVersion;
import 'package:relay_protocol/relay_protocol.dart';

import 'daemon_launcher.dart';
import 'login_item.dart';

/// relayd outlives the app, so after an update the previous version's
/// relayd is still the one answering, without the new version's methods.
/// The app replaces it with the bundled one: stopped with `shutdown`
/// (SIGTERM before 0.1.2), then started again by whoever started it.

/// What starts relayd at login and would restart it: the LaunchAgent that
/// SMAppService registered (macOS) or the systemd user unit (Linux). The
/// Windows Run entry only starts it at login, so it counts as neither.
enum ServiceManager { launchd, systemd }

/// An older relayd than this app's, and a newer bundled one to replace it.
class DaemonUpgrade {
  const DaemonUpgrade({required this.running, required this.bundled, required this.pid});
  final String running;
  final String bundled;
  final int pid;
}

/// The parts of replacing relayd that touch the system (a fake in tests).
abstract class DaemonHost {
  /// `relay version` of the bundled helper; null without one.
  Future<String?> bundledVersion();

  /// The service manager that started relayd [pid], if any.
  Future<ServiceManager?> managerOf(int pid);

  /// SIGTERM, for a relayd from before `shutdown`.
  Future<void> terminate(int pid);

  /// Whether relayd [pid] is gone: nothing answers on its socket or port as
  /// [pid], and the process has exited.
  Future<bool> isGone(int pid);

  /// Starts the bundled relayd: through [via] when that is what manages
  /// it, so there is one relayd and it is the service manager's, else detached.
  Future<void> start(ServiceManager? via);

  /// Connects to the relayd that [start] started.
  Future<RelayClient> connect();
}

class DaemonUpdater {
  DaemonUpdater(
    this.host, {
    this.appVersion = relayVersion,
    this.pollEvery = const Duration(milliseconds: 200),
    this.stopTimeout = const Duration(seconds: 20),
  });

  final DaemonHost host;
  final String appVersion;
  final Duration pollEvery;
  final Duration stopTimeout;

  /// An upgrade when [c]'s relayd is older than this app and the bundled
  /// helper is newer than it. Never a downgrade, and nothing for a relayd
  /// whose version doesn't parse.
  Future<DaemonUpgrade?> check(RelayClient c) async {
    final running = c.hello['version'] as String? ?? '';
    final pid = (c.hello['pid'] as num?)?.toInt();
    if (pid == null || (compareVersions(running, appVersion) ?? 0) >= 0) return null;
    // A stale helper (a dev build, an update that didn't replace it) would
    // restart into the same old relayd.
    final bundled = await host.bundledVersion();
    if (bundled == null || (compareVersions(bundled, running) ?? 0) <= 0) return null;
    return DaemonUpgrade(running: running, bundled: bundled, pid: pid);
  }

  /// Agent runs [c]'s relayd is running; stopping relayd stops them.
  static Future<int> activeRuns(RelayClient c) async =>
      (await c.list(M.runsList, {'active': true})).where((r) => r['live'] == true).length;

  /// Stops [c]'s relayd, waits for it to go, and starts the bundled one.
  /// Without [force], throws [RpcError.busy] while agent runs are active
  /// and leaves relayd as it was. [onStopping] is called once relayd has
  /// agreed to stop (its connection closes next).
  Future<RelayClient> restart(RelayClient c, DaemonUpgrade u, {bool force = false, void Function()? onStopping}) async {
    if (!force) {
      final n = await activeRuns(c);
      if (n > 0) throw _busy(n);
    }
    // Asked before stopping: afterwards there is no pid to match.
    final manager = await host.managerOf(u.pid);
    try {
      await c.call(M.shutdown, {'force': force});
    } on RpcError catch (e) {
      if (e.code != RpcError.methodNotFound) rethrow;
      // Before 0.1.2: SIGTERM stops it the same way. Runs were checked above;
      // the window since is too short to matter.
      await host.terminate(u.pid);
    } on StateError {
      // The connection closed before the answer: it is stopping anyway.
    }
    onStopping?.call();
    await c.close();
    final end = DateTime.now().add(stopTimeout);
    while (!await host.isGone(u.pid)) {
      if (DateTime.now().isAfter(end)) throw StateError('relayd ${u.running} (pid ${u.pid}) did not stop');
      await Future<void>.delayed(pollEvery);
    }
    await host.start(manager);
    return host.connect();
  }

  static RpcError _busy(int n) =>
      RpcError(RpcError.busy, '$n agent run${n == 1 ? ' is' : 's are'} active; stopping relayd stops them.', {'activeRuns': n});
}

/// [DaemonHost] for real: the bundled helper, launchctl, systemctl.
class SystemDaemonHost implements DaemonHost {
  SystemDaemonHost(this.launcher);

  final DaemonLauncher launcher;

  /// The LaunchAgent's label (macos/Runner/com.binarycastle.relay.daemon.plist).
  static const launchdLabel = 'com.binarycastle.relay.daemon';

  @override
  Future<String?> bundledVersion() async {
    final bin = launcher.relayBinary;
    if (bin == null) return null;
    try {
      final r = await Process.run(bin, ['version']).timeout(const Duration(seconds: 10));
      return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ServiceManager?> managerOf(int pid) async {
    try {
      if (Platform.isMacOS) {
        final r = await Process.run('launchctl', ['list', launchdLabel]);
        final m = RegExp(r'"PID"\s*=\s*(\d+);').firstMatch('${r.stdout}');
        return r.exitCode == 0 && m?.group(1) == '$pid' ? ServiceManager.launchd : null;
      }
      if (Platform.isLinux) {
        // An AppImage's AppRun execs relayd, so MainPID is relayd here too.
        final r = await Process.run('systemctl', ['--user', 'show', '-p', 'MainPID', '--value', DesktopLoginItem.unit]);
        return r.exitCode == 0 && '${r.stdout}'.trim() == '$pid' ? ServiceManager.systemd : null;
      }
    } on ProcessException {
      return null;
    }
    return null;
  }

  @override
  Future<void> terminate(int pid) async => Process.killPid(pid, ProcessSignal.sigterm);

  @override
  Future<bool> isGone(int pid) async {
    try {
      final c = await RelayClient.connect(launcher.paths, client: 'probe', timeout: const Duration(milliseconds: 500));
      final same = (c.hello['pid'] as num?)?.toInt() == pid;
      await c.close();
      // Another relayd already answering (a service manager was quicker)
      // means this one is gone.
      if (same) return false;
    } catch (_) {}
    return !await _alive(pid);
  }

  static Future<bool> _alive(int pid) async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        return RegExp('\\b$pid\\b').hasMatch('${r.stdout}');
      }
      return (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<void> start(ServiceManager? via) async {
    try {
      switch (via) {
        case ServiceManager.launchd:
          // relayd exited 0, so KeepAlive (SuccessfulExit false) leaves it
          // stopped; kickstart runs the agent's program, this bundle's helper.
          final uid = '${(await Process.run('id', ['-u'])).stdout}'.trim();
          if ((await Process.run('launchctl', ['kickstart', 'gui/$uid/$launchdLabel'])).exitCode == 0) return;
        case ServiceManager.systemd:
          // Point the unit at this version's binary (or AppImage) first.
          final bin = launcher.relayBinary;
          if (bin != null && await DesktopLoginItem.status() == 'enabled') await DesktopLoginItem.set(true, relayBinary: bin);
          if ((await Process.run('systemctl', ['--user', 'start', DesktopLoginItem.unit])).exitCode == 0) return;
        case null:
      }
    } catch (_) {
      // Fall back to starting it ourselves, as when nothing manages it.
    }
    await launcher.startDetached();
  }

  @override
  Future<RelayClient> connect() => launcher.waitForDaemon();
}
