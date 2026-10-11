import 'dart:io';

import 'package:flutter/services.dart';

/// macOS notifications and the Dock badge (macos/Runner, `relay/notify`).
/// A no-op elsewhere until those platforms get theirs.
class NativeNotifications {
  NativeNotifications._();
  static final instance = NativeNotifications._();

  static const _channel = MethodChannel('relay/notify');
  void Function(Map<String, Object?> info)? onOpen;

  bool get _supported => Platform.isMacOS;

  void init() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final info = ((call.arguments as Map?)?['info'] as Map?)?.map((k, v) => MapEntry('$k', v as Object?)) ?? {};
        onOpen?.call(info);
      }
    });
  }

  Future<void> post({required String id, required String title, required String body, Map<String, Object?> info = const {}}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('post', {'id': id, 'title': title, 'body': body, 'info': info});
    } on MissingPluginException {
      // Widget tests and other hosts without the native side.
    }
  }

  Future<void> badge(int count) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('badge', {'label': count > 0 ? '$count' : ''});
    } on MissingPluginException {
      // ignore
    }
  }
}
