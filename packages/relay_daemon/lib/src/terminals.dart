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
/// a second per terminal) before it goes to clients. They live as long as
/// relayd, not the window: each keeps its recent output so the app can
/// reattach after the Code view (or the app) closes.
class Terminals {
  Terminals(this.ctx);

  final DaemonContext ctx;
  final _ptys = <String, Pty>{};
  final _buffers = <String, BytesBuilder>{};
  final _meta = <String, Map<String, Object?>>{};
  final _scrollback = <String, BytesBuilder>{};
  Timer? _flush;

  /// Output kept per terminal for [attach].
  static const scrollbackBytes = 256 * 1024;

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
    _meta[id] = {'cwd': cwd, 'command': shell, 'runId': ?runId, 'openedAt': DateTime.now().toUtc().toIso8601String()};
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
      _scrollback.remove(id);
      ctx.broadcast(E.termExit, {'termId': id, 'code': code});
    }));
    return id;
  }

  void _flushAll() {
    _flush = null;
    for (final e in _buffers.entries) {
      final bytes = e.value.takeBytes();
      if (bytes.isEmpty) continue;
      _keep(e.key, bytes);
      ctx.broadcast(E.termOutput, {'termId': e.key, 'data': base64Encode(bytes)});
    }
  }

  /// Kept at broadcast time, so what [attach] returns is exactly the output
  /// sent before its answer: a client applies `term.output` that arrives
  /// after it, and drops what came before.
  void _keep(String id, Uint8List bytes) {
    if (!_ptys.containsKey(id)) return;
    final kept = _scrollback[id] ??= BytesBuilder();
    kept.add(bytes);
    if (kept.length > scrollbackBytes * 2) {
      final all = kept.takeBytes();
      kept.add(Uint8List.sublistView(all, all.length - scrollbackBytes));
    }
  }

  /// A terminal's recent output (base64) and what it is.
  Map<String, Object?> attach(String id) {
    _pty(id);
    final kept = _scrollback[id]?.toBytes() ?? Uint8List(0);
    final tail = kept.length > scrollbackBytes ? Uint8List.sublistView(kept, kept.length - scrollbackBytes) : kept;
    return {'id': id, ..._meta[id]!, 'data': base64Encode(tail)};
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
    _scrollback.remove(id);
    if (pty != null) await pty.kill();
  }

  Future<void> dispose() async {
    for (final id in _ptys.keys.toList()) {
      await close(id);
    }
  }
}
