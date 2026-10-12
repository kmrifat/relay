import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/relay_data.dart';
import '../ui/widgets.dart';
import 'theme.dart';

/// Above the window while an older relayd waits for its agent runs before
/// being replaced (or couldn't be replaced).
class UpgradeBanner extends ConsumerWidget {
  const UpgradeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(upgradeProvider);
    if (s == null) return const SizedBox.shrink();
    final u = s.upgrade;
    final runs = s.activeRuns == 1 ? '1 agent run' : '${s.activeRuns} agent runs';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(color: context.c.warningWash, border: Border(bottom: BorderSide(color: context.c.separator))),
      child: Row(children: [
        Icon(s.error != null ? LucideIcons.triangleAlert : LucideIcons.refreshCw, size: 14, color: context.c.warning),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            s.error ??
                'Relay ${u.bundled} is installed, but relayd ${u.running} is still running $runs. '
                    'It restarts when they finish; until then some features may not work.',
            style: context.t(12),
          ),
        ),
        const SizedBox(width: 10),
        if (s.error != null)
          IconBtn(LucideIcons.x, tooltip: 'Dismiss', onTap: () => ref.read(upgradeProvider.notifier).set(null))
        else
          Btn('Restart now', small: true, onTap: () => _confirm(context, ref, runs)),
      ]),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref, String runs) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restart relayd now?', style: context.t(14, w: FontWeight.w600)),
        content: Text('This stops $runs. Their tasks go back to the queue and start again with the new relayd.',
            style: context.t(12, color: context.c.text2)),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(context)),
          Btn('Restart', kind: BtnKind.danger, onTap: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) await ref.read(connectionProvider.notifier).replaceNow();
  }
}
