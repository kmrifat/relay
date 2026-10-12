@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_core/relay_core.dart';
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

import 'daemon_test.dart' show repo, waitFor;

/// `shutdown`: an updated app stops an older relayd before starting its own.
void main() {
  late Directory tmp;
  late String bin;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('relay_shutdown_');
    bin = p.join(tmp.path, Platform.isWindows ? 'relay.exe' : 'relay');
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', bin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  RelayDaemon daemonAt(String home) => RelayDaemon(RelayPaths(home), relayBinary: bin, detectOnStart: false, resolveShellEnv: false);

  test('an idle relayd stops, takes its socket and daemon.json with it, and a new one can start', () async {
    final paths = RelayPaths(p.join(tmp.path, 'idle'));
    final daemon = daemonAt(paths.home);
    await daemon.start();
    final c = await RelayClient.connect(paths, client: 'test');

    // Not for the paired phone (commands arrive through Api.invoke).
    await expectLater(daemon.api.invoke(M.shutdown, {}), throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.methodNotFound)));

    final answer = await c.map(M.shutdown);
    expect(answer['pid'], pid);
    expect(answer['version'], relayVersion);
    expect(answer['stoppedRuns'], 0);
    await daemon.stopped.timeout(const Duration(seconds: 10));
    await c.done.timeout(const Duration(seconds: 5));
    expect(File(paths.daemonInfo).existsSync(), isFalse);
    if (RelayPaths.usesUnixSocket) expect(File(paths.socket).existsSync(), isFalse);
    await expectLater(RelayClient.connect(paths, client: 'test'), throwsA(anything));

    // The replacement starts in the same home.
    final next = daemonAt(paths.home);
    await next.start();
    final c2 = await RelayClient.connect(paths, client: 'test');
    expect(c2.hello['version'], relayVersion);
    await c2.close();
    await next.stop();
  });

  test('refused while an agent run is active, unless forced', () async {
    final paths = RelayPaths(p.join(tmp.path, 'busy'));
    final daemon = daemonAt(paths.home);
    await daemon.start();
    final c = await RelayClient.connect(paths, client: 'test');
    await c.call(M.settingsSet, {'values': {'userName': 'Rifat'}});

    final project = await c.map(M.projectsCreate, {'name': 'Shutdown', 'key': 'SD'});
    final checkout = await repo(p.join(tmp.path, 'code'), 'app', {'README.md': 'app\n'});
    final r = await c.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    final task = await c.map(M.tasksCreate, {
      'projectId': project['id'],
      'fields': {'title': 'Hold a run open', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [r['id']], 'status': 'queued'},
    });
    // The demo agent asks before writing and waits for an answer: active.
    final run = await waitFor(() async {
      final runs = await c.list(M.runsList, {'active': true});
      return runs.where((x) => x['taskId'] == task['id'] && x['live'] == true).firstOrNull;
    });

    await expectLater(
      c.call(M.shutdown),
      throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.busy).having((e) => (e.data as Map)['activeRuns'], 'activeRuns', 1)),
    );
    expect((await c.map(M.status))['activeRuns'], 1, reason: 'still running after a refusal');

    final answer = await c.map(M.shutdown, {'force': true});
    expect(answer['stoppedRuns'], 1);
    await daemon.stopped.timeout(const Duration(seconds: 20));
    expect(File(paths.daemonInfo).existsSync(), isFalse);

    // The next relayd finds the run stopped, so the task can be retried.
    final next = daemonAt(paths.home);
    await next.start();
    final c2 = await RelayClient.connect(paths, client: 'test');
    final after = await c2.map(M.runsGet, {'id': run['id']});
    expect(RunStatus.isActive(after['status'] as String), isFalse);
    await c2.close();
    await next.stop();
  });
}
