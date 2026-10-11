import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;

void main() {
  testWidgets('team page: workflow, members and an inspector that edits the agent', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final updates = <Map<String, Object?>>[];
    final now = DateTime.now().toUtc().toIso8601String();
    Map<String, Object?> role(String id, String name, String role, String color, String model, String effort, List<String> caps) => {
      'id': id, 'name': name, 'role': role, 'runtime': 'demo', 'adapter': 'demo', 'binaryPath': '/x/relay', 'slots': 2, 'color': color,
      'letter': name[0], 'enabled': true, 'teamId': 'tm1', 'model': model, 'effort': effort, 'caps': caps,
      'models': [{'id': 'opus', 'label': 'Opus'}, {'id': 'sonnet', 'label': 'Sonnet'}, {'id': 'haiku', 'label': 'Haiku'}],
      'efforts': ['low', 'medium', 'high'], 'responsibilities': 'You own the goal.',
    };
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.agentsList: (_) => [
        {'id': 'demo', 'adapter': 'demo', 'name': 'Demo agent', 'binaryPath': '/x/relay', 'slots': 3, 'color': '#0A64D8', 'letter': 'D', 'enabled': true},
        role('pria', 'Pria', 'Project manager', '#8944AB', 'opus', 'high', ['createTasks', 'assign']),
        role('bram', 'Bram', 'Sr backend dev', '#0A64D8', 'sonnet', 'high', ['editCode', 'runShell']),
      ],
      M.teamsList: (_) => [
        {'id': 'tm1', 'name': 'Kitchenly squad', 'members': ['pria', 'bram'], 'projectIds': ['p1'], 'createdAt': now,
          'edges': [{'from': 'you', 'to': 'pria'}, {'from': 'pria', 'to': 'bram'}, {'from': 'bram', 'to': 'you'}]},
      ],
      M.agentsUpdate: (p) {
        updates.add(p);
        return {'id': p['id']};
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Kitchenly squad'));
    await tester.tap(find.text('Kitchenly squad'));
    await settleUntil(tester, find.text('How work flows'));

    expect(find.text('Pria · Project manager'), findsOneWidget); // workflow node
    expect(find.text('You review'), findsOneWidget);
    expect(find.text('Sr backend dev'), findsOneWidget); // members table
    expect(find.text('Opus'), findsWidgets);
    // The first member is in the inspector.
    expect(find.text('Model: Opus'), findsOneWidget);
    expect(find.text('Assign teammates'), findsOneWidget);

    // Pick Bram; switch his model to Haiku.
    await tester.tap(find.text('Bram').first);
    await tester.pumpAndSettle();
    expect(find.text('Model: Sonnet'), findsOneWidget);
    await tester.tap(find.text('Model: Sonnet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Haiku').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(updates.last, {'id': 'bram', 'fields': {'model': 'haiku', 'effort': 'high'}});

    // Take away his shell.
    await tester.tap(find.text('Run shell'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(updates.last, {'id': 'bram', 'fields': {'caps': ['editCode']}});
    await tester.binding.setSurfaceSize(null);
  });
}
