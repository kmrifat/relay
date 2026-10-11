import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;

void main() {
  testWidgets('composer: @ picks an agent, its model, effort, mode and repos go with the message', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final posted = <Map<String, Object?>>[];
    final ui = <String, String>{};
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.agentsList: (_) => [
        {
          'id': 'demo', 'adapter': 'demo', 'name': 'Demo agent', 'binaryPath': '/x/relay', 'slots': 3, 'color': '#0A64D8', 'letter': 'D', 'enabled': true,
          'models': [{'id': 'opus', 'label': 'Opus', 'note': 'strong'}, {'id': 'haiku', 'label': 'Haiku'}],
          'efforts': ['low', 'medium', 'high'],
        },
      ],
      M.messagesPost: (p) {
        posted.add(p);
        return {'message': {'id': 'm9', 'channelId': p['channelId'], 'body': p['body']}};
      },
      M.uiGet: (p) => ui[p['key']],
      M.uiSet: (p) {
        ui[p['key'] as String] = p['value'] as String;
        return true;
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.tap(find.text('kitchenly'));
    await settleUntil(tester, find.text('Made a task from that.'));

    // @dem + Tab: the agent becomes the message's target; its handle leaves the text.
    final box = find.byType(TextField).last;
    await tester.enterText(box, 'why is login slow? @dem');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Demo agent'), findsWidgets);
    expect(find.text('make a task'), findsOneWidget);
    expect((tester.widget(box) as TextField).controller!.text.trim(), 'why is login slow?');

    // Open the options: Haiku, effort low, Just answer, the api repo.
    await tester.tap(find.text('make a task'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Model: default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Haiku').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Effort: default'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('low').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Just answer'));
    await tester.pump();
    await tester.tap(find.text('api').last);
    await tester.pump();
    expect(find.text('Haiku · low · just answer · api'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);

    await tester.tap(find.text('Ask'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final sent = posted.single;
    expect([sent['agent'], sent['model'], sent['effort'], sent['mode'], sent['repoIds']], ['demo', 'haiku', 'low', 'answer', ['r2']]);
    expect(sent['body'], 'why is login slow?');
    // The choice is remembered for the next @demo in this channel.
    expect(ui['channel.ch-p1.demo'], contains('"mode":"answer"'));
    expect(find.text('Haiku · low · just answer · api'), findsNothing); // target clears after sending
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('⌘J asks an agent from anywhere; the question goes to the product channel', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final posted = <Map<String, Object?>>[];
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.messagesPost: (p) {
        posted.add(p);
        return {'message': {'id': 'm9'}};
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('AGENTS'), findsOneWidget);
    expect(find.text('Answers go to #kitchenly'), findsOneWidget);
    // The question on KT-3 is one of the things to continue.
    expect(find.text('Answer KT-3'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'which tests are flaky?');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect([posted.single['channelId'], posted.single['agent'], posted.single['mode'], posted.single['body']], ['ch-p1', 'demo', 'answer', 'which tests are flaky?']);
    expect(find.textContaining('AGENTS'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('a PM plan in the channel: tasks in order, approve starts it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final approved = <String>[];
    final now = DateTime.now().toUtc().toIso8601String();
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.messagesList: (p) => p['channelId'] == 'ch-p1'
          ? [
              {'id': 'plan-1', 'channelId': 'ch-p1', 'authorKind': 'agent', 'author': 'Pria', 'body': 'API first, then QA.', 'tag': 'plan', 'planId': 'plan-1', 'planState': 'proposed', 'createdAt': now,
                'items': [
                  {'taskId': 't9', 'key': 'KT-9', 'title': 'Refund endpoint', 'agent': 'Bram', 'after': []},
                  {'taskId': 't10', 'key': 'KT-10', 'title': 'Test refunds', 'agent': 'Quinn', 'after': [0]},
                ]},
            ]
          : [],
      M.plansApprove: (p) {
        approved.add(p['planId'] as String);
        return 2;
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    await tester.tap(find.text('kitchenly'));
    await settleUntil(tester, find.text('Plan · 2 tasks'));
    expect(find.text('Waiting for your OK'), findsOneWidget);
    expect(find.text('Refund endpoint'), findsOneWidget);
    expect(find.text('2 ← 1'), findsOneWidget);
    await tester.tap(find.text('Approve and start'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(approved, ['plan-1']);
    await tester.binding.setSurfaceSize(null);
  });
}
