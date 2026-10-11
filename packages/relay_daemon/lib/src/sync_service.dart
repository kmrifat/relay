import 'dart:async';
import 'dart:io';

import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_sync/relay_sync.dart';

import 'context.dart';

/// relayd's side of team sync: when to sync, the team lifecycle (create,
/// invite, join, revoke, leave), and this device's public record.
class SyncService {
  SyncService(this.ctx) : secretsPath = '${ctx.paths.home}/secrets.json' {
    secrets = Secrets.load(secretsPath);
    secrets.save(secretsPath); // creates the device seed on first run
  }

  final DaemonContext ctx;
  final String secretsPath;
  late Secrets secrets;
  SyncEngine? _engine;
  Timer? _timer;
  Timer? _debounce;
  bool _running = false;
  String? lastError;
  SyncResult? lastResult;
  DateTime? lastSync;
  StreamSubscription<EntityChange>? _changes;

  Store get store => ctx.store;
  bool get inTeam => secrets.inTeam;

  void start() {
    if (secrets.inTeam) _engine = _makeEngine();
    publishDevice();
    _changes = store.changes.listen((c) {
      if (c.remote || !inTeam || !Kind.synced.contains(c.entity.kind)) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () => syncNow());
    });
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final every = ctx.intSetting('syncIntervalSeconds', 30);
    _timer = Timer.periodic(Duration(seconds: every.clamp(5, 3600)), (_) => syncNow());
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _debounce?.cancel();
    await _changes?.cancel();
  }

  SyncEngine _makeEngine() => SyncEngine(store: store, backend: secrets.storage!.backend(), secrets: secrets, saveSecrets: () => secrets.save(secretsPath));

  SyncEngine get _e => _engine ?? (throw RpcError(RpcError.invalidParams, 'This Mac is not in a team yet.'));

  /// This device's record for teammates: who, which agents, shared or not.
  void publishDevice() {
    final agents = store.list<AgentProfile>(Kind.agent).where((a) => a.binaryPath != null && a.enabled).toList();
    final current = store.get<DeviceInfo>(Kind.device, ctx.deviceId);
    final fields = <String, Object?>{
      'name': ctx.setting('deviceName', _defaultDeviceName()),
      'person': ctx.setting('userName', 'You'),
      'shareAgents': ctx.boolSetting('shareAgents', false),
      'agents': [
        for (final a in agents)
          {'id': a.id, 'name': a.name, 'color': a.color, 'letter': a.letter, 'slots': a.slots, 'version': a.version},
      ],
    };
    final changed = current == null || fields.entries.any((e) => '${current.data[e.key]}' != '${e.value}');
    final stale = current?.lastSeen == null || DateTime.now().difference(current!.lastSeen!).inMinutes >= 30;
    if (changed || (inTeam && stale)) {
      store.patch<DeviceInfo>(Kind.device, ctx.deviceId, {...fields, 'lastSeen': DateTime.now().toUtc().toIso8601String()});
    }
  }

  String _defaultDeviceName() {
    final host = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '').replaceAll('-', ' ');
    return host.isEmpty ? 'This Mac' : host;
  }

  /// One pull + push. Safe to call any time; overlapping calls are skipped.
  Future<Map<String, Object?>> syncNow() async {
    if (!inTeam || _running) return status();
    _running = true;
    try {
      publishDevice();
      lastResult = await _e.sync();
      lastSync = DateTime.now();
      lastError = lastResult!.problems.isEmpty ? null : lastResult!.problems.first;
    } on SyncError catch (e) {
      lastError = e.message;
      if (e.message.contains('removed from the team')) {
        ctx.notice('This Mac was removed from the team. Sync stopped; your local copy stays.', level: 'warning');
        _timer?.cancel();
      }
    } on StorageException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = '$e';
    } finally {
      _running = false;
    }
    ctx.broadcast(E.syncState, status());
    return status();
  }

  Map<String, Object?> status() => {
    'inTeam': inTeam,
    'teamId': secrets.teamId,
    'teamName': secrets.teamName,
    'storage': secrets.storage?.describe(),
    'epoch': secrets.currentEpoch,
    'deviceId': ctx.deviceId,
    'pendingOps': store.pendingCount,
    'lastSync': lastSync?.toUtc().toIso8601String(),
    'lastPush': store.meta('sync.lastPush'),
    'lastPull': store.meta('sync.lastPull'),
    'lastResult': lastResult?.toJson(),
    'error': lastError,
    'intervalSeconds': ctx.intSetting('syncIntervalSeconds', 30),
    'shareAgents': ctx.boolSetting('shareAgents', false),
  };

  // ------------------------------------------------------------ lifecycle

  static StorageSettings parseStorage(Map<String, Object?> p) {
    final kind = p['kind'] as String? ?? 's3';
    if (kind == 'folder') {
      final f = p['folder'] as String? ?? '';
      if (f.isEmpty) throw RpcError(RpcError.invalidParams, 'Choose a folder.');
      return StorageSettings.folder(f);
    }
    String req(String k) {
      final v = (p[k] as String? ?? '').trim();
      if (v.isEmpty) throw RpcError(RpcError.invalidParams, 'Fill in $k.');
      return v;
    }

    if (kind == 'r2') {
      return StorageSettings.r2(accountId: req('accountId'), bucket: req('bucket'), accessKeyId: req('accessKeyId'), secretAccessKey: req('secretAccessKey'));
    }
    return StorageSettings.s3(endpoint: req('endpoint'), bucket: req('bucket'), region: (p['region'] as String?) ?? 'auto', accessKeyId: req('accessKeyId'), secretAccessKey: req('secretAccessKey'));
  }

  /// Checks storage before using it. Returns problems; empty means ready.
  Future<List<String>> test(StorageSettings storage) async {
    if (storage.kind == 'folder') {
      final d = Directory(storage.folder!);
      if (!d.existsSync()) return ['The folder does not exist.'];
      try {
        final probe = File('${d.path}/.relay-probe');
        probe.writeAsStringSync('ok');
        probe.deleteSync();
        return [];
      } catch (e) {
        return ['Relay cannot write to that folder: $e'];
      }
    }
    return (storage.backend() as S3Backend).testConnection('relay/probe-${ctx.deviceId}');
  }

  Future<Map<String, Object?>> createTeam(String name, StorageSettings storage) async {
    if (inTeam) throw RpcError(RpcError.invalidParams, 'This Mac is already in a team.');
    final problems = await test(storage);
    if (problems.isNotEmpty) throw RpcError(RpcError.invalidParams, problems.first);
    secrets.storage = storage;
    _claimLocalTasks();
    try {
      _engine = await SyncEngine.createTeam(store: store, secrets: secrets, teamName: name, saveSecrets: () => secrets.save(secretsPath));
    } catch (e) {
      secrets.leave();
      secrets.save(secretsPath);
      throw RpcError(RpcError.internal, 'Could not create the team: $e');
    }
    await syncNow();
    return status();
  }

  Future<String> invite() => _e.createInvite();

  /// Tasks from before the team existed have no `runOn`; pin them to this
  /// device so a teammate's scheduler never picks them up.
  void _claimLocalTasks() {
    for (final t in store.list<Task>(Kind.task)) {
      if (t.str('runOn') == null) store.patch<Task>(Kind.task, t.id, {'runOn': ctx.deviceId});
    }
  }

  Future<Map<String, Object?>> join(String code) async {
    if (inTeam) throw RpcError(RpcError.invalidParams, 'This Mac is already in a team. Leave it first.');
    _claimLocalTasks();
    try {
      _engine = await SyncEngine.join(store: store, secrets: secrets, code: code, saveSecrets: () => secrets.save(secretsPath));
    } on SyncError catch (e) {
      throw RpcError(RpcError.invalidParams, e.message);
    } on StorageException catch (e) {
      throw RpcError(RpcError.invalidParams, 'Could not reach the team\'s storage: ${e.message}');
    }
    // Everyone's checkout paths differ; ask the user to point repos at theirs.
    await syncNow();
    _schedule();
    return status();
  }

  Future<Map<String, Object?>> revoke(String deviceId) async {
    try {
      await _e.revoke(deviceId);
    } on SyncError catch (e) {
      throw RpcError(RpcError.invalidParams, e.message);
    }
    await syncNow();
    return status();
  }

  Future<Map<String, Object?>> leave() async {
    if (_engine != null) {
      try {
        await _engine!.backend.delete('${_engine!.root}/members/${ctx.deviceId}.json');
      } catch (_) {}
    }
    secrets.leave();
    secrets.save(secretsPath);
    _engine = null;
    return status();
  }

  void settingsChanged() {
    publishDevice();
    _schedule();
  }
}
