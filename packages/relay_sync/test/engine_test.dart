import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:relay_core/relay_core.dart';
import 'package:relay_sync/relay_sync.dart';
import 'package:test/test.dart';

class Device {
  Device(this.name) : store = Store.memory(deviceId: name), secrets = Secrets.fresh();
  final String name;
  final Store store;
  final Secrets secrets;
  SyncEngine? engine;
  void save() {}
}

Future<void> sharedFlow(StorageSettings storage) async {
  final a = Device('mac-a');
  final b = Device('mac-b');

  // A has work before the team exists; it becomes the team's history.
  final project = a.store.create<Project>(Kind.project, {'key': 'KT', 'name': 'Kitchenly'});
  final task = a.store.createTask(project.id, {'title': 'Share links'});
  a.store.create<AgentProfile>(Kind.agent, {'id': 'claude-code', 'name': 'Claude Code'}); // local only

  a.secrets.storage = storage;
  a.engine = await SyncEngine.createTeam(store: a.store, secrets: a.secrets, teamName: 'binarycastle', saveSecrets: a.save);
  expect((await a.engine!.sync()).pushedOps, greaterThan(0));
  expect(a.store.pendingCount, 0);

  final code = await a.engine!.createInvite();
  expect(code, startsWith(Invite.prefix));
  b.engine = await SyncEngine.join(store: b.store, secrets: b.secrets, code: code, saveSecrets: b.save);
  expect(b.secrets.teamName, 'binarycastle');
  await b.engine!.sync();
  expect(b.store.get<Task>(Kind.task, task.id)!.title, 'Share links');
  expect(b.store.get<AgentProfile>(Kind.agent, 'claude-code'), isNull); // agent profiles stay local
  expect(await a.engine!.members(), containsAll(['mac-a', 'mac-b']));

  // The invite was single-use.
  await expectLater(SyncEngine.join(store: Device('mac-c').store, secrets: Secrets.fresh(), code: code, saveSecrets: () {}),
      throwsA(isA<SyncError>()));

  // Both edit offline, different fields and the same field; both converge.
  a.store.patch<Task>(Kind.task, task.id, {'status': 'queued', 'title': 'A title'});
  await Future<void>.delayed(const Duration(milliseconds: 5));
  b.store.patch<Task>(Kind.task, task.id, {'brief': 'from B', 'title': 'B title'});
  b.store.createTask(project.id, {'title': 'Made on B'});
  for (var i = 0; i < 2; i++) {
    await a.engine!.sync();
    await b.engine!.sync();
  }
  final ta = a.store.get<Task>(Kind.task, task.id)!;
  final tb = b.store.get<Task>(Kind.task, task.id)!;
  expect(ta.title, tb.title);
  expect(ta.title, 'B title'); // later write wins
  expect(ta.status, 'queued');
  expect(ta.brief, 'from B');
  expect(a.store.list<Task>(Kind.task).map((t) => t.title), contains('Made on B'));

  // Remove B: the key rotates, B can't read anything new.
  final epoch = await a.engine!.revoke('mac-b');
  expect(epoch, 2);
  a.store.patch<Task>(Kind.task, task.id, {'title': 'After B left'});
  await a.engine!.sync();
  await expectLater(b.engine!.sync(), throwsA(isA<SyncError>().having((e) => e.message, 'message', contains('removed'))));
  expect(b.store.get<Task>(Kind.task, task.id)!.title, isNot('After B left'));

  // A new member joining later gets the whole key ring and history.
  final c = Device('mac-c');
  c.engine = await SyncEngine.join(store: c.store, secrets: c.secrets, code: await a.engine!.createInvite(), saveSecrets: c.save);
  await c.engine!.sync();
  expect(c.store.get<Task>(Kind.task, task.id)!.title, 'After B left');
  expect(c.store.list<Task>(Kind.task).map((t) => t.title), contains('Made on B'));
}

