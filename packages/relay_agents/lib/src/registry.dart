import 'dart:convert';
import 'dart:io';

import 'adapter.dart';
import 'claude.dart';
import 'codex.dart';
import 'generic.dart';

/// The user's login-shell environment.
///
/// Apps started from the Dock get a minimal PATH, so CLIs installed with
/// nvm, Homebrew or pipx are invisible. relayd asks the login shell once.
class ShellEnv {
  static Map<String, String>? _cached;

  static Future<Map<String, String>> resolve() async {
    if (_cached != null) return _cached!;
    final env = Map.of(Platform.environment);
    if (Platform.isMacOS || Platform.isLinux) {
      final shell = env['SHELL'] ?? '/bin/zsh';
      try {
        final r = await Process.run(shell, ['-ilc', r'printf "__RELAY_PATH__%s" "$PATH"'])
            .timeout(const Duration(seconds: 5));
        final out = r.stdout as String;
        final i = out.lastIndexOf('__RELAY_PATH__');
        if (i >= 0) env['PATH'] = out.substring(i + 14).trim();
      } catch (_) {}
      final home = env['HOME'] ?? '';
      final extra = ['$home/.local/bin', '/opt/homebrew/bin', '/usr/local/bin', '$home/.bun/bin', '$home/.cargo/bin'];
      final parts = (env['PATH'] ?? '').split(':');
      for (final e in extra) {
        if (!parts.contains(e)) parts.add(e);
      }
      env['PATH'] = parts.where((s) => s.isNotEmpty).join(':');
    }
    return _cached = env;
  }

  /// Finds [name] on [path] (colon or semicolon separated).
  static String? which(String name, String path) {
    final sep = Platform.isWindows ? ';' : ':';
    final exts = Platform.isWindows ? ['.exe', '.cmd', '.bat', ''] : [''];
    for (final dir in path.split(sep)) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final f = File('$dir${Platform.pathSeparator}$name$ext');
        if (f.existsSync()) {
          if (Platform.isWindows) return f.path;
          final mode = f.statSync().mode;
          if (mode & 0x49 != 0) return f.path; // any execute bit
        }
      }
    }
    return null;
  }
}

/// All adapters Relay knows about.
class AgentRegistry {
  AgentRegistry({List<AgentAdapter>? adapters})
    : adapters = {
        for (final a in adapters ??
            [ClaudeCodeAdapter(), CodexAdapter(), geminiAdapter(), openCodeAdapter(), aiderAdapter()])
          a.id: a,
      };

  final Map<String, AgentAdapter> adapters;

  AgentAdapter? operator [](String id) => adapters[id];

  /// Looks for every known CLI on the login-shell PATH and asks its version.
  Future<List<DetectedAgent>> detect({Map<String, String>? env}) async {
    final e = env ?? await ShellEnv.resolve();
    final found = <DetectedAgent>[];
    for (final a in adapters.values) {
      for (final bin in a.binaries) {
        final path = ShellEnv.which(bin, e['PATH'] ?? '');
        if (path == null) continue;
        String? version;
        try {
          final r = await Process.run(path, ['--version'], environment: e).timeout(const Duration(seconds: 8));
          version = '${r.stdout}'.trim().split('\n').first;
          if (version.isEmpty) version = null;
        } catch (_) {}
        found.add(DetectedAgent(adapter: a.id, binaryPath: path, version: version));
        break;
      }
    }
    return found;
  }
}

/// Encodes an MCP config file that gives an agent the `relay` tools.
String mcpConfigJson({required String relayBinary, required String runId, required String socket}) => jsonEncode({
  'mcpServers': {
    'relay': {
      'command': relayBinary,
      'args': ['mcp', '--run', runId],
      'env': {'RELAY_SOCKET': socket},
    },
  },
});
