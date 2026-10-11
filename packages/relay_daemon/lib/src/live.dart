import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_sync/relay_sync.dart';

import 'context.dart';

/// relayd's live connection to the team Worker's room (docs/format/worker.md
/// §4): pokes so teammates pull at once, run events streamed as they happen,
/// and who is online. Every message is sealed with the team key; the room
/// only relays bytes. Without a Worker, sync falls back to polling.
class LiveLink {
  LiveLink(this.ctx, {required this.secrets, required this.onPoke, required this.onKeyRotated, required this.onChange});

  final DaemonContext ctx;
  final Secrets secrets;

  /// A teammate pushed: pull now.
  final void Function() onPoke;

  /// The room closed us with 4001 (key rotated): refresh keys, reconnect.
  final Future<void> Function() onKeyRotated;

  /// Connected/online changed.
  final void Function() onChange;

  /// Runs a command from this device's paired phone (set by relayd).
  Future<Object?> Function(String method, Map<String, Object?> params)? onCommand;

  /// What a paired phone may ask its Mac to do: answer the agents and
  /// steer runs. Everything else syncs as data.
  static const remoteMethods = {
    'permissions.answer',
    'comments.post',
    'runs.start',
    'runs.steer',
    'runs.stop',
    'runs.pause',
    'runs.resume',
    'agents.update',
  };

  final _pending = <String, Completer<Object?>>{};
  int _cmdSeq = 0;

  WebSocket? _ws;
  bool _running = false;
  int _attempt = 0;
  Timer? _retry;
  Timer? _flush;
  StreamSubscription<RunEvent>? _local;
  final _outbox = <String, List<RunEvent>>{};

  /// Devices in the room right now (this one included).
  Set<String> online = {};
  bool get connected => _ws != null;
  int sent = 0, received = 0;

  bool get _wanted => _running && secrets.inTeam && secrets.storage?.kind == 'worker';

  void start() {
    _running = true;
    _local ??= ctx.store.runEvents.listen(_onLocalEvent);
    if (_ws == null) unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _flush?.cancel();
    await _local?.cancel();
    _local = null;
    final ws = _ws;
    _ws = null;
    online = {};
    await ws?.close(1000);
    onChange();
  }

