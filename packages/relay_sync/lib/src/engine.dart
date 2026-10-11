import 'dart:convert';
import 'dart:typed_data';

import 'package:relay_core/relay_core.dart';

import 'crypto.dart';
import 'settings.dart';
import 'storage.dart';

class SyncError implements Exception {
  SyncError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What one sync pass did.
class SyncResult {
  SyncResult({this.pushedOps = 0, this.pulledOps = 0, this.objectsRead = 0, this.problems = const []});
  final int pushedOps;
  final int pulledOps;
  final int objectsRead;
  final List<String> problems;
  Map<String, Object?> toJson() => {'pushed': pushedOps, 'pulled': pulledOps, 'objects': objectsRead, 'problems': problems};
}

/// A parsed invite code (`relay-invite:` + base64url JSON).
class Invite {
  Invite({required this.teamId, required this.inviteId, required this.secret, required this.storage});

  factory Invite.parse(String code) {
    final c = code.trim();
    if (!c.startsWith(prefix)) throw SyncError('That is not a Relay invite code.');
    try {
      final j = (jsonDecode(utf8.decode(unb64(c.substring(prefix.length)))) as Map).cast<String, Object?>();
      return Invite(
        teamId: j['team'] as String,
        inviteId: j['inv'] as String,
        secret: unb64(j['s'] as String),
        storage: StorageSettings.fromJson((j['storage'] as Map).cast()),
      );
    } catch (_) {
      throw SyncError('The invite code is damaged. Ask for a new one.');
    }
  }

  static const prefix = 'relay-invite:';

  final String teamId;
  final String inviteId;
  final Uint8List secret;
  final StorageSettings storage;

  String encode() => prefix +
      b64(utf8.encode(jsonEncode({'v': 1, 'team': teamId, 'inv': inviteId, 's': b64(secret), 'storage': storage.toJson()})));
}

/// Moves the op log between this device's store and the team's storage.
///
/// Layout under `relay/TEAM/` (docs/format/sync.md):
/// ```text
///   team.json                   {format, teamId, epoch} (plain)
///   members/DEVICE.json         {deviceId, publicKey} (plain)
///   keys/EPOCH/DEVICE.key       team key for the epoch, sealed to the device
///   invites/ID.inv              key ring sealed with the invite secret
///   ops/DEVICE/SEQ.op           a batch of ops, sealed with the team key
/// ```
class SyncEngine {
  SyncEngine({required this.store, required this.backend, required this.secrets, required this.saveSecrets, this.batchSize = 400});

  final Store store;
  final StorageBackend backend;
  final Secrets secrets;
  final void Function() saveSecrets;
  final int batchSize;

  String get teamId => secrets.teamId ?? (throw SyncError('Not in a team'));
  String get deviceId => store.deviceId;
  String get root => 'relay/$teamId';

  // ---------------------------------------------------------------- team

  /// Starts a new team on [secrets.storage] with this device as its first member.
  static Future<SyncEngine> createTeam({
    required Store store,
    required Secrets secrets,
    required String teamName,
    required void Function() saveSecrets,
  }) async {
    final storage = secrets.storage ?? (throw SyncError('Choose where the team syncs first.'));
    secrets
      ..teamId = newId()
      ..teamName = teamName
      ..keyring.clear()
      ..keyring[1] = RelayCrypto.newKey();
    final engine = SyncEngine(store: store, backend: storage.backend(), secrets: secrets, saveSecrets: saveSecrets);
    await engine.backend.put('${engine.root}/team.json', _json({'format': 1, 'teamId': secrets.teamId, 'epoch': 1}),
        condition: const WriteCondition.ifAbsent());
    await engine._publishMember();
    saveSecrets();
    // Everything this device already has becomes the team's starting point.
    return engine;
  }

  Future<void> _publishMember() async {
    await backend.put('$root/members/$deviceId.json', _json({
      'deviceId': deviceId,
      'publicKey': b64(await RelayCrypto.publicKey(secrets.deviceSeed)),
      'addedAt': DateTime.now().toUtc().toIso8601String(),
    }));
  }

