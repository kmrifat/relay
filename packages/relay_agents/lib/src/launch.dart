import 'dart:async';
import 'dart:io';

/// Starting agent CLIs and their process trees the same way on macOS, Linux
/// and Windows (M10-01).
///
/// Windows has two traps. npm installs CLIs as `.cmd` shims, and
/// `CreateProcess` runs a `.cmd` through cmd.exe, which re-parses the
/// arguments (quotes, `%`, `^`, newlines: the "BatBadBut" class). And
/// signals don't exist: `Process.kill` terminates. So:
/// - an npm shim is resolved to `node.exe <script>`, which takes argv as is;
/// - any other `.cmd`/`.bat` goes through cmd.exe with every argument
///   escaped, and an argument cmd.exe can't carry (a newline) is refused;
/// - stopping kills the whole tree (`taskkill /T`); pausing isn't offered.
abstract final class Launch {
  /// The executable and arguments that run [binary] with [args].
  static (String, List<String>) command(String binary, List<String> args, {Map<String, String>? environment}) {
    if (!Platform.isWindows) return (binary, args);
    final lower = binary.toLowerCase();
    if (!lower.endsWith('.cmd') && !lower.endsWith('.bat')) return (binary, args);
    final shim = npmShimTarget(binary, environment: environment);
    if (shim != null) return (shim.$1, [...shim.$2, ...args]);
    for (final a in args) {
      if (a.contains('\n') || a.contains('\r')) {
        throw ArgumentError('${File(binary).uri.pathSegments.last} is a batch file, which can\'t take a multi-line argument. '
            'Install the CLI with npm (or as an .exe), or put the text in a file.');
      }
    }
    final comspec = environment?['ComSpec'] ?? Platform.environment['ComSpec'] ?? r'C:\Windows\System32\cmd.exe';
    return (comspec, ['/d', '/s', '/c', '"${[cmdQuote(binary), ...args.map(cmdQuote)].join(' ')}"']);
  }

  static Future<Process> start(
    String binary,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    final (exe, argv) = command(binary, args, environment: environment);
    return Process.start(exe, argv, workingDirectory: workingDirectory, environment: environment);
  }

  static Future<ProcessResult> run(String binary, List<String> args, {Map<String, String>? environment}) {
    final (exe, argv) = command(binary, args, environment: environment);
    return Process.run(exe, argv, environment: environment);
  }

  /// npm's `.cmd` shim runs `"%_prog%" "%dp0%\node_modules\…\cli.js" %*`.
  /// Returns (node, [script]) for it, or null when it isn't one.
  static (String, List<String>)? npmShimTarget(String shimPath, {Map<String, String>? environment}) {
    final String text;
    try {
      text = File(shimPath).readAsStringSync();
    } catch (_) {
      return null;
    }
    final m = RegExp(r'"%(?:dp0|~dp0)%?\\?([^"]+\.(?:js|cjs|mjs))"', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final dir = File(shimPath).parent.path;
    final sep = Platform.pathSeparator;
    final rel = m.group(1)!.replaceAll(RegExp(r'[\\/]+'), sep).replaceFirst(RegExp(r'^[\\/]'), '');
    final script = '$dir$sep$rel';
    if (!File(script).existsSync()) return null;
    final local = File('$dir${sep}node.exe');
    final node = local.existsSync() ? local.path : (which('node', pathOf(environment ?? Platform.environment)) ?? 'node.exe');
    return (node, [script]);
  }

  /// One argument for cmd.exe /s /c "…": quoted for the program's own
  /// parser, then every cmd metacharacter escaped with ^ (cross-spawn's
  /// approach).
  static String cmdQuote(String arg) {
    // MSVCRT quoting: backslashes before a quote double, quotes escape.
    var s = arg.replaceAllMapped(RegExp(r'(\\*)"'), (m) => '${m[1]!}${m[1]!}\\"');
    s = s.replaceAllMapped(RegExp(r'(\\*)$'), (m) => '${m[1]!}${m[1]!}');
    s = '"$s"';
    return s.replaceAllMapped(RegExp(r'[()\][%!^"`<>&|;, *?]'), (m) => '^${m[0]}');
  }

  /// PATH from an environment map, whatever its case (Windows says `Path`).
  static String pathOf(Map<String, String> env) {
    if (env['PATH'] != null) return env['PATH']!;
    for (final e in env.entries) {
      if (e.key.toUpperCase() == 'PATH') return e.value;
    }
    return '';
  }

  /// Finds [name] on [path]. Windows tries PATHEXT's extensions.
  static String? which(String name, String path, {Map<String, String>? environment}) {
    final sep = Platform.isWindows ? ';' : ':';
    final exts = Platform.isWindows
        ? [
            for (final e in ((environment ?? Platform.environment)['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD').split(';'))
              if (e.isNotEmpty) e.toLowerCase(),
            '',
          ]
        : [''];
    if (Platform.isWindows) {
      // .exe before .cmd/.bat: a real binary beats a shim when both exist.
      exts.sort((a, b) => (a == '.exe' ? 0 : 1).compareTo(b == '.exe' ? 0 : 1));
    }
    for (final dir in path.split(sep)) {
      if (dir.isEmpty) continue;
      for (final ext in exts) {
        final f = File('$dir${Platform.pathSeparator}$name$ext');
        if (!f.existsSync()) continue;
        if (Platform.isWindows) {
          if (ext.isEmpty) continue; // an extensionless file can't be run
          return f.path;
        }
        if (f.statSync().mode & 0x49 != 0) return f.path; // any execute bit
      }
    }
    return null;
  }
}

/// A process and everything it started: agents run tools, `relay mcp`,
/// node behind shims. Stopping only the direct child would orphan them.
abstract final class ProcessTree {
  /// Every descendant of [pid], deepest first (macOS and Linux).
  static Future<List<int>> descendants(int pid) async {
    if (Platform.isWindows) return const [];
    final out = <int>[];
    Future<void> walk(int p) async {
      final r = await Process.run('pgrep', ['-P', '$p']);
      for (final line in '${r.stdout}'.split('\n')) {
        final c = int.tryParse(line.trim());
        if (c == null) continue;
        await walk(c);
        out.add(c);
      }
    }

    try {
      await walk(pid);
    } catch (_) {}
    return out;
  }

  /// Sends [signal] to [pid] and its descendants. False where signals
  /// don't exist (Windows), so callers can say "not available".
  static Future<bool> signal(int pid, ProcessSignal signal) async {
    if (Platform.isWindows) return false;
    final kids = await descendants(pid);
    // Stop parents first so they can't start new children; continue children first.
    final order = signal == ProcessSignal.sigstop ? [pid, ...kids.reversed] : [...kids, pid];
    for (final p in order) {
      Process.killPid(p, signal);
    }
    return true;
  }

  /// Ends the whole tree: politely, then forcefully after [grace].
  static Future<void> kill(Process process, {Duration grace = const Duration(seconds: 5)}) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      try {
        await process.exitCode.timeout(grace);
      } on TimeoutException {
        process.kill();
      }
      return;
    }
    final kids = await descendants(process.pid);
    for (final p in [...kids, process.pid]) {
      Process.killPid(p, ProcessSignal.sigcont);
      Process.killPid(p, ProcessSignal.sigterm);
    }
    try {
      await process.exitCode.timeout(grace);
    } on TimeoutException {
      for (final p in [...kids, process.pid]) {
        Process.killPid(p, ProcessSignal.sigkill);
      }
    }
  }
}
