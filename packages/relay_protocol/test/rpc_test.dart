import 'dart:async';

import 'package:relay_protocol/relay_protocol.dart';
import 'package:test/test.dart';

/// Two peers joined by in-memory pipes.
(RpcPeer, RpcPeer) pair() {
  final aToB = StreamController<List<int>>();
  final bToA = StreamController<List<int>>();
  final a = RpcPeer(bToA.stream, aToB.sink, name: 'a');
  final b = RpcPeer(aToB.stream, bToA.sink, name: 'b');
  return (a, b);
}

void main() {
  test('request and response', () async {
    final (a, b) = pair();
    b.registerMethod('add', (p) => (p['x'] as int) + (p['y'] as int));
    expect(await a.request('add', {'x': 2, 'y': 3}), 5);
  });

  test('errors come back as RpcError', () async {
    final (a, b) = pair();
    b.registerMethod('boom', (_) => throw RpcError(RpcError.notFound, 'nope'));
    await expectLater(a.request('boom'), throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.notFound)));
    await expectLater(a.request('missing'), throwsA(isA<RpcError>().having((e) => e.code, 'code', RpcError.methodNotFound)));
  });

  test('notifications both ways, with fallback', () async {
    final (a, b) = pair();
    final got = Completer<Map<String, Object?>>();
    a.fallbackNotification = got.complete;
    b.notify('run.events', {'runId': 'r1'});
    final p = await got.future;
    expect(p['method'], 'run.events');
    expect(p['runId'], 'r1');
  });

  test('closing fails pending requests', () async {
    final (a, b) = pair();
    b.registerMethod('slow', (_) => Completer<Object?>().future);
    final failed = expectLater(a.request('slow'), throwsStateError);
    await a.close();
    await failed;
  });

  test('client hello carries token and protocol', () async {
    final aToB = StreamController<List<int>>();
    final bToA = StreamController<List<int>>();
    final server = RpcPeer(aToB.stream, bToA.sink, name: 'server');
    server.registerMethod(M.hello, (p) {
      if (p['token'] != 'secret') throw RpcError(RpcError.unauthorized, 'bad token');
      return {'version': '0.1.0', 'protocol': protocolVersion};
    });
    final c = await RelayClient.attach(bToA.stream, aToB.sink, token: 'secret');
    expect(c.hello['protocol'], protocolVersion);
    final events = <RelayEvent>[];
    c.events.listen(events.add);
    server.notify(E.notice, {'text': 'hi'});
    await Future<void>.delayed(Duration.zero);
    expect(events.single.method, E.notice);
  });
}