  /// A one-time invite. The code carries the storage credentials and the
  /// secret that opens the invite, so share it privately; it stops working
  /// once used or after [ttl].
  Future<String> createInvite({Duration ttl = const Duration(days: 2)}) async {
    final inviteId = newToken(16);
    final secret = RelayCrypto.randomBytes(32);
    final key = await RelayCrypto.inviteKey(secret, teamId);
    final objectKey = '$root/invites/$inviteId.inv';
    final sealed = await RelayCrypto.seal(
      key: key,
      teamId: teamId,
      type: EnvelopeType.invite,
      epoch: 0,
      objectKey: objectKey,
      plain: utf8.encode(jsonEncode({
        'teamName': secrets.teamName,
        'expiresAt': DateTime.now().add(ttl).toUtc().toIso8601String(),
        'keyring': {for (final e in secrets.keyring.entries) '${e.key}': b64(e.value)},
      })),
    );
    await backend.put(objectKey, sealed, condition: const WriteCondition.ifAbsent());
    return Invite(teamId: teamId, inviteId: inviteId, secret: secret, storage: secrets.storage!).encode();
  }

  /// Joins a team with an invite [code], filling [secrets]. The caller then
  /// syncs to receive the whole workspace.
  static Future<SyncEngine> join({
    required Store store,
    required Secrets secrets,
    required String code,
    required void Function() saveSecrets,
  }) async {
    final invite = Invite.parse(code);
    final backend = invite.storage.backend();
    final objectKey = 'relay/${invite.teamId}/invites/${invite.inviteId}.inv';
    final body = await backend.get(objectKey);
    if (body == null) throw SyncError('This invite was already used or withdrawn. Ask for a new one.');
    final Map<String, Object?> payload;
    try {
      payload = (jsonDecode(utf8.decode(await RelayCrypto.open(
        key: await RelayCrypto.inviteKey(invite.secret, invite.teamId),
        teamId: invite.teamId,
        type: EnvelopeType.invite,
        objectKey: objectKey,
        bytes: body.bytes,
      ))) as Map).cast();
    } on DecryptionFailed {
      throw SyncError('The invite code does not match its invite. Ask for a new one.');
    }
    final expires = DateTime.tryParse(payload['expiresAt'] as String? ?? '');
    if (expires != null && expires.isBefore(DateTime.now())) {
      await backend.delete(objectKey);
      throw SyncError('This invite has expired. Ask for a new one.');
    }
    secrets
      ..teamId = invite.teamId
      ..teamName = payload['teamName'] as String?
      ..storage = invite.storage
      ..keyring.clear();
    for (final e in ((payload['keyring'] as Map?) ?? {}).entries) {
      secrets.keyring[int.parse('${e.key}')] = unb64(e.value as String);
    }
    final engine = SyncEngine(store: store, backend: backend, secrets: secrets, saveSecrets: saveSecrets);
    await engine._publishMember();
    await backend.delete(objectKey); // one use
    saveSecrets();
    return engine;
  }

  /// Device ids currently in the team.
  Future<List<String>> members() async => [
    for (final o in await backend.list('$root/members/'))
      if (o.key.endsWith('.json')) o.key.substring('$root/members/'.length, o.key.length - 5),
  ];

  Future<bool> isMember() async => await backend.get('$root/members/$deviceId.json') != null;

  /// Removes [removedDevice] and rotates the team key: a new epoch, sealed
  /// to every remaining member. The removed device keeps what it already
  /// read but can't open anything written from now on.
  Future<int> revoke(String removedDevice) async {
    if (removedDevice == deviceId) throw SyncError('Use Leave team to remove this device.');
    await backend.delete('$root/members/$removedDevice.json');
    final team = await backend.get('$root/team.json') ?? (throw SyncError('team.json is missing'));
    final current = (jsonDecode(utf8.decode(team.bytes)) as Map)['epoch'] as int;
    final epoch = (current > secrets.currentEpoch ? current : secrets.currentEpoch) + 1;
    final key = RelayCrypto.newKey();
    for (final m in await members()) {
      final info = await backend.get('$root/members/$m.json');
      if (info == null) continue;
      final pub = unb64((jsonDecode(utf8.decode(info.bytes)) as Map)['publicKey'] as String);
      await backend.put('$root/keys/$epoch/$m.key', await RelayCrypto.wrapFor(pub, key));
    }
    // Only publish the new epoch once every member's key is in place.
    await backend.put('$root/team.json', _json({'format': 1, 'teamId': teamId, 'epoch': epoch}), condition: WriteCondition.ifMatch(team.etag));
    secrets.keyring[epoch] = key;
    saveSecrets();
    store.patch<DeviceInfo>(Kind.device, removedDevice, {'revoked': true});
    return epoch;
  }

