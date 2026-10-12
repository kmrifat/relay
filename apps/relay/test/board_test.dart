import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_protocol/relay_protocol.dart';

import 'app_test.dart' show app, fakeRelayd, settleUntil;

void main() {
  testWidgets('board v2: epic lanes, filter, folded Done, peek with a comment box', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    final now = DateTime.now().toUtc().toIso8601String();
    final posted = <Map<String, Object?>>[];
    final client = await tester.runAsync(() => fakeRelayd(extra: {
      M.tasksList: (_) => [
        {'id': 'e1', 'projectId': 'p1', 'number': 9, 'title': 'Meal planning', 'status': 'backlog', 'epic': true, 'createdAt': now},
        {'id': 't2', 'projectId': 'p1', 'number': 2, 'title': 'Recurring meal plans', 'status': 'backlog', 'parentId': 'e1', 'createdAt': now,
          'doneWhen': [{'text': 'weekly repeat', 'done': true}, {'text': 'skip a week', 'done': false}]},
        {'id': 't3', 'projectId': 'p1', 'number': 3, 'title': 'Login with magic link', 'status': 'running', 'createdAt': now},
        {'id': 't4', 'projectId': 'p1', 'number': 4, 'title': 'Old thing', 'status': 'done', 'createdAt': now},
      ],
      M.commentsPost: (p) {
        posted.add(p);
        return {'id': 'c1', ...p};
      },
    }));
    await tester.pumpWidget(app(client!));
    await settleUntil(tester, find.text('Recurring meal plans'));

    // Epics are lanes, with progress; the epic itself is not a card.
    expect(find.text('Meal planning'), findsOneWidget);
    expect(find.text('epic · 0 of 1 done'), findsOneWidget);
    expect(find.text('No epic'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget); // done-when on the card
    // Done starts folded.
    expect(find.text('Old thing'), findsNothing);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('In progress'), findsOneWidget);

    // / filters.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Filter this board  /'), 'magic');
    await tester.pump();
    expect(find.text('Recurring meal plans'), findsNothing);
    expect(find.text('Login with magic link'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Filter this board  /'), '');
    await tester.pump();

    // A click peeks; the peek's box comments when nothing is running.
    await tester.tap(find.text('Recurring meal plans'));
    await tester.pumpAndSettle();
    expect(find.text('Done when · 1 of 2'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Comment on the task… ↵ sends'), 'Use ISO weeks');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(posted.single, {'taskId': 't2', 'body': 'Use ISO weeks'});
    await tester.binding.setSurfaceSize(null);
  });
}
