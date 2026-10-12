import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/shell.dart';
import 'package:relay/app/theme.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;
import 'keyboard_test.dart' show mod;

void main() {
  testWidgets('mission control: products with their team lanes, needs you answered inline, team chatter', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    final comments = <Map<String, Object?>>[];
    final now = DateTime.now().toUtc().toIso8601String();
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.projectsList: (_) => [
        {'id': 'p1', 'key': 'KT', 'name': 'Kitchenly', 'position': 0, 'createdAt': now, 'goal': 'Meal plans by Friday', 'milestone': 'v1'},
      ],
      M.agentsList: (_) => [
        {'id': 'demo', 'adapter': 'demo', 'name': 'Demo agent', 'binaryPath': '/x/relay', 'slots': 3, 'color': '#0A64D8', 'letter': 'D', 'enabled': true},
        {'id': 'pria', 'name': 'Pria', 'role': 'Project manager', 'runtime': 'demo', 'adapter': 'demo', 'binaryPath': '/x/relay', 'slots': 1, 'color': '#8944AB',
          'letter': 'P', 'enabled': true, 'teamId': 'tm1', 'model': 'opus', 'effort': 'high', 'models': [{'id': 'opus', 'label': 'Opus'}]},
      ],
      M.teamsList: (_) => [
        {'id': 'tm1', 'name': 'Kitchenly squad', 'members': ['pria'], 'projectIds': ['p1'], 'createdAt': now, 'edges': []},
      ],
      M.activityList: (_) => [
        {'kind': 'agent-message', 'at': now, 'taskId': 't1', 'key': 'KT-1', 'from': 'pria', 'fromName': 'Pria', 'to': 'demo', 'toName': 'Demo agent', 'text': 'Contract changed, regenerate the client.'},
      ],
      M.commentsPost: (p) {
        comments.add(p);
        return {'id': 'c9', ...p};
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await mod(tester, LogicalKeyboardKey.digit0); // ⌘ on the Mac, Ctrl elsewhere
    await settleUntil(tester, find.text('Team chatter'));

    expect(find.textContaining('Goal · Meal plans by Friday'), findsOneWidget);
    expect(find.text('Milestone · v1'), findsOneWidget);
    expect(find.text('Project manager'), findsOneWidget); // Pria's lane
    expect(find.text('IDLE'), findsWidgets);
    await settleUntil(tester, find.text('Contract changed, regenerate the client.'));
    expect(find.text('Pria → Demo agent · KT-1 · now'), findsOneWidget);
    // KT-3's question can be answered right here.
    expect(find.textContaining('asks · KT-3'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Your answer · ↵ sends'), 'Resend');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(comments.single, {'taskId': 't3', 'body': 'Resend'});
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('the app opens on Mission control', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final client = await tester.runAsync(fakeRelayd);
    await tester.pumpWidget(ProviderScope(
      overrides: [clientProvider.overrideWithValue(client!)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Shell()),
    ));
    await settleUntil(tester, find.text('Resend or CF Email?'));
    expect(find.text('Mission control'), findsWidgets);
    expect(find.text('Needs you · 2'), findsOneWidget); // KT-3's question, KT-1 ready to merge
    await tester.binding.setSurfaceSize(null);
  });
}