  /// Picks up keys for epochs this device doesn't have yet.
  Future<void> _refreshKeyring() async {
    final team = await backend.get('$root/team.json');
    if (team == null) throw SyncError('The team\'s storage has no team.json. Is this the right bucket?');
    final epoch = (jsonDecode(utf8.decode(team.bytes)) as Map)['epoch'] as int;
    for (var e = secrets.currentEpoch + 1; e <= epoch; e++) {
      final wrapped = await backend.get('$root/keys/$e/$deviceId.key');
      if (wrapped == null) {
        throw SyncError('This device was removed from the team (no key for epoch $e).');
      }
      secrets.keyring[e] = await RelayCrypto.unwrap(secrets.deviceSeed, wrapped.bytes);
      saveSecrets();
    }
  }

  // ---------------------------------------------------------------- sync

  Future<SyncResult> sync() async {
    final problems = <String>[];
    final pulled = await pull(problems);
    final pushed = await push();
    return SyncResult(pushedOps: pushed, pulledOps: pulled.$1, objectsRead: pulled.$2, problems: problems);
  }

  /// Uploads pending ops in sealed batches. Returns how many were sent.
  Future<int> push() async {
    await _refreshKeyring();
    var sent = 0;
    while (true) {
      final pending = store.pendingOps(limit: batchSize);
      if (pending.isEmpty) break;
      final local = pending.where((o) => !Kind.synced.contains(o.kind)).map((o) => o.seq!).toList();
      final shared = pending.where((o) => Kind.synced.contains(o.kind)).toList();
      if (shared.isNotEmpty) {
        final epoch = secrets.currentEpoch;
        var seq = int.tryParse(store.meta('sync.nextSeq') ?? '') ?? 1;
        final plain = utf8.encode(jsonEncode([for (final o in shared) o.toJson()]));
        while (true) {
          final key = '$root/ops/$deviceId/${seq.toString().padLeft(12, '0')}.op';
          final sealed = await RelayCrypto.seal(key: secrets.keyring[epoch]!, teamId: teamId, type: EnvelopeType.ops, epoch: epoch, objectKey: key, plain: plain);
          try {
            await backend.put(key, sealed, condition: const WriteCondition.ifAbsent());
            break;
          } on PreconditionFailed {
            seq++; // the slot is taken (a reinstalled device reusing its id)
          }
        }
        store.setMeta('sync.nextSeq', '${seq + 1}');
        sent += shared.length;
      }
      store.markSynced([...local, ...shared.map((o) => o.seq!)]);
    }
    if (sent > 0) store.setMeta('sync.lastPush', DateTime.now().toUtc().toIso8601String());
    return sent;
  }

  /// Downloads and merges other devices' new batches. Returns (ops, objects).
  Future<(int, int)> pull([List<String>? problems]) async {
    await _refreshKeyring();
    final listing = await backend.list('$root/ops/');
    final byDevice = <String, List<RemoteObject>>{};
    for (final o in listing) {
      final rest = o.key.substring('$root/ops/'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) continue;
      final dev = rest.substring(0, slash);
      if (dev == deviceId) continue;
      (byDevice[dev] ??= []).add(o);
    }
    var ops = 0, objects = 0;
    for (final MapEntry(key: dev, value: objs) in byDevice.entries) {
      final cursor = store.meta('sync.cursor.$dev') ?? '';
      for (final o in objs..sort((a, b) => a.key.compareTo(b.key))) {
        if (o.key.compareTo(cursor) <= 0) continue;
        final body = await backend.get(o.key);
        if (body == null) continue;
        final epoch = RelayCrypto.epochOf(body.bytes);
        final key = epoch == null ? null : secrets.keyring[epoch];
        if (key == null) {
          problems?.add('${o.key}: no key for epoch $epoch');
          break; // wait for the key; keep the cursor here
        }
        try {
          final plain = await RelayCrypto.open(key: key, teamId: teamId, type: EnvelopeType.ops, objectKey: o.key, bytes: body.bytes);
          for (final j in jsonDecode(utf8.decode(plain)) as List) {
            final op = Op.fromJson((j as Map).cast());
            if (!Kind.synced.contains(op.kind)) continue;
            store.applyRemote(op);
            ops++;
          }
        } on DecryptionFailed catch (e) {
          // Tampered or foreign: skip it for good, but say so.
          problems?.add('${o.key}: ${e.message}');
        } on FormatException catch (e) {
          problems?.add('${o.key}: ${e.message}');
        }
        objects++;
        store.setMeta('sync.cursor.$dev', o.key);
      }
    }
    store.setMeta('sync.lastPull', DateTime.now().toUtc().toIso8601String());
    return (ops, objects);
  }

  static Uint8List _json(Object o) => Uint8List.fromList(utf8.encode(jsonEncode(o)));
}
