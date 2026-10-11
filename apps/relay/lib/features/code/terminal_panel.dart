import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:xterm/xterm.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';

/// A real terminal (xterm.dart) bound to a relayd PTY.
class RelayTerminal extends ConsumerStatefulWidget {
  const RelayTerminal({super.key, required this.cwd, this.termId, this.onOpened});
  final String cwd;

  /// Attach to an already-open terminal (e.g. after Take over).
  final String? termId;
  final ValueChanged<String>? onOpened;

  @override
  ConsumerState<RelayTerminal> createState() => _RelayTerminalState();
}

class _RelayTerminalState extends ConsumerState<RelayTerminal> {
  final terminal = Terminal(maxLines: 5000);
  String? termId;
  StreamSubscription<RelayEvent>? _sub;
  RelayClient? _client;

  @override
  void initState() {
    super.initState();
    _client = ref.read(clientProvider);
    _sub = _client!.events.listen((e) {
      if (e.params['termId'] != termId) return;
      if (e.method == E.termOutput) {
        terminal.write(utf8.decode(base64Decode(e.params['data'] as String), allowMalformed: true));
      } else if (e.method == E.termExit) {
        terminal.write('\r\n[process exited]\r\n');
      }
    });
    terminal.onOutput = (data) {
      final id = termId;
      if (id != null) _client!.call(M.termInput, {'termId': id, 'data': base64Encode(utf8.encode(data))});
    };
    terminal.onResize = (w, h, _, _) {
      final id = termId;
      if (id != null) _client!.call(M.termResize, {'termId': id, 'cols': w, 'rows': h});
    };
    _open();
  }

  Future<void> _open() async {
    if (widget.termId != null) {
      termId = widget.termId;
    } else {
      try {
        termId = await _client!.call<String>(M.termOpen, {'path': widget.cwd, 'cols': terminal.viewWidth, 'rows': terminal.viewHeight});
      } on RpcError catch (e) {
        terminal.write('Could not open a terminal: ${e.message}\r\n');
        return;
      }
    }
    widget.onOpened?.call(termId!);
    _client!.call(M.termResize, {'termId': termId, 'cols': terminal.viewWidth, 'rows': terminal.viewHeight});
  }

  @override
  void dispose() {
    _sub?.cancel();
    final id = termId;
    if (id != null && widget.termId == null) _client?.call(M.termClose, {'termId': id});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TerminalView(
      terminal,
      autofocus: true,
      backgroundOpacity: 0,
      padding: const EdgeInsets.all(8),
      textStyle: const TerminalStyle(fontFamily: mono, fontSize: 12.5),
      theme: TerminalTheme(
        cursor: c.text,
        selection: c.accent.withValues(alpha: 0.4),
        foreground: c.text,
        background: c.codeBg,
        black: const Color(0xFF1E1E1E),
        red: const Color(0xFFFF6961),
        green: const Color(0xFF32D74B),
        yellow: const Color(0xFFE2C08D),
        blue: const Color(0xFF4D9BFF),
        magenta: const Color(0xFFD49BF5),
        cyan: const Color(0xFF64D2FF),
        white: const Color(0xFFD4D4D4),
        brightBlack: const Color(0xFF8D8D93),
        brightRed: const Color(0xFFFF8A80),
        brightGreen: const Color(0xFF73C991),
        brightYellow: const Color(0xFFFFD60A),
        brightBlue: const Color(0xFF82B1FF),
        brightMagenta: const Color(0xFFE1BEE7),
        brightCyan: const Color(0xFF84FFFF),
        brightWhite: const Color(0xFFFFFFFF),
        searchHitBackground: c.warning,
        searchHitBackgroundCurrent: c.accent,
        searchHitForeground: Colors.black,
      ),
    );
  }
}
