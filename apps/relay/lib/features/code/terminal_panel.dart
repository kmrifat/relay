import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../app/theme.dart';
import 'term_hub.dart';

/// A real terminal (xterm.dart) showing a relayd PTY. The shell lives in
/// [TermSession] (term_hub.dart), so this widget can come and go.
class RelayTerminal extends StatelessWidget {
  const RelayTerminal({super.key, required this.session, this.autofocus = true});
  final TermSession session;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TerminalView(
      session.terminal,
      autofocus: autofocus,
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
