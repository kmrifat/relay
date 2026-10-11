import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_protocol/relay_protocol.dart';

/// Finds relayd, starts it if needed, and connects.
///
/// In a release build relayd lives at `Relay.app/Contents/Helpers/relay`
/// (embedded by tool/build_relay_helper.sh). It is started detached so it
/// keeps running, with its agents, after the window closes.
class DaemonLauncher {
  DaemonLauncher({RelayPaths? paths}) : paths = paths ?? RelayPaths.resolve();

  final RelayPaths paths;

  /// `Contents/Helpers` next to the app's executable, or `$RELAY_HELPERS`.
  String? get helpersDir {
    final env = Platform.environment['RELAY_HELPERS'];
    if (env != null && Directory(env).existsSync()) return env;
    final exe = File(Platform.resolvedExecutable);
    final helpers = p.join(exe.parent.parent.path, 'Helpers');
    if (Directory(helpers).existsSync()) return helpers;
    return null;
  }

  String? get relayBinary {
    final dir = helpersDir;
    if (dir != null && File(p.join(dir, 'relay')).existsSync()) return p.join(dir, 'relay');
    return null;
  }

  /// Connects, starting relayd first when nothing answers.
  Future<RelayClient> connect({void Function(String)? onStatus}) async {
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
      environment: {'RELAY_PTY': p.join(p.dirname(bin), 'relay-pty')},
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
