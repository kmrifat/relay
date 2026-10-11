import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/shell.dart';
import 'package:relay/app/sidebar.dart';
import 'package:relay/app/theme.dart';
import 'package:relay/data/nav.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay/mobile/mobile_data.dart';
import 'package:relay/mobile/mobile_shell.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

/// An in-memory relayd: answers the calls the UI makes with seeded data.
Future<RelayClient> fakeRelayd({bool phone = false, bool paired = true}) async {
  final toServer = StreamController<List<int>>();
  final toClient = StreamController<List<int>>();
  final server = RpcPeer(toServer.stream, toClient.sink, name: 'fake-relayd');
  final now = DateTime.now().toUtc().toIso8601String();
  final project = {'id': 'p1', 'key': 'KT', 'name': 'Kitchenly', 'position': 0, 'createdAt': now};
  final repos = [
    {'id': 'r1', 'projectId': 'p1', 'name': 'shared', 'role': 'shared', 'mergeStep': 0, 'color': '#D49BF5', 'contractPaths': ['openapi.yaml'], 'paths': {'dev': '/tmp/shared'}},
    {'id': 'r2', 'projectId': 'p1', 'name': 'api', 'role': 'api', 'mergeStep': 1, 'dependsOn': ['r1'], 'color': '#32D74B', 'paths': {'dev': '/tmp/api'}},
    {'id': 'r3', 'projectId': 'p1', 'name': 'app', 'role': 'app', 'mergeStep': 2, 'dependsOn': ['r1'], 'color': '#4D9BFF', 'paths': {'dev': '/tmp/app'}},
  ];
  final tasks = [
    {'id': 't1', 'projectId': 'p1', 'number': 1, 'title': 'Share a recipe with a link', 'status': 'review', 'priority': 1, 'repoIds': ['r1', 'r2', 'r3'], 'assigneeKind': 'agent', 'assignee': 'demo', 'createdAt': now},
    {'id': 't2', 'projectId': 'p1', 'number': 2, 'title': 'Recurring meal plans', 'status': 'backlog', 'createdAt': now},
    {'id': 't3', 'projectId': 'p1', 'number': 3, 'title': 'Login with magic link', 'status': 'running', 'attention': 'question', 'question': phone ? 'Should the magic link go out through Resend or Cloudflare Email Workers?' : 'Resend or CF Email?', 'createdAt': now},
  ];
  final agents = [
    {'id': 'demo', 'adapter': 'demo', 'name': 'Demo agent', 'binaryPath': '/x/relay', 'slots': 3, 'color': '#0A64D8', 'letter': 'D', 'enabled': true},
  ];
  final changes = [
    {'id': 'c1', 'taskId': 't1', 'repoId': 'r1', 'status': 'merged', 'branch': 'kt-1', 'worktreePath': '/tmp/ws/shared', 'additions': 34, 'deletions': 2, 'filesChanged': 1},
    {'id': 'c2', 'taskId': 't1', 'repoId': 'r2', 'status': 'ready', 'branch': 'kt-1', 'worktreePath': '/tmp/ws/api', 'additions': 188, 'deletions': 12, 'filesChanged': 4},
  ];
  final handlers = <String, Object? Function(Map<String, Object?>)>{
    M.hello: (_) => {'version': 'test', 'protocol': protocolVersion, 'deviceId': 'dev', 'userName': 'Rifat'},
    M.projectsList: (_) => [project],
    M.reposList: (_) => repos,
    M.tasksList: (_) => tasks,
    M.agentsList: (_) => agents,
    M.rulesList: (_) => [],
    M.runsList: (_) => [],
    M.runsEvents: (_) => [],
    M.workspacesList: (_) => [
      {'taskId': 't1', 'changes': changes},
    ],
    M.devicesList: (_) => [
      {'id': 'dev', 'name': 'Studio', 'person': 'Rifat', 'lastSeen': now, 'agents': agents},
      {'id': 'dev2', 'name': 'Air', 'person': 'Nadia', 'lastSeen': now, 'shareAgents': true, 'agents': [
        {'id': 'codex', 'name': 'Codex', 'color': '#10A37F', 'letter': 'C', 'slots': 2},
      ]},
    ],
    M.syncStatus: (_) => {if (phone && paired) ...{'pairedMac': 'dev', 'pairedMacName': 'Studio', 'live': true, 'online': ['dev', 'phone1']}, 'inTeam': phone ? paired : true, 'teamName': 'binarycastle', 'deviceId': 'dev', 'pendingOps': 0, 'lastSync': now, 'intervalSeconds': 30, 'shareAgents': false,
        'storage': {'kind': 'r2', 'bucket': 'relay', 'endpoint': 'https://acct.r2.cloudflarestorage.com'}},
    M.status: (_) => {'version': 'test', 'protocol': protocolVersion, 'pid': 1, 'uptimeSeconds': 5, 'rssBytes': 12 << 20, 'deviceId': 'dev'},
    M.settingsGet: (_) => {'userName': 'Rifat', 'deviceName': 'Studio'},
    M.channelsList: (_) => [
      {'id': 'ch-general', 'name': 'general', 'unread': 0},
      {'id': 'ch-p1', 'name': 'kitchenly', 'projectId': 'p1', 'unread': 2, 'pin.m3': true},
    ],
    M.messagesList: (p) => p['channelId'] == 'ch-p1'
        ? [
            {'id': 'm1', 'channelId': 'ch-p1', 'authorKind': 'system', 'author': 'Relay', 'tag': 'digest', 'body': 'Overnight: 2 runs · 1 ready for review', 'createdAt': now,
              'items': [{'taskId': 't1', 'key': 'KT-1', 'title': 'Share a recipe with a link', 'ok': true, 'agent': 'Demo agent'}]},
            {'id': 'm2', 'channelId': 'ch-p1', 'authorKind': 'person', 'author': 'Nadia', 'deviceId': 'dev2', 'body': 'Drag feels laggy. @codex can you profile it?', 'createdAt': now,
              'react.+1.Rifat': true, 'react.+1.Nadia': true},
            {'id': 'm3', 'channelId': 'ch-p1', 'authorKind': 'agent', 'author': 'Codex', 'deviceId': 'dev2', 'body': 'Made a task from that.', 'taskId': 't2', 'createdAt': now,
              'files': [{'id': 'f1', 'name': 'presence-spec.md', 'size': 4096, 'stored': 'team'}]},
          ]
        : [],
    M.channelsRead: (_) => true,
    M.commentsList: (_) => [
      {'id': 'cm1', 'taskId': 't1', 'authorKind': 'agent', 'author': 'Demo agent', 'body': 'Done. Wrote the share link.', 'createdAt': now},
    ],
  };
  for (final e in handlers.entries) {
    server.registerMethod(e.key, e.value);
  }
  return RelayClient.attach(toClient.stream, toServer.sink, token: 'test');
}

