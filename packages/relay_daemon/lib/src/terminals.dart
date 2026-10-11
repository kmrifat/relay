import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:relay_agents/relay_agents.dart' show Launch;
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_pty/relay_pty.dart';

import 'context.dart';

/// Interactive terminals for the Code view. Output is batched (≤ 30 frames
/// a second per terminal) before it goes to clients.
class Terminals {
  Terminals(this.ctx);

  final DaemonContext ctx;
  final _ptys = <String, Pty>{};
  final _buffers = <String, BytesBuilder>{};
  final _meta = <String, Map<String, Object?>>{};
  Timer? _flush;

  /// The person's shell: `$SHELL -l` on macOS/Linux; on Windows PowerShell 7
  /// if installed, else Windows PowerShell, else cmd.exe.
  static (String, List<String>) defaultShell(Map<String, String> env) {
    if (!Platform.isWindows) return (env['SHELL'] ?? (Platform.isMacOS ? '/bin/zsh' : '/bin/bash'), const ['-l']);
    final path = Launch.pathOf(env);
    final pwsh = Launch.which('pwsh', path, environment: env);
    if (pwsh != null) return (pwsh, const ['-NoLogo']);
    final ps = Launch.which('powershell', path, environment: env);
    if (ps != null) return (ps, const ['-NoLogo']);
    return (env['ComSpec'] ?? r'C:\Windows\System32\cmd.exe', const []);
  }

  List<Map<String, Object?>> list() => [for (final e in _meta.entries) {'id': e.key, ...e.value}];

  Future<String> open({required String cwd, int cols = 100, int rows = 30, String? command, List<String> args = const [], String? runId}) async {
    final helper = ctx.ptyHelper ?? Pty.findHelper();
    if (helper == null) throw RpcError(RpcError.internal, 'relay-pty helper not found');
    if (!Directory(cwd).existsSync()) throw RpcError(RpcError.invalidParams, 'No folder $cwd');
    final (shell, shellArgs) = command != null ? (command, args) : defaultShell(ctx.env);
    final pty = await Pty.start(
      shell,
      shellArgs,
      helper: helper,
      cwd: cwd,
      cols: cols,
      rows: rows,
      environment: {...ctx.env, 'TERM': 'xterm-256color', 'RELAY_TERMINAL': '1'},
    );
    final id = newId();
    _ptys[id] = pty;
    _meta[id] = {'cwd': cwd, 'command': shell, 'runId': ?runId};
    pty.output.listen((bytes) {
      (_buffers[id] ??= BytesBuilder(copy: false)).add(bytes);
      _flush ??= Timer(const Duration(milliseconds: 33), _flushAll);
    });
    pty.errors.listen((bytes) {
      (_buffers[id] ??= BytesBuilder(copy: false)).add(bytes);
      _flush ??= Timer(const Duration(milliseconds: 33), _flushAll);
    });
    unawaited(pty.exitCode.then((code) {
      _flushAll();
      _ptys.remove(id);
      _meta.remove(id);
      ctx.broadcast(E.termExit, {'termId': id, 'code': code});
    }));
    return id;
  }

  void _flushAll() {
    _flush = null;
    for (final e in _buffers.entries) {
      final bytes = e.value.takeBytes();
      if (bytes.isEmpty) continue;
      ctx.broadcast(E.termOutput, {'termId': e.key, 'data': base64Encode(bytes)});
    }
  }

  Pty _pty(String id) => _ptys[id] ?? (throw RpcError(RpcError.notFound, 'No terminal $id'));

  void input(String id, {String? text, String? data}) {
    final pty = _pty(id);
    if (data != null) {
      pty.write(base64Decode(data));
    } else if (text != null) {
      pty.writeString(text);
    }
  }

  void resize(String id, int cols, int rows) => _pty(id).resize(cols, rows);

  Future<void> close(String id) async {
    final pty = _ptys.remove(id);
    _meta.remove(id);
    _buffers.remove(id);
    if (pty != null) await pty.kill();
  }

  Future<void> dispose() async {
    for (final id in _ptys.keys.toList()) {
      await close(id);
    }
  }
}