void main() {
  test('two devices converge through a shared folder; invites; revoke rotates the key', () async {
    await sharedFlow(StorageSettings.folder(Directory.systemTemp.createTempSync('relay_sync_').path));
  });

  test('a tampered batch is reported and skipped; the rest still applies', () async {
    final folder = Directory.systemTemp.createTempSync('relay_sync_t_').path;
    final a = Device('mac-a')..secrets.storage = StorageSettings.folder(folder);
    a.engine = await SyncEngine.createTeam(store: a.store, secrets: a.secrets, teamName: 't', saveSecrets: a.save);
    final b = Device('mac-b');
    b.engine = await SyncEngine.join(store: b.store, secrets: b.secrets, code: await a.engine!.createInvite(), saveSecrets: b.save);
    final p = a.store.create<Project>(Kind.project, {'key': 'X', 'name': 'One'});
    await a.engine!.push();
    a.store.patch<Project>(Kind.project, p.id, {'name': 'Two'});
    await a.engine!.push();
    // Flip a byte in the first batch.
    final first = File('$folder/relay/${a.secrets.teamId}/ops/mac-a/000000000001.op');
    final bytes = first.readAsBytesSync()..[45] ^= 0xff;
    first.writeAsBytesSync(bytes);
    final res = await b.engine!.sync();
    expect(res.problems.single, contains('authentication failed'));
    expect(b.store.get<Project>(Kind.project, p.id)!.name, 'Two');
  });

  test('works over S3 (fake server: SigV4, ListObjectsV2, If-None-Match, If-Match)', () async {
    final server = await FakeS3.start();
    addTearDown(server.close);
    await sharedFlow(StorageSettings.s3(endpoint: 'http://127.0.0.1:${server.port}', bucket: 'relay-test', region: 'auto', accessKeyId: 'AKIDTEST', secretAccessKey: 'secret'));
    expect(server.unsignedRequests, 0);
    expect(server.requests, greaterThan(20));
  });

  test('S3 testConnection reports a store that ignores If-None-Match', () async {
    final server = await FakeS3.start(honourConditions: false);
    addTearDown(server.close);
    final s3 = StorageSettings.s3(endpoint: 'http://127.0.0.1:${server.port}', bucket: 'b', accessKeyId: 'k', secretAccessKey: 's').backend() as S3Backend;
    final problems = await s3.testConnection('relay/probe');
    expect(problems.single, contains('If-None-Match'));
  });
}

/// A small in-memory S3 for tests: path-style buckets, ListObjectsV2 with
/// prefix and start-after, conditional PUT/DELETE, and a signature check
/// that every request carries an AWS4 Authorization header.
class FakeS3 {
  FakeS3._(this._server, this.honourConditions);
  final HttpServer _server;
  final bool honourConditions;
  final objects = <String, Uint8List>{};
  int requests = 0;
  int unsignedRequests = 0;

  int get port => _server.port;

  static Future<FakeS3> start({bool honourConditions = true}) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeS3._(s, honourConditions);
    s.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  String _etag(List<int> b) => '"${hashes.md5.convert(b)}"';

  Future<void> _handle(HttpRequest req) async {
    requests++;
    final auth = req.headers.value('authorization') ?? '';
    if (!auth.startsWith('AWS4-HMAC-SHA256 Credential=') || req.headers.value('x-amz-content-sha256') == null) unsignedRequests++;
    final segs = req.uri.pathSegments;
    final res = req.response;
    final body = await req.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d)).then((b) => b.takeBytes());
    if (segs.length == 1 && req.method == 'GET') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final after = req.uri.queryParameters['start-after'];
      final keys = objects.keys.where((k) => k.startsWith(prefix) && (after == null || k.compareTo(after) > 0)).toList()..sort();
      res.headers.contentType = ContentType('application', 'xml');
      res.write('<ListBucketResult><IsTruncated>false</IsTruncated>');
      for (final k in keys) {
        res.write('<Contents><Key>$k</Key><ETag>${_etag(objects[k]!).replaceAll('"', '&quot;')}</ETag><Size>${objects[k]!.length}</Size></Contents>');
      }
      res.write('</ListBucketResult>');
      await res.close();
      return;
    }
    final key = segs.skip(1).join('/');
    final existing = objects[key];
    switch (req.method) {
      case 'GET' || 'HEAD':
        if (existing == null) {
          res.statusCode = 404;
          res.write('<Error><Code>NoSuchKey</Code></Error>');
        } else {
          res.headers.set('etag', _etag(existing));
          if (req.method == 'GET') res.add(existing);
        }
      case 'PUT':
        final ifNone = req.headers.value('if-none-match');
        final ifMatch = req.headers.value('if-match');
        if (honourConditions && ifNone == '*' && existing != null) {
          res.statusCode = 412;
        } else if (honourConditions && ifMatch != null && (existing == null || _etag(existing) != ifMatch)) {
          res.statusCode = 412;
        } else {
          objects[key] = Uint8List.fromList(body);
          res.headers.set('etag', _etag(body));
        }
      case 'DELETE':
        objects.remove(key);
        res.statusCode = 204;
    }
    await res.close();
  }
}
