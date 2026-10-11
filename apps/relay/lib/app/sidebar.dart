import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';

import '../data/nav.dart';
import '../data/relay_data.dart';
import '../features/project/project_dialogs.dart';
import '../features/teams/team_page.dart';
import '../ui/widgets.dart';
import 'theme.dart';

/// Which tasks each smart list shows.
bool inSmartList(AppPage p, Task t) => switch (p) {
  AppPage.inbox => t.data['attention'] != null || t.status == TaskStatus.review,
  AppPage.running => t.status == TaskStatus.running,
  AppPage.review => t.status == TaskStatus.review && t.data['attention'] == null,
  AppPage.waiting => t.data['attention'] == 'permission' || t.data['attention'] == 'question' || t.data['attention'] == 'approval',
  _ => false,
};

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, this.focusNode});

  /// With focus (⌃Tab), ↑ and ↓ move between the places it lists.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Every place in order, as it is built, for the arrow keys.
    final places = <(bool, VoidCallback)>[];
    _Row row({IconData? icon, Color? iconColor, Widget? leading, required String label, int? count, Widget? trailing, bool selected = false, bool subtle = false, required VoidCallback onTap}) {
      places.add((selected, onTap));
      return _Row(icon: icon, iconColor: iconColor, leading: leading, label: label, count: count, trailing: trailing, selected: selected, subtle: subtle, onTap: onTap);
    }

    final c = context.c;
    final data = ref.watch(dataProvider);
    final nav = ref.watch(navProvider);
    final n = ref.read(navProvider.notifier);
    final tasks = data.tasksOf(null);
    int count(AppPage p) => tasks.where((t) => inSmartList(p, t)).length;
    final running = data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).length;
    final onTask = nav.taskId != null;
    final sync = ref.watch(syncStatusProvider);
    final inTeam = sync['inTeam'] == true;
    final me = ref.read(clientProvider).hello['deviceId'] as String? ?? '';
    final online = data.onlineDevices(sync, me);
    final unread = ref.watch(unreadProvider);
    // Teammates: one row per person, online if any of their devices is.
    final people = <String, List<DeviceInfo>>{};
    for (final d in data.devices.where((d) => d.id != me)) {
      (people[d.person.isEmpty ? d.name : d.person] ??= []).add(d);
    }

    return _ArrowNav(focusNode: focusNode, places: places, child: Container(
      color: c.sidebar,
      // macOS draws the traffic lights over the sidebar; elsewhere the
      // window has its own title bar.
      padding: EdgeInsets.fromLTRB(10, Platform.isMacOS ? 34 : 12, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(7)),
              child: const Icon(LucideIcons.listChecks, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Relay', style: context.t(13, w: FontWeight.w700)),
                Text(
                  inTeam
                      ? '${sync['teamName']} · ${online.length} online'
                      : (running == 0 ? 'No agents running' : '$running agent${running == 1 ? '' : 's'} running'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t(11, color: c.text2),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            row(icon: LucideIcons.inbox, iconColor: c.accentIcon, label: 'Inbox', count: count(AppPage.inbox),
                selected: !onTask && nav.page == AppPage.inbox, onTap: () => n.page(AppPage.inbox)),
            row(icon: LucideIcons.zap, iconColor: c.success, label: 'Running now', count: count(AppPage.running),
                selected: !onTask && nav.page == AppPage.running, onTap: () => n.page(AppPage.running)),
            row(icon: LucideIcons.gitPullRequest, iconColor: c.warning, label: 'Needs review', count: count(AppPage.review),
                selected: !onTask && nav.page == AppPage.review, onTap: () => n.page(AppPage.review)),
            row(icon: LucideIcons.triangleAlert, iconColor: c.danger, label: 'Waiting on you', count: count(AppPage.waiting),
                selected: !onTask && nav.page == AppPage.waiting, onTap: () => n.page(AppPage.waiting)),
            const SizedBox(height: 14),
            _Header('Projects', onAdd: () => showNewProjectDialog(context, ref)),
            for (final p in data.projects) ...[
              row(
                leading: _Tile(p.key.substring(0, 1), hexColor(p.color)),
                label: p.name,
                count: data.tasksOf(p.id).where((t) => t.status != TaskStatus.done).length,
                selected: !onTask && nav.page == AppPage.project && nav.projectId == p.id && nav.repoFilter == null,
                subtle: nav.page == AppPage.project && nav.projectId == p.id,
                onTap: () => n.project(p.id),
              ),
              if (nav.page == AppPage.project && nav.projectId == p.id)
                for (final r in data.reposOf(p.id)) _repoRow(places, ref, r, !onTask && nav.repoFilter == r.id),
            ],
            const SizedBox(height: 14),
            _Header('Agent teams', onAdd: () => showNewTeamDialog(context, ref), addTooltip: 'New agent team'),
            for (final t in data.teams)
              Builder(builder: (context) {
                final live = data.all<Run>(Kind.run).any((r) => t.members.contains(r.agentId) && RunStatus.isActive(r.status));
                return row(
                  icon: LucideIcons.users,
                  iconColor: c.text2,
                  label: t.name,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (live) ...[Dot(c.success, size: 6), const SizedBox(width: 6)],
                    Text('${t.members.length}', style: context.t(11, color: !onTask && nav.page == AppPage.team && nav.teamId == t.id ? Colors.white : c.text2)),
                  ]),
                  selected: !onTask && nav.page == AppPage.team && nav.teamId == t.id,
                  onTap: () => n.team(t.id),
                );
              }),
            row(icon: LucideIcons.bot, iconColor: c.accentIcon, label: 'All agents', selected: !onTask && nav.page == AppPage.agents, onTap: () => n.page(AppPage.agents)),
            for (final a in data.clis.where((a) => a.binaryPath != null))
              row(
                leading: AgentTile(agent: a, size: 14),
                label: a.name,
                trailing: _agentTrailing(context, data, a),
                onTap: () => n.page(AppPage.agents),
              ),
            if (people.isNotEmpty) ...[
              const SizedBox(height: 14),
              _Header('Team', onTap: () => n.page(AppPage.settings)),
              for (final MapEntry(key: person, value: devices) in people.entries)
                Builder(builder: (context) {
                  final isOnline = devices.any((d) => online.contains(d.id));
                  final shared = devices.where((d) => d.shareAgents).expand((d) => d.agents).map((a) => '${a['name']}'.split(' ').first).toSet();
                  return row(
                    leading: Avatar(person, size: 14, color: isOnline ? null : c.text3),
                    label: person,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (shared.isNotEmpty) Text('+ ${shared.first}', style: context.t(11, color: c.text3)),
                      if (!isOnline && shared.isEmpty) Text('away', style: context.t(11, color: c.text3)),
                      const SizedBox(width: 6),
                      if (isOnline) Dot(c.success),
                    ]),
                    onTap: () => n.page(AppPage.settings),
                  );
                }),
            ],
            if (data.channels.isNotEmpty) ...[
              const SizedBox(height: 14),
              _Header('Channels'),
              for (final ch in data.channels)
                row(
                  icon: LucideIcons.hash,
                  iconColor: c.text2,
                  label: ch.name,
                  count: (unread[ch.id] ?? 0) > 0 ? unread[ch.id] : null,
                  selected: !onTask && nav.page == AppPage.channel && nav.channelId == ch.id,
                  onTap: () => n.channel(ch.id),
                ),
            ],
          ]),
        ),
        row(
          icon: LucideIcons.settings,
          iconColor: c.text2,
          label: 'Settings',
          trailing: _syncTrailing(context, ref.watch(syncStatusProvider)),
          selected: !onTask && nav.page == AppPage.settings,
          onTap: () => n.page(AppPage.settings),
        ),
      ]),
    ));
  }

  /// Team sync at a glance: green synced, orange waiting, red failing.
  Widget? _syncTrailing(BuildContext context, Map<String, Object?> s) {
    if (s['inTeam'] != true) return null;
    final c = context.c;
    final pending = (s['pendingOps'] as num?)?.toInt() ?? 0;
    final (color, tip) = s['error'] != null
        ? (c.danger, 'Sync: ${s['error']}')
        : (pending > 0 ? (c.warning, '$pending changes waiting to sync') : (c.success, 'Synced with ${s['teamName']}'));
    return Tooltip(message: tip, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(LucideIcons.cloud, size: 12, color: c.text2),
      const SizedBox(width: 4),
      Dot(color),
    ]));
  }

  Widget _agentTrailing(BuildContext context, DataSnapshot data, AgentProfile a) {
    final active = data.all<Run>(Kind.run).where((r) => r.agentId == a.id && RunStatus.isActive(r.status)).length;
    final limited = a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(limited ? 'limit' : '$active/${a.slots}', style: context.t(11, color: limited ? context.c.warning : context.c.text2)),
      const SizedBox(width: 6),
      Dot(limited ? context.c.warning : (active > 0 ? context.c.success : context.c.text3)),
    ]);
  }
}

