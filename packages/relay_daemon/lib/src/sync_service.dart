import 'dart:async';
import 'dart:io';

import 'package:relay_core/relay_core.dart';
import 'package:relay_protocol/relay_protocol.dart';
import 'package:relay_sync/relay_sync.dart';

import 'context.dart';
import 'live.dart';

/// relayd's side of team sync: when to sync, the team lifecycle (create,
/// invite, join, revoke, leave), and this device's public record.
class SyncService {
  SyncService(this.ctx) : secretsPath = '${ctx.paths.home}/secrets.json' {
    secrets = Secrets.load(secretsPath);
    secrets.save(secretsPath); // creates the device seed on first run
    live = LiveLink(
      ctx,
      secrets: secrets,
      onPoke: () {
        _poke?.cancel();
        _poke = Timer(const Duration(milliseconds: 250), syncNow);
      },
      onKeyRotated: syncNow,
      onChange: () => ctx.broadcast(E.syncState, status()),
    );
  }

  /// The team Worker's room; idle unless storage is a Worker.
  late final LiveLink live;

  /// Per-agent live numbers for this device's record (set by relayd):
  /// `{agentId: {active, costToday, limitedUntil}}`.
  Map<String, Map<String, Object?>> Function()? agentStats;
  Timer? _poke;

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

  /// The sync engine while in a team (files go through its storage).
  SyncEngine? get engine => _engine;
  bool get inTeam => secrets.inTeam;

  void start() {
    if (secrets.inTeam) _engine = _makeEngine();
    publishDevice();
    live.start();
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
    _poke?.cancel();
    await _changes?.cancel();
    await live.stop();
  }

  SyncEngine _makeEngine() =>
      SyncEngine(store: store, backend: secrets.storage!.backend(token: secrets.workerToken), secrets: secrets, saveSecrets: () => secrets.save(secretsPath));

  SyncEngine get _e => _engine ?? (throw RpcError(RpcError.invalidParams, 'This Mac is not in a team yet.'));

