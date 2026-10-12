import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/data/relay_data.dart';
import 'package:relay/features/chat/chat_panel.dart';
import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;
import 'keyboard_test.dart' show mod;

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

  testWidgets('⌘J opens the chat: it goes to the picked agent with the page you are on; keys in replies are links', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    final sent = <Map<String, Object?>>[];
    final now = DateTime.now().toUtc().toIso8601String();
    var started = false;
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.tasksList: (_) => [
        {'id': 't1', 'projectId': 'p1', 'number': 1, 'title': 'Share a recipe with a link', 'status': 'review', 'createdAt': now},
        {'id': 't3', 'projectId': 'p1', 'number': 3, 'title': 'Login with magic link', 'status': 'running', 'createdAt': now},
        {'id': 'c9', 'projectId': 'p1', 'number': 9, 'title': 'Chat: what needs me?', 'status': 'done', 'ask': 'chat', 'assignee': 'demo', 'createdAt': now},
      ],
      M.runsList: (_) => [
        {'id': 'rc', 'taskId': 'c9', 'agentId': 'demo', 'status': 'done', 'chatText': 'what needs me?', 'startedAt': now},
      ],
      M.runsEvents: (p) => p['runId'] == 'rc'
          ? [
              {'runId': 'rc', 'seq': 1, 'at': now, 'type': 'tool_use', 'data': {'id': 'u1', 'tool': 'mcp__relay__relay_tasks', 'summary': 'KT'}},
              {'runId': 'rc', 'seq': 2, 'at': now, 'type': 'message', 'data': {'text': 'KT-3 is waiting for your answer.'}},
            ]
          : [],
      M.chatsSend: (p) {
        sent.add(p);
        started = true;
        return {'chatId': 'c9', 'runId': 'rc'};
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Share a recipe with a link'));
    // A chat is never a card on the board.
    expect(find.text('Chat: what needs me?'), findsNothing);

    await mod(tester, LogicalKeyboardKey.keyJ); // ⌘ on the Mac, Ctrl elsewhere
    await tester.pumpAndSettle();
    expect(find.text('Chat with Demo agent'), findsOneWidget);
    expect(find.text('How is Kitchenly going?'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Ask Demo agent anything, or tell it what to do'), 'what needs me?');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(started, isTrue);
    expect([sent.single['agentId'], sent.single['text'], sent.single['projectId'], sent.single['chatId']], ['demo', 'what needs me?', 'p1', null]);
    expect(sent.single['context'], 'Kitchenly');

    // The turn: what was asked, the steps, and the reply with KT-3 a link.
    await settleUntil(tester, find.textContaining('is waiting for your answer', findRichText: true));
    expect(find.text('what needs me?'), findsNWidgets(2)); // the chat's name, and what was asked
    expect(find.textContaining('relay_tasks'), findsOneWidget);
    await tester.tapOnText(find.textRange.ofSubstring('KT-3', descendentOf: find.textContaining('is waiting for your answer', findRichText: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Login with magic link'), findsWidgets);
    expect(find.text('Board'), findsOneWidget); // the breadcrumb: Kitchenly › Board › KT-3

    // ⌘J again hides it.
    await mod(tester, LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(find.text('Chat with Demo agent'), findsNothing);
    expect(find.text('what needs me?'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  test('task keys of known projects become links, not inside code or links', () {
    final data = DataSnapshot({Kind.project: {'p1': const Project({'id': 'p1', 'key': 'KT', 'name': 'Kitchenly'})}}, 1);
    expect(linkTaskKeys('See KT-3, [KT-1](x), `KT-2` and AB-4.', data), 'See [KT-3](relay:task/KT-3), [KT-1](x), `KT-2` and AB-4.');
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
