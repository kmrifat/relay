@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:relay_core/relay_core.dart';
import 'package:relay_daemon/relay_daemon.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

import 'daemon_test.dart' show repo, waitFor;

void main() {
  late Directory tmp;
  late RelayDaemon daemon;
  late RelayClient c;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('relay_ch_');
    final bin = p.join(tmp.path, 'relay');
    final r = await Process.run('dart', ['compile', 'exe', 'bin/relay.dart', '-o', bin]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    daemon = RelayDaemon(RelayPaths(p.join(tmp.path, 'home')), relayBinary: bin, detectOnStart: false, resolveShellEnv: false);
    await daemon.start();
    c = await RelayClient.connect(RelayPaths(p.join(tmp.path, 'home')), client: 'test');
    await c.call(M.settingsSet, {'values': {'userName': 'Rifat'}});
  });

  tearDownAll(() async {
    await c.close();
    await daemon.stop();
  });

  test('channels: defaults, /task and @agent make tasks, agents report back, reactions, files, digest', () async {
    final notes = <Map<String, Object?>>[];
    final notesSub = c.events.where((e) => e.method == E.notify).listen((e) => notes.add(e.params));
    final project = await c.map(M.projectsCreate, {'name': 'Task Manager', 'key': 'tm'});
    final checkout = await repo(p.join(tmp.path, 'code'), 'app', {'README.md': 'app\n'});
    await c.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    final chs = await waitFor(() async {
      final l = await c.list(M.channelsList);
      return l.length == 2 ? l : null;
    });
    expect(chs.map((x) => x['name']), ['general', 'task-manager']);
    final ch = chs.firstWhere((x) => x['projectId'] == project['id']);
    final chId = ch['id'] as String;
    expect(chId, Channel.idFor(project['id'] as String));

    // A plain message; mine doesn't count as unread.
    final hello = (await c.map(M.messagesPost, {'channelId': chId, 'body': 'Morning all'}))['message'] as Map;
    expect((await c.list(M.channelsList)).firstWhere((x) => x['id'] == chId)['unread'], 0);

    // /task with an agent: a queued task on the channel's board.
    final made = await c.map(M.messagesPost, {'channelId': chId, 'body': '/task @demo add golden tests for the channel view'});
    final task = made['task'] as Map;
    expect(task['title'], 'add golden tests for the channel view');
    expect(task['assignee'], 'demo');
    expect(task['status'], 'queued');
    expect((made['message'] as Map)['taskId'], task['id']);
    await expectLater(c.call(M.messagesPost, {'channelId': Channel.general, 'body': '/task nope'}), throwsA(isA<RpcError>()));

    // The demo agent runs it (asks once to write), then reports in the channel.
    final events = <Map<String, Object?>>[];
    final sub = c.events.where((e) => e.method == E.runEvents).listen((e) => events.addAll((e.params['events'] as List).map((x) => {...(x as Map).cast<String, Object?>(), 'runId': e.params['runId']})));
    final perm = await waitFor(() async => events.where((e) => e['type'] == 'permission').firstOrNull);
    await c.call(M.permissionsAnswer, {'runId': perm['runId'], 'requestId': (perm['data'] as Map)['id'], 'answer': 'allow_once'});
    final report = await waitFor(() async {
      final ms = await c.list(M.messagesList, {'channelId': chId});
      return ms.where((m) => m['authorKind'] == 'agent' && m['taskId'] == task['id']).firstOrNull;
    }, timeout: const Duration(seconds: 30));
    expect(report['author'], 'Demo agent');
    expect(report['body'], contains('RELAY_DEMO.md'));
    await sub.cancel();

    // @agent in a message: a task from it, and the agent says so.
    final asked = await c.map(M.messagesPost, {'channelId': chId, 'body': 'The board drag feels laggy. @demo can you profile it?'});
    final t2 = (asked['tasks'] as List).single as Map;
    expect(t2['title'], 'The board drag feels laggy.');
    expect(t2['fromMessage'], (asked['message'] as Map)['id']);
    final ack = (await c.list(M.messagesList, {'channelId': chId})).where((m) => m['taskId'] == t2['id'] && m['authorKind'] == 'agent').single;
    expect(ack['body'], startsWith('Made a task from that'));
    expect(ack['replyTo'], (asked['message'] as Map)['id']);
    final run2 = await waitFor(() async => (await c.list(M.runsList)).where((r) => r['taskId'] == t2['id']).firstOrNull);
    await c.call(M.runsStop, {'runId': run2['id']});

    // Reactions merge per person; pins.
    await c.call(M.messagesReact, {'messageId': hello['id'], 'emoji': '+1'});
    await c.call(M.messagesReact, {'messageId': hello['id'], 'emoji': 'noted'});
    await c.call(M.messagesReact, {'messageId': hello['id'], 'emoji': 'noted', 'on': false});
    final reacted = Message((await c.list(M.messagesList, {'channelId': chId})).firstWhere((m) => m['id'] == hello['id']));
    expect(reacted.reactions, {'+1': ['Rifat']});
    await c.call(M.channelsPin, {'channelId': chId, 'messageId': hello['id']});
    expect(Channel((await c.list(M.channelsList)).firstWhere((x) => x['id'] == chId)).pins, [hello['id']]);

    // Files: kept by Relay, opened by path.
    final spec = File(p.join(tmp.path, 'presence-spec.md'))..writeAsStringSync('# Presence\n');
    final withFile = (await c.map(M.messagesPost, {'channelId': chId, 'body': 'Spec for presence', 'files': [spec.path]}))['message'] as Map;
    final meta = (withFile['files'] as List).single as Map;
    expect(meta['name'], 'presence-spec.md');
    expect(meta['size'], 11);
    final opened = await c.map(M.filesGet, {'messageId': withFile['id'], 'fileId': meta['id']});
    expect(File(opened['path'] as String).readAsStringSync(), '# Presence\n');

    // The morning digest: one per channel per day, listing yesterday's runs.
    final now = DateTime.now();
    daemon.channels.postDigests(now: DateTime(now.year, now.month, now.day, 9));
    daemon.channels.postDigests(now: DateTime(now.year, now.month, now.day, 10));
    final digests = (await c.list(M.messagesList, {'channelId': chId})).where((m) => m['tag'] == 'digest').toList();
    expect(digests, hasLength(1));
    expect(digests.single['body'], startsWith('Overnight: 2 runs'));
    expect((digests.single['items'] as List).length, 2);

    // Notifications: the agent asked, the work is ready, nothing for my own messages.
    expect(notes.where((n) => n['kind'] == 'ask' && n['taskId'] == task['id']), isNotEmpty);
    expect(notes.where((n) => n['kind'] == 'review' && n['title'] == 'TM-1 is ready for review'), hasLength(1));
    expect(notes.where((n) => n['kind'] == 'mention'), isEmpty);

    // Unread: a teammate's message (arriving by sync) counts until read,
    // and mentioning me notifies.
    daemon.ctx.store.create<Message>(Kind.message, {'channelId': chId, 'authorKind': 'person', 'author': 'Sara', 'deviceId': 'sara-mac', 'body': 'hi @rifat, ok if it takes one of your slots?'});
    await waitFor(() async => notes.where((n) => n['kind'] == 'mention').firstOrNull);
    expect(notes.lastWhere((n) => n['kind'] == 'mention')['title'], 'Sara in #task-manager');
    await notesSub.cancel();
    expect((await c.list(M.channelsList)).firstWhere((x) => x['id'] == chId)['unread'], greaterThan(0));
    await c.call(M.channelsRead, {'channelId': chId});
    expect((await c.list(M.channelsList)).firstWhere((x) => x['id'] == chId)['unread'], 0);
  });
}
