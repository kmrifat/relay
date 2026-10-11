import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import '../../app/theme.dart';
import '../../data/relay_data.dart';
import '../../ui/widgets.dart';

/// Settings → Team: set up sync (create or join), then status, invites,
/// sharing and the team's devices.
class TeamSection extends ConsumerWidget {
  const TeamSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(syncStatusProvider);
    if (s.isEmpty) return const SizedBox(height: 40);
    return s['inTeam'] == true ? _InTeam(s) : const _Setup();
  }
}

/// Not in a team yet: create one on your storage, or join with a code.
class _Setup extends ConsumerStatefulWidget {
  const _Setup();
  @override
  ConsumerState<_Setup> createState() => _SetupState();
}

class _SetupState extends ConsumerState<_Setup> {
  bool joining = false;
  String kind = 'cloudflare';
  final apiToken = TextEditingController();
  final team = TextEditingController();
  final account = TextEditingController();
  final endpoint = TextEditingController();
  final region = TextEditingController(text: 'auto');
  final bucket = TextEditingController();
  final keyId = TextEditingController();
  final secret = TextEditingController();
  final folder = TextEditingController();
  final code = TextEditingController();
  String? message;
  bool ok = false;
  bool busy = false;

  Map<String, Object?> get storage => switch (kind) {
    'cloudflare' => {'kind': 'cloudflare', 'accountId': account.text.trim(), 'apiToken': apiToken.text.trim()},
    'folder' => {'kind': 'folder', 'folder': folder.text.trim()},
    'r2' => {'kind': 'r2', 'accountId': account.text, 'bucket': bucket.text, 'accessKeyId': keyId.text, 'secretAccessKey': secret.text},
    _ => {'kind': 's3', 'endpoint': endpoint.text, 'region': region.text, 'bucket': bucket.text, 'accessKeyId': keyId.text, 'secretAccessKey': secret.text},
  };

  Future<void> _run(Future<void> Function(RelayClient c) f) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await f(ref.read(clientProvider));
    } on RpcError catch (e) {
      ok = false;
      message = e.message;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> test() => _run((c) async {
    final problems = ((await c.map(M.syncTest, {'storage': storage}))['problems'] as List).cast<String>();
    ok = problems.isEmpty;
    message = ok
        ? (kind == 'cloudflare' ? 'The token can deploy Workers and create R2 buckets on this account.' : 'Storage works: Relay can read, write and lock objects there.')
        : problems.join('\n');
  });

  Future<void> create() => _run((c) async {
    if (team.text.trim().isEmpty) throw RpcError(RpcError.invalidParams, 'Name the team.');
    ref.read(syncStatusProvider.notifier).set(await c.map(M.syncCreateTeam, {'name': team.text.trim(), 'storage': storage}));
  });

  Future<void> join() => _run((c) async {
    ref.read(syncStatusProvider.notifier).set(await c.map(M.syncJoin, {'code': code.text.trim()}));
    await ref.read(dataProvider.notifier).reload(c);
  });

  Widget secretField(BuildContext context, TextEditingController ctl, {String? hint}) {
    final c = context.c;
    return TextField(
      controller: ctl,
      obscureText: true,
      cursorOpacityAnimates: false,
      style: context.t(12, family: mono),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: context.t(12, color: c.text3),
        filled: true,
        fillColor: c.field,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.fieldStroke)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: c.accent, width: 2)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final step = busy ? ref.watch(syncStatusProvider.select((s) => s['step'] as String?)) : null;
    Widget field(String label, TextEditingController ctl, {String? hint, bool mono = false}) =>
        FieldRow(label, FieldInput(controller: ctl, hint: hint, mono: mono, size: 12), labelWidth: 120);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Share this board with your team. Everything is encrypted on this Mac before it leaves; '
          'your storage only ever holds ciphertext. No Relay account, no Relay server.',
          style: context.t(12, color: c.text2)),
      const SizedBox(height: 10),
      Row(children: [
        Segmented<bool>(options: const [(false, 'Create a team'), (true, 'Join with an invite')], value: joining, onChanged: (v) => setState(() {
          joining = v;
          message = null;
        })),
      ]),
      const SizedBox(height: 10),
      if (joining)
        Box(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Paste the invite code a teammate sent you. Each code works once.', style: context.t(12, color: c.text2)),
            const SizedBox(height: 8),
            FieldInput(controller: code, hint: 'relay-invite:…', mono: true, maxLines: 4, minLines: 3, size: 11),
          ]),
        )
      else
        Box(
          child: Column(children: [
            field('Team name', team, hint: 'binarycastle'),
            const Hairline(),
            FieldRow('Storage', Row(children: [
              Segmented<String>(small: true, options: const [('cloudflare', 'Cloudflare Worker'), ('r2', 'R2 keys'), ('s3', 'S3'), ('folder', 'Shared folder')], value: kind, onChanged: (v) => setState(() {
                kind = v;
                message = null;
              })),
            ]), labelWidth: 120),
            const Hairline(),
            if (kind == 'cloudflare') ...[
              field('Account ID', account, hint: 'dash.cloudflare.com → Workers & Pages → Account ID', mono: true),
              const Hairline(),
              FieldRow('API token', secretField(context, apiToken, hint: 'Workers Scripts: Edit · Workers R2 Storage: Edit'), labelWidth: 120),
            ] else if (kind == 'folder')
              FieldRow('Folder', Row(children: [
                Expanded(child: FieldInput(controller: folder, hint: 'A folder every teammate can reach (Dropbox, NAS…)', mono: true, size: 12)),
                const SizedBox(width: 8),
                Btn('Choose…', small: true, onTap: () async {
                  final p = await getDirectoryPath(confirmButtonText: 'Use folder');
                  if (p != null) setState(() => folder.text = p);
                }),
              ]), labelWidth: 120)
            else ...[
              if (kind == 'r2') field('Account ID', account, mono: true) else ...[
                field('Endpoint', endpoint, hint: 'https://s3.example.com', mono: true),
                const Hairline(),
                field('Region', region, mono: true),
              ],
              const Hairline(),
              field('Bucket', bucket, hint: 'relay', mono: true),
              const Hairline(),
              field('Access key ID', keyId, mono: true),
              const Hairline(),
              FieldRow('Secret key', secretField(context, secret), labelWidth: 120),
            ],
          ]),
        ),
      if (!joining && kind == 'cloudflare') ...[
        const SizedBox(height: 6),
        Text('Relay deploys a small Worker and an R2 bucket to your account (free plan is fine) and uses this token only for that; it is not stored. '
            'Teammates then need no Cloudflare keys at all, removing someone cuts their access, and changes and agent runs show up live.',
            style: context.t(11, color: c.text3)),
      ] else if (!joining && kind != 'folder') ...[
        const SizedBox(height: 6),
        Text('Use an API token scoped to this one bucket with Object Read & Write. It is kept in secrets.json (only you can read it) '
            'and goes to teammates inside the invite code. The Worker option avoids sharing it.', style: context.t(11, color: c.text3)),
      ],
      if (message != null) ...[
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? LucideIcons.circleCheck : LucideIcons.circleAlert, size: 13, color: ok ? c.success : c.danger),
          const SizedBox(width: 6),
          Expanded(child: Text(message!, style: context.t(12, color: ok ? c.success : c.danger))),
        ]),
      ],
      const SizedBox(height: 10),
      Row(children: [
        if (!joining) ...[Btn('Test connection', onTap: busy ? null : test), const SizedBox(width: 8)],
        Btn(joining ? 'Join team' : 'Create team', kind: BtnKind.primary, onTap: busy ? null : (joining ? join : create)),
        if (busy) ...[const SizedBox(width: 10), Flexible(child: Text(step ?? 'Working…', maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, color: c.text2)))],
      ]),
    ]);
  }
}

