import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/nav.dart';
import '../data/relay_data.dart';
import '../features/chat/chat_panel.dart';
import '../ui/platform.dart';
import '../ui/widgets.dart';
import 'breadcrumbs.dart';
import 'theme.dart';

/// Back and Forward, at the start of every toolbar. Their tooltips name
/// the place they go to, so you always know where you came from.
class NavButtons extends ConsumerWidget {
  const NavButtons({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(navProvider);
    final data = ref.watch(dataProvider);
    final n = ref.read(navProvider.notifier);
    final back = n.previous, next = n.next;
    final off = context.c.text3.withValues(alpha: 0.4);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconBtn(LucideIcons.chevronLeft, size: 16, color: back == null ? off : null, tooltip: back == null ? null : 'Back to ${placeName(back, data)}  ⌘[', onTap: back == null ? null : n.back),
      IconBtn(LucideIcons.chevronRight, size: 16, color: next == null ? off : null, tooltip: next == null ? null : 'Forward to ${placeName(next, data)}  ⌘]', onTap: next == null ? null : n.forward),
    ]);
  }
}

/// Opens the chat panel; shown at the end of every toolbar while it is shut.
class ChatToggle extends ConsumerWidget {
  const ChatToggle({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(chatProvider.select((s) => s.open))) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Btn('Chat', icon: LucideIcons.sparkles, small: true, tooltip: 'Chat with an agent  ${Desk.isMac ? '⌘J' : 'Ctrl+J'}', onTap: ref.read(chatProvider.notifier).toggle),
    );
  }
}

/// The places above this page ("Agents › Claude Code ›"), each one a link.
/// Empty on a top-level page; the toolbar's title is the last step.
class CrumbTrail extends ConsumerWidget {
  const CrumbTrail({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(navProvider);
    final data = ref.watch(dataProvider);
    final parents = crumbsFor(nav, data)..removeLast();
    if (parents.isEmpty) return const SizedBox.shrink();
    final c = context.c;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final p in parents) ...[
        Pressable(
          onTap: () => ref.read(navProvider.notifier).go(p.to),
          builder: (context, hover, focus) => Container(
            foregroundDecoration: focusRing(context, focus, 3),
            child: Text(p.label,
                maxLines: 1,
                style: context.t(11, w: FontWeight.w500, color: hover ? c.accentIcon : c.text2).copyWith(decoration: hover ? TextDecoration.underline : null)),
          ),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Icon(LucideIcons.chevronRight, size: 10, color: c.text3)),
      ],
    ]);
  }
}
