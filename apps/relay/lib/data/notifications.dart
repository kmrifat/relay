import 'dart:convert';
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
    if (Platform.isWindows) {
      await _windowsToast(title, body);
      return;
    }
    if (Platform.isLinux) {
      // The desktop's notification daemon (libnotify), when there is one.
      try {
        await Process.run('notify-send', ['--app-name=Relay', title, body]);
      } on ProcessException {
        // No notify-send: the in-app toasts still show.
      }
      return;
    }
    if (!_supported) return;
    try {
      await _channel.invokeMethod('post', {'id': id, 'title': title, 'body': body, 'info': info});
    } on MissingPluginException {
      // Widget tests and other hosts without the native side.
    }
  }

  /// The AppUserModelID the installer gives Relay's Start menu shortcut
  /// (tool/release/windows_installer.iss), so toasts show as Relay.
  static const windowsAppId = 'binarycastle.Relay';

  /// A Windows toast through PowerShell's WinRT bridge: no native plugin.
  /// Text goes in as XML, the script as -EncodedCommand (no quoting).
  Future<void> _windowsToast(String title, String body) async {
    String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final script = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > \$null
\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
\$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>${esc(title).replaceAll("'", "''")}</text><text>${esc(body).replaceAll("'", "''")}</text></binding></visual></toast>')
\$toast = New-Object Windows.UI.Notifications.ToastNotification \$xml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$windowsAppId').Show(\$toast)
''';
    final units = <int>[];
    for (final c in script.codeUnits) {
      units
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    try {
      await Process.start('powershell.exe', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', base64Encode(units)], mode: ProcessStartMode.detached);
    } on ProcessException {
      // No PowerShell: the in-app toasts still show.
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
