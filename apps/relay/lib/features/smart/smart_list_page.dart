import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/sidebar.dart';
import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../list/list_view.dart';

/// Inbox, Running now, Needs review, Waiting on you: tasks across projects.
class SmartListPage extends ConsumerWidget {
  const SmartListPage({super.key, required this.page});
  final AppPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final tasks = data.tasksOf(null).where((t) => inSmartList(page, t)).toList();
    final (title, sub) = switch (page) {
      AppPage.inbox => ('Inbox', 'Questions, permission requests, failures and work to review'),
      AppPage.running => ('Running now', 'Tasks an agent is working on'),
      AppPage.review => ('Needs review', 'Finished by an agent, waiting for a person'),
      AppPage.waiting => ('Needs you', 'Questions, permissions and OKs agents are waiting for'),
      _ => ('', ''),
    };
    return Column(children: [
      Toolbar(title: title, subtitle: '${tasks.length} · $sub'),
      Container(height: 1, color: context.c.separator),
      Expanded(child: TaskListView(projectId: null, tasksOverride: tasks, showFilters: false)),
      StatusBar(left: 'Double-click a row to open it · right-click for actions'),
    ]);
  }
}
