import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import '../board/board_view.dart';
import '../code/code_view.dart';
import '../git/git_view.dart';
import '../list/list_view.dart';
import '../repos/repos_view.dart';
import '../task/new_task_sheet.dart';
import '../task/quick_find.dart';
import '../timeline/timeline_view.dart';

/// One project: toolbar with the view switcher, the view, a status bar.
class ProjectPage extends ConsumerWidget {
  const ProjectPage({super.key, required this.projectId, required this.view});
  final String projectId;
  final ProjectView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final nav = ref.watch(navProvider);
    final project = data.get<Project>(Kind.project, projectId)!;
    final tasks = data.tasksOf(projectId);
    final repos = data.reposOf(projectId);
    final filter = nav.repoFilter == null ? null : data.get<Repo>(Kind.repo, nav.repoFilter);
    final running = tasks.where((t) => t.status == TaskStatus.running).length;
    final waiting = tasks.where((t) => t.data['attention'] == 'permission' || t.data['attention'] == 'question').length;

    final subtitle = switch (view) {
      ProjectView.board => 'Board · ${tasks.length} tasks${filter != null ? ' · ${filter.name}' : ''}',
      ProjectView.list => 'List · ${tasks.length} tasks',
      ProjectView.timeline => 'Timeline · today',
      ProjectView.git => 'Git · ${repos.length} repo${repos.length == 1 ? '' : 's'}',
      ProjectView.code => 'Code',
      ProjectView.repos => '${repos.length} repositor${repos.length == 1 ? 'y' : 'ies'} · ${tasks.length} tasks',
    };

    final body = switch (view) {
      ProjectView.board => BoardView(projectId: projectId, repoFilter: nav.repoFilter),
      ProjectView.list => TaskListView(projectId: projectId, repoFilter: nav.repoFilter),
      ProjectView.timeline => TimelineView(projectId: projectId),
      ProjectView.git => GitView(projectId: projectId),
      ProjectView.code => CodeView(projectId: projectId),
      ProjectView.repos => ReposView(projectId: projectId),
    };

    return Column(children: [
      Toolbar(
        title: project.name,
        subtitle: subtitle,
        middle: [
          Segmented<ProjectView>(
            options: const [
              (ProjectView.board, 'Board'),
              (ProjectView.list, 'List'),
              (ProjectView.timeline, 'Timeline'),
              (ProjectView.git, 'Git'),
              (ProjectView.code, 'Code'),
              (ProjectView.repos, 'Repos'),
            ],
            value: view,
            onChanged: (v) => ref.read(navProvider.notifier).view(v),
          ),
          const SizedBox(width: 8),
          IconBtn(LucideIcons.plus, tooltip: 'New task (⌘N)', onTap: () => showNewTaskSheet(context, ref)),
          if (filter != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => ref.read(navProvider.notifier).repoFilter(null),
              child: Pill('${filter.name}  ✕', fg: Colors.white, bg: hexColor(filter.color), radius: 10),
            ),
          ],
        ],
        actions: [
          const QuickFindField(),
        ],
      ),
      Container(height: 1, color: context.c.separator),
      Expanded(child: body),
      StatusBar(
        left: '${tasks.length} tasks · $running running${waiting > 0 ? ' · $waiting waiting on you' : ''}',
        right: [
          for (final a in data.agents.where((a) => a.binaryPath != null).take(3))
            Row(mainAxisSize: MainAxisSize.min, children: [
              AgentTile(agent: a, size: 9),
              const SizedBox(width: 5),
              Text('${a.name} · ${data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).length}/${a.slots}',
                  style: context.t(11, color: context.c.text2)),
            ]),
          Text('Local · relayd', style: context.t(11, color: context.c.text2)),
        ],
      ),
    ]);
  }
}