  Future<void> _connect() async {
    if (!_wanted) return;
    try {
      final backend = secrets.storage!.backend(token: secrets.workerToken) as WorkerBackend;
      final token = await secrets.workerToken();
      final ws = await WebSocket.connect(backend.socketUrl(ctx.deviceId).toString(), headers: {'authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 15));
      if (!_wanted) {
        await ws.close(1000);
        return;
      }
      ws.pingInterval = const Duration(seconds: 30);
      _ws = ws;
      _attempt = 0;
      onChange();
      ws.listen(_onMessage, onDone: () => _closed(ws), onError: (_) => _closed(ws), cancelOnError: true);
      // Catch up on anything pushed while we were away.
      onPoke();
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _closed(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    online = {};
    onChange();
    if (!_running) return;
    if (ws.closeCode == 4001) {
      unawaited(onKeyRotated().whenComplete(_connect));
    } else {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_wanted) return;
    _retry?.cancel();
    final seconds = min(60, 1 << min(_attempt++, 6));
    _retry = Timer(Duration(seconds: seconds), _connect);
  }

  // ------------------------------------------------------------ sending

  /// Tells teammates there is something to pull.
  void poke() => _send({'t': 'poke'});

  /// Asks this phone's Mac to run [method] (one of [remoteMethods]) and
  /// waits for its answer. Signed with the pairing key, so other team
  /// members can't pass for this phone.
  Future<Object?> command(String method, Map<String, Object?> params, {Duration timeout = const Duration(seconds: 15)}) async {
    final pairing = secrets.pairing ?? (throw StateError('This device is not paired with a Mac.'));
    if (_ws == null) throw const CommandFailed('Not connected to the team. Check the connection.');
    if (!online.contains(pairing.mac)) throw CommandFailed('${pairing.macName} is offline or asleep.');
    final id = '${ctx.deviceId}-${++_cmdSeq}-${DateTime.now().microsecondsSinceEpoch}';
    final body = jsonEncode({'method': method, 'params': params});
    final done = _pending[id] = Completer<Object?>();
    await _send({'t': 'cmd', 'to': pairing.mac, 'id': id, 'pair': pairing.id, 'body': body, 'mac': await RelayCrypto.pairMac(pairing.key, '$id|$body')});
    try {
      return await done.future.timeout(timeout, onTimeout: () => throw CommandFailed('${pairing.macName} did not answer.'));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _onCommand(Map<String, Object?> msg) async {
    final id = msg['id'] as String? ?? '';
    final from = msg['from'] as String? ?? '';
    Future<void> ack(Map<String, Object?> r) => _send({'t': 'ack', 'to': from, 'id': id, ...r});
    final key = secrets.companions[msg['pair'] as String? ?? ''];
    final body = msg['body'] as String? ?? '';
    if (key == null || onCommand == null || await RelayCrypto.pairMac(key, '$id|$body') != msg['mac']) {
      return ack({'ok': false, 'error': 'This Mac does not take commands from that device.'});
    }
    final j = (jsonDecode(body) as Map).cast<String, Object?>();
    final method = j['method'] as String? ?? '';
    if (!remoteMethods.contains(method)) return ack({'ok': false, 'error': '$method is not allowed from a phone.'});
    try {
      final result = await onCommand!(method, (j['params'] as Map? ?? const {}).cast<String, Object?>());
      await ack({'ok': true, 'result': result});
    } catch (e) {
      await ack({'ok': false, 'error': e is RpcError ? e.message : '$e'});
    }
  }

  /// Asks the device running [runId] for its events after [after].
  void want(String runId, int after) => _send({'t': 'want', 'runId': runId, 'after': after});

  void _onLocalEvent(RunEvent e) {
    if (_ws == null || online.length < 2) return;
    final run = ctx.store.get<Run>(Kind.run, e.runId);
    if (run == null || (run.deviceId ?? ctx.deviceId) != ctx.deviceId) return; // teammates' runs come from them
    (_outbox[e.runId] ??= []).add(e);
    _flush ??= Timer(const Duration(milliseconds: 100), () {
      _flush = null;
      for (final MapEntry(:key, :value) in _outbox.entries) {
        _send({'t': 'run', 'runId': key, 'events': [for (final e in value) e.toJson()]});
      }
      _outbox.clear();
    });
  }

  Future<void> _send(Map<String, Object?> msg) async {
    final ws = _ws;
    if (ws == null || !secrets.inTeam) return;
    final epoch = secrets.currentEpoch;
    final sealed = await RelayCrypto.seal(
      key: secrets.keyring[epoch]!,
      teamId: secrets.teamId!,
      type: EnvelopeType.live,
      epoch: epoch,
      objectKey: 'live',
      plain: utf8.encode(jsonEncode({...msg, 'from': ctx.deviceId})),
    );
    ws.add(jsonEncode({'t': 'sealed', 'e': b64(sealed)}));
    sent++;
  }

  // ------------------------------------------------------------ receiving

  Future<void> _onMessage(Object? raw) async {
    if (raw is! String) return;
    final Map<String, Object?> outer;
    try {
      outer = (jsonDecode(raw) as Map).cast();
    } on FormatException {
      return;
    }
    if (outer['t'] == 'presence') {
      online = {...((outer['devices'] as List?) ?? const []).cast<String>()};
      onChange();
      return;
    }
    if (outer['t'] != 'sealed') return;
    final Map<String, Object?> msg;
    try {
      final bytes = unb64(outer['e'] as String);
      final key = secrets.keyring[RelayCrypto.epochOf(bytes)];
      if (key == null) return;
      final plain = await RelayCrypto.open(key: key, teamId: secrets.teamId!, type: EnvelopeType.live, objectKey: 'live', bytes: bytes);
      msg = (jsonDecode(utf8.decode(plain)) as Map).cast();
    } on Object {
      return; // not ours, or tampered: drop it
    }
    received++;
    if (msg['to'] != null && msg['to'] != ctx.deviceId) return; // addressed to someone else
    switch (msg['t']) {
      case 'cmd':
        await _onCommand(msg);
      case 'ack':
        final done = _pending[msg['id'] as String? ?? ''];
        if (done == null || done.isCompleted) return;
        msg['ok'] == true ? done.complete(msg['result']) : done.completeError(CommandFailed('${msg['error']}'));
      case 'poke':
        onPoke();
      case 'run':
        final run = ctx.store.get<Run>(Kind.run, msg['runId'] as String? ?? '');
        if (run != null && run.deviceId == ctx.deviceId) return; // never let others write our runs
        ctx.store.importEvents([for (final e in (msg['events'] as List? ?? const [])) RunEvent.fromJson((e as Map).cast())]);
      case 'want':
        final runId = msg['runId'] as String? ?? '';
        final run = ctx.store.get<Run>(Kind.run, runId);
        if (run == null || (run.deviceId ?? ctx.deviceId) != ctx.deviceId) return;
        final events = ctx.store.events(runId, after: (msg['after'] as num?)?.toInt() ?? 0, limit: 2000);
        if (events.isNotEmpty) await _send({'t': 'run', 'runId': runId, 'events': [for (final e in events) e.toJson()]});
    }
  }
}

/// A phone's command didn't reach its Mac or the Mac refused it.
class CommandFailed implements Exception {
  const CommandFailed(this.message);
  final String message;
  @override
  String toString() => message;
}
