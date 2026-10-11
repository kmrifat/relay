import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'mac_section.dart';
import 'team_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Map<String, Object?> status = {};
  final name = TextEditingController();
  final device = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    final s = await client.map(M.status);
    final settings = await client.map(M.settingsGet);
    if (!mounted) return;
    setState(() {
      status = s;
      name.text = '${settings['userName'] ?? ''}';
      device.text = '${settings['deviceName'] ?? ''}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rss = (status['rssBytes'] as num?)?.toInt() ?? 0;
    return Column(children: [
      const Toolbar(title: 'Settings', subtitle: 'You · Team · relayd'),
      Container(height: 1, color: c.separator),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 40), children: [
          Center(
            child: SizedBox(
              width: 640,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('You', style: context.label),
                const SizedBox(height: 8),
                Box(
                  child: Column(children: [
                    FieldRow('Your name', FieldInput(
                      controller: name,
                      hint: 'Shown on comments and merges',
                      onSubmitted: (v) => ref.read(clientProvider).call(M.settingsSet, {'values': {'userName': v.trim()}}),
                    ), labelWidth: 110),
                    const Hairline(),
                    FieldRow('This Mac', FieldInput(
                      controller: device,
                      hint: 'How teammates see this device',
                      onSubmitted: (v) => ref.read(clientProvider).call(M.settingsSet, {'values': {'deviceName': v.trim()}}),
                    ), labelWidth: 110),
                  ]),
                ),
                const SizedBox(height: 20),
                Text('Team', style: context.label),
                const SizedBox(height: 8),
                const TeamSection(),
                const SizedBox(height: 20),
                const MacSection(),
                Text('relayd', style: context.label),
                const SizedBox(height: 8),
                Box(
                  child: Column(children: [
                    FieldRow('Version', Text('${status['version'] ?? ''} · protocol ${status['protocol'] ?? ''}', style: context.t(12)), labelWidth: 110),
                    const Hairline(),
                    FieldRow('Process', Text('pid ${status['pid'] ?? ''} · up ${_uptime((status['uptimeSeconds'] as num?)?.toInt() ?? 0)} · ${(rss / 1048576).toStringAsFixed(0)} MB', style: context.t(12)), labelWidth: 110),
                    const Hairline(),
                    FieldRow('Active runs', Text('${status['activeRuns'] ?? 0} · ${status['terminals'] ?? 0} terminals', style: context.t(12)), labelWidth: 110),
                    const Hairline(),
                    FieldRow('Data', SelectableText('${status['home'] ?? ''}', style: context.t(12, family: mono)), labelWidth: 110),
                    const Hairline(),
                    FieldRow('Device', SelectableText('${status['deviceId'] ?? ''}', style: context.t(12, family: mono)), labelWidth: 110),
                  ]),
                ),
                const SizedBox(height: 10),
                Text('relayd keeps running when you close this window, so agents finish their work. The CLI talks to it too: `relay status`, `relay task add`.',
                    style: context.t(11, color: c.text3)),
                const SizedBox(height: 10),
                Row(children: [Btn('Refresh', onTap: _load)]),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }

  static String _uptime(int s) => s < 60 ? '${s}s' : (s < 3600 ? '${s ~/ 60}m' : '${s ~/ 3600}h ${(s % 3600) ~/ 60}m');
}
