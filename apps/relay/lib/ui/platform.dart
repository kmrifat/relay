import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:path/path.dart' as p;

/// Desktop differences between macOS, Windows and Linux (M10), in one place.
abstract final class Desk {
  static bool get isMac => Platform.isMacOS;

  /// "Mac", "PC" or "computer", for "on this Mac" and friends.
  static String get computer => Platform.isMacOS ? 'Mac' : (Platform.isWindows ? 'PC' : 'computer');
  static String get thisComputer => 'this $computer';

  /// ⌘ on the Mac, Ctrl elsewhere.
  static SingleActivator key(LogicalKeyboardKey k, {bool shift = false}) =>
      SingleActivator(k, meta: isMac, control: !isMac, shift: shift);

  /// The terminal's shell, for labels: zsh, bash, PowerShell.
  static String get shellName {
    if (Platform.isWindows) return 'PowerShell';
    final s = Platform.environment['SHELL'];
    return s == null || s.isEmpty ? (Platform.isMacOS ? 'zsh' : 'bash') : p.basename(s);
  }

  /// The home folder shown as `~`.
  static String tilde(String path) {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null || home.isEmpty || !path.startsWith(home)) return path;
    return '~${path.substring(home.length)}';
  }

  /// The last part of a path, on any OS.
  static String base(String path) => p.basename(path.replaceAll(RegExp(r'[\\/]+$'), ''));

  /// Opens a file, folder or URL with the system's default app.
  static Future<void> open(String target) async {
    if (Platform.isMacOS) {
      await Process.run('open', [target]);
    } else if (Platform.isWindows) {
      await Process.run('explorer.exe', [target]);
    } else {
      await Process.run('xdg-open', [target]);
    }
  }

  /// Editors offered for "Open in…", by name → how to start them here.
  static const editors = ['Visual Studio Code', 'Cursor', 'Zed'];
  static String get fileManager => Platform.isMacOS ? 'Finder' : (Platform.isWindows ? 'Explorer' : 'Files');

  /// Opens [folder] in [app] (an editor above, or [fileManager]).
  static Future<ProcessResult> openIn(String app, String folder) {
    if (app == fileManager) {
      return Platform.isMacOS
          ? Process.run('open', [folder])
          : Platform.isWindows
          ? Process.run('explorer.exe', [folder])
          : Process.run('xdg-open', [folder]);
    }
    if (Platform.isMacOS) return Process.run('open', ['-a', app, folder]);
    final cli = switch (app) { 'Visual Studio Code' => 'code', 'Cursor' => 'cursor', 'Zed' => 'zed', _ => app.toLowerCase() };
    // The editors install .cmd launchers on Windows; cmd resolves them.
    return Platform.isWindows ? Process.run('cmd', ['/c', cli, folder]) : Process.run(cli, [folder]);
  }
}
