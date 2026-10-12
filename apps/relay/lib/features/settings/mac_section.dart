import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_daemon/relay_daemon.dart' show relayVersion;

import '../../app/theme.dart';
import '../../data/system.dart';
import '../../ui/widgets.dart';

/// Settings → This Mac / This computer (M9-02/03, M10-05): relayd at login
/// everywhere; the menu bar item and Sparkle updates on macOS.
class MacSection extends ConsumerStatefulWidget {
  const MacSection({super.key});
  @override
  ConsumerState<MacSection> createState() => _MacSectionState();
}

class _MacSectionState extends ConsumerState<MacSection> {
  String? login;
  bool canUpdate = false;
  bool autoCheck = false;
  bool menuBar = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await SystemBridge.instance.loginItem();
    final u = await SystemBridge.instance.canUpdate();
    final a = u && await SystemBridge.instance.autoCheck();
    if (!mounted) return;
    setState(() {
      login = l;
      canUpdate = u;
      autoCheck = a;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) return const SizedBox.shrink();
    final mac = Platform.isMacOS;
    final c = context.c;
    Widget toggle(String label, String help, bool value, ValueChanged<bool>? onChanged) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, style: context.t(12, color: c.text2))),
        Expanded(child: Text(help, style: context.t(11, color: c.text3))),
        Transform.scale(scale: 0.7, child: Switch(value: value, onChanged: onChanged, activeTrackColor: c.accent)),
      ]),
    );
    final loginHelp = switch (login) {
      'enabled' => Platform.isWindows
          ? 'relayd starts when you sign in (Startup apps), so queued and overnight work runs without opening Relay.'
          : 'relayd starts when you log in, so queued and overnight work runs without opening Relay.',
      'needsApproval' => 'Allow "Relay" in System Settings → General → Login Items.',
      'unsupported' => 'Needs macOS 13 or later.',
      'notFound' => Platform.isMacOS ? 'This build has no login agent (run a full macOS build).' : 'This build has no relayd next to it (helpers/).',
      _ => 'Start relayd when you log in, so queued and overnight work runs.',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(mac ? 'This Mac' : 'This computer', style: context.label),
      const SizedBox(height: 8),
      Box(
        child: Column(children: [
          toggle('Start at login', loginHelp, login == 'enabled' || login == 'needsApproval', login == 'unsupported' || login == null
              ? null
              : (v) async {
                  try {
                    final s = await SystemBridge.instance.setLoginItem(v);
                    setState(() {
                      login = s;
                      error = null;
                    });
                  } catch (e) {
                    setState(() => error = '$e');
                  }
                }),
          if (mac) ...[
          const Hairline(),
          toggle('Menu bar', 'Keep Relay in the menu bar when its window is closed: what runs, what waits on you, pause new work.', menuBar, (v) {
            setState(() => menuBar = v);
            SystemBridge.instance.keepInMenuBar(v);
          }),
          const Hairline(),
          FieldRow('Updates', Row(children: [
            Expanded(
              child: Text(canUpdate ? 'Relay $relayVersion' : 'Relay $relayVersion · this build can\'t update itself yet', style: context.t(12)),
            ),
            Btn('Check for Updates…', small: true, onTap: canUpdate ? () => SystemBridge.instance.checkForUpdates() : null),
          ]), labelWidth: 110),
          if (canUpdate) ...[
            const Hairline(),
            toggle('Check daily', 'Look for a new Relay once a day. It always asks before installing.', autoCheck, (v) {
              setState(() => autoCheck = v);
              SystemBridge.instance.setAutoCheck(v);
            }),
          ],
          ],
        ]),
      ),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error!, style: context.t(11, color: c.danger))),
      const SizedBox(height: 20),
    ]);
  }
}