Widget _repoRow(List<(bool, VoidCallback)> places, WidgetRef ref, Repo r, bool selected) {
  places.add((selected, () => ref.read(navProvider.notifier).repoFilter(selected ? null : r.id)));
  return _RepoRow(repo: r, selected: selected);
}

/// ↑/↓ (or J/K) move to the previous or next place while the sidebar has
/// focus; a line on its edge shows that it does.
class _ArrowNav extends StatelessWidget {
  const _ArrowNav({required this.focusNode, required this.places, required this.child});
  final FocusNode? focusNode;
  final List<(bool, VoidCallback)> places;
  final Widget child;

  void _step(int d) {
    if (places.isEmpty) return;
    final i = places.indexWhere((p) => p.$1);
    places[(i + d).clamp(0, places.length - 1)].$2();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    onKeyEvent: (node, e) {
      if (e is KeyUpEvent) return KeyEventResult.ignored;
      final k = e.logicalKey;
      if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.keyJ) {
        _step(1);
      } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyK) {
        _step(-1);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
    child: focusNode == null
        ? child
        : ListenableBuilder(
            listenable: focusNode!,
            builder: (context, child) => Container(
              foregroundDecoration: focusNode!.hasFocus ? BoxDecoration(border: Border(right: BorderSide(color: context.c.accentIcon, width: 2))) : null,
              child: child,
            ),
            child: child,
          ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.letter, this.color);
  final String letter;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
    child: Text(letter, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: Colors.white)),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.onAdd, this.onTap, this.addTooltip = 'New project'});
  final String text;
  final VoidCallback? onAdd;
  final VoidCallback? onTap;
  final String addTooltip;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 4, 4),
    child: Row(children: [
      Expanded(child: GestureDetector(onTap: onTap, child: Text(text, style: context.label))),
      if (onAdd != null) IconBtn(LucideIcons.plus, size: 12, onTap: onAdd, tooltip: addTooltip, color: context.c.text3),
    ]),
  );
}

