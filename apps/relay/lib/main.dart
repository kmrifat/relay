import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/shell.dart';
import 'app/theme.dart';
import 'data/relay_data.dart';
import 'ui/widgets.dart';

void main() {
  runApp(const ProviderScope(child: RelayApp()));
}

class RelayApp extends StatelessWidget {
  const RelayApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Relay',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(Brightness.light),
    darkTheme: buildTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: const ConnectionGate(),
  );
}

/// Shows the shell once relayd answers; until then, what's happening.
class ConnectionGate extends ConsumerWidget {
  const ConnectionGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    if (conn.status == ConnStatus.connected) return const Shell();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: context.c.accent, borderRadius: BorderRadius.circular(13)),
              child: const Icon(Icons.checklist_rounded, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 16),
            Text('Relay', style: context.t(22, w: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(conn.message ?? '', textAlign: TextAlign.center, style: context.t(13, color: context.c.text2)),
            if (conn.status == ConnStatus.failed) ...[
              const SizedBox(height: 16),
              Btn('Try again', kind: BtnKind.primary, onTap: () => ref.read(connectionProvider.notifier).connect()),
            ] else ...[
              const SizedBox(height: 16),
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
        ),
      ),
    );
  }
}