/// In a team: sync health, invites, sharing, devices.
class _InTeam extends ConsumerWidget {
  const _InTeam(this.s);
  final Map<String, Object?> s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final client = ref.read(clientProvider);
    final notifier = ref.read(syncStatusProvider.notifier);
    final storage = (s['storage'] as Map?)?.cast<String, Object?>() ?? {};
    final error = s['error'] as String?;
    final pending = (s['pendingOps'] as num?)?.toInt() ?? 0;
    final last = DateTime.tryParse(s['lastSync'] as String? ?? s['lastPull'] as String? ?? '');
    final me = s['deviceId'] as String?;
    final devices = ref.watch(dataProvider.select((d) => d.devices));
    final interval = (s['intervalSeconds'] as num?)?.toInt() ?? 30;
    final where = switch (storage['kind']) {
      'folder' => '${storage['folder']}',
      'worker' => '${Uri.tryParse('${storage['endpoint']}')?.host ?? storage['endpoint']} (Worker)',
      _ => '${storage['bucket']} · ${Uri.tryParse('${storage['endpoint']}')?.host ?? ''}',
    };
    final online = ((s['online'] as List?) ?? const []).cast<String>().toSet();
    final isLive = s['live'] == true;

    Future<void> setting(String k, Object v) async {
      await client.call(M.settingsSet, {'values': {k: v}});
      await notifier.refresh();
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Box(
        child: Column(children: [
          FieldRow('Team', Text('${s['teamName']}', style: context.t(12, w: FontWeight.w600)), labelWidth: 120),
          const Hairline(),
          FieldRow('Storage', Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, family: mono)), labelWidth: 120),
          const Hairline(),
          FieldRow('Status', Row(children: [
            Dot(error != null ? c.danger : (pending > 0 ? c.warning : c.success)),
            const SizedBox(width: 6),
            Expanded(child: Text(
              error ??
                  [
                    last == null ? 'Not synced yet' : 'Synced ${ago(last)}',
                    if (pending > 0) '$pending changes waiting',
                    if (isLive) 'live · ${online.length} online' else if (storage['kind'] == 'worker') 'live link reconnecting',
                  ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.t(12, color: error != null ? c.danger : c.text),
            )),
          ]), labelWidth: 120),
          const Hairline(),
          FieldRow('Sync every', Row(children: [
            Segmented<int>(small: true, options: const [(15, '15 s'), (30, '30 s'), (60, '1 min'), (300, '5 min')], value: interval, onChanged: (v) => setting('syncIntervalSeconds', v)),
          ]), labelWidth: 120),
          const Hairline(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              SizedBox(width: 120, child: Text('Share my agents', style: context.t(12, color: c.text2))),
              Expanded(child: Text('Teammates may queue work on this Mac\'s agents (your subscriptions, your machine).', style: context.t(11, color: c.text3))),
              Transform.scale(scale: 0.7, child: Switch(value: s['shareAgents'] == true, onChanged: (v) => setting('shareAgents', v), activeTrackColor: c.accent)),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Btn('Sync now', icon: LucideIcons.refreshCw, onTap: () async => notifier.set(await client.map(M.syncNow))),
        const SizedBox(width: 8),
        Btn('Invite teammate…', icon: LucideIcons.userPlus, onTap: () => _invite(context, client)),
        const Spacer(),
        Btn('Leave team', kind: BtnKind.plain, onTap: () async {
          if (!await _confirm(context, 'Leave ${s['teamName']}?', 'This Mac stops syncing. Your local copy of the board stays; teammates keep theirs.', 'Leave')) return;
          notifier.set(await client.map(M.syncLeave));
        }),
      ]),
      const SizedBox(height: 20),
      Text('Devices', style: context.label),
      const SizedBox(height: 8),
      Box(
        child: Column(children: [
          for (final (i, d) in devices.indexed) ...[
            if (i > 0) const Hairline(),
            _DeviceRow(d, me: d.id == me, online: online.contains(d.id), onRemove: d.id == me ? null : () async {
              if (!await _confirm(context, 'Remove ${d.name}?',
                  '${d.person.isEmpty ? 'This device' : d.person} loses access to everything new: the team key rotates now. '
                  'What they already synced stays on their Mac.', 'Remove')) {
                return;
              }
              try {
                notifier.set(await client.map(M.syncRevoke, {'deviceId': d.id}));
              } on RpcError catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
              }
            }),
          ],
        ]),
      ),
    ]);
  }

  Future<void> _invite(BuildContext context, RelayClient client) async {
    final String code;
    try {
      code = (await client.map(M.syncInvite))['code'] as String;
    } on RpcError catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Invite a teammate', style: context.t(14, w: FontWeight.w600)),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Send this code privately. It works once, and it carries the storage key, so treat it like a password. '
                'They paste it in Settings → Team → Join.', style: context.t(12, color: context.c.text2)),
            const SizedBox(height: 10),
            Box(
              padding: const EdgeInsets.all(8),
              color: context.c.codeBg,
              child: SelectableText(code, maxLines: 5, style: context.t(11, family: mono)),
            ),
          ]),
        ),
        actions: [
          Btn('Done', onTap: () => Navigator.pop(context)),
          Btn('Copy code', kind: BtnKind.primary, icon: LucideIcons.copy, onTap: () {
            Clipboard.setData(ClipboardData(text: code));
            Navigator.pop(context);
          }),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow(this.d, {required this.me, this.online = false, this.onRemove});
  final DeviceInfo d;
  final bool me;
  final bool online;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final recent = d.lastSeen != null && DateTime.now().difference(d.lastSeen!).inMinutes < 60;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Avatar(d.person.isEmpty ? d.name : d.person, size: 22, color: me ? c.accent : c.purple),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.t(12, w: FontWeight.w600))),
              if (me) ...[const SizedBox(width: 6), Pill('This Mac', fg: c.accent, bg: c.accent.withValues(alpha: 0.12))],
              if (d.shareAgents) ...[const SizedBox(width: 6), Pill('Shares agents', fg: c.success, bg: c.successWash)],
            ]),
            const SizedBox(height: 2),
            Text('${d.person.isEmpty ? '' : '${d.person} · '}${me || online ? 'online' : (d.lastSeen == null ? 'never seen' : 'seen ${ago(d.lastSeen)}')}',
                style: context.t(11, color: c.text3)),
          ]),
        ),
        for (final a in d.agents.take(5)) Padding(padding: const EdgeInsets.only(left: 3), child: Tooltip(message: '${a['name']}', child: AgentTile(agent: AgentProfile(a), size: 16))),
        const SizedBox(width: 10),
        Tooltip(message: me || online ? 'Online' : (recent ? 'Seen in the last hour' : 'Offline'), child: Dot(me || online ? c.success : (recent ? c.warning : c.text3))),
        if (onRemove != null) ...[const SizedBox(width: 6), IconBtn(LucideIcons.userMinus, tooltip: 'Remove from team', onTap: onRemove, size: 14)],
      ]),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: context.t(14, w: FontWeight.w600)),
        content: SizedBox(width: 360, child: Text(body, style: context.t(12, color: context.c.text2))),
        actions: [
          Btn('Cancel', onTap: () => Navigator.pop(context, false)),
          Btn(action, kind: BtnKind.danger, onTap: () => Navigator.pop(context, true)),
        ],
      ),
    ) ??
    false;
