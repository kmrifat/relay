import 'dart:async';
import 'dart:convert';

/// An error returned by the other side of a JSON-RPC call.
class RpcError implements Exception {
  RpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internal = -32603;

  /// Relay-specific: the caller is not allowed (bad token, wrong version).
  static const unauthorized = -32001;

  /// Relay-specific: a referenced record does not exist.
  static const notFound = -32004;

  Map<String, Object?> toJson() => {'code': code, 'message': message, 'data': ?data};

  @override
  String toString() => 'RpcError($code): $message';
}

typedef RpcHandler = FutureOr<Object?> Function(Map<String, Object?> params);
typedef NotificationHandler = void Function(Map<String, Object?> params);

/// One end of a JSON-RPC 2.0 connection. Messages are UTF-8 JSON, one per
/// line. Both ends can call methods and send notifications, so the same
/// class serves the UI, relayd, `relay mcp` and tests.
class RpcPeer {
  RpcPeer(Stream<List<int>> input, this._output, {this.name = 'peer'}) {
    _sub = utf8.decoder
        .bind(input)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone, onError: (_) => _onDone());
    // A failed write (the other side went away: broken pipe) is reported on
    // the sink's done future; left unheard it would be an uncaught error.
    _output.done.then((_) => _onDone(), onError: (Object _) => _onDone());
  }

  final String name;
  final StreamSink<List<int>> _output;
  late final StreamSubscription<String> _sub;
  final _methods = <String, RpcHandler>{};
  final _notifications = <String, NotificationHandler>{};
  final _pending = <int, Completer<Object?>>{};
  final _done = Completer<void>();
  int _nextId = 1;
  bool _closed = false;

  /// Completes when the connection ends.
  Future<void> get done => _done.future;
  bool get isClosed => _closed;

  /// Called for notifications with no registered handler.
  NotificationHandler? fallbackNotification;

  void registerMethod(String method, RpcHandler handler) => _methods[method] = handler;
  void onNotification(String method, NotificationHandler handler) => _notifications[method] = handler;

  Future<Object?> request(String method, [Map<String, Object?> params = const {}]) {
    if (_closed) return Future.error(StateError('$name: connection closed'));
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void notify(String method, [Map<String, Object?> params = const {}]) {
    if (_closed) return;
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _send(Map<String, Object?> msg) {
    try {
      _output.add(utf8.encode('${jsonEncode(msg)}\n'));
    } catch (_) {
      _onDone();
    }
  }

  Future<void> _onLine(String line) async {
    if (line.trim().isEmpty) return;
    Map<String, Object?> msg;
    try {
      msg = (jsonDecode(line) as Map).cast<String, Object?>();
    } catch (_) {
      _send({'jsonrpc': '2.0', 'id': null, 'error': RpcError(RpcError.parseError, 'Parse error').toJson()});
      return;
    }
    final id = msg['id'];
    final method = msg['method'] as String?;
    if (method == null) {
      // A response to one of our requests.
      final c = _pending.remove(id);
      if (c == null) return;
      final err = msg['error'];
      if (err is Map) {
        c.completeError(RpcError((err['code'] as num?)?.toInt() ?? RpcError.internal, err['message'] as String? ?? '', err['data']));
      } else {
        c.complete(msg['result']);
      }
      return;
    }
    final params = (msg['params'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    if (id == null) {
      try {
        final h = _notifications[method];
        if (h != null) {
          h(params);
        } else {
          fallbackNotification?.call({'method': method, ...params});
        }
      } catch (_) {}
      return;
    }
    final handler = _methods[method];
    if (handler == null) {
      _send({'jsonrpc': '2.0', 'id': id, 'error': RpcError(RpcError.methodNotFound, 'No method $method').toJson()});
      return;
    }
    try {
      final result = await handler(params);
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
    } on RpcError catch (e) {
      _send({'jsonrpc': '2.0', 'id': id, 'error': e.toJson()});
    } catch (e) {
      _send({'jsonrpc': '2.0', 'id': id, 'error': RpcError(RpcError.internal, e.toString()).toJson()});
    }
  }

  void _onDone() {
    if (_closed) return;
    _closed = true;
    for (final c in _pending.values) {
      c.completeError(StateError('$name: connection closed'));
    }
    _pending.clear();
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    _onDone();
    await _sub.cancel();
    try {
      await _output.close();
    } catch (_) {}
  }
}