  /// This device's record for teammates: who, which agents, shared or not.
  void publishDevice() {
    final agents = store.list<AgentProfile>(Kind.agent).where((a) => a.binaryPath != null && a.enabled).toList();
    final current = store.get<DeviceInfo>(Kind.device, ctx.deviceId);
    final stats = agentStats?.call() ?? const {};
    final fields = <String, Object?>{
      'name': ctx.setting('deviceName', _defaultDeviceName()),
      'person': ctx.setting('userName', 'You'),
      'shareAgents': ctx.boolSetting('shareAgents', false),
      'kind': ctx.setting('deviceKind', 'mac'),
      'companionOf': ctx.store.meta('settings.companionOf'),
      'agents': [
        for (final a in agents)
          {
            'id': a.id,
            'name': a.name,
            'color': a.color,
            'letter': a.letter,
            'slots': a.slots,
            'version': a.version,
            'dailyCapUsd': a.dailyCapUsd,
            // Role agents show as who they are on the team; their
            // responsibilities (your prompts) stay on this Mac.
            if (a.isRole) ...{
              'role': a.role,
              'team': ?(a.teamId == null ? null : ctx.store.get<Team>(Kind.team, a.teamId!)?.name),
              'model': ?a.model,
              'effort': ?a.effort,
            },
            ...?stats[a.id],
          },
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
      if (lastResult!.pushedOps > 0) live.poke();
      lastError = lastResult!.problems.isEmpty ? null : lastResult!.problems.first;
    } on SyncError catch (e) {
      lastError = e.message;
      if (e.message.contains('removed from the team')) {
        ctx.notice('This Mac was removed from the team. Sync stopped; your local copy stays.', level: 'warning');
        _timer?.cancel();
        unawaited(live.stop());
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
    'live': live.connected,
    'online': live.online.toList(),
    'liveIn': live.received,
    'pairedMac': secrets.pairing?.mac,
    'pairedMacName': secrets.pairing?.macName,
    'phones': secrets.companions.length,
    'liveOut': live.sent,
  };

  // ------------------------------------------------------------ lifecycle

  static StorageSettings parseStorage(Map<String, Object?> p) {
    final kind = p['kind'] as String? ?? 's3';
    if (kind == 'worker') {
      final url = (p['url'] as String? ?? '').trim();
      if (Uri.tryParse(url)?.hasScheme != true) throw RpcError(RpcError.invalidParams, 'Enter the Worker\'s URL.');
      return StorageSettings.worker(url, setupToken: p['setupToken'] as String?);
    }
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

  /// `{kind: cloudflare, accountId, apiToken}`: deploy a Worker there.
  static WorkerDeployer? deployerFor(Map<String, Object?> p) {
    if (p['kind'] != 'cloudflare') return null;
    final account = (p['accountId'] as String? ?? '').trim();
    final token = (p['apiToken'] as String? ?? '').trim();
    if (account.isEmpty || token.isEmpty) throw RpcError(RpcError.invalidParams, 'Fill in the account ID and API token.');
    return WorkerDeployer(accountId: account, apiToken: token);
  }

  /// Checks storage given as `sync.test`/`sync.createTeam` params.
  Future<List<String>> testParams(Map<String, Object?> p) async {
    final deployer = deployerFor(p);
    if (deployer != null) return deployer.check();
    return test(parseStorage(p));
  }

  /// Checks storage before using it. Returns problems; empty means ready.
  Future<List<String>> test(StorageSettings storage) async {
    if (storage.kind == 'worker') {
      try {
        final h = await (storage.backend() as WorkerBackend).health();
        if (h['configured'] == true && storage.setupToken != null) return ['This Worker already serves a team. Join it with an invite instead.'];
        return [];
      } on StorageException catch (e) {
        return [e.message];
      }
    }
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

  /// Creates the team on `sync.createTeam` params; for `cloudflare`, deploys
  /// the team Worker first (progress goes out as `sync.state` `step`s).
  Future<Map<String, Object?>> createTeamFrom(String name, Map<String, Object?> p) async {
    final deployer = deployerFor(p);
    if (deployer == null) return createTeam(name, parseStorage(p));
    if (inTeam) throw RpcError(RpcError.invalidParams, 'This Mac is already in a team.');
    final StorageSettings storage;
    try {
      storage = await deployer.deploy(
        scriptName: WorkerDeployer.nameFor(name),
        bucket: WorkerDeployer.nameFor(name),
        onStep: (s) => ctx.broadcast(E.syncState, {...status(), 'step': s}),
      );
    } on SyncError catch (e) {
      throw RpcError(RpcError.invalidParams, e.message);
    }
    return createTeam(name, storage);
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
    live.start();
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
    live.start();
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

  // ------------------------------------------------------------ push

  WorkerBackend get _worker {
    final b = _engine?.backend;
    if (b is! WorkerBackend) throw RpcError(RpcError.invalidParams, 'Phone notifications go through the team Worker. Set up team sync with a Cloudflare Worker first.');
    return b;
  }

  Future<Map<String, Object?>> pushConfig(Map<String, Object?> p) async {
    String req(String k) => (p[k] as String? ?? '').trim().isEmpty ? throw RpcError(RpcError.invalidParams, 'Fill in $k.') : (p[k] as String).trim();
    try {
      await _worker.pushConfig(keyId: req('keyId'), teamId: req('teamId'), bundleId: p['bundleId'] as String? ?? 'com.binarycastle.relay', p8: req('p8'));
      return await _worker.pushStatus();
    } on StorageException catch (e) {
      throw RpcError(RpcError.invalidParams, e.message);
    }
  }

  Future<Map<String, Object?>> pushStatus() async {
    try {
      return await _worker.pushStatus();
    } on StorageException catch (e) {
      return {'configured': false, 'error': e.message};
    }
  }

  /// On a phone: its APNs token, so its Mac can wake it.
  Future<void> pushRegister(String token, {bool sandbox = false}) async {
    try {
      await _worker.pushRegister(device: ctx.deviceId, token: token, sandbox: sandbox);
    } on StorageException catch (e) {
      throw RpcError(RpcError.internal, e.message);
    }
  }

  DateTime? _pushOffUntil;

  /// Wakes this Mac's paired phones that aren't connected right now (a
  /// phone in the room already shows it). With `pushPreview` off, the text
  /// that goes through Apple says only what kind of thing happened.
  Future<void> pushToPhones(Map<String, Object?> note) async {
    final b = _engine?.backend;
    if (b is! WorkerBackend) return;
    if (_pushOffUntil != null && DateTime.now().isBefore(_pushOffUntil!)) return;
    final phones = store.list<DeviceInfo>(Kind.device).where((d) => !d.revoked && d.data['companionOf'] == ctx.deviceId && !live.online.contains(d.id));
    final preview = ctx.boolSetting('pushPreview', true);
    final generic = switch (note['kind']) {
      'ask' => 'An agent needs you',
      'review' => 'Work is ready for review',
      'failed' => 'A task failed',
      'mention' => 'You were mentioned',
      _ => 'Relay',
    };
    for (final phone in phones) {
      try {
        await b.push(
          to: phone.id,
          title: preview ? '${note['title']}' : generic,
          body: preview ? '${note['body'] ?? ''}' : '',
          data: {'taskId': ?note['taskId'], 'channelId': ?note['channelId']},
        );
      } on StorageException catch (e) {
        // Not set up (501) or no registration yet: don't keep asking.
        if (e.message.contains('not set up')) _pushOffUntil = DateTime.now().add(const Duration(minutes: 10));
      }
    }
  }

  // ------------------------------------------------------------ phones

  /// A code (shown as a QR) that pairs a phone with this Mac: a one-time
  /// team invite plus a key only the two of them hold, which signs the
  /// phone's commands (answer an agent, steer a run).
  Future<Map<String, Object?>> pairPhone() async {
    if (!inTeam) throw RpcError(RpcError.invalidParams, 'Set up team sync first (Settings → Team). The phone reaches this Mac through it.');
    if (secrets.storage!.kind == 'folder') throw RpcError(RpcError.invalidParams, 'A phone can\'t reach a shared folder. Use a Cloudflare Worker for team sync.');
    final invite = await _e.createInvite();
    final pairing = Pairing(
      id: newId(),
      key: RelayCrypto.randomBytes(32),
      mac: ctx.deviceId,
      macName: ctx.setting('deviceName', _defaultDeviceName()),
      person: ctx.setting('userName', 'You'),
    );
    secrets.companions[pairing.id] = pairing.key;
    secrets.save(secretsPath);
    return {'code': pairing.encode(invite), 'macName': pairing.macName};
  }

  /// On a phone: joins the team from a Mac's pairing code and becomes
  /// that Mac's companion.
  Future<Map<String, Object?>> pairWith(String code) async {
    final (Pairing pairing, String invite) parsed;
    try {
      parsed = Pairing.parse(code);
    } on FormatException catch (e) {
      throw RpcError(RpcError.invalidParams, e.message);
    }
    final (pairing, invite) = parsed;
    store.setMeta('settings.userName', pairing.person);
    store.setMeta('settings.companionOf', pairing.mac);
    store.setMeta('settings.deviceKind', 'phone');
    if (store.meta('settings.deviceName') == null) store.setMeta('settings.deviceName', '${pairing.person.split(' ').first}\'s iPhone');
    await join(invite);
    secrets.pairing = pairing;
    secrets.save(secretsPath);
    publishDevice();
    return status();
  }

  Future<Map<String, Object?>> leave() async {
    if (_engine != null) {
      try {
        await _engine!.backend.delete('${_engine!.root}/members/${ctx.deviceId}.json');
      } catch (_) {}
    }
    await live.stop();
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
