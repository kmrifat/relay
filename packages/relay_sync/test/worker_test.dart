@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:relay_core/relay_core.dart';
import 'package:relay_sync/relay_sync.dart';
import 'package:test/test.dart';

import 'engine_test.dart' show Device, sharedFlow;

final workerDir = '${Directory.current.parent.parent.path}/worker';

/// The real Worker (worker/src/index.js) on Miniflare. Needs `npm ci` in
/// worker/; skipped without it.
Future<(Process, String)> startWorker() async {
  final p = await Process.start('node', ['test/serve.mjs', 'setup-secret'], workingDirectory: workerDir);
  final url = await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).first.timeout(const Duration(seconds: 30));
  addTearDown(() => p.kill());
  return (p, url.trim());
}

void main() {
  final ready = Directory('$workerDir/node_modules/miniflare').existsSync();

  test('the shared flow through the team Worker', skip: ready ? false : 'run npm ci in worker/', () async {
    final (_, url) = await startWorker();
    await sharedFlow(StorageSettings.worker(url, setupToken: 'setup-secret'));
  });

  test('invites carry no credentials; a removed device loses storage access', skip: ready ? false : 'run npm ci in worker/', () async {
    final (_, url) = await startWorker();
    final a = Device('mac-a')..secrets.storage = StorageSettings.worker(url, setupToken: 'setup-secret');
    a.engine = await SyncEngine.createTeam(store: a.store, secrets: a.secrets, teamName: 't', saveSecrets: a.save);
    expect(a.secrets.storage!.setupToken, isNull);
    expect(jsonEncode(a.secrets.storage!.toJson()), isNot(contains('setup')));

    final code = await a.engine!.createInvite();
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(code.substring(Invite.prefix.length))));
    expect(jsonDecode(payload)['storage'], {'kind': 'worker', 'endpoint': url});

    // A second team can't take over the Worker with the spent setup token.
    final intruder = Device('mac-x')..secrets.storage = StorageSettings.worker(url, setupToken: 'setup-secret');
    await expectLater(SyncEngine.createTeam(store: intruder.store, secrets: intruder.secrets, teamName: 'x', saveSecrets: () {}), throwsA(isA<StorageException>()));

    final b = Device('mac-b');
    b.engine = await SyncEngine.join(store: b.store, secrets: b.secrets, code: code, saveSecrets: b.save);
    b.store.create<Project>(Kind.project, {'key': 'B', 'name': 'From B'});
    await b.engine!.sync();
    await a.engine!.revoke('mac-b');

    // B's old token can't list or write any more, only see that it's out.
    final raw = WorkerBackend(Uri.parse(url), token: b.secrets.workerToken);
    await expectLater(raw.list('relay/${a.secrets.teamId}/ops/'), throwsA(isA<StorageAccessDenied>()));
    await expectLater(raw.put('relay/${a.secrets.teamId}/ops/mac-b/000000000099.op', utf8.encode('x')), throwsA(isA<StorageAccessDenied>()));
    await expectLater(b.engine!.sync(), throwsA(isA<SyncError>().having((e) => e.message, 'message', contains('removed'))));
    // A carries on with the new key.
    a.store.create<Project>(Kind.project, {'key': 'A2', 'name': 'After'});
    expect((await a.engine!.sync()).problems, isEmpty);
  });
}
