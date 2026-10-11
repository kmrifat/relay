import 'dart:async';
import 'dart:io';

import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';

const _usage = '''
relay — Relay's daemon, MCP server and command line

  relay daemon                 run relayd in the foreground
  relay status                 show relayd's status
  relay project add NAME --key KEY [--repo PATH]...
  relay projects               list projects
  relay task add "Title" --project KEY [--brief TEXT] [--agent ID] [--repo NAME]... [--queue]
  relay tasks --project KEY    list tasks
  relay agents                 list agents (and detect CLIs)
  relay worker deploy --account ID --team NAME
                               deploy the team Worker to your Cloudflare account
                               and create the team on it (token: CLOUDFLARE_API_TOKEN)
  relay team create NAME --folder PATH | --worker URL --setup-token T
  relay team status | invite | join CODE | sync | leave
  relay team push-setup --p8 AuthKey_X.p8 --key-id ID --apple-team ID [--bundle ID]
                               phone push through the team Worker (your APNs key)
  relay mcp --run RUN_ID       MCP server for an agent (stdio)
  relay demo-agent             the built-in demo agent (stream-json)
  relay version
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    stdout.write(_usage);
    return;
  }
  final paths = RelayPaths.resolve();
  final cmd = args.first;
  final rest = args.skip(1).toList();
  try {
    switch (cmd) {
      case 'daemon':
        await _daemon(paths);
      case 'mcp':
        exitCode = await runMcpServer(_opt(rest, '--run') ?? Platform.environment['RELAY_RUN'] ?? '', paths);
      case 'demo-agent':
        exitCode = await runDemoAgent(rest);
      case 'version':
        stdout.writeln(relayVersion);
      case 'status':
        final c = await RelayClient.connect(paths, client: 'cli');
        final s = await c.map(M.status);
        for (final e in s.entries) {
          stdout.writeln('${e.key.padRight(14)} ${e.value}');
        }
        await c.close();
      case 'projects':
        final c = await RelayClient.connect(paths, client: 'cli');
        for (final p in await c.list(M.projectsList)) {
          stdout.writeln('${(p['key'] as String).padRight(6)} ${p['name']}');
        }
        await c.close();
      case 'project':
        if (rest.isEmpty || rest.first != 'add' || rest.length < 2) throw const FormatException('relay project add NAME --key KEY [--repo PATH]...');
        final c = await RelayClient.connect(paths, client: 'cli');
        final name = rest[1];
        final key = _opt(rest, '--key') ?? name.substring(0, name.length < 2 ? name.length : 2).toUpperCase();
        final p = await c.map(M.projectsCreate, {'name': name, 'key': key});
        for (final repo in _opts(rest, '--repo')) {
          final r = await c.map(M.reposAdd, {'projectId': p['id'], 'path': Directory(repo).absolute.path});
          stdout.writeln('  + repo ${r['name']} (${r['stack']}, base ${r['baseBranch']})');
        }
        stdout.writeln('Created ${p['key']} · ${p['name']}');
        await c.close();
      case 'tasks':
        final c = await RelayClient.connect(paths, client: 'cli');
        final project = await _project(c, _opt(rest, '--project'));
        for (final t in await c.list(M.tasksList, {'projectId': project['id']})) {
          final id = '${project['key']}-${t['number']}'.padRight(8);
          stdout.writeln('$id${(t['status'] as String).padRight(9)} ${t['title']}');
        }
        await c.close();
      case 'task':
        if (rest.isEmpty || rest.first != 'add' || rest.length < 2) throw const FormatException('relay task add "Title" --project KEY');
        final c = await RelayClient.connect(paths, client: 'cli');
        final project = await _project(c, _opt(rest, '--project'));
        final repos = await c.list(M.reposList, {'projectId': project['id']});
        final repoNames = _opts(rest, '--repo');
        final agent = _opt(rest, '--agent');
        final t = await c.map(M.tasksCreate, {
          'projectId': project['id'],
          'fields': {
            'title': rest[1],
            'brief': _opt(rest, '--brief') ?? '',
            if (agent != null) ...{'assigneeKind': 'agent', 'assignee': agent},
            'repoIds': [for (final r in repos) if (repoNames.contains(r['name'])) r['id']],
            'status': rest.contains('--queue') ? 'queued' : 'backlog',
          },
        });
        stdout.writeln('Created ${project['key']}-${t['number']} · ${t['title']}');
        await c.close();
      case 'agents':
        final c = await RelayClient.connect(paths, client: 'cli');
        await c.call(M.agentsDetect);
        for (final a in await c.list(M.agentsList)) {
          stdout.writeln('${(a['id'] as String).padRight(12)} ${a['binaryPath'] ?? '(not found)'}  ${a['version'] ?? ''}');
        }
        await c.close();
      case 'worker':
        if (rest.isEmpty || rest.first != 'deploy') throw const FormatException('relay worker deploy --account ID --team NAME');
        final account = _opt(rest, '--account') ?? Platform.environment['CLOUDFLARE_ACCOUNT_ID'];
        final team = _opt(rest, '--team');
        if (account == null || team == null) throw const FormatException('relay worker deploy --account ID --team NAME');
        final token = Platform.environment['CLOUDFLARE_API_TOKEN'] ?? _secretPrompt('Cloudflare API token (Workers Scripts: Edit, Workers R2 Storage: Edit): ');
        final c = await RelayClient.connect(paths, client: 'cli');
        final steps = c.events.where((e) => e.method == E.syncState && e.params['step'] != null).listen((e) => stdout.writeln('  ${e.params['step']}'));
        final s = await c.map(M.syncCreateTeam, {'name': team, 'storage': {'kind': 'cloudflare', 'accountId': account, 'apiToken': token}});
        await steps.cancel();
        stdout.writeln('Team ${s['teamName']} is live at ${(s['storage'] as Map)['endpoint']}');
        stdout.writeln('Invite teammates with `relay team invite`.');
        await c.close();
      case 'team':
        final sub = rest.isEmpty ? 'status' : rest.first;
        final c = await RelayClient.connect(paths, client: 'cli');
        switch (sub) {
          case 'create':
            if (rest.length < 2) throw const FormatException('relay team create NAME --folder PATH | --worker URL --setup-token T');
            final folder = _opt(rest, '--folder');
            final worker = _opt(rest, '--worker');
            final storage = folder != null
                ? {'kind': 'folder', 'folder': Directory(folder).absolute.path}
                : worker != null
                ? {'kind': 'worker', 'url': worker, 'setupToken': _opt(rest, '--setup-token')}
                : throw const FormatException('relay team create NAME --folder PATH | --worker URL --setup-token T');
            _printTeam(await c.map(M.syncCreateTeam, {'name': rest[1], 'storage': storage}));
          case 'invite':
            stdout.writeln((await c.map(M.syncInvite))['code']);
            stderr.writeln('Send this privately. It works once.');
          case 'join':
            if (rest.length < 2) throw const FormatException('relay team join CODE');
            _printTeam(await c.map(M.syncJoin, {'code': rest[1]}));
          case 'sync':
            _printTeam(await c.map(M.syncNow));
          case 'push-setup':
            final p8 = _opt(rest, '--p8');
            if (p8 == null) throw const FormatException('relay team push-setup --p8 AuthKey_X.p8 --key-id ID --apple-team ID');
            final keyId = _opt(rest, '--key-id') ?? RegExp(r'AuthKey_([A-Z0-9]{10})').firstMatch(p8)?.group(1) ?? '';
            final s = await c.map(M.pushConfig, {
              'p8': File(p8).readAsStringSync(),
              'keyId': keyId,
              'teamId': _opt(rest, '--apple-team') ?? '',
              'bundleId': ?_opt(rest, '--bundle'),
            });
            stdout.writeln('Push is on (${s['devices']} phone(s) registered).');
          case 'leave':
            _printTeam(await c.map(M.syncLeave));
          default:
            _printTeam(await c.map(M.syncStatus));
            for (final d in await c.list(M.devicesList)) {
              if (d['revoked'] == true) continue;
              stdout.writeln('  ${'${d['name']}'.padRight(28)} ${d['person'] ?? ''}${d['shareAgents'] == true ? ' · shares agents' : ''}');
            }
        }
        await c.close();
      default:
        stderr.write(_usage);
        exitCode = 64;
    }
  } on SocketException catch (e) {
    stderr.writeln('Cannot reach relayd: ${e.message}. Start it with `relay daemon` or open the Relay app.');
    exitCode = 69;
  } on RpcError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on FormatException catch (e) {
    stderr.writeln('Usage: ${e.message}');
    exitCode = 64;
  } on AlreadyRunning catch (e) {
    stderr.writeln(e);
    exitCode = 0;
  }
}

Future<void> _daemon(RelayPaths paths) async {
  final self = Platform.resolvedExecutable;
  final compiled = !self.endsWith('/dart') && !self.endsWith('dart.exe');
  final daemon = RelayDaemon(
    paths,
    relayBinary: compiled ? self : Platform.environment['RELAY_BINARY'],
    ptyHelper: Platform.environment['RELAY_PTY'],
  );
  await daemon.start();
  stdout.writeln('relayd $relayVersion listening (pid $pid, home ${paths.home})');
  final signals = [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm];
  for (final s in signals) {
    s.watch().listen((_) => daemon.stop());
  }
  await daemon.stopped;
  exit(0);
}

void _printTeam(Map<String, Object?> s) {
  if (s['inTeam'] != true) {
    stdout.writeln('Not in a team.');
    return;
  }
  final storage = (s['storage'] as Map?) ?? {};
  stdout.writeln('Team     ${s['teamName']} (key epoch ${s['epoch']})');
  stdout.writeln('Storage  ${storage['kind']} ${storage['endpoint'] ?? storage['folder'] ?? ''}${storage['bucket'] != null ? ' / ${storage['bucket']}' : ''}');
  stdout.writeln('Synced   ${s['lastSync'] ?? 'not yet'}${(s['pendingOps'] as num? ?? 0) > 0 ? ' · ${s['pendingOps']} waiting' : ''}');
  if (s['error'] != null) stdout.writeln('Error    ${s['error']}');
}

String _secretPrompt(String label) {
  stdout.write(label);
  final echo = stdin.hasTerminal && stdin.echoMode;
  if (stdin.hasTerminal) stdin.echoMode = false;
  final v = stdin.readLineSync() ?? '';
  if (stdin.hasTerminal) stdin.echoMode = echo;
  stdout.writeln();
  return v.trim();
}

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

List<String> _opts(List<String> args, String name) => [
  for (var i = 0; i < args.length - 1; i++)
    if (args[i] == name) args[i + 1],
];

Future<Map<String, Object?>> _project(RelayClient c, String? key) async {
  final projects = await c.list(M.projectsList);
  if (projects.isEmpty) throw RpcError(RpcError.notFound, 'No projects yet. Create one with `relay project add`.');
  if (key == null) return projects.first;
  return projects.firstWhere(
    (p) => (p['key'] as String).toLowerCase() == key.toLowerCase(),
    orElse: () => throw RpcError(RpcError.notFound, 'No project $key'),
  );
}
