import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:xterm/xterm.dart';

import '../../data/relay_data.dart';

/// One relayd terminal as the app sees it. It outlives the widget showing
/// it, so switching views (or tabs) keeps the shell and its scrollback.
class TermSession extends ChangeNotifier {
  TermSession._(this._hub, this.id);
  final TermHub _hub;
  final String id;
  String cwd = '';
  String? runId;
  final terminal = Terminal(maxLines: 5000);
  bool exited = false;

  /// Output is applied only after `term.attach` answers; what arrived
  /// before is in its scrollback (docs/protocol.md).
  bool _attached = false;

  void _write(List<int> bytes) => terminal.write(utf8.decode(bytes, allowMalformed: true));

  void _exit() {
    exited = true;
    terminal.write('\r\n[process exited]\r\n');
    notifyListeners();
  }

  /// Types [command] and presses Return.
  void run(String command) {
    if (exited) return;
    _hub.client.call(M.termInput, {'termId': id, 'text': '$command\r'});
  }
}

class TermHub {
  TermHub(this.client) {
    _sub = client.events.listen(_onEvent);
  }

  final RelayClient client;
  final _sessions = <String, TermSession>{};
  late final StreamSubscription<RelayEvent> _sub;

  TermSession? operator [](String id) => _sessions[id];

  void _onEvent(RelayEvent e) {
    final s = _sessions[e.params['termId']];
    if (s == null || !s._attached) return;
    if (e.method == E.termOutput) {
      s._write(base64Decode(e.params['data'] as String));
    } else if (e.method == E.termExit) {
      s._exit();
    }
  }

  /// A new shell in [cwd].
  Future<TermSession> open(String cwd, {int cols = 100, int rows = 30}) async {
    final id = await client.call<String>(M.termOpen, {'path': cwd, 'cols': cols, 'rows': rows});
    return (await attach(id))!;
  }

  /// Pauses the agent's run and opens a shell in its workspace.
  Future<TermSession> takeover(String runId) async {
    final id = await client.call<String>(M.termTakeover, {'runId': runId});
    return (await attach(id))!;
  }

  /// Shows a terminal relayd already has; null if it has gone.
  Future<TermSession?> attach(String id) async {
    final known = _sessions[id];
    if (known != null) return known;
    final s = _sessions[id] = TermSession._(this, id);
    final Map<String, Object?> r;
    try {
      r = await client.map(M.termAttach, {'termId': id});
    } on RpcError {
      _sessions.remove(id);
      return null;
    }
    s
      ..cwd = r['cwd'] as String? ?? ''
      ..runId = r['runId'] as String?
      .._write(base64Decode(r['data'] as String? ?? ''))
      .._attached = true;
    s.terminal.onOutput = (data) {
      if (!s.exited) client.call(M.termInput, {'termId': id, 'data': base64Encode(utf8.encode(data))});
    };
    s.terminal.onResize = (w, h, _, _) {
      if (!s.exited) client.call(M.termResize, {'termId': id, 'cols': w, 'rows': h});
    };
    return s;
  }

  /// Ends the shell.
  Future<void> close(String id) async {
    _sessions.remove(id)?.dispose();
    try {
      await client.call(M.termClose, {'termId': id});
    } on RpcError catch (_) {
      // Already gone.
    }
  }

  void dispose() {
    _sub.cancel();
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
  }
}

/// Shared by every project's Code view; reconnecting to relayd makes a new one.
final termHubProvider = Provider<TermHub>((ref) {
  final hub = TermHub(ref.watch(clientProvider));
  ref.onDispose(hub.dispose);
  return hub;
});