/// Pumps real time until [finder] shows up (RPC goes through real streams).
Future<void> settleUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
}

Widget app(RelayClient client) => ProviderScope(
  overrides: [clientProvider.overrideWithValue(client)],
  child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Shell()),
);

void main() {
  testWidgets('board shows tasks by column, repo chips, and opens a task', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(app(client!));
    // Let the data load and the default project be chosen.
    await settleUntil(tester, find.text('Share a recipe with a link'));

    expect(find.text('Kitchenly'), findsWidgets);
    expect(find.text('Share a recipe with a link'), findsOneWidget);
    expect(find.text('Recurring meal plans'), findsOneWidget);
    expect(find.text('Asks you'), findsOneWidget);
    // The project opens into its repos in the sidebar.
    expect(find.text('shared'), findsWidgets);
    expect(find.text('Approve & merge'), findsOneWidget);

    await tester.tap(find.text('Share a recipe with a link'));
    await settleUntil(tester, find.text('Done. Wrote the share link.'));
    expect(find.text('KT-1 · Share a recipe with a link'), findsOneWidget);
    expect(find.text('Change set'), findsOneWidget);
    expect(find.textContaining('Merged'), findsOneWidget);
    expect(find.text('Done. Wrote the share link.'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('settings shows the team, its devices and sync health', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.tap(find.text('Settings'));
    await settleUntil(tester, find.text('binarycastle'));
    expect(find.text('binarycastle'), findsOneWidget);
    expect(find.textContaining('Synced'), findsOneWidget);
    expect(find.text('Air'), findsOneWidget);
    expect(find.text('This Mac'), findsWidgets);
    expect(find.text('Shares agents'), findsOneWidget);
    expect(find.byTooltip('Remove from team'), findsOneWidget); // not for this Mac
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('a channel: digest, mentions, reactions, task card, file, people and agents', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    expect(find.text('kitchenly'), findsOneWidget); // sidebar channel
    await tester.tap(find.text('kitchenly'));
    await settleUntil(tester, find.text('Made a task from that.'));
    expect(find.text('Overnight: 2 runs · 1 ready for review'), findsOneWidget);
    expect(find.text('DIGEST'), findsOneWidget);
    expect(find.text('AGENT · NADIA\'S MAC'), findsOneWidget);
    expect(find.text('+1  2'), findsOneWidget);
    expect(find.text('Recurring meal plans'), findsOneWidget); // task card for t2
    expect(find.text('presence-spec.md'), findsWidgets); // file + pinned
    expect(find.text('@codex'), findsOneWidget); // Nadia's shared agent
    expect(find.text('Nadia'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, '/task @co');
    await tester.pump();
    expect(find.text('Create task'), findsOneWidget);
    expect(find.textContaining('Codex · Nadia'), findsOneWidget); // @ suggestions
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iPhone: unpaired shows pairing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    final client = await tester.runAsync(() => fakeRelayd(phone: true, paired: false));
    await tester.pumpWidget(ProviderScope(
      overrides: [clientProvider.overrideWithValue(client!)],
      child: const MaterialApp(home: MobileShell()),
    ));
    await settleUntil(tester, find.text('Pair with your Mac'));
    expect(find.text('Scan the QR code'), findsOneWidget);
    expect(find.text('Paste a code'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('iPhone: inbox answers, board, agents', (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    final client = await tester.runAsync(() => fakeRelayd(phone: true));
    await tester.pumpWidget(ProviderScope(
      overrides: [clientProvider.overrideWithValue(client!)],
      child: const MaterialApp(home: MobileShell()),
    ));
    await settleUntil(tester, find.text('Inbox'));
    await settleUntil(tester, find.text('Demo agent asks'));
    // One-tap answers from an either/or question.
    expect(find.text('Resend'), findsOneWidget);
    expect(find.text('Cloudflare Email Workers'), findsOneWidget);
    expect(find.text('Reply in your own words'), findsOneWidget);
    expect(find.text('Share a recipe with a link'), findsOneWidget); // ready for review

    await tester.tap(find.text('Board'));
    await tester.pump();
    expect(find.text('Kitchenly'), findsOneWidget);
    expect(find.text('Waiting for an answer'), findsOneWidget);

    await tester.tap(find.text('Agents'));
    await tester.pump();
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Awake'), findsOneWidget);
    expect(find.text("Nadia's Codex"), findsOneWidget); // shared by a teammate
    await tester.binding.setSurfaceSize(null);
  });

  test('either/or questions become one-tap answers', () {
    expect(choicesIn('Should the magic link go out through Resend or Cloudflare Email Workers?'), ('Resend', 'Cloudflare Email Workers'));
    expect(choicesIn('Which provider should we use?'), isNull);
    expect(choicesIn('A or B or C?'), isNull);
  });

  test('smart lists pick the right tasks', () {
    final question = Task(const {'id': 'a', 'projectId': 'p', 'status': 'running', 'attention': 'question'});
    final review = Task(const {'id': 'b', 'projectId': 'p', 'status': 'review'});
    expect(inSmartList(AppPage.waiting, question), isTrue);
    expect(inSmartList(AppPage.review, review), isTrue);
    expect(inSmartList(AppPage.review, question), isFalse);
    expect(inSmartList(AppPage.inbox, review), isTrue);
  });

  test('hexColor parses #RRGGBB and falls back', () {
    expect(hexColor('#0A64D8'), const Color(0xFF0A64D8));
    expect(hexColor('nope', const Color(0xFF000000)), const Color(0xFF000000));
  });
}
