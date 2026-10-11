@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_core/relay_core.dart';
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_git/relay_git.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

final root = Directory.current.parent.parent.path;
final relayBin = p.join(root, 'tool', 'out', 'relay${Platform.isWindows ? '.exe' : ''}');
final ptyBin = p.join(root, 'tool', 'out', 'relay-pty${Platform.isWindows ? '.exe' : ''}');

Future<String> repo(String parent, String name, Map<String, String> files) async {
  final git = Git();
  final dir = p.join(parent, name);
  Directory(dir).createSync(recursive: true);
  await git.run(dir, ['init', '-q', '-b', 'main']);
  await git.run(dir, ['config', 'user.email', 't@example.com']);
  await git.run(dir, ['config', 'user.name', 'Test']);
  await git.run(dir, ['config', 'commit.gpgsign', 'false']);
  for (final e in files.entries) {
    File(p.join(dir, e.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
  await git.commitAll(dir, 'init');
  return dir;
}

Future<T> waitFor<T>(Future<T?> Function() probe, {Duration timeout = const Duration(seconds: 60)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final v = await probe();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }
  throw TimeoutException('condition not met');
}

void main() {
  late RelayDaemon daemon;
  late RelayClient client;
  late String home;
  late String code;

  setUpAll(() async {
    Directory(p.dirname(relayBin)).createSync(recursive: true);
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', relayBin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    if (!File(ptyBin).existsSync()) {
      await Process.run(p.join(root, 'tool', 'build_pty.sh'), []);
    }
    final tmp = Directory.systemTemp.createTempSync('relayd_test_');
    home = p.join(tmp.path, 'home');
    code = p.join(tmp.path, 'code');
    await repo(code, 'shared', {'openapi.yaml': 'openapi: 3.1.0\npaths: {}\n'});
    await repo(code, 'api', {'routes.php': '<?php\n', 'artisan': ''});
    await repo(code, 'app', {'pubspec.yaml': 'name: app\n', 'lib/main.dart': 'void main() {}\n', 'ios/.keep': ''});
    await repo(code, 'admin', {'package.json': '{}'});

    daemon = RelayDaemon(RelayPaths(home), relayBinary: relayBin, ptyHelper: ptyBin, detectOnStart: false, resolveShellEnv: false);
    await daemon.start();
    client = await RelayClient.connect(RelayPaths(home), client: 'test');
    await client.call(M.settingsSet, {'values': {'userName': 'Rifat'}});
  });

  tearDownAll(() async {
    await client.close();
    await daemon.stop();
  });

  test('hello, status and a second daemon refuses to start', () async {
    expect(client.hello['protocol'], protocolVersion);
    final s = await client.map(M.status);
    expect(s['version'], relayVersion);
    await expectLater(RelayDaemon(RelayPaths(home), detectOnStart: false, resolveShellEnv: false).start(), throwsA(isA<AlreadyRunning>()));
  });

  test('a bad token is refused', () async {
    final info = DaemonInfo.read(RelayPaths(home))!;
    final sock = info.socket != null
        ? await Socket.connect(InternetAddress(info.socket!, type: InternetAddressType.unix), 0)
        : await Socket.connect(InternetAddress.loopbackIPv4, info.port!);
    await expectLater(RelayClient.attach(sock, sock, token: 'wrong'), throwsA(isA<RpcError>()));
    sock.destroy();
  });

  test('multi-repo task: demo agent runs, asks permission, change set merges in order', () async {
    final project = await client.map(M.projectsCreate, {'name': 'Kitchenly', 'key': 'kt'});
    expect(project['key'], 'KT');
    final pid = project['id'];

    final info = await client.map(M.reposInspect, {'path': p.join(code, 'app')});
    expect(info['stack'], 'Flutter');
    expect(info['testCommand'], 'flutter test');

    final shared = await client.map(M.reposAdd, {'projectId': pid, 'path': p.join(code, 'shared'), 'fields': {'mergeStep': 0}});
    expect(shared['contractPaths'], ['openapi.yaml']);
    final api = await client.map(M.reposAdd, {'projectId': pid, 'path': p.join(code, 'api'), 'fields': {'mergeStep': 1, 'dependsOn': [shared['id']]}});
    expect(api['stack'], 'Laravel');
    final app = await client.map(M.reposAdd, {'projectId': pid, 'path': p.join(code, 'app'), 'fields': {'mergeStep': 2, 'dependsOn': [shared['id']]}});
    await client.map(M.reposAdd, {'projectId': pid, 'path': p.join(code, 'admin'), 'fields': {'mergeStep': 2}});

    // Repo suggestions: UI + API words, and the shared contract between them.
    final sugg = await client.list(M.tasksSuggestRepos, {'projectId': pid, 'text': 'Add a share button on the recipe screen that calls a new share-link endpoint', 'repoIds': <String>[]});
    expect(sugg.map((s) => s['name']), containsAll(['app', 'api', 'shared']));

    // Watch run events arrive batched.
    final runEvents = <Map<String, Object?>>[];
    final sub = client.events.where((e) => e.method == E.runEvents).listen((e) {
      runEvents.addAll((e.params['events'] as List).map((x) => (x as Map).cast<String, Object?>()));
    });

    final task = await client.map(M.tasksCreate, {
      'projectId': pid,
      'fields': {
        'title': 'Share a recipe with a link',
        'brief': 'Add share links.',
        'assigneeKind': 'agent',
        'assignee': 'demo',
        'repoIds': [api['id'], app['id']],
        'status': 'queued',
        'doneWhen': [{'text': 'Link opens without login', 'done': false}],
      },
    });
    expect(task['number'], 1);

    // The scheduler starts it; the demo agent asks to write, twice (api, app).
    final answered = <String>{};
    for (var i = 0; i < 2; i++) {
      final perm = await waitFor(() async => runEvents
          .where((e) => e['type'] == 'permission' && !answered.contains((e['data'] as Map)['id']))
          .firstOrNull);
      answered.add((perm['data'] as Map)['id'] as String);
      final runId = perm['runId'] as String;
      final t = (await client.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
      expect(t['attention'], 'permission');
      await client.call(M.permissionsAnswer, {'runId': runId, 'requestId': (perm['data'] as Map)['id'], 'answer': 'allow_once'});
    }

    final done = await waitFor(() async {
      final t = (await client.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
      return t['status'] == 'review' ? t : null;
    });
    expect(done['attention'], isNull);
    await sub.cancel();

    final detail = await client.map(M.tasksGet, {'id': task['id']});
    final runs = (detail['runs'] as List).cast<Map>();
    expect(runs.single['status'], 'done');
    expect(runs.single['summary'], contains('RELAY_DEMO.md'));
    final comments = (detail['comments'] as List).cast<Map>();
    expect(comments.any((c) => c['authorKind'] == 'agent'), isTrue);

    // Workspace: worktrees for api + app on kt-1, read-only links for the rest, PROJECT.md.
    final ws = detail['workspace'] as String;
    expect(File(p.join(ws, 'PROJECT.md')).readAsStringSync(), contains('Merge order'));
    // Untouched repos are read-only snapshots, not links to the user's checkout.
    expect(Directory(p.join(ws, 'shared')).existsSync(), isTrue);
    expect(FileSystemEntity.isLinkSync(p.join(ws, 'shared')), isFalse);
    expect(() => File(p.join(ws, 'admin', 'package.json')).writeAsStringSync('x'), throwsA(isA<FileSystemException>()));
    expect(File(p.join(ws, 'api', '.git')).existsSync(), isTrue);
    expect(await Git().currentBranch(p.join(ws, 'app')), 'kt-1');
    expect(File(p.join(ws, 'api', 'RELAY_DEMO.md')).existsSync(), isTrue);

    final changes = await client.list(M.changesList, {'taskId': task['id']});
    expect(changes, hasLength(2));
    expect(changes.every((c) => c['status'] == 'ready' && (c['additions'] as int) > 0), isTrue);

    // The commit carries Relay trailers, so the Git view can show the agent.
    final log = await client.list(M.gitLog, {'path': p.join(ws, 'api'), 'limit': 5});
    expect(log.first['agent'], 'demo');
    expect(log.first['task'], 'KT-1');
    expect((log.first['graph'] as Map)['lane'], 0);

    // Merge in order: api (step 1) then app (step 2). Main checkouts get the files.
    final merged = await client.list(M.changesMerge, {'taskId': task['id']});
    expect(merged.map((m) => m['repo']), ['api', 'app']);
    expect(merged.every((m) => m['ok'] == true), isTrue);
    expect(File(p.join(code, 'api', 'RELAY_DEMO.md')).existsSync(), isTrue);
    expect(File(p.join(code, 'app', 'RELAY_DEMO.md')).existsSync(), isTrue);
    final after = (await client.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
    expect(after['status'], 'done');
  });

  test('contract change notifies with a system comment', () async {
    final pid = (await client.list(M.projectsList)).first['id'];
    final repos = await client.list(M.reposList, {'projectId': pid});
    final shared = repos.firstWhere((r) => r['name'] == 'shared');
    final api = repos.firstWhere((r) => r['name'] == 'api');
    await client.call(M.settingsSet, {'values': {'askBeforeShell': 'false'}});
    final task = await client.map(M.tasksCreate, {
      'projectId': pid,
      'fields': {'title': 'Contract tweak', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [shared['id'], api['id']], 'status': 'queued'},
    });
    await waitFor(() async {
      final t = (await client.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
      return t['status'] == 'review' ? t : null;
    });
    // The demo agent wrote RELAY_DEMO.md in shared; make it a contract change.
    final ws = (await client.map(M.tasksGet, {'id': task['id']}))['workspace'] as String;
    File(p.join(ws, 'shared', 'openapi.yaml')).writeAsStringSync('openapi: 3.1.0\npaths:\n  /share: {}\n');
    await client.call(M.runsStart, {'taskId': task['id'], 'agentId': 'demo', 'note': 'continue'});
    final note = await waitFor(() async {
      final cs = await client.list(M.commentsList, {'taskId': task['id']});
      return cs.where((c) => c['authorKind'] == 'system').firstOrNull;
    });
    expect(note['body'], contains('openapi.yaml'));
    expect(note['body'], contains('api'));
    await client.call(M.settingsSet, {'values': {'askBeforeShell': 'true'}});
  });

  test('push: a ready change goes to the remote on its branch', () async {
    final pid = (await client.list(M.projectsList)).first['id'];
    final repos = await client.list(M.reposList, {'projectId': pid});
    final api = repos.firstWhere((r) => r['name'] == 'api');
    final bare = Directory.systemTemp.createTempSync('relay_remote_').path;
    await Git().run(bare, ['init', '-q', '--bare']);
    await Git().run(api['localPath'] as String, ['remote', 'add', 'origin', bare]);
    await client.call(M.settingsSet, {'values': {'askBeforeShell': 'false'}});
    final task = await client.map(M.tasksCreate, {
      'projectId': pid,
      'fields': {'title': 'Push me', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [api['id']], 'status': 'queued'},
    });
    await waitFor(() async {
      final t = (await client.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
      return t['status'] == 'review' ? t : null;
    });
    final res = await client.list(M.changesPush, {'taskId': task['id']});
    expect(res.single['ok'], isTrue, reason: '${res.single}');
    final branches = await Git().run(bare, ['branch', '--format=%(refname:short)']);
    expect(branches, contains('kt-${task['number']}'));
    await client.call(M.settingsSet, {'values': {'askBeforeShell': 'true'}});
  });

  test('time limit stops a run; a spend cap keeps an agent from starting', () async {
    final pid = (await client.list(M.projectsList)).first['id'];
    final repos = await client.list(M.reposList, {'projectId': pid});
    final app = repos.firstWhere((r) => r['name'] == 'app');
    // The demo agent waits on its permission request, so the run would hang.
    final slow = await client.map(M.tasksCreate, {
      'projectId': pid,
      'fields': {'title': 'Too slow', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [app['id']], 'status': 'queued', 'stopAfterSeconds': 2},
    });
    final stopped = await waitFor(() async {
      final runs = (await client.map(M.tasksGet, {'id': slow['id']}))['runs'] as List;
      return runs.isNotEmpty && (runs.last as Map)['status'] == 'stopped' ? runs.last : null;
    }, timeout: const Duration(seconds: 30));
    expect(stopped, isNotNull);

    // Pretend the demo agent already spent $1 today, against a $0.50 cap.
    daemon.ctx.store.create<Run>(Kind.run, {'taskId': slow['id'], 'agentId': 'demo', 'status': 'done', 'startedAt': DateTime.now().toUtc().toIso8601String(), 'costUsd': 1.0});
    await client.call(M.agentsUpdate, {'id': 'demo', 'fields': {'dailyCapUsd': 0.5}});
    final capped = await client.map(M.tasksCreate, {
      'projectId': pid,
      'fields': {'title': 'Over budget', 'assigneeKind': 'agent', 'assignee': 'demo', 'status': 'queued'},
    });
    await daemon.supervisor.tick();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final t = (await client.map(M.tasksGet, {'id': capped['id']}))['task'] as Map;
    expect(t['status'], 'queued');
    await client.call(M.agentsUpdate, {'id': 'demo', 'fields': {'dailyCapUsd': 0}});
    await client.call(M.tasksMove, {'id': capped['id'], 'status': 'backlog'});
  });

  test('terminal: open a shell in a repo and read its output', () async {
    final repos = await client.list(M.reposList);
    final cwd = repos.first['localPath'] as String;
    final out = StringBuffer();
    final sub = client.events.where((e) => e.method == E.termOutput).listen((e) {
      out.write(utf8.decode(base64Decode(e.params['data'] as String)));
    });
    final id = await client.call<String>(M.termOpen, {'path': cwd, 'cols': 80, 'rows': 24});
    await client.call(M.termInput, {'termId': id, 'text': 'echo relay-$id-ok${Platform.isWindows ? '\r' : '\n'}'});
    await waitFor(() async => out.toString().contains('relay-$id-ok') ? true : null, timeout: const Duration(seconds: 15));
    await client.call(M.termClose, {'termId': id});
    await sub.cancel();
  });

  test('files: listing and reading are limited to repos and workspaces', () async {
    final repos = await client.list(M.reposList);
    final cwd = repos.firstWhere((r) => r['name'] == 'app')['localPath'] as String;
    final files = await client.map(M.fsList, {'path': cwd});
    expect(files['files'], contains('lib/main.dart'));
    final f = await client.map(M.fsRead, {'path': p.join(cwd, 'lib', 'main.dart')});
    expect(f['text'], contains('void main'));
    final outside = Platform.isWindows ? r'C:\Windows\win.ini' : '/etc/hosts';
    await expectLater(client.map(M.fsRead, {'path': outside}), throwsA(isA<RpcError>()));
  });

  test('MCP server: agents post progress through relay mcp', () async {
    final runs = await client.list(M.runsList);
    final run = runs.first;
    final proc = await Process.start(relayBin, ['mcp', '--run', run['id'] as String], environment: {'RELAY_HOME': home});
    final lines = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    Future<Map> call(int id, String method, Map params) async {
      proc.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
      final line = await lines.firstWhere((l) => (jsonDecode(l) as Map)['id'] == id).timeout(const Duration(seconds: 15));
      return jsonDecode(line) as Map;
    }

    final init = await call(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't'}});
    expect((init['result'] as Map)['serverInfo']['name'], 'relay');
    final list = await call(2, 'tools/list', {});
    expect(((list['result'] as Map)['tools'] as List).map((t) => t['name']), contains('relay_progress'));
    final res = await call(3, 'tools/call', {'name': 'relay_progress', 'arguments': {'text': 'Halfway there'}});
    expect(((res['result'] as Map)['content'] as List).first['text'], 'Posted.');
    final cs = await client.list(M.commentsList, {'taskId': run['taskId']});
    expect(cs.any((c) => c['body'] == 'Halfway there' && c['authorKind'] == 'agent'), isTrue);
    final task = await call(4, 'tools/call', {'name': 'relay_task', 'arguments': {}});
    expect(((task['result'] as Map)['content'] as List).first['text'], contains('#'));
    await proc.stdin.close();
    proc.kill();
  });
}
