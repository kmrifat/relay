import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/nav.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

const _hourW = 80.0;
const _laneH = 46.0;
const _labelW = 204.0;

class _Bar {
  _Bar(this.start, this.end, this.label, this.kind, {this.task, this.run});
  DateTime start;
  DateTime end;
  final String label;

  /// running, done, failed, scheduled
  final String kind;
  final Task? task;
  final Run? run;
}

/// Agents' runs over the day (design T08).
class TimelineView extends ConsumerStatefulWidget {
  const TimelineView({super.key, required this.projectId});
  final String projectId;
  @override
  ConsumerState<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends ConsumerState<TimelineView> {
  final _h = ScrollController();
  late DateTime day;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    day = DateTime(n.year, n.month, n.day);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_h.hasClients) _h.jumpTo(((n.hour - 2).clamp(0, 14)) * _hourW);
    });
    // Repaint the now line once a minute, not every frame.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    _h.dispose();
    super.dispose();
  }

  double _x(DateTime t) => t.toLocal().difference(day).inSeconds / 3600 * _hourW;
  DateTime _t(double x) => day.add(Duration(seconds: (x / _hourW * 3600).round()));

  Duration _typical(DataSnapshot data, String agentId) {
    final done = data.all<Run>(Kind.run).where((r) => r.agentId == agentId && r.status == RunStatus.done && r.startedAt != null && r.endedAt != null).toList();
    if (done.isEmpty) return const Duration(minutes: 20);
    final total = done.fold<int>(0, (s, r) => s + r.endedAt!.difference(r.startedAt!).inSeconds);
    return Duration(seconds: (total / done.length).round().clamp(120, 4 * 3600));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final now = DateTime.now();
    final dayEnd = day.add(const Duration(days: 1));
    final tasks = {for (final t in data.tasksOf(widget.projectId)) t.id: t};
    final agents = data.agents.where((a) => a.binaryPath != null || data.all<Run>(Kind.run).any((r) => r.agentId == a.id)).toList();

    // Lanes: each agent gets as many lanes as slots it used today (≥ 1).
    final lanes = <(AgentProfile, int, List<_Bar>)>[];
    for (final a in agents) {
      final bars = <_Bar>[];
      for (final r in data.all<Run>(Kind.run).where((r) => r.agentId == a.id && tasks.containsKey(r.taskId))) {
        final s = r.startedAt?.toLocal();
        if (s == null) continue;
        final active = RunStatus.isActive(r.status);
        final e = active ? (s.add(_typical(data, a.id)).isAfter(now) ? s.add(_typical(data, a.id)) : now.add(const Duration(minutes: 5))) : (r.endedAt?.toLocal() ?? s);
        if (e.isBefore(day) || s.isAfter(dayEnd)) continue;
        bars.add(_Bar(s, e.difference(s).inMinutes < 4 ? s.add(const Duration(minutes: 4)) : e, data.keyOf(tasks[r.taskId]!), active ? 'running' : (r.status == RunStatus.done ? 'done' : 'failed'), task: tasks[r.taskId], run: r));
      }
      // Queued work for this agent, laid out after what's running.
      var cursor = now;
      for (final t in tasks.values.where((t) => t.status == TaskStatus.queued && _assignedTo(t) == a.id)) {
        final at = DateTime.tryParse(t.startAt)?.toLocal();
        final start = at != null && at.isAfter(cursor) ? at : cursor;
        final end = start.add(_typical(data, a.id));
        bars.add(_Bar(start, end, data.keyOf(t), 'scheduled', task: t));
        if (at == null) cursor = end;
      }
      bars.sort((x, y) => x.start.compareTo(y.start));
      final laneEnds = <DateTime>[];
      final assigned = <int, List<_Bar>>{};
      for (final b in bars) {
        var lane = laneEnds.indexWhere((e) => !e.isAfter(b.start));
        if (lane == -1) {
          laneEnds.add(b.end);
          lane = laneEnds.length - 1;
        } else {
          laneEnds[lane] = b.end;
        }
        (assigned[lane] ??= []).add(b);
      }
      final count = laneEnds.isEmpty ? 1 : laneEnds.length;
      for (var i = 0; i < count; i++) {
        lanes.add((a, i, assigned[i] ?? []));
      }
    }

    final overnight = tasks.values.where((t) {
      final at = DateTime.tryParse(t.startAt)?.toLocal();
      return t.status == TaskStatus.queued && at != null && !at.isBefore(dayEnd);
    }).toList();

    final width = 24 * _hourW;
    final height = lanes.length * _laneH;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: SingleChildScrollView(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Lane labels.
            SizedBox(
              width: _labelW,
              child: Column(children: [
                Container(height: 40, color: c.bar, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 16),
                    child: Text('${_weekday(day)}, ${day.day} ${_month(day)}', style: context.t(12, w: FontWeight.w600))),
                for (var i = 0; i < lanes.length; i++)
                  Container(
                    height: _laneH,
                    color: i.isEven ? c.window : c.zebra,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      AgentTile(agent: lanes[i].$1, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(lanes[i].$1.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12)),
                          Text(_limited(lanes[i].$1) ? 'limit' : 'slot ${lanes[i].$2 + 1}', style: context.t(10, color: _limited(lanes[i].$1) ? c.warning : c.text3)),
                        ]),
                      ),
                    ]),
                  ),
              ]),
            ),
            Container(width: 1, height: height + 40, color: c.inner),
            Expanded(
              child: SingleChildScrollView(
                controller: _h,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  height: height + 40,
                  child: Stack(children: [
                    // Header + lane backgrounds + hour lines.
                    Positioned(left: 0, top: 0, right: 0, height: 40, child: Container(color: c.bar)),
                    for (var i = 0; i < lanes.length; i++)
                      Positioned(left: 0, right: 0, top: 40 + i * _laneH, height: _laneH, child: Container(color: i.isEven ? c.window : c.zebra)),
                    for (var h = 0; h < 24; h++) ...[
                      Positioned(left: h * _hourW + 4, top: 14, child: Text('${h.toString().padLeft(2, '0')}:00', style: context.t(11, color: c.text3))),
                      Positioned(left: h * _hourW, top: 40, width: 1, height: height, child: Container(color: c.inner.withValues(alpha: 0.6))),
                    ],
                    // Limit windows.
                    for (var i = 0; i < lanes.length; i++)
                      if (_limited(lanes[i].$1) && lanes[i].$2 == 0)
                        Positioned(
                          left: _x(now),
                          top: 40 + i * _laneH + 5,
                          width: (_x(lanes[i].$1.limitedUntil!) - _x(now)).clamp(20, width),
                          height: _laneH - 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(color: c.warning.withValues(alpha: 0.08), border: Border.all(color: c.warning.withValues(alpha: 0.35)), borderRadius: BorderRadius.circular(6)),
                            child: Text('Limit reached · back at ${TimeOfDay.fromDateTime(lanes[i].$1.limitedUntil!.toLocal()).format(context)}',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(11, color: c.warning)),
                          ),
                        ),
                    // Bars.
                    for (var i = 0; i < lanes.length; i++)
                      for (final b in lanes[i].$3) _bar(context, b, i, now),
                    // Now line.
                    Positioned(left: _x(now) - 1, top: 30, width: 2, height: height + 10, child: Container(color: c.danger)),
                    Positioned(
                      left: _x(now) - 18,
                      top: 22,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: c.danger, borderRadius: BorderRadius.circular(4)),
                        child: Text(TimeOfDay.fromDateTime(now).format(context), style: context.t(10, w: FontWeight.w700, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: c.inner))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Box(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(LucideIcons.clock, size: 14, color: c.accentIcon),
                  const SizedBox(width: 8),
                  Text('Tonight · after plans reset', style: context.t(13, w: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('tasks set to start tomorrow or later', style: context.t(11, color: c.text3)),
                ]),
                const SizedBox(height: 8),
                if (overnight.isEmpty)
                  Text('Nothing scheduled. In a task, choose "Tonight at 01:00" to run it after limits reset.', style: context.t(12, color: c.text2))
                else
                  for (final t in overnight)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(children: [
                        SizedBox(width: 56, child: Text(data.keyOf(t), style: context.t(11, family: mono, color: c.text3))),
                        Expanded(child: Text(t.title, style: context.t(12))),
                        Text(DateTime.parse(t.startAt).toLocal().toString().substring(5, 16), style: context.t(11, color: c.text2)),
                      ]),
                    ),
              ]),
            ),
          ),
          const SizedBox(width: 16),
          Box(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _legend(context, c.success.withValues(alpha: 0.15), c.success, 'Running'),
              _legend(context, c.accentIcon.withValues(alpha: 0.08), c.accentIcon, 'Scheduled · drag to move'),
              _legend(context, c.inner, null, 'Done'),
              _legend(context, c.dangerWash, c.danger, 'Failed'),
              _legend(context, c.warning.withValues(alpha: 0.08), c.warning.withValues(alpha: 0.35), 'Plan limit'),
            ]),
          ),
        ]),
      ),
    ]);
  }

  bool _limited(AgentProfile a) => a.limitedUntil != null && a.limitedUntil!.isAfter(DateTime.now());

  String? _assignedTo(Task t) {
    for (final s in t.pipeline) {
      if (s.status != 'done' && s.status != 'skipped') return s.assigneeKind == 'agent' ? s.assignee : null;
    }
    return t.assigneeKind == 'agent' ? t.assignee : null;
  }

  Widget _bar(BuildContext context, _Bar b, int lane, DateTime now) {
    final c = context.c;
    final left = _x(b.start);
    final w = (_x(b.end) - left).clamp(14.0, 24 * _hourW);
    final (bg, border, fg) = switch (b.kind) {
      'running' => (c.success.withValues(alpha: 0.15), c.success, c.text),
      'done' => (c.inner, Colors.transparent, c.text2),
      'failed' => (c.dangerWash, c.danger, c.danger),
      _ => (c.accentIcon.withValues(alpha: 0.08), c.accentIcon, c.text),
    };
    final doneFrac = b.kind == 'running' ? ((_x(now) - left) / w).clamp(0.0, 1.0) : 0.0;
    Widget bar = Container(
      height: 28,
      decoration: BoxDecoration(color: bg, border: Border.all(color: border), borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        if (doneFrac > 0) FractionallySizedBox(widthFactor: doneFrac, child: Container(color: c.success.withValues(alpha: 0.35))),
        if (w >= 40)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              if (b.kind == 'done') Icon(LucideIcons.check, size: 11, color: c.text2),
              if (b.kind == 'failed') Icon(LucideIcons.x, size: 11, color: c.danger),
              if (b.kind == 'scheduled') Icon(b.task!.dependsOn.isNotEmpty ? LucideIcons.lock : LucideIcons.circleDot, size: 11, color: c.accentIcon),
              if (b.kind != 'running') const SizedBox(width: 4),
              Expanded(child: Text('${b.label} ${b.task?.title ?? ''}', maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: context.t(11, w: b.kind == 'running' ? FontWeight.w600 : FontWeight.w400, color: fg))),
            ]),
          ),
      ]),
    );
    bar = GestureDetector(
      onTap: () => b.task == null ? null : ref.read(navProvider.notifier).openTask(b.task!.id),
      onHorizontalDragUpdate: b.kind == 'scheduled'
          ? (d) => setState(() {
                final dur = b.end.difference(b.start);
                b.start = _t(_x(b.start) + d.delta.dx);
                b.end = b.start.add(dur);
              })
          : null,
      onHorizontalDragEnd: b.kind == 'scheduled'
          ? (_) {
              final start = b.start.isBefore(DateTime.now()) ? 'slot' : b.start.toUtc().toIso8601String();
              ref.read(clientProvider).call(M.tasksUpdate, {'id': b.task!.id, 'fields': {'startAt': start}});
            }
          : null,
      child: MouseRegion(cursor: b.kind == 'scheduled' ? SystemMouseCursors.resizeLeftRight : SystemMouseCursors.click, child: Tooltip(message: '${b.label} · ${b.task?.title ?? ''}', child: bar)),
    );
    return Positioned(left: left, top: 40 + lane * _laneH + 9, width: w, child: bar);
  }

  Widget _legend(BuildContext context, Color bg, Color? border, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 20, height: 10, decoration: BoxDecoration(color: bg, border: border == null ? null : Border.all(color: border), borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 8),
      Text(label, style: context.t(11, color: context.c.text2)),
    ]),
  );
}

String _weekday(DateTime d) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];
String _month(DateTime d) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1];
