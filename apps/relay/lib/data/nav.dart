import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Views inside a project (the toolbar switcher).
enum ProjectView { board, list, timeline, git, code, repos }

/// Smart lists in the sidebar, plus the non-project pages.
enum AppPage { project, inbox, running, review, waiting, agents, settings, channel }

class NavState {
  const NavState({
    this.page = AppPage.project,
    this.projectId,
    this.view = ProjectView.board,
    this.taskId,
    this.repoFilter,
    this.channelId,
  });

  final AppPage page;
  final String? projectId;
  final ProjectView view;

  /// The task open in the detail pane, if any.
  final String? taskId;

  /// Board filter: only tasks touching this repo.
  final String? repoFilter;

  /// The open channel (AppPage.channel).
  final String? channelId;

  NavState copyWith({AppPage? page, String? projectId, ProjectView? view, String? taskId, bool clearTask = false, String? repoFilter, bool clearRepo = false, String? channelId}) =>
      NavState(
        page: page ?? this.page,
        projectId: projectId ?? this.projectId,
        view: view ?? this.view,
        taskId: clearTask ? null : (taskId ?? this.taskId),
        repoFilter: clearRepo ? null : (repoFilter ?? this.repoFilter),
        channelId: channelId ?? this.channelId,
      );
}

class NavNotifier extends Notifier<NavState> {
  @override
  NavState build() => const NavState();

  void project(String id, {ProjectView? view}) =>
      state = state.copyWith(page: AppPage.project, projectId: id, view: view, clearTask: true, clearRepo: state.projectId != id);
  void view(ProjectView v) => state = state.copyWith(page: AppPage.project, view: v);
  void page(AppPage p) => state = state.copyWith(page: p, clearTask: true);
  void channel(String id) => state = state.copyWith(page: AppPage.channel, channelId: id, clearTask: true);
  void openTask(String id) => state = state.copyWith(taskId: id);
  void closeTask() => state = state.copyWith(clearTask: true);
  void repoFilter(String? repoId) => state = repoId == null ? state.copyWith(clearRepo: true) : state.copyWith(repoFilter: repoId, view: ProjectView.board, page: AppPage.project);
}

final navProvider = NotifierProvider<NavNotifier, NavState>(NavNotifier.new);
