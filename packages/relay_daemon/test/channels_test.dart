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
    final bin = p.join(tmp.path, Platform.isWindows ? 'relay.exe' : 'relay');
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
    expect(t2['title'], 'The board drag feels laggy. Can you profile it?');
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

  test('the composer picker: options reach the task; "just answer" replies in the thread with no board card', () async {
    final project = (await c.list(M.projectsList)).first;
    final chId = Channel.idFor(project['id'] as String);
    final repos = await c.list(M.reposList, {'projectId': project['id']});

    // Plan options travel with a task-mode message to its task.
    final made = await c.map(M.messagesPost, {
      'channelId': chId,
      'body': 'tidy the README',
      'agent': 'demo',
      'model': 'haiku',
      'effort': 'low',
      'repoIds': [repos.first['id']],
    });
    final t = (made['tasks'] as List).single as Map;
    expect([t['assignee'], t['model'], t['modelFor'], t['effort'], t['repoIds']], ['demo', 'haiku', 'demo', 'low', [repos.first['id']]]);
    expect(t['ask'], isNull);
    final run = await waitFor(() async => (await c.list(M.runsList)).where((r) => r['taskId'] == t['id']).firstOrNull);
    await c.call(M.runsStop, {'runId': run['id']});

    // A question: read-only, answered in the thread, never on the board.
    final asked = await c.map(M.messagesPost, {'channelId': chId, 'body': 'what is in this repo?', 'agent': 'demo', 'mode': 'answer'});
    final q = (asked['tasks'] as List).single as Map;
    expect(q['ask'], 'answer');
    expect(q['title'], startsWith('Question: '));
    final answer = await waitFor(() async {
      final ms = await c.list(M.messagesList, {'channelId': chId});
      return ms.where((m) => m['taskId'] == q['id'] && m['authorKind'] == 'agent').firstOrNull;
    }, timeout: const Duration(seconds: 30));
    expect(answer['body'], contains('A real agent would answer'));
    expect(answer['replyTo'], (asked['message'] as Map)['id']);
    final ack = (await c.list(M.messagesList, {'channelId': chId})).where((m) => m['replyTo'] == (asked['message'] as Map)['id'] && m['body'] == 'Looking into it…');
    expect(ack, hasLength(1));
    final done = await waitFor(() async {
      final x = ((await c.map(M.tasksGet, {'id': q['id']}))['task'] as Map);
      return x['status'] == 'done' ? x : null;
    });
    expect(done['status'], 'done');
    // Nothing was written, and no change set exists for the question.
    expect((await c.map(M.tasksGet, {'id': q['id']}))['changes'], isEmpty);
    expect(File(p.join(repos.first['localPath'] as String, 'RELAY_DEMO.md')).existsSync(), isFalse);

    await expectLater(c.call(M.messagesPost, {'channelId': chId, 'body': 'x', 'mode': 'shout'}), throwsA(isA<RpcError>()));
  });

  test('a side-panel chat: hidden task, turns resume the session, person tools', () async {
    final project = (await c.list(M.projectsList)).first;
    final first = await c.map(M.chatsSend, {'agentId': 'demo', 'text': 'what is running?', 'context': 'Agents › Demo agent', 'projectId': project['id']});
    final chatId = first['chatId'] as String;
    final task = ((await c.map(M.tasksGet, {'id': chatId}))['task'] as Map);
    expect([task['ask'], task['assignee'], task['title'], task['number']], ['chat', 'demo', 'Chat: what is running?', 0]);
    Future<Map<String, Object?>> finished(String runId) => waitFor(() async {
          final r = await c.map(M.runsGet, {'id': runId});
          return RunStatus.isFinished(r['status'] as String) ? r : null;
        }, timeout: const Duration(seconds: 30));
    final r1 = await finished(first['runId'] as String);
    expect([r1['status'], r1['chatText']], ['done', 'what is running?']);
    expect(r1['prompt'], allOf(contains('side panel of Relay'), contains('## Their message\nwhat is running?'), contains('They are looking at: Agents › Demo agent')));
    expect(r1['summary'], contains('A real agent would answer "what is running?"'));

    // The next turn resumes the agent's session with just the message.
    final second = await c.map(M.chatsSend, {'chatId': chatId, 'agentId': 'demo', 'text': 'and what is queued?'});
    expect(second['chatId'], chatId);
    final r2 = await finished(second['runId'] as String);
    expect(r2['prompt'], 'and what is queued?');
    expect(r2['summary'], contains('"and what is queued?"'));

    // A chat run acts for the person: it gets their tools, not a task's.
    final tools = RelayTools(RelayPaths(p.join(tmp.path, 'home')), r2['id'] as String);
    final names = (await tools.list()).map((t) => t['name']).toSet();
    expect(names, containsAll(['relay_tasks', 'relay_update_task', 'relay_create_task']));
    expect(names, isNot(contains('relay_progress')));
    await tools.close();

    // Chats never show up as work.
    expect(await RelayTools(RelayPaths(p.join(tmp.path, 'home')), null).call('relay_tasks', {'project': project['key']}), isNot(contains('Chat:')));
  });

  test('a signed-out agent says how to sign back in', () async {
    // Stands in for a Claude Code whose login expired: reads the prompt,
    // complains on stderr, exits 1.
    final fake = File(p.join(tmp.path, 'claude-signed-out'))
      ..writeAsStringSync('#!/bin/sh\nread -r line\necho "Failed to authenticate: OAuth session expired and could not be refreshed" >&2\nexit 1\n');
    await Process.run('chmod', ['+x', fake.path]);
    daemon.ctx.store.create<AgentProfile>(Kind.agent, {'id': 'claude-code', 'adapter': 'claude-code', 'name': 'Claude Code', 'binaryPath': fake.path, 'enabled': true, 'slots': 1});
    final project = await c.map(M.projectsCreate, {'name': 'Sign in', 'key': 'si'});
    final checkout = await repo(p.join(tmp.path, 'code'), 'signin', {'README.md': 'x\n'});
    await c.map(M.reposAdd, {'projectId': project['id'], 'path': checkout});
    final chId = Channel.idFor(project['id'] as String);
    await waitFor(() async => (await c.list(M.channelsList)).where((x) => x['id'] == chId).firstOrNull);

    final asked = await c.map(M.messagesPost, {'channelId': chId, 'body': '@claude-code you there?'});
    final task = (asked['tasks'] as List).single as Map;
    final report = await waitFor(() async {
      final ms = await c.list(M.messagesList, {'channelId': chId});
      return ms.where((m) => m['taskId'] == task['id'] && (m['body'] as String).contains('failed')).firstOrNull;
    }, timeout: const Duration(seconds: 30));
    expect(report['body'], 'SI-1 failed: Claude Code is signed out. Run `claude` in a terminal and type /login, then run the task again.');

    // The report goes out as the run ends; the task is marked after its
    // workspace is refreshed.
    final t = await waitFor(() async {
      final t = daemon.ctx.task(task['id'] as String);
      return t.data['attention'] == 'failed' ? t : null;
    });
    expect(t.data['lastError'], startsWith('Claude Code is signed out.'));
    final run = (await c.list(M.runsList)).firstWhere((r) => r['taskId'] == task['id']);
    expect(run['rawError'], contains('OAuth session expired'));
  }, skip: Platform.isWindows ? 'the stand-in agent is a shell script' : false);
}
