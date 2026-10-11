@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

import 'daemon_test.dart' show repo, waitFor;

/// Two relayds, each with its own RELAY_HOME, share one team through a folder.
void main() {
  late Directory tmp;
  late RelayDaemon da, db;
  late RelayClient a, b;

  late String relayBin;

  Future<(RelayDaemon, RelayClient)> boot(String name) async {
    final home = p.join(tmp.path, name);
    final d = RelayDaemon(RelayPaths(home), relayBinary: relayBin, detectOnStart: false, resolveShellEnv: false);
    await d.start();
    final c = await RelayClient.connect(RelayPaths(home), client: 'test');
    await c.call(M.settingsSet, {'values': {'userName': name, 'deviceName': '$name Mac'}});
    return (d, c);
  }

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('relay_sync_d_');
    // Its own binary: daemon_test may be compiling tool/out/relay in parallel.
    relayBin = p.join(tmp.path, Platform.isWindows ? 'relay.exe' : 'relay');
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', relayBin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    (da, a) = await boot('ann');
    (db, b) = await boot('bo');
  });

  tearDownAll(() async {
    await a.close();
    await b.close();
    await da.stop();
    await db.stop();
  });

  test('create, invite, join; tasks and repos sync; runs stay on their device', () async {
    final folder = Directory(p.join(tmp.path, 'shared'))..createSync();
    final storage = {'kind': 'folder', 'folder': folder.path};
    expect((await a.map(M.syncTest, {'storage': storage}))['problems'], isEmpty);
    expect((await a.map(M.syncTest, {'storage': {'kind': 'folder', 'folder': '/nope/missing'}}))['problems'], isNotEmpty);

    // Ann has a project with a repo before the team exists.
    final checkout = await repo(p.join(tmp.path, 'ann-code'), 'api', {'README.md': 'api\n'});
    final project = await a.map(M.projectsCreate, {'name': 'Kitchenly', 'key': 'kt'});
    final r = await a.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    final task = await a.map(M.tasksCreate, {'projectId': project['id'], 'fields': {'title': 'Share links'}});

    final team = await a.map(M.syncCreateTeam, {'name': 'binarycastle', 'storage': storage});
    expect(team['inTeam'], isTrue);
    expect(team['pendingOps'], 0);
    await expectLater(a.call(M.syncCreateTeam, {'name': 'again', 'storage': storage}), throwsA(isA<RpcError>()));

    final code = (await a.map(M.syncInvite))['code'] as String;
    final joined = await b.map(M.syncJoin, {'code': code});
    expect(joined['teamName'], 'binarycastle');

    // Bo sees Ann's work; the repo has no checkout on Bo's Mac yet.
    final tasks = await b.list(M.tasksList, {'projectId': project['id']});
    expect(tasks.map((t) => t['title']), contains('Share links'));
    final repos = await b.list(M.reposList, {'projectId': project['id']});
    expect(repos.single['localPath'], isNull);
    final devices = await b.list(M.devicesList);
    expect(devices.map((d) => d['name']), containsAll(['ann Mac', 'bo Mac']));

    // Bo points the repo at his own checkout; Ann's path is untouched.
    await b.call(M.reposUpdate, {'id': r['id'], 'fields': {'localPath': '/Users/bo/code/api'}});
    await b.map(M.syncNow);
    await a.map(M.syncNow);
    final annRepo = (await a.list(M.reposList, {'projectId': project['id']})).single;
    expect(annRepo['localPath'], endsWith(p.join('ann-code', 'api')));

    // Bo queues a task on Ann's Mac. Ann hasn't shared her agents, so it waits.
    final annDevice = (await a.map(M.syncStatus))['deviceId'];
    final t2 = await b.map(M.tasksCreate, {
      'projectId': project['id'],
      'fields': {'title': 'Ann runs this', 'runOn': annDevice, 'assigneeKind': 'agent', 'assignee': 'demo', 'status': 'queued'},
    });
    await b.map(M.syncNow);
    await a.map(M.syncNow);
    final waiting = await waitFor(() async {
      final t = (await a.map(M.tasksGet, {'id': t2['id']}))['task'] as Map;
      return t['attention'] == 'not-shared' ? t : null;
    }, timeout: const Duration(seconds: 10));
    expect(waiting['status'], 'queued');
    // Bo's own scheduler never touched it.
    expect((await b.list(M.runsList)).where((r) => r['taskId'] == t2['id']), isEmpty);

    // Ann shares her agents: her Mac runs it, and Bo sees that it did.
    await a.call(M.settingsSet, {'values': {'shareAgents': true}});
    final run = await waitFor(() async {
      final runs = (await a.list(M.runsList)).where((r) => r['taskId'] == t2['id']);
      return runs.isEmpty ? null : runs.first;
    }, timeout: const Duration(seconds: 15));
    expect(run['deviceId'], annDevice);
    expect(run['agentId'], 'demo');
    await a.map(M.syncNow);
    await b.map(M.syncNow);
    final seen = await b.list(M.runsList);
    expect(seen.where((r) => r['taskId'] == t2['id']).single['deviceId'], annDevice);

    // An edit on either side converges.
    await a.call(M.tasksUpdate, {'id': task['id'], 'fields': {'brief': 'from Ann'}});
    await a.map(M.syncNow);
    await b.map(M.syncNow);
    expect(((await b.map(M.tasksGet, {'id': task['id']}))['task'] as Map)['brief'], 'from Ann');

    // Ann removes Bo; Bo's next sync stops.
    final bo = (await b.map(M.syncStatus))['deviceId'];
    await a.map(M.syncRevoke, {'deviceId': bo});
    final after = await b.map(M.syncNow);
    expect(after['error'], contains('removed'));

    final left = await b.map(M.syncLeave);
    expect(left['inTeam'], isFalse);
    // Local data stays after leaving.
    expect((await b.list(M.tasksList, {'projectId': project['id']})).length, 2);
  });
}
