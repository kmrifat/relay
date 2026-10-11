import 'dart:io';

import 'package:flutter/services.dart';

/// System notifications and the badge (macos/Runner and ios/Runner, both on
/// `relay/notify`); on iPhone also the APNs token for push. A no-op
/// elsewhere until those platforms get theirs.
class NativeNotifications {
  NativeNotifications._();
  static final instance = NativeNotifications._();

  static const _channel = MethodChannel('relay/notify');
  void Function(Map<String, Object?> info)? onOpen;

  /// iPhone: the APNs device token, once registered.
  void Function(String token, bool sandbox)? onToken;

  bool get _supported => Platform.isMacOS || Platform.isIOS;

  void init() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'open':
          final info = (args['info'] as Map?)?.map((k, v) => MapEntry('$k', v as Object?)) ?? {};
          onOpen?.call(info);
        case 'token':
          onToken?.call('${args['token']}', args['sandbox'] == true);
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

  /// iPhone: ask for permission and register with APNs ([onToken]).
  Future<void> registerForPush() async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('register');
    } on MissingPluginException {
      // ignore
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
