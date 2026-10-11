@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

import 'daemon_test.dart' show repo, waitFor;

final workerDir = p.join(Directory.current.parent.parent.path, 'worker');

/// Two relayds in a team through the real Worker (on Miniflare): pokes
/// instead of polling, run steps streamed live, revoke closes the room.
void main() {
  final ready = Directory(p.join(workerDir, 'node_modules', 'miniflare')).existsSync();
  late Directory tmp;
  late String relayBin;
  late Process worker;
  late String url;
  final daemons = <RelayDaemon>[];
  final clients = <RelayClient>[];

  Future<RelayClient> boot(String name) async {
    final home = p.join(tmp.path, name);
    final d = RelayDaemon(RelayPaths(home), relayBinary: relayBin, detectOnStart: false, resolveShellEnv: false);
    await d.start();
    daemons.add(d);
    final c = await RelayClient.connect(RelayPaths(home), client: 'test');
    clients.add(c);
    // Polling once an hour: anything faster below comes from the live room.
    await c.call(M.settingsSet, {'values': {'userName': name, 'deviceName': '$name Mac', 'syncIntervalSeconds': 3600}});
    return c;
  }

  setUpAll(() async {
    if (!ready) return;
    tmp = Directory.systemTemp.createTempSync('relay_live_');
    relayBin = p.join(tmp.path, 'relay');
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', relayBin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    worker = await Process.start('node', ['test/serve.mjs', 'setup-secret'], workingDirectory: workerDir);
    url = (await worker.stdout.transform(utf8.decoder).transform(const LineSplitter()).first).trim();
  });

  tearDownAll(() async {
    if (!ready) return;
    for (final c in clients) {
      await c.close();
    }
    for (final d in daemons) {
      await d.stop();
    }
    worker.kill();
  });

  test('live room: pokes, streamed run steps, revoke', skip: ready ? false : 'run npm ci in worker/', () async {
    final a = await boot('ann');
    final b = await boot('bo');
    final team = await a.map(M.syncCreateTeam, {'name': 'binarycastle', 'storage': {'kind': 'worker', 'url': url, 'setupToken': 'setup-secret'}});
    expect((team['storage'] as Map)['kind'], 'worker');
    final code = (await a.map(M.syncInvite))['code'] as String;
    expect(code, isNot(contains('setup-secret')));
    await b.map(M.syncJoin, {'code': code});

    await waitFor(() async {
      final s = await a.map(M.syncStatus);
      return s['live'] == true && (s['online'] as List).length == 2 ? s : null;
    }, timeout: const Duration(seconds: 20));

    // A change on Ann's Mac reaches Bo without polling: push, poke, pull.
    final project = await a.map(M.projectsCreate, {'name': 'Kitchenly', 'key': 'kt'});
    final made = DateTime.now();
    await waitFor(() async {
      final ps = await b.list(M.projectsList);
      return ps.any((x) => x['id'] == project['id']) ? true : null;
    }, timeout: const Duration(seconds: 15));
    // 3 s local debounce + the poke round trip; polling would take an hour.
    expect(DateTime.now().difference(made).inSeconds, lessThan(8));
    expect((await a.map(M.syncStatus))['liveOut'], greaterThan(0));
    expect((await b.map(M.syncStatus))['liveIn'], greaterThan(0));

    // Ann's demo agent runs; Bo watches its steps arrive live.
    final checkout = await repo(p.join(tmp.path, 'code'), 'api', {'README.md': 'api\n'});
    final r = await a.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    final task = await a.map(M.tasksCreate, {
      'projectId': project['id'],
      'fields': {'title': 'Stream me', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [r['id']]},
    });
    final run = await a.map(M.runsStart, {'taskId': task['id'], 'agentId': 'demo'});
    final runId = run['id'] as String;
    await a.map(M.syncNow); // so Bo has the run record
    await b.map(M.syncNow);
    final bEvents = <Map<String, Object?>>[];
    final sub = b.events.where((e) => e.method == E.runEvents && e.params['runId'] == runId).listen((e) {
      bEvents.addAll((e.params['events'] as List).cast<Map<String, Object?>>());
    });
    await b.list(M.runsEvents, {'runId': runId}); // asks Ann for the backlog
    final aSeq = await waitFor(() async {
      final ev = await a.list(M.runsEvents, {'runId': runId});
      return ev.length >= 3 ? ev.last['seq'] as int : null;
    }, timeout: const Duration(seconds: 20));
    await waitFor(() async => bEvents.any((e) => e['seq'] == aSeq) ? true : null, timeout: const Duration(seconds: 5));
    // From here on each new step reaches Bo within a second.
    final before = (await a.list(M.runsEvents, {'runId': runId})).length;
    await a.call(M.runsSteer, {'runId': runId, 'text': 'one more thing'});
    final at = DateTime.now();
    final next = await waitFor(() async {
      final ev = await a.list(M.runsEvents, {'runId': runId});
      return ev.length > before ? ev.last['seq'] as int : null;
    }, timeout: const Duration(seconds: 10));
    await waitFor(() async => bEvents.any((e) => e['seq'] == next) ? true : null, timeout: const Duration(seconds: 3));
    expect(DateTime.now().difference(at).inMilliseconds, lessThan(1000)); // M7-02 AC
    expect((await b.list(M.runsEvents, {'runId': runId})).length, greaterThanOrEqualTo(aSeq));
    await sub.cancel();
    await a.call(M.runsStop, {'runId': runId});

    // Ann removes Bo: his room connection closes and his sync stops.
    final bo = (await b.map(M.syncStatus))['deviceId'];
    await a.map(M.syncRevoke, {'deviceId': bo});
    await waitFor(() async {
      final s = await b.map(M.syncStatus);
      return s['live'] == false && '${s['error']}'.contains('removed') ? s : null;
    }, timeout: const Duration(seconds: 30));
    await waitFor(() async {
      final s = await a.map(M.syncStatus);
      return (s['online'] as List).length == 1 ? s : null;
    }, timeout: const Duration(seconds: 15));
  });
}
