import 'package:relay_core/relay_core.dart';

import '../data/nav.dart';
import '../data/relay_data.dart';

/// One step of the path to where you are: its name, and the place it opens.
typedef Crumb = ({String label, NavState to});

const _viewNames = {
  ProjectView.board: 'Board',
  ProjectView.list: 'List',
  ProjectView.timeline: 'Timeline',
  ProjectView.git: 'Git',
  ProjectView.code: 'Code',
  ProjectView.repos: 'Repos',
};

/// The path to [nav], outermost first; the last crumb is the page itself.
/// The toolbar shows it, and Back says where it goes with the last one.
List<Crumb> crumbsFor(NavState nav, DataSnapshot data) {
  final crumbs = <Crumb>[];
  void add(String label, NavState to) => crumbs.add((label: label, to: to));
  final page = NavState(page: nav.page, projectId: nav.projectId, view: nav.view, channelId: nav.channelId, teamId: nav.teamId, agentId: nav.agentId);

  switch (nav.page) {
    case AppPage.home:
      add('Mission control', page);
    case AppPage.activity:
      add('Activity', page);
    case AppPage.inbox:
      add('Inbox', page);
    case AppPage.running:
      add('Running now', page);
    case AppPage.review:
      add('Needs review', page);
    case AppPage.waiting:
      add('Needs you', page);
    case AppPage.settings:
      add('Settings', page);
    case AppPage.agents:
      add('Agents', page);
    case AppPage.agent:
      add('Agents', NavState(page: AppPage.agents, projectId: nav.projectId, view: nav.view));
      add(data.get<AgentProfile>(Kind.agent, nav.agentId)?.name ?? 'Agent', page);
    case AppPage.team:
      add('Agents', NavState(page: AppPage.agents, projectId: nav.projectId, view: nav.view));
      add(data.get<Team>(Kind.team, nav.teamId)?.name ?? 'Team', page);
    case AppPage.channel:
      add('#${data.get<Channel>(Kind.channel, nav.channelId)?.name ?? 'channel'}', page);
    case AppPage.project:
      final p = data.get<Project>(Kind.project, nav.projectId);
      add(p?.name ?? 'Project', NavState(page: AppPage.project, projectId: nav.projectId));
      if (nav.view != ProjectView.board || nav.taskId != null) add(_viewNames[nav.view]!, page);
  }

  final task = data.get<Task>(Kind.task, nav.taskId);
  if (task != null) add(data.keyOf(task), nav);
  return crumbs;
}

/// A short name for a place, e.g. "Agents › Claude Code" → "Claude Code".
String placeName(NavState nav, DataSnapshot data) => crumbsFor(nav, data).last.label;
