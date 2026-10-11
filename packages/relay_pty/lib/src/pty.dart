import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A command running in a pseudo-terminal, through the `relay-pty` helper.
class Pty {
  Pty._(this._process, this.cols, this.rows);

  /// Starts [command] in a terminal of [cols]×[rows] in [cwd].
  ///
  /// [helper] is the path to the compiled `relay-pty` (next to the relay
  /// binary in releases; see [findHelper]).
  static Future<Pty> start(
    String command,
    List<String> args, {
    required String helper,
    String cwd = '',
    int cols = 80,
    int rows = 24,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      helper,
      ['$cols', '$rows', cwd, '--', command, ...args],
      environment: environment,
    );
    return Pty._(process, cols, rows);
  }

  /// Looks for `relay-pty` next to the running executable, then in
  /// `$RELAY_PTY`, then `tool/out/relay-pty` in a source checkout.
  static String? findHelper({String? near}) {
    final candidates = [
      Platform.environment['RELAY_PTY'],
      if (near != null) '$near/relay-pty',
      '${File(Platform.resolvedExecutable).parent.path}/relay-pty',
      '${Directory.current.path}/tool/out/relay-pty',
      '${Directory.current.parent.parent.path}/tool/out/relay-pty',
    ];
    for (final c in candidates) {
      if (c != null && File(c).existsSync()) return c;
    }
    return null;
  }

  final Process _process;
  int cols;
  int rows;

  /// Raw terminal output.
  Stream<List<int>> get output => _process.stdout;

  /// Helper errors (e.g. the command was not found).
  Stream<List<int>> get errors => _process.stderr;

  Future<int> get exitCode => _process.exitCode;
  int get pid => _process.pid;

  void write(List<int> bytes) => _frame(0, bytes);
  void writeString(String s) => write(utf8.encode(s));

  void resize(int cols, int rows) {
    this.cols = cols;
    this.rows = rows;
    _frame(1, [cols >> 8, cols & 0xff, rows >> 8, rows & 0xff]);
  }

  /// Sends a signal to the terminal's process group (SIGINT = 2, SIGTERM = 15).
  void signal(int sig) => _frame(2, [sig >> 24 & 0xff, sig >> 16 & 0xff, sig >> 8 & 0xff, sig & 0xff]);

  void interrupt() => signal(2);

  void _frame(int type, List<int> payload) {
    final b = BytesBuilder(copy: false)
      ..addByte(type)
      ..add([payload.length >> 24 & 0xff, payload.length >> 16 & 0xff, payload.length >> 8 & 0xff, payload.length & 0xff])
      ..add(payload);
    try {
      _process.stdin.add(b.takeBytes());
    } catch (_) {}
  }

  /// Hangs up the terminal and waits for the command to exit.
  Future<int> kill() async {
    signal(15);
    try {
      await _process.stdin.close();
    } catch (_) {}
    return _process.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return -9;
    });
  }
}
