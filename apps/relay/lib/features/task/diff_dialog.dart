import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

/// Shows a change entry's diff against its repo's base branch.
Future<void> showDiffDialog(BuildContext context, WidgetRef ref, ChangeEntry ch, Repo? repo) async {
  final client = ref.read(clientProvider);
  final text = await client.call<String>(M.gitDiff, {'path': ch.worktreePath, 'base': repo?.baseBranch ?? 'main'});
  final status = await client.list(M.gitStatus, {'path': ch.worktreePath});
  final untracked = status.where((s) => s['letter'] == 'U').map((s) => s['path']).toList();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final c = context.c;
      final lines = text.split('\n');
      return Dialog(
        child: SizedBox(
          width: 900,
          height: 640,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Text('${repo?.name ?? ''} · ${ch.branch} vs ${repo?.baseBranch ?? 'main'}', style: context.t(14, w: FontWeight.w700)),
                const SizedBox(width: 10),
                DiffNums(ch.additions, ch.deletions),
                const Spacer(),
                Btn('Close', onTap: () => Navigator.pop(context)),
              ]),
            ),
            if (untracked.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Text('New files not yet committed: ${untracked.join(', ')}', style: context.t(11, color: c.text2)),
              ),
            const Hairline(),
            Expanded(
              child: Container(
                color: c.codeBg,
                child: text.trim().isEmpty
                    ? Center(child: Text('No committed changes against ${repo?.baseBranch ?? 'main'} yet.', style: context.t(12, color: c.text2)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: lines.length,
                        itemExtent: 18,
                        itemBuilder: (context, i) {
                          final l = lines[i];
                          final color = l.startsWith('+++') || l.startsWith('---')
                              ? c.text2
                              : l.startsWith('+')
                                  ? c.success
                                  : l.startsWith('-')
                                      ? c.danger
                                      : l.startsWith('@@')
                                          ? c.accentIcon
                                          : (l.startsWith('diff ') ? c.text : c.text2);
                          return Container(
                            color: l.startsWith('+') && !l.startsWith('+++')
                                ? c.success.withValues(alpha: 0.07)
                                : (l.startsWith('-') && !l.startsWith('---') ? c.danger.withValues(alpha: 0.07) : null),
                            child: Text(l, maxLines: 1, overflow: TextOverflow.clip, style: context.t(12, family: mono, color: color, w: l.startsWith('diff ') ? FontWeight.w500 : FontWeight.w400)),
                          );
                        },
                      ),
              ),
            ),
          ]),
        ),
      );
    },
  );
}
