import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Views inside a project (the toolbar switcher).
enum ProjectView { board, list, timeline, git, code, repos }

/// Smart lists in the sidebar, plus the non-project pages.
enum AppPage { project, inbox, running, review, waiting, agents, agent, settings, channel, team, home, activity }

class NavState {
  const NavState({
    this.page = AppPage.home,
    this.projectId,
    this.view = ProjectView.board,
    this.taskId,
    this.repoFilter,
    this.channelId,
    this.teamId,
    this.agentId,
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

  /// The open team (AppPage.team) and the agent shown in its inspector;
  /// on AppPage.agent, the agent whose page is open.
  final String? teamId;
  final String? agentId;

  NavState copyWith({AppPage? page, String? projectId, ProjectView? view, String? taskId, bool clearTask = false, String? repoFilter, bool clearRepo = false, String? channelId, String? teamId, String? agentId}) =>
      NavState(
        page: page ?? this.page,
        projectId: projectId ?? this.projectId,
        view: view ?? this.view,
        taskId: clearTask ? null : (taskId ?? this.taskId),
        repoFilter: clearRepo ? null : (repoFilter ?? this.repoFilter),
        channelId: channelId ?? this.channelId,
        teamId: teamId ?? this.teamId,
        agentId: agentId ?? this.agentId,
      );

  /// Saved by relayd (ui.set), so Relay reopens where you left off.
  Map<String, Object?> toJson() => {
        'page': page.name,
        'projectId': ?projectId,
        'view': view.name,
        'taskId': ?taskId,
        'repoFilter': ?repoFilter,
        'channelId': ?channelId,
        'teamId': ?teamId,
        'agentId': ?agentId,
      };

  static NavState? fromJson(Map<String, Object?> j) {
    final page = AppPage.values.asNameMap()[j['page']];
    if (page == null) return null;
    return NavState(
      page: page,
      projectId: j['projectId'] as String?,
      view: ProjectView.values.asNameMap()[j['view']] ?? ProjectView.board,
      taskId: j['taskId'] as String?,
      repoFilter: j['repoFilter'] as String?,
      channelId: j['channelId'] as String?,
      teamId: j['teamId'] as String?,
      agentId: j['agentId'] as String?,
    );
  }
}

class NavNotifier extends Notifier<NavState> {
  NavNotifier([this.initial = const NavState()]);

  /// Where the app opens: Mission control.
  final NavState initial;

  final _back = <NavState>[];
  final _forward = <NavState>[];

  @override
  NavState build() => initial;

  /// Every move goes through here, so ⌘[ and ⌘] can walk it back.
  void _go(NavState next) {
    final now = state;
    if (_same(now, next)) return;
    _back.add(now);
    if (_back.length > 50) _back.removeAt(0);
    _forward.clear();
    state = next;
  }

  static bool _same(NavState a, NavState b) =>
      a.page == b.page && a.projectId == b.projectId && a.view == b.view && a.taskId == b.taskId && a.repoFilter == b.repoFilter && a.channelId == b.channelId &&
      a.teamId == b.teamId && a.agentId == b.agentId;

  bool get canGoBack => _back.isNotEmpty;
  bool get canGoForward => _forward.isNotEmpty;

  /// Where Back goes, and where Forward goes.
  NavState? get previous => _back.lastOrNull;
  NavState? get next => _forward.lastOrNull;

  /// Puts back the place saved at the last quit, unless you already moved.
  void restore(NavState saved) {
    if (_back.isNotEmpty || !_same(state, initial)) return;
    state = saved;
  }

  /// Any place, e.g. a breadcrumb's.
  void go(NavState to) => _go(to);

  void back() {
    if (_back.isEmpty) return;
    _forward.add(state);
    state = _back.removeLast();
  }

  void forward() {
    if (_forward.isEmpty) return;
    _back.add(state);
    state = _forward.removeLast();
  }

  void project(String id, {ProjectView? view}) =>
      _go(state.copyWith(page: AppPage.project, projectId: id, view: view, clearTask: true, clearRepo: state.projectId != id));
  void view(ProjectView v) => _go(state.copyWith(page: AppPage.project, view: v, clearTask: true));
  void page(AppPage p) => _go(state.copyWith(page: p, clearTask: true));
  void channel(String id) => _go(state.copyWith(page: AppPage.channel, channelId: id, clearTask: true));

  /// A team's page, with [agentId] (a member) in its inspector.
  void team(String id, {String? agentId}) => _go(NavState(
        page: AppPage.team, projectId: state.projectId, view: state.view, channelId: state.channelId, teamId: id, agentId: agentId));
  /// One agent's page: what it is doing, its queue and history.
  void agent(String id) => _go(NavState(page: AppPage.agent, projectId: state.projectId, view: state.view, channelId: state.channelId, agentId: id));
  void openTask(String id) => _go(state.copyWith(taskId: id));
  void closeTask() => _go(state.copyWith(clearTask: true));
  void repoFilter(String? repoId) => _go(repoId == null ? state.copyWith(clearRepo: true) : state.copyWith(repoFilter: repoId, view: ProjectView.board, page: AppPage.project));
}

final navProvider = NotifierProvider<NavNotifier, NavState>(NavNotifier.new);
