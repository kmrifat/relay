import 'package:relay_core/relay_core.dart';
import 'package:test/test.dart';

void main() {
  group('ids', () {
    test('sort by creation time', () {
      final a = newId(DateTime(2026, 1, 1));
      final b = newId(DateTime(2026, 1, 2));
      expect(a.compareTo(b), lessThan(0));
      expect(a, hasLength(22));
    });
  });

  group('Hlc', () {
    test('increases within the same millisecond', () {
      final c = HlcClock('a', wallClock: () => 1000);
      final x = c.now();
      final y = c.now();
      expect(y.compareTo(x), greaterThan(0));
      expect(y.counter, 1);
    });

    test('round-trips through its string form', () {
      final h = Hlc(1234, 7, 'dev-1');
      expect(Hlc.parse(h.toString()), h);
    });

    test('moves past a remote timestamp from the future', () {
      final c = HlcClock('a', wallClock: () => 1000);
      c.receive(Hlc(5000, 3, 'b'));
      expect(c.now().compareTo(Hlc(5000, 3, 'b')), greaterThan(0));
    });
  });

  group('Store', () {
    late Store store;
    late Project project;

    setUp(() {
      store = Store.memory(deviceId: 'mac');
      project = store.create<Project>(Kind.project, {'key': 'TM', 'name': 'TaskManager'});
    });
    tearDown(() => store.close());

    test('creates tasks with increasing numbers', () {
      final a = store.createTask(project.id, {'title': 'One'});
      final b = store.createTask(project.id, {'title': 'Two'});
      expect(a.number, 1);
      expect(b.number, 2);
      expect(b.displayKey(project.key), 'TM-2');
      expect(store.list<Task>(Kind.task, projectId: project.id), hasLength(2));
    });

    test('every change is an op', () {
      final before = store.opCount;
      final t = store.createTask(project.id, {'title': 'One'});
      store.patch<Task>(Kind.task, t.id, {'status': TaskStatus.running});
      expect(store.opCount, before + 3); // project counter, task create, task patch
      expect(store.get<Task>(Kind.task, t.id)!.status, TaskStatus.running);
    });

    test('null removes a field, delete hides the record', () {
      final t = store.createTask(project.id, {'title': 'One', 'assignee': 'claude-code'});
      store.patch<Task>(Kind.task, t.id, {'assignee': null});
      expect(store.get<Task>(Kind.task, t.id)!.assignee, isNull);
      store.delete(Kind.task, t.id);
      expect(store.get<Task>(Kind.task, t.id), isNull);
      expect(store.list<Task>(Kind.task), isEmpty);
    });

    test('remote ops merge per field, newest wins', () {
      final t = store.createTask(project.id, {'title': 'Local', 'brief': 'b'});
      final old = Op(hlc: Hlc(1, 0, 'phone'), kind: Kind.task, id: t.id, patch: {'title': 'Old remote'});
      store.applyRemote(old);
      expect(store.get<Task>(Kind.task, t.id)!.title, 'Local');

      final newer = Op(
        hlc: Hlc(DateTime.now().millisecondsSinceEpoch + 60000, 0, 'phone'),
        kind: Kind.task,
        id: t.id,
        patch: {'title': 'New remote'},
      );
      store.applyRemote(newer);
      final merged = store.get<Task>(Kind.task, t.id)!;
      expect(merged.title, 'New remote');
      expect(merged.brief, 'b'); // untouched field kept
    });

    test('two stores converge whatever order ops arrive in', () {
      final a = Store.memory(deviceId: 'a');
      final b = Store.memory(deviceId: 'b');
      a.patch<Task>(Kind.task, 't1', {'title': 'A1', 'status': 'queued'});
      b.patch<Task>(Kind.task, 't1', {'title': 'B1'});
      a.patch<Task>(Kind.task, 't1', {'brief': 'from a'});
      final opsA = a.pendingOps();
      final opsB = b.pendingOps();
      for (final op in opsB) {
        a.applyRemote(op);
      }
      for (final op in opsA.reversed) {
        b.applyRemote(op);
      }
      final ta = a.get<Task>(Kind.task, 't1')!;
      final tb = b.get<Task>(Kind.task, 't1')!;
      expect(ta.title, tb.title);
      expect(ta.status, tb.status);
      expect(ta.brief, tb.brief);
      a.close();
      b.close();
    });

    test('run events are append-only and ordered', () {
      store.appendEvent('r1', RunEventType.message, {'text': 'hi'});
      store.appendEvent('r1', RunEventType.toolUse, {'tool': 'Read'});
      final evs = store.events('r1');
      expect(evs.map((e) => e.seq), [1, 2]);
      expect(store.events('r1', after: 1).single.type, RunEventType.toolUse);
    });

    test('change stream reports writes', () async {
      final seen = <String>[];
      store.changes.listen((c) => seen.add(c.entity.kind));
      store.createTask(project.id, {'title': 'x'});
      expect(seen, containsAll([Kind.project, Kind.task]));
    });
  });
}
