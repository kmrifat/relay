import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';
import 'mission_control.dart';

/// Everything agents did lately (⌘⇧A): messages between them, handoffs,
/// reports, channel posts and runs that ended, by product and kind.
class ActivityPage extends ConsumerStatefulWidget {
  const ActivityPage({super.key});
  @override
  ConsumerState<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends ConsumerState<ActivityPage> {
  String? projectId;
  String kind = 'all';

  static const kinds = [
    ('all', 'All'),
    ('agent-message', 'Messages'),
    ('handoff', 'Handoffs'),
    ('report', 'Reports'),
    ('run', 'Runs'),
    ('post', 'Posts'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final data = ref.watch(dataProvider);
    final feed = (ref.watch(activityProvider(projectId)).value ?? const []).where((e) => kind == 'all' || e['kind'] == kind).toList();
    final project = data.projects.where((p) => p.id == projectId).firstOrNull;
    return Column(children: [
      Toolbar(
        title: 'Activity',
        subtitle: 'The last two days · ${feed.length} item${feed.length == 1 ? '' : 's'}',
        middle: [
          Segmented<String>(small: true, options: kinds, value: kind, onChanged: (v) => setState(() => kind = v)),
          const SizedBox(width: 8),
          Builder(builder: (context) => Btn(project?.name ?? 'All products', small: true, onTap: () async {
            final box = context.findRenderObject() as RenderBox;
            final v = await showMenuAt<String>(context, box.localToGlobal(Offset(0, box.size.height)), [
              ('', 'All products', null),
              for (final p in data.projects) (p.id, p.name, null),
            ]);
            if (v != null) setState(() => projectId = v.isEmpty ? null : v);
          })),
        ],
      ),
      Container(height: 1, color: c.separator),
      Expanded(
        child: feed.isEmpty
            ? Center(child: Text('Nothing yet. When agents work, message each other or hand work on, it shows here.', style: context.t(13, color: c.text2)))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                itemCount: feed.length,
                separatorBuilder: (_, _) => const Hairline(),
                itemBuilder: (context, i) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: ActivityRow(item: feed[i], data: data)),
              ),
      ),
    ]);
  }
}
