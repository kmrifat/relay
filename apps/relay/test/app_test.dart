import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/shell.dart';
import 'package:relay/app/sidebar.dart';
import 'package:relay/app/theme.dart';
import 'package:relay/data/nav.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

/// An in-memory relayd: answers the calls the UI makes with seeded data.
Future<RelayClient> fakeRelayd() async {
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
    {'id': 't3', 'projectId': 'p1', 'number': 3, 'title': 'Login with magic link', 'status': 'running', 'attention': 'question', 'question': 'Resend or CF Email?', 'createdAt': now},
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
    M.syncStatus: (_) => {'inTeam': true, 'teamName': 'binarycastle', 'deviceId': 'dev', 'pendingOps': 0, 'lastSync': now, 'intervalSeconds': 30, 'shareAgents': false,
        'storage': {'kind': 'r2', 'bucket': 'relay', 'endpoint': 'https://acct.r2.cloudflarestorage.com'}},
    M.status: (_) => {'version': 'test', 'protocol': protocolVersion, 'pid': 1, 'uptimeSeconds': 5, 'rssBytes': 12 << 20, 'deviceId': 'dev'},
    M.settingsGet: (_) => {'userName': 'Rifat', 'deviceName': 'Studio'},
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
