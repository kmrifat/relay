import 'dart:async';
import 'dart:io';

import 'protocol.dart';
import 'rpc.dart';

/// A connection from the UI (or CLI, or tests) to relayd.
class RelayClient {
  RelayClient._(this.peer, this.hello);

  final RpcPeer peer;

  /// relayd's answer to `hello`: `{version, protocol, deviceId, pid}`.
  final Map<String, Object?> hello;

  final _events = StreamController<RelayEvent>.broadcast();

  /// Every notification relayd sends, as `(method, params)`.
  Stream<RelayEvent> get events => _events.stream;

  Future<void> get done => peer.done;

  /// Connects using [RelayPaths] and the token in `daemon.json`.
  static Future<RelayClient> connect(
    RelayPaths paths, {
    String client = 'ui',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final info = DaemonInfo.read(paths);
    if (info == null) throw const SocketException('relayd is not running (no daemon.json)');
    final Socket socket;
    if (info.socket != null) {
      socket = await Socket.connect(InternetAddress(info.socket!, type: InternetAddressType.unix), 0, timeout: timeout);
    } else {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, info.port!, timeout: timeout);
    }
    return attach(socket, socket, token: info.token, client: client);
  }

  /// Wraps an already-open stream pair (sockets, or in-memory pipes in tests).
  static Future<RelayClient> attach(
    Stream<List<int>> input,
    StreamSink<List<int>> output, {
    required String token,
    String client = 'ui',
  }) async {
    final peer = RpcPeer(input, output, name: client);
    final hello = (await peer.request(M.hello, {
      'token': token,
      'protocol': protocolVersion,
      'client': client,
    }) as Map).cast<String, Object?>();
    final c = RelayClient._(peer, hello);
    peer.fallbackNotification = (p) {
      final method = p['method'] as String;
      c._events.add(RelayEvent(method, Map.of(p)..remove('method')));
    };
    unawaited(peer.done.then((_) => c._events.close()));
    return c;
  }

  Future<T> call<T>(String method, [Map<String, Object?> params = const {}]) async {
    final r = await peer.request(method, params);
    return r as T;
  }

  /// Calls a method that returns a list of JSON objects.
  Future<List<Map<String, Object?>>> list(String method, [Map<String, Object?> params = const {}]) async {
    final r = await peer.request(method, params) as List;
    return r.map((e) => (e as Map).cast<String, Object?>()).toList();
  }

  Future<Map<String, Object?>> map(String method, [Map<String, Object?> params = const {}]) async {
    final r = await peer.request(method, params);
    return (r as Map).cast<String, Object?>();
  }

  Future<void> close() => peer.close();
}

class RelayEvent {
  RelayEvent(this.method, this.params);
  final String method;
  final Map<String, Object?> params;
}
