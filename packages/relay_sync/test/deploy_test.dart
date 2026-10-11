@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:relay_core/relay_core.dart';
import 'package:relay_sync/relay_sync.dart';
import 'package:relay_sync/src/worker_source.dart';
import 'package:test/test.dart';

final root = Directory.current.parent.parent.path;
final workerDir = '$root/worker';

/// Just enough of Cloudflare's API to deploy a Worker.
class FakeCloudflare {
  FakeCloudflare._(this._server);
  final HttpServer _server;
  final calls = <String>[];
  final scripts = <String, Map<String, Object?>>{}; // name → metadata
  String? subdomain;
  bool bucketExists = false;
  String token = 'cf-token';
  String? uploadedSource;

  int get port => _server.port;
  Uri get api => Uri.parse('http://127.0.0.1:$port/client/v4');

  static Future<FakeCloudflare> start() async {
    final f = FakeCloudflare._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    f._server.listen(f._handle);
    return f;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path.replaceFirst('/client/v4/accounts/acct/', '');
    calls.add('${req.method} $path');
    final res = req.response..headers.contentType = ContentType.json;
    void ok(Object? result) => res.write(jsonEncode({'success': true, 'errors': [], 'result': result}));
    void fail(int status, int code, String msg) => res
      ..statusCode = status
      ..write(jsonEncode({'success': false, 'errors': [{'code': code, 'message': msg}], 'result': null}));
    if (req.headers.value('authorization') != 'Bearer $token') {
      fail(403, 10000, 'Authentication error');
    } else if (req.method == 'POST' && path == 'r2/buckets') {
      bucketExists ? fail(409, 10004, 'The bucket you tried to create already exists.') : ok({'name': 'relay'});
      bucketExists = true;
    } else if (req.method == 'GET' && path == 'workers/scripts') {
      ok([for (final e in scripts.entries) {'id': e.key, if (e.value['migrations'] != null || e.value['_tag'] != null) 'migration_tag': 'v1'}]);
    } else if (req.method == 'PUT' && path.startsWith('workers/scripts/')) {
      final body = await utf8.decodeStream(req);
      final boundary = req.headers.contentType!.parameters['boundary']!;
      final parts = {
        for (final p in body.split('--$boundary').where((p) => p.contains('name="')))
          RegExp(r'name="([^"]+)"').firstMatch(p)!.group(1)!: p.substring(p.indexOf('\r\n\r\n') + 4, p.lastIndexOf('\r\n')),
      };
      final meta = (jsonDecode(parts['metadata']!) as Map).cast<String, Object?>();
      final name = path.split('/').last;
      scripts[name] = {...meta, if (scripts[name] != null) '_tag': 'v1'};
      uploadedSource = parts['index.js'];
      ok({'id': name});
    } else if (path == 'workers/subdomain') {
      if (req.method == 'PUT') {
        subdomain = (jsonDecode(await utf8.decodeStream(req)) as Map)['subdomain'] as String;
        ok({'subdomain': subdomain});
      } else {
        subdomain == null ? fail(404, 10007, 'This account does not have a workers.dev subdomain.') : ok({'subdomain': subdomain});
      }
    } else if (req.method == 'POST' && path.endsWith('/subdomain')) {
      ok({'enabled': true});
    } else {
      fail(404, 7003, 'No route for $path');
    }
    await res.close();
  }
}

void main() {
  test('the embedded Worker matches worker/src/index.js (run tool/gen_worker_source.sh)', () {
    expect(workerSource, File('$workerDir/src/index.js').readAsStringSync());
  });

  test('deploys to a fresh account, then a team is created on it', skip: Directory('$workerDir/node_modules/miniflare').existsSync() ? false : 'run npm ci in worker/', () async {
    final cf = await FakeCloudflare.start();
    Process? worker;
    addTearDown(() => worker?.kill());
    // The "deployed" Worker: Miniflare, started with the setup token the
    // deployer just uploaded.
    Future<String> serve(String script, String _) async {
      final bindings = cf.scripts[script]!['bindings'] as List;
      final setup = (bindings.firstWhere((b) => (b as Map)['name'] == 'SETUP_TOKEN') as Map)['text'] as String;
      worker = await Process.start('node', ['test/serve.mjs', setup], workingDirectory: workerDir);
      return (await worker!.stdout.transform(utf8.decoder).transform(const LineSplitter()).first).trim();
    }

    final steps = <String>[];
    final deployer = WorkerDeployer(accountId: 'acct', apiToken: 'cf-token', api: cf.api, urlFor: serve);
    final storage = await deployer.deploy(scriptName: 'relay-kt', onStep: steps.add);

    final meta = cf.scripts['relay-kt']!;
    expect(meta['main_module'], 'index.js');
    expect(meta['migrations'], {'new_tag': 'v1', 'new_sqlite_classes': ['TeamRoom']});
    expect((meta['bindings'] as List).map((b) => (b as Map)['type']), ['r2_bucket', 'durable_object_namespace', 'secret_text']);
    expect(cf.uploadedSource, workerSource);
    expect(cf.subdomain, startsWith('relay-')); // a fresh account had none
    expect(steps.first, contains('R2 bucket'));
    expect(storage.kind, 'worker');
    expect(storage.setupToken, isNotNull);

    final store = Store.memory(deviceId: 'mac-a');
    final secrets = Secrets.fresh()..storage = storage;
    final engine = await SyncEngine.createTeam(store: store, secrets: secrets, teamName: 'binarycastle', saveSecrets: () {});
    store.create<Project>(Kind.project, {'key': 'KT', 'name': 'Kitchenly'});
    expect((await engine.sync()).pushedOps, greaterThan(0));
  });

  test('a redeploy keeps the Durable Object migration and the bucket; a bad token says what it needs', () async {
    final cf = await FakeCloudflare.start()
      ..subdomain = 'team'
      ..bucketExists = true
      ..scripts['relay-kt'] = {'_tag': 'v1'};
    final d = WorkerDeployer(accountId: 'acct', apiToken: 'cf-token', api: cf.api, urlFor: (_, _) => 'http://127.0.0.1:1');
    await expectLater(d.deploy(scriptName: 'relay-kt', waitUpTo: Duration.zero), throwsA(isA<SyncError>().having((e) => e.message, 'm', contains('did not answer'))));
    expect(cf.scripts['relay-kt']!['migrations'], isNull);

    final bad = WorkerDeployer(accountId: 'acct', apiToken: 'wrong', api: cf.api);
    await expectLater(bad.deploy(scriptName: 'relay-kt'), throwsA(isA<SyncError>().having((e) => e.message, 'm', contains('Workers Scripts: Edit'))));
    await expectLater(d.deploy(scriptName: 'Bad Name'), throwsA(isA<SyncError>()));
  });
}
