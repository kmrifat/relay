import 'dart:io';

import 'package:path/path.dart' as p;

/// relayd at login on Linux and Windows (M10-05); macOS uses SMAppService
/// (M9-02, SystemBridge). Status strings match the Mac's: enabled, off,
/// unsupported.
///
/// - Linux: a systemd user unit, `~/.config/systemd/user/relayd.service`,
///   enabled with `systemctl --user` (it starts at the next login; the
///   running relayd carries on).
/// - Windows: a per-user Run entry starting `relay.exe daemon --detach`,
///   which relaunches itself without a console window.
abstract final class DesktopLoginItem {
  static const unit = 'relayd.service';
  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const runValue = 'RelayDaemon';

  static String get _unitPath {
    final config = Platform.environment['XDG_CONFIG_HOME'] ?? p.join(Platform.environment['HOME'] ?? '', '.config');
    return p.join(config, 'systemd', 'user', unit);
  }

  static Future<String> status() async {
    try {
      if (Platform.isLinux) {
        final r = await Process.run('systemctl', ['--user', 'is-enabled', unit]);
        return '${r.stdout}'.trim() == 'enabled' ? 'enabled' : 'off';
      }
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', runKey, '/v', runValue]);
        return r.exitCode == 0 ? 'enabled' : 'off';
      }
    } on ProcessException {
      return 'unsupported';
    }
    return 'unsupported';
  }

  /// Turns it on or off for [relayBinary] (the bundle's helpers/relay).
  static Future<String> set(bool on, {required String relayBinary}) async {
    if (Platform.isLinux) {
      if (on) {
        File(_unitPath)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('''
[Unit]
Description=Relay daemon (relayd): runs your coding agents' queued work
After=network-online.target

[Service]
ExecStart="$relayBinary" daemon
Restart=on-failure

[Install]
WantedBy=default.target
''');
        await _ok(Process.run('systemctl', ['--user', 'daemon-reload']));
        await _ok(Process.run('systemctl', ['--user', 'enable', unit]));
      } else {
        await Process.run('systemctl', ['--user', 'disable', unit]);
        final f = File(_unitPath);
        if (f.existsSync()) f.deleteSync();
        await Process.run('systemctl', ['--user', 'daemon-reload']);
      }
    } else if (Platform.isWindows) {
      if (on) {
        await _ok(Process.run('reg', ['add', runKey, '/v', runValue, '/t', 'REG_SZ', '/d', '"$relayBinary" daemon --detach', '/f']));
      } else {
        await Process.run('reg', ['delete', runKey, '/v', runValue, '/f']);
      }
    } else {
      return 'unsupported';
    }
    return status();
  }

  static Future<void> _ok(Future<ProcessResult> f) async {
    final r = await f;
    if (r.exitCode != 0) throw ProcessException('', const [], '${r.stderr}'.trim(), r.exitCode);
  }
}
