import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/relay_data.dart';
import '../ui/platform.dart';
import 'commands.dart';

/// The macOS menu bar: Relay's commands with their keys, so they can be
/// found by looking (design P06). The keys themselves are handled by
/// [Commands.handleKey] first, so a menu item never fires twice.
class RelayMenus extends ConsumerWidget {
  const RelayMenus({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Desk.isMac) return child;
    final connected = ref.watch(connectionProvider).status == ConnStatus.connected;
    final projects = connected ? ref.watch(dataProvider).projects : const [];
    final all = {for (final c in commands) c.id: c};

    PlatformMenuItem item(String id, {String? label}) {
      final c = all[id]!;
      final key = c.keys.first;
      return PlatformMenuItem(
        label: label ?? c.label,
        shortcut: key is MenuSerializableShortcut ? key : null,
        onSelected: () => Commands.instance.run(id),
      );
    }

    List<PlatformMenuItem> provided(List<PlatformProvidedMenuItemType> types) => [
      for (final t in types)
        if (PlatformProvidedMenuItem.hasMenu(t)) PlatformProvidedMenuItem(type: t),
    ];

    return PlatformMenuBar(
      menus: [
        PlatformMenu(label: 'Relay', menus: [
          PlatformMenuItemGroup(members: provided([PlatformProvidedMenuItemType.about])),
          PlatformMenuItemGroup(members: [item(Cmd.settings)]),
          PlatformMenuItemGroup(members: provided([PlatformProvidedMenuItemType.servicesSubmenu])),
          PlatformMenuItemGroup(members: provided([
            PlatformProvidedMenuItemType.hide,
            PlatformProvidedMenuItemType.hideOtherApplications,
            PlatformProvidedMenuItemType.showAllApplications,
          ])),
          PlatformMenuItemGroup(members: provided([PlatformProvidedMenuItemType.quit])),
        ]),
        PlatformMenu(label: 'File', menus: [item(Cmd.newTask)]),
        PlatformMenu(label: 'Go', menus: [
          PlatformMenuItemGroup(members: [item(Cmd.home), item(Cmd.needsYou), item(Cmd.agents)]),
          if (projects.isNotEmpty)
            PlatformMenuItemGroup(members: [
              for (var i = 0; i < projects.length && i < 9; i++) item(Cmd.project(i), label: projects[i].name),
            ]),
          PlatformMenuItemGroup(members: [item(Cmd.back), item(Cmd.forward)]),
          PlatformMenuItemGroup(members: [item(Cmd.quickFind), item(Cmd.askAgent), item(Cmd.switchPane)]),
        ]),
        PlatformMenu(label: 'View', menus: [
          PlatformMenuItemGroup(members: [for (var i = 0; i < viewNames.length; i++) item(Cmd.view(i))]),
          PlatformMenuItemGroup(members: [item(Cmd.toggleTerminal), item(Cmd.leaveFocus)]),
          PlatformMenuItemGroup(members: provided([PlatformProvidedMenuItemType.toggleFullScreen])),
        ]),
        PlatformMenu(label: 'Window', menus: provided([
          PlatformProvidedMenuItemType.minimizeWindow,
          PlatformProvidedMenuItemType.zoomWindow,
          PlatformProvidedMenuItemType.arrangeWindowsInFront,
        ])),
        PlatformMenu(label: 'Help', menus: [item(Cmd.keyboardMap)]),
      ],
      child: child,
    );
  }
}
