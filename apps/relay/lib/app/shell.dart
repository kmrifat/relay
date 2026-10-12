import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../data/system.dart';
import '../data/notifications.dart';
import '../data/nav.dart';
import '../data/relay_data.dart';
import '../features/chat/chat_panel.dart';
import '../features/channel/channel_page.dart';
import '../features/code/code_session.dart';
import '../features/help/keyboard_map.dart';
import '../features/home/activity_page.dart';
import '../features/home/mission_control.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/agents/agent_page.dart';
import '../features/agents/fleet_page.dart';
import '../features/project/project_dialogs.dart';
import '../features/project/project_page.dart';
import '../features/settings/settings_page.dart';
import '../features/smart/smart_list_page.dart';
import '../features/task/new_task_sheet.dart';
import '../features/teams/team_page.dart';
import '../features/task/quick_find.dart';
import '../features/task/task_page.dart';
import '../ui/widgets.dart';
import '../ui/platform.dart';
import '../ui/split.dart';
import 'commands.dart';
import 'sidebar.dart';
import 'theme.dart';
import 'upgrade_banner.dart';

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
          case 'channel':
            final ch = data.channels.where((c) => c.name == value).firstOrNull;
            if (ch != null) n.channel(ch.id);
        }
      }
    });
  }

  int _badge = -1;
  bool _paused = false;

  /// First run: no projects and onboarding not done (decided once at start,
  /// so adding the first repo doesn't end it early).
  bool _onboarding = false;

  final _sidebarFocus = FocusNode(debugLabel: 'sidebar');
  ModalRoute<Object?>? _route;
  final _contentFocus = idleFocusNode(debugLabel: 'content', skipTraversal: true);
  final _rootFocus = idleFocusNode(debugLabel: 'shell');

  @override
  void initState() {
    super.initState();
    // Off while a dialog, sheet or menu is in front of the shell.
    Commands.instance.enabled = () => mounted && (_route?.isCurrent ?? true);
    HardwareKeyboard.instance.addHandler(Commands.instance.handleKey);
    SystemBridge.instance
      ..init()
      ..onMenu = (action, args) async {
        final client = ref.read(clientProvider);
        switch (action) {
          case 'openTask':
            final id = args['taskId'] as String? ?? '';
            if (id.isNotEmpty) ref.read(navProvider.notifier).openTask(id);
          case 'pause' || 'resume':
            await client.call(M.settingsSet, {'values': {'schedulerPaused': action == 'pause'}});
            if (mounted) setState(() => _paused = action == 'pause');
        }
      };
    Future.microtask(() async {
      final client = ref.read(clientProvider);
      final s = await client.map(M.settingsGet);
      final projects = await client.list(M.projectsList);
      final saved = await client.call<String?>(M.uiGet, {'key': 'nav'}).catchError((Object _) => null);
      if (!mounted) return;
      if (saved != null) {
        final place = NavState.fromJson((jsonDecode(saved) as Map).cast<String, Object?>());
        // Not into a project that has since gone.
        final known = place != null && (place.projectId == null || projects.any((p) => (p as Map)['id'] == place.projectId));
        if (known) ref.read(navProvider.notifier).restore(place);
      }
      setState(() {
        _paused = '${s['schedulerPaused']}' == 'true';
        _onboarding = '${s['onboarded']}' != 'true' && projects.isEmpty;
      });
    });
    NativeNotifications.instance
      ..init()
      ..onOpen = (info) {
        final n = ref.read(navProvider.notifier);
        if (info['channelId'] is String) n.channel(info['channelId'] as String);
        if (info['taskId'] is String) n.openTask(info['taskId'] as String);
      };
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(Commands.instance.handleKey);
    Commands.instance.unregister();
    _sidebarFocus.dispose();
    _contentFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  /// What each command does (commands.dart has the keys).
  Map<String, VoidCallback> _handlers(DataSnapshot data, NavState nav) {
    final n = ref.read(navProvider.notifier);
    String? projectId() => nav.projectId ?? data.projects.firstOrNull?.id;
    void view(ProjectView v) {
      final id = projectId();
      if (id == null) return;
      if (nav.projectId == null) n.project(id);
      n.view(v);
    }

    return {
      Cmd.quickFind: () => showQuickFind(context, ref),
      Cmd.askAgent: ref.read(chatProvider.notifier).toggle,
      Cmd.home: () => n.page(AppPage.home),
      Cmd.activity: () => n.page(AppPage.activity),
      for (var i = 0; i < data.projects.length && i < 9; i++) Cmd.project(i): () => n.project(data.projects[i].id),
      Cmd.needsYou: () => n.page(AppPage.waiting),
      Cmd.agents: () => n.page(AppPage.agents),
      Cmd.back: n.back,
      Cmd.forward: n.forward,
      Cmd.settings: () => n.page(AppPage.settings),
      Cmd.keyboardMap: () => showKeyboardMap(context),
      for (var i = 0; i < ProjectView.values.length; i++) Cmd.view(i): () => view(ProjectView.values[i]),
      Cmd.newTask: () => showNewTaskSheet(context, ref),
      Cmd.toggleTerminal: () async {
        final id = projectId();
        if (id == null) return;
        final s = ref.read(codeSessionProvider(id));
        final inCode = nav.page == AppPage.project && nav.view == ProjectView.code && nav.taskId == null && nav.projectId == id;
        if (inCode && s.panelOpen) {
          s.togglePanel();
          _focusContent();
          return;
        }
        view(ProjectView.code);
        if (!s.panelOpen) s.togglePanel();
        if (s.terms.isEmpty && s.restored) await s.newTerminal(Desk.shellName);
        s.focusTerminal();
      },
      Cmd.leaveFocus: _focusContent,
      Cmd.switchPane: () => _sidebarFocus.hasFocus ? _focusContent() : _sidebarFocus.requestFocus(),
    };
  }

  void _focusContent() {
    _contentFocus.requestFocus();
    focusContent.value++;
  }

  @override
  Widget build(BuildContext context) {
    // relayd decides what is worth a notification; macOS shows it while
    // Relay is in the background. In front, mentions elsewhere get a toast.
    ref.listen(notifyProvider, (_, next) {
      final n = next.value;
      if (n == null) return;
      NativeNotifications.instance.post(
        id: '${n['kind']}-${n['taskId'] ?? n['messageId'] ?? DateTime.now().microsecondsSinceEpoch}',
        title: '${n['title']}',
        body: '${n['body']}',
        info: {'taskId': ?n['taskId'], 'channelId': ?n['channelId']},
      );
      final nav = ref.read(navProvider);
      if (n['kind'] == 'mention' && !(nav.page == AppPage.channel && nav.channelId == n['channelId'])) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          width: 460,
          backgroundColor: context.c.box,
          content: Text('${n['title']}: ${n['body']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.t(12)),
          action: SnackBarAction(label: 'Open', onPressed: () => ref.read(navProvider.notifier).channel('${n['channelId']}')),
        ));
      }
    });
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

    // Where you are, so the next launch opens there.
    ref.listen(navProvider, (_, next) {
      ref.read(clientProvider).call(M.uiSet, {'key': 'nav', 'value': jsonEncode(next.toJson())}).catchError((Object _) => null);
    });
    final nav = ref.watch(navProvider);
    final data = ref.watch(dataProvider);
    // Default to the first project once data arrives.
    if (nav.page == AppPage.project && nav.projectId == null && data.projects.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(navProvider.notifier).project(data.projects.first.id));
    }
    _debugNav(data);
    // Dock badge: what is waiting on you.
    final waiting = data.tasksOf(null).where((t) => inSmartList(AppPage.waiting, t)).length;
    if (waiting != _badge) {
      _badge = waiting;
      NativeNotifications.instance.badge(waiting);
    }
    // The menu bar item: running, waiting on you, and those tasks.
    final waitingTasks = data.tasksOf(null).where((t) => inSmartList(AppPage.waiting, t)).toList();
    SystemBridge.instance.status(
      running: data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).length,
      waiting: waitingTasks.length,
      paused: _paused,
      items: [for (final t in waitingTasks.take(6)) (t.id, '${data.keyOf(t)}  ${t.title}')],
    );

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
        AppPage.agent => nav.agentId == null ? const FleetPage() : AgentPage(agentId: nav.agentId!),
        AppPage.settings => const SettingsPage(),
        AppPage.channel => nav.channelId == null ? const SettingsPage() : ChannelPage(channelId: nav.channelId!),
        AppPage.team => nav.teamId == null ? const FleetPage() : TeamPage(teamId: nav.teamId!, agentId: nav.agentId),
        AppPage.home => const MissionControl(),
        AppPage.activity => const ActivityPage(),
      };
    }

    final chatOpen = ref.watch(chatProvider.select((s) => s.open));
    _route = ModalRoute.of(context);
    if (_onboarding) {
      Commands.instance.unregister();
    } else {
      Commands.instance.register(_handlers(data, nav));
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => ref.read(navProvider.notifier).closeTask(),
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        child: Scaffold(
          body: _onboarding
              ? OnboardingPage(onDone: () => setState(() => _onboarding = false))
              : Column(children: [
                  const UpgradeBanner(),
                  Expanded(
                    child: ResizableSplit(
                      id: 'shell.sidebar',
                      initial: 220,
                      min: 180,
                      keepOther: 640,
                      first: Sidebar(focusNode: _sidebarFocus),
                      // The chat sits on the right of every page.
                      second: ResizableSplit(
                        id: 'shell.chat',
                        sized: SplitSide.second,
                        initial: 380,
                        min: 320,
                        keepOther: 560,
                        collapsedTo: chatOpen ? null : 0,
                        first: Focus(focusNode: _contentFocus, child: content),
                        second: chatOpen ? const ChatPanel() : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ]),
        ),
      ),
    );
  }
}
