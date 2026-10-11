import 'dart:io';

import 'package:flutter/services.dart';

/// The Mac app's native side (macos/Runner): the menu bar item, relayd at
/// login, and Sparkle updates. A no-op elsewhere.
class SystemBridge {
  SystemBridge._();
  static final instance = SystemBridge._();

  static const _system = MethodChannel('relay/system');
  static const _updater = MethodChannel('relay/updater');

  /// Menu bar choices: `openTask {taskId}`, `pause`, `resume`.
  void Function(String action, Map<String, Object?> args)? onMenu;

  bool get _mac => Platform.isMacOS;
  String _last = '';

  void init() {
    if (!_mac) return;
    _system.setMethodCallHandler((call) async {
      if (call.method == 'menu') {
        final args = (call.arguments as Map?)?.map((k, v) => MapEntry('$k', v as Object?)) ?? {};
        onMenu?.call('${args['action']}', args);
      }
    });
  }

  Future<T?> _call<T>(MethodChannel ch, String method, [Object? args]) async {
    if (!_mac) return null;
    try {
      return await ch.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  /// What the menu bar shows; sent only when it changes.
  Future<void> status({required int running, required int waiting, required bool paused, required List<(String, String)> items}) async {
    final key = '$running|$waiting|$paused|${items.map((i) => i.$1).join(',')}';
    if (key == _last) return;
    _last = key;
    await _call<void>(_system, 'status', {
      'running': running,
      'waiting': waiting,
      'paused': paused,
      'items': [for (final (id, title) in items) {'id': id, 'title': title}],
    });
  }

  Future<void> keepInMenuBar(bool on) => _call<void>(_system, 'keepInMenuBar', {'on': on});

  /// enabled, off, needsApproval, notFound or unsupported; null off the Mac.
  Future<String?> loginItem() => _call<String>(_system, 'loginItem');
  Future<String?> setLoginItem(bool on) => _call<String>(_system, 'setLoginItem', {'on': on});

  Future<bool> canUpdate() async => await _call<bool>(_updater, 'isAvailable') ?? false;
  Future<void> checkForUpdates() => _call<void>(_updater, 'check');
}
