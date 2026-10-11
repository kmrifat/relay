import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_core/relay_core.dart';

import '../app/theme.dart' show hexColor;
import '../data/relay_data.dart';

/// What the phone knows about its Mac and the team, derived from synced
/// records (the Mac's device record carries its agents and their numbers).
class PhoneView {
  PhoneView(this.data, this.sync, this.me);

  final DataSnapshot data;
  final Map<String, Object?> sync;
  final String me;

  String? get macId => sync['pairedMac'] as String?;

  /// The person this phone belongs to (set when pairing).
  String get myName => data.get<DeviceInfo>(Kind.device, me)?.person ?? mac?.person ?? 'You';
  String get macName => sync['pairedMacName'] as String? ?? 'your Mac';
  DeviceInfo? get mac => data.get<DeviceInfo>(Kind.device, macId);
  bool get paired => macId != null;
  Set<String> get online => data.onlineDevices(sync, me);
  bool get macOnline => macId != null && online.contains(macId);

  /// "your Mac", "Sara's Mac".
  String whereRuns(String? deviceId) {
    if (deviceId == null || deviceId == macId) return 'your Mac';
    final d = data.get<DeviceInfo>(Kind.device, deviceId);
    if (d == null) return 'a teammate\'s Mac';
    return d.person.isEmpty ? d.name : '${d.person.split(' ').first}\'s Mac';
  }

  /// An agent's display bits wherever it runs.
  ({String name, String letter, Color color}) agent(String? id, {String? deviceId}) {
    final local = data.get<AgentProfile>(Kind.agent, id);
    if (local != null) return (name: local.name, letter: local.letter, color: hexColor(local.color));
    for (final d in data.devices) {
      if (deviceId != null && d.id != deviceId) continue;
      for (final a in d.agents) {
        if (a['id'] == id) return (name: '${a['name']}', letter: '${a['letter'] ?? '?'}', color: hexColor(a['color'] as String?));
      }
    }
    final s = id ?? 'Agent';
    return (name: s, letter: s.isEmpty ? '?' : s.substring(0, 1).toUpperCase(), color: const Color(0xFF5A5A5E));
  }

  /// Teammates' shared agents (not this Mac's).
  List<(DeviceInfo, Map<String, Object?>)> get sharedAgents => [
    for (final d in data.devices.where((d) => d.id != macId && d.id != me && d.shareAgents))
      for (final a in d.agents) (d, a),
  ];

  List<Task> get asks => data.tasksOf(null).where((t) => t.data['attention'] == 'question' || t.data['attention'] == 'permission').toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<Task> get review => data.tasksOf(null).where((t) => t.status == TaskStatus.review).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Recent messages that @mention me.
  List<Message> mentions(String myName) {
    final handles = {myName.toLowerCase().replaceAll(' ', ''), myName.toLowerCase().split(' ').first};
    final since = DateTime.now().subtract(const Duration(days: 3));
    return data.all<Message>(Kind.message)
        .where((m) => m.createdAt.isAfter(since) && m.deviceId != me && m.deviceId != macId && m.mentions.any((h) => handles.contains(h.toLowerCase())))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  int get runningCount => data.all<Run>(Kind.run).where((r) => RunStatus.isActive(r.status)).length;
}

final phoneViewProvider = Provider<PhoneView>((ref) {
  final data = ref.watch(dataProvider);
  final sync = ref.watch(syncStatusProvider);
  final me = ref.watch(clientProvider).hello['deviceId'] as String? ?? '';
  return PhoneView(data, sync, me);
});

/// "2 min", "12 min", "1 h".
String shortAgo(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h';
  return '${d.inDays} d';
}

/// Two choices from a question like "…through Resend or Cloudflare Email
/// Workers?", for one-tap answers. Null when it isn't an either/or.
(String, String)? choicesIn(String question) {
  final q = question.trim();
  if (!q.endsWith('?')) return null;
  final parts = q.substring(0, q.length - 1).split(' or ');
  if (parts.length != 2) return null;
  final before = parts[0].trim().split(RegExp(r'\s+'));
  final a = before.last;
  final b = parts[1].trim().split(RegExp(r'\s+')).take(3).join(' ');
  if (a.isEmpty || b.isEmpty || a.length > 24) return null;
  return (a[0].toUpperCase() + a.substring(1), b[0].toUpperCase() + b.substring(1));
}
