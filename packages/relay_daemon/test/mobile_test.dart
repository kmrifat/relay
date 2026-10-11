@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_sync/relay_sync.dart';
import 'package:test/test.dart';

import 'daemon_test.dart' show repo, waitFor;

final workerDir = p.join(Directory.current.parent.parent.path, 'worker');

/// M8-02: a phone paired with a Mac through the team Worker sees the board
/// and the Mac's agents, queues work that runs on the Mac, watches the run
/// live and answers the agent's permission request.
void main() {
  final ready = Directory(p.join(workerDir, 'node_modules', 'miniflare')).existsSync();
  late Directory tmp;
  late Process worker;
  late RelayDaemon macDaemon;
  late RelayClient mac;
  late MobileHost host;
  late RelayClient phone;
  late HttpServer apns;
  final pushes = <Map<String, Object?>>[];

  setUpAll(() async {
    if (!ready) return;
    tmp = Directory.systemTemp.createTempSync('relay_mobile_');
    final bin = p.join(tmp.path, 'relay');
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', bin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    // A fake APNs that records what the Worker sends.
    apns = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    apns.listen((req) async {
      final body = await utf8.decodeStream(req);
      pushes.add({'path': req.uri.path, 'topic': req.headers.value('apns-topic'), 'auth': req.headers.value('authorization'), ...(jsonDecode(body) as Map).cast<String, Object?>()});
      await (req.response..statusCode = 200).close();
    });
    worker = await Process.start('node', ['test/serve.mjs', 'setup-secret'], workingDirectory: workerDir,
        environment: {'APNS_HOST': 'http://127.0.0.1:${apns.port}'});
    final url = (await worker.stdout.transform(utf8.decoder).transform(const LineSplitter()).first).trim();

    macDaemon = RelayDaemon(RelayPaths(p.join(tmp.path, 'mac')), relayBinary: bin, detectOnStart: false, resolveShellEnv: false);
    await macDaemon.start();
    mac = await RelayClient.connect(RelayPaths(p.join(tmp.path, 'mac')), client: 'test');
    await mac.call(M.settingsSet, {'values': {'userName': 'Rifat Khan', 'deviceName': 'Rifat’s MacBook Pro', 'syncIntervalSeconds': 3600}});
    await mac.map(M.syncCreateTeam, {'name': 'binarycastle', 'storage': {'kind': 'worker', 'url': url, 'setupToken': 'setup-secret'}});

    host = MobileHost(RelayPaths(p.join(tmp.path, 'phone')));
    phone = await host.start();
  });

  tearDownAll(() async {
    if (!ready) return;
    await phone.close();
    await host.stop();
    await mac.close();
    try {
      await macDaemon.stop();
    } catch (_) {}
    worker.kill();
    await apns.close(force: true);
  });

  test('pair, see the board and agents, queue work on the Mac, answer its agent', skip: ready ? false : 'run npm ci in worker/', () async {
    final project = await mac.map(M.projectsCreate, {'name': 'TaskManager', 'key': 'tm'});
    final checkout = await repo(p.join(tmp.path, 'code'), 'app', {'README.md': 'app\n'});
    final r = await mac.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    await mac.map(M.syncNow);

    // Pairing: the Mac's QR code; the phone joins as its companion.
    final pair = await mac.map(M.syncPairPhone);
    final code = pair['code'] as String;
    expect(code, startsWith(Pairing.prefix));
    expect(code, isNot(contains('setup-secret')));
    final joined = await phone.map(M.syncPair, {'code': code});
    expect(joined['teamName'], 'binarycastle');
    expect(joined['pairedMacName'], 'Rifat’s MacBook Pro');
    expect(host.hello()['userName'], 'Rifat Khan');

    await waitFor(() async {
      final s = await phone.map(M.syncStatus);
      return s['live'] == true && (s['online'] as List).contains(macDaemon.ctx.deviceId) ? s : null;
    }, timeout: const Duration(seconds: 20));

    // The board and the Mac's agents (with live numbers) arrive.
    expect((await phone.list(M.projectsList)).single['name'], 'TaskManager');
    final agents = await waitFor(() async {
      await mac.map(M.syncNow);
      await phone.map(M.syncNow);
      final a = await phone.list(M.agentsList);
      return a.any((x) => x['id'] == 'demo') ? a : null;
    });
    expect(agents.firstWhere((x) => x['id'] == 'demo')['active'], 0);

    // Queue a task from the phone: it runs on the Mac (no sharing needed:
    // it's my own phone).
    final task = await phone.map(M.tasksCreate, {
      'projectId': project['id'],
      'fields': {'title': 'From the phone', 'assigneeKind': 'agent', 'assignee': 'demo', 'repoIds': [r['id']], 'status': 'queued'},
    });
    expect(task['runOn'], macDaemon.ctx.deviceId);
    final events = <Map<String, Object?>>[];
    phone.events.where((e) => e.method == E.runEvents).listen((e) => events.addAll([
          for (final x in (e.params['events'] as List)) {...(x as Map).cast<String, Object?>(), 'runId': e.params['runId']},
        ]));
    final run = await waitFor(() async {
      final runs = await phone.list(M.runsList, {'taskId': task['id']});
      return runs.firstOrNull;
    }, timeout: const Duration(seconds: 30));
    expect(run['deviceId'], macDaemon.ctx.deviceId);
    await phone.list(M.runsEvents, {'runId': run['id']}); // backlog from the Mac

    // The agent asks; the phone sees it live and allows it.
    final perm = await waitFor(() async => events.where((e) => e['type'] == 'permission').firstOrNull, timeout: const Duration(seconds: 30));
    await phone.call(M.permissionsAnswer, {'runId': perm['runId'], 'requestId': (perm['data'] as Map)['id'], 'answer': 'allow_once'});
    await waitFor(() async {
      await phone.map(M.syncNow);
      final t = (await phone.map(M.tasksGet, {'id': task['id']}))['task'] as Map;
      return t['status'] == 'review' ? t : null;
    }, timeout: const Duration(seconds: 30));

    // A comment from the phone goes through the Mac.
    final comment = await phone.map(M.commentsPost, {'taskId': task['id'], 'body': 'Looks good, thanks'});
    expect(comment['author'], 'Rifat Khan');

    // A phone with the wrong pairing key is refused (a teammate can't pass
    // for my phone).
    final real = host.sync.secrets.pairing!;
    host.sync.secrets.pairing = Pairing(id: real.id, key: RelayCrypto.randomBytes(32), mac: real.mac, macName: real.macName, person: real.person);
    await expectLater(phone.call(M.runsStop, {'runId': run['id']}), throwsA(isA<RpcError>().having((e) => e.message, 'm', contains('does not take commands'))));
    host.sync.secrets.pairing = real;

    // Only allowed methods: the phone host never forwards others, and the
    // Mac refuses them anyway.
    await expectLater(host.sync.live.command(M.projectsCreate, {'name': 'x', 'key': 'x'}), throwsA(isA<CommandFailed>()));

    // Push: the team's APNs key goes into the Worker; the phone registers;
    // while the phone is away from the room, an agent's question wakes it.
    final pem = await Process.run('sh', ['-c', 'openssl ecparam -genkey -name prime256v1 -noout | openssl pkcs8 -topk8 -nocrypt']);
    expect(pem.exitCode, 0, reason: '${pem.stderr}');
    final st = await mac.map(M.pushConfig, {'keyId': 'ABCDE12345', 'teamId': 'TEAM123456', 'p8': pem.stdout as String});
    expect(st['configured'], isTrue);
    await phone.call(M.pushRegister, {'token': 'ab' * 32, 'sandbox': true});
    expect((await mac.map(M.pushStatus))['devices'], 1);
    await host.sync.live.stop(); // the app went to the background
    await waitFor(() async {
      final s = await mac.map(M.syncStatus);
      return (s['online'] as List).length == 1 ? s : null;
    }, timeout: const Duration(seconds: 10));
    await mac.call(M.tasksUpdate, {'id': task['id'], 'fields': {'attention': 'question', 'question': 'Ship it tonight?'}});
    final push = await waitFor(() async => pushes.firstOrNull, timeout: const Duration(seconds: 10));
    expect(push['path'], '/3/device/${'ab' * 32}');
    expect(push['topic'], 'com.binarycastle.relay');
    expect('${push['auth']}', startsWith('bearer '));
    expect(((push['aps'] as Map)['alert'] as Map)['title'], 'TM-1 has a question');
    expect((push['relay'] as Map)['taskId'], task['id']);
    host.sync.live.start();
    await waitFor(() async => host.sync.live.online.contains(macDaemon.ctx.deviceId) ? true : null, timeout: const Duration(seconds: 15));

    // The Mac goes away: commands say so.
    await mac.close();
    await macDaemon.stop();
    await waitFor(() async {
      final s = await phone.map(M.syncStatus);
      return (s['online'] as List).contains(macDaemon.ctx.deviceId) ? null : s;
    }, timeout: const Duration(seconds: 15));
    await expectLater(phone.call(M.runsStart, {'taskId': task['id']}), throwsA(isA<RpcError>().having((e) => e.message, 'm', contains('offline'))));
  });
}
