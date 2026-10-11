import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../data/nav.dart';
import '../data/relay_data.dart';
import '../features/agents/fleet_page.dart';
import '../features/project/project_dialogs.dart';
import '../features/project/project_page.dart';
import '../features/settings/settings_page.dart';
import '../features/smart/smart_list_page.dart';
import '../features/task/new_task_sheet.dart';
import '../features/task/quick_find.dart';
import '../features/task/task_page.dart';
import '../ui/widgets.dart';
import 'sidebar.dart';
import 'theme.dart';

class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});
  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  bool _debugNavDone = false;

  /// Debug builds only: `RELAY_DEBUG_NAV=task:KT-1`, `view:git`,
  /// `page:agents` or `new-task` opens that screen at start, for screenshots.
  void _debugNav(DataSnapshot data) {
    if (_debugNavDone || !kDebugMode || data.rev == 0) return;
    _debugNavDone = true;
    final spec = Platform.environment['RELAY_DEBUG_NAV'];
    if (spec == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final n = ref.read(navProvider.notifier);
      for (final part in spec.split(',')) {
        final [kind, value, ...] = [...part.split(':'), ''];
        switch (kind) {
          case 'project':
            final p = data.projects.where((p) => p.key == value).firstOrNull;
            if (p != null) n.project(p.id);
          case 'view':
            n.view(ProjectView.values.byName(value));
          case 'page':
            n.page(AppPage.values.byName(value));
          case 'task':
            final t = data.tasksOf(null).where((t) => data.keyOf(t) == value).firstOrNull;
            if (t != null) {
              n.project(t.projectId);
              n.openTask(t.id);
            }
          case 'new-task':
            showNewTaskSheet(context, ref);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(noticesProvider, (_, next) {
      final n = next.value;
      if (n == null) return;
      final level = n['level'] as String? ?? 'info';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 460,
        duration: const Duration(seconds: 4),
        backgroundColor: context.c.box,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: context.c.boxStroke)),
        content: Row(children: [
          Icon(
            switch (level) { 'error' => LucideIcons.circleAlert, 'warning' => LucideIcons.triangleAlert, 'ask' => LucideIcons.shieldCheck, _ => LucideIcons.info },
            size: 15,
            color: switch (level) { 'error' => context.c.danger, 'warning' || 'ask' => context.c.warning, _ => context.c.accentIcon },
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(n['text'] as String? ?? '', style: context.t(12))),
        ]),
      ));
    });

    final nav = ref.watch(navProvider);
    final data = ref.watch(dataProvider);
    // Default to the first project once data arrives.
    if (nav.page == AppPage.project && nav.projectId == null && data.projects.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(navProvider.notifier).project(data.projects.first.id));
    }
    _debugNav(data);

    Widget content;
    if (nav.taskId != null && data.get<Task>(Kind.task, nav.taskId) != null) {
      content = TaskPage(taskId: nav.taskId!);
    } else {
      content = switch (nav.page) {
        AppPage.project => nav.projectId == null || data.get<Project>(Kind.project, nav.projectId) == null
            ? const NoProjects()
            : ProjectPage(projectId: nav.projectId!, view: nav.view),
        AppPage.inbox || AppPage.running || AppPage.review || AppPage.waiting => SmartListPage(page: nav.page),
        AppPage.agents => const FleetPage(),
        AppPage.settings => const SettingsPage(),
      };
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => showNewTaskSheet(context, ref),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showQuickFind(context, ref),
        const SingleActivator(LogicalKeyboardKey.escape): () => ref.read(navProvider.notifier).closeTask(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(children: [
            const SizedBox(width: 220, child: Sidebar()),
            Container(width: 1, color: context.c.separator),
            Expanded(child: content),
          ]),
        ),
      ),
    );
  }
}
