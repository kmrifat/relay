import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:relay_daemon/relay_daemon.dart' show MobileHost;
import 'package:relay_protocol/relay_protocol.dart';

/// The phone UI (iOS, or `RELAY_MOBILE=1` on a Mac for development).
bool get isMobile => Platform.isIOS || Platform.environment['RELAY_MOBILE'] == '1';

/// Finds relayd, starts it if needed, and connects.
///
/// In a release build relayd lives at `Relay.app/Contents/Helpers/relay`
/// (embedded by tool/build_relay_helper.sh). It is started detached so it
/// keeps running, with its agents, after the window closes.
class DaemonLauncher {
  DaemonLauncher({RelayPaths? paths}) : paths = paths ?? RelayPaths.resolve();

  final RelayPaths paths;

  /// Where relayd and relay-pty live: `$RELAY_HELPERS`, else macOS's
  /// `Relay.app/Contents/Helpers`, else `helpers/` next to the app's
  /// executable (Windows and Linux bundles, M10).
  String? get helpersDir {
    final env = Platform.environment['RELAY_HELPERS'];
    if (env != null && Directory(env).existsSync()) return env;
    final exe = File(Platform.resolvedExecutable);
    for (final dir in [p.join(exe.parent.parent.path, 'Helpers'), p.join(exe.parent.path, 'helpers')]) {
      if (Directory(dir).existsSync()) return dir;
    }
    return null;
  }

  static String get _exe => Platform.isWindows ? '.exe' : '';

  String? get relayBinary {
    final dir = helpersDir;
    final bin = dir == null ? null : p.join(dir, 'relay$_exe');
    return bin != null && File(bin).existsSync() ? bin : null;
  }

  /// Connects, starting relayd first when nothing answers.
  /// On a phone, Relay runs in-process (no daemon, no agents): see
  /// [MobileHost]. One per app.
  static MobileHost? mobile;
  static RelayClient? _mobileClient;

  Future<RelayClient> connect({void Function(String)? onStatus}) async {
    if (isMobile) {
      if (_mobileClient != null) return _mobileClient!;
      final home = Platform.environment['RELAY_HOME'] ?? p.join((await getApplicationSupportDirectory()).path, 'relay');
      mobile = MobileHost(RelayPaths(home));
      return _mobileClient = await mobile!.start();
    }
    try {
      return await RelayClient.connect(paths);
    } catch (_) {}
    final bin = relayBinary;
    if (bin == null) {
      throw StateError('relayd is not running and no relay binary was found in the app bundle. '
          'Run `tool/build_relay_helper.sh tool/out` and `tool/out/relay daemon`.');
    }
    onStatus?.call('Starting relayd…');
    Directory(paths.home).createSync(recursive: true);
    await Process.start(
      bin,
      ['daemon'],
      mode: ProcessStartMode.detached,
      environment: {'RELAY_PTY': p.join(p.dirname(bin), 'relay-pty$_exe')},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    Object? last;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        return await RelayClient.connect(paths);
      } catch (e) {
        last = e;
      }
    }
    throw StateError('relayd did not start: $last');
  }
}