class _Row extends StatelessWidget {
  const _Row({this.icon, this.iconColor, this.leading, required this.label, this.count, this.trailing, this.selected = false, this.subtle = false, this.onTap});
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String label;
  final int? count;
  final Widget? trailing;
  final bool selected;
  final bool subtle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : context.c.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Hoverable(
        selected: selected || subtle,
        selectedColor: selected ? context.c.accent : context.c.inner,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(children: [
            if (icon != null) Icon(icon, size: 15, color: selected ? Colors.white : iconColor),
            ?leading,
            const SizedBox(width: 8),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(13, w: selected ? FontWeight.w600 : FontWeight.w400, color: fg))),
            if (trailing != null) trailing! else if (count != null && count! > 0) Text('$count', style: context.t(11, color: selected ? Colors.white : context.c.text2)),
          ]),
        ),
      ),
    );
  }
}

class _RepoRow extends ConsumerWidget {
  const _RepoRow({required this.repo, required this.selected});
  final Repo repo;
  final bool selected;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dataProvider);
    final cloned = repo.data['cloned'] != false && repo.data['localPath'] != null;
    final live = data.all<ChangeEntry>(Kind.change).any((c) => c.repoId == repo.id && c.status == 'running');
    final open = data.tasksOf(repo.projectId).where((t) => t.status != TaskStatus.done && t.repoIds.contains(repo.id)).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1, left: 22),
      child: Hoverable(
        selected: selected,
        onTap: () => ref.read(navProvider.notifier).repoFilter(selected ? null : repo.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            Dot(hexColor(repo.color), size: 8),
            const SizedBox(width: 8),
            Expanded(child: Text(repo.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: selected ? Colors.white : (cloned ? context.c.text : context.c.text2)))),
            if (repo.agentPolicy == 'ask') Icon(LucideIcons.lock, size: 11, color: context.c.warning),
            if (!cloned) Icon(LucideIcons.download, size: 11, color: context.c.text3),
            if (live) ...[const SizedBox(width: 4), Dot(context.c.success, size: 6)],
            if (open > 0) ...[const SizedBox(width: 6), Text('$open', style: context.t(11, color: selected ? Colors.white : context.c.text2))],
          ]),
        ),
      ),
    );
  }
}
