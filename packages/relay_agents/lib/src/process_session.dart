import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adapter.dart';
import 'launch.dart';

/// Shared plumbing for agents that run as a child process and print one
/// event per line: start, line splitting, stderr capture, pause/stop.
abstract class ProcessSession implements AgentSession {
  ProcessSession(this.process) {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _maybeDone);
    _stderrSub = process.stderr.transform(utf8.decoder).listen((s) {
      _stderr.write(s);
      if (_stderr.length > 64 * 1024) {
        final keep = _stderr.toString().substring(_stderr.length - 32 * 1024);
        _stderr
          ..clear()
          ..write(keep);
      }
    }, onDone: _maybeDone);
    process.exitCode.then((code) {
      _exit = code;
      _maybeDone();
    });
  }

  final Process process;
  final _events = StreamController<AgentEvent>();
  late final StreamSubscription<String> _stdoutSub;
  late final StreamSubscription<String> _stderrSub;
  final _stderr = StringBuffer();
  int _streamsDone = 0;
  int? _exit;
  bool _closed = false;
  bool stopping = false;

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Future<int> get exitCode => process.exitCode;

  String get stderrText => _stderr.toString();

  void emit(String type, [Map<String, Object?> data = const {}]) {
    if (!_closed) _events.add(AgentEvent(type, data));
  }

  /// Handles one line of stdout.
  void onLine(String line);

  /// Called once the process has exited and its output is drained.
  void onExit(int code) {}

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    try {
      onLine(line);
    } catch (e) {
      emit('output', {'text': line});
    }
  }

  void _maybeDone() {
    _streamsDone++;
    if (_streamsDone < 3 || _closed) return; // stdout, stderr and exit code
    onExit(_exit ?? -1);
    _closed = true;
    _events.close();
  }

  void writeLine(Map<String, Object?> json) {
    try {
      process.stdin.writeln(jsonEncode(json));
    } catch (_) {}
  }

  @override
  bool get canPause => !Platform.isWindows;

  /// Freezes the agent and everything it started (tools, `relay mcp`).
  @override
  void pause() => unawaited(ProcessTree.signal(process.pid, ProcessSignal.sigstop));

  @override
  void resume() => unawaited(ProcessTree.signal(process.pid, ProcessSignal.sigcont));

  @override
  void finish() {
    try {
      process.stdin.close();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    stopping = true;
    await ProcessTree.kill(process);
  }

  Future<void> dispose() async {
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
  }
}
