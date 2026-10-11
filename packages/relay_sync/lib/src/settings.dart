import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
import 'folder_backend.dart';
import 's3_backend.dart';
import 'sigv4.dart';
import 'storage.dart';
import 'worker_backend.dart';

/// Where the team's encrypted op log lives.
class StorageSettings {
  const StorageSettings.folder(this.folder)
    : kind = 'folder',
      endpoint = null,
      bucket = null,
      region = 'auto',
      accessKeyId = null,
      secretAccessKey = null,
      setupToken = null;

  const StorageSettings.s3({
    required String this.endpoint,
    required String this.bucket,
    this.region = 'auto',
    required String this.accessKeyId,
    required String this.secretAccessKey,
  }) : kind = 's3',
       folder = null,
       setupToken = null;

  /// The team's Worker (worker/src/index.js) in front of its R2 bucket.
  /// [setupToken] is only set on the device that deployed it, until the
  /// team is created; it never goes into invites.
  StorageSettings.worker(String this.endpoint, {this.setupToken})
    : kind = 'worker',
      folder = null,
      bucket = null,
      region = 'auto',
      accessKeyId = null,
      secretAccessKey = null;

  /// Cloudflare R2: `https://<account>.r2.cloudflarestorage.com`, region auto.
  factory StorageSettings.r2({required String accountId, required String bucket, required String accessKeyId, required String secretAccessKey}) =>
      StorageSettings.s3(
        endpoint: 'https://$accountId.r2.cloudflarestorage.com',
        bucket: bucket,
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
      );

  factory StorageSettings.fromJson(Map<String, Object?> j) => switch (j['kind']) {
    'folder' => StorageSettings.folder(j['folder'] as String),
    'worker' => StorageSettings.worker(j['endpoint'] as String),
    _ => StorageSettings.s3(
          endpoint: j['endpoint'] as String,
          bucket: j['bucket'] as String,
          region: j['region'] as String? ?? 'auto',
          accessKeyId: j['accessKeyId'] as String,
          secretAccessKey: j['secretAccessKey'] as String,
        ),
  };

  /// `folder` (a shared folder, e.g. iCloud Drive), `s3` (R2, S3, MinIO)
  /// or `worker` (the team's Worker; [endpoint] is its URL).
  final String kind;
  final String? folder;
  final String? endpoint;
  final String? bucket;
  final String region;
  final String? accessKeyId;
  final String? secretAccessKey;
  final String? setupToken;

  /// [token] gives the Worker's bearer token for `worker` storage.
  StorageBackend backend({Future<String?> Function()? token}) => switch (kind) {
    'folder' => FolderBackend(Directory(folder!)),
    'worker' => WorkerBackend(Uri.parse(endpoint!), token: token ?? () async => null),
    _ => S3Backend(
      config: S3Config(endpoint: Uri.parse(endpoint!), bucket: bucket!, region: region),
      credentials: AwsCredentials(accessKeyId: accessKeyId!, secretAccessKey: secretAccessKey!),
    ),
  };

  /// What the UI may show: no secret.
  Map<String, Object?> describe() => kind == 'folder'
      ? {'kind': kind, 'folder': folder}
      : kind == 'worker'
      ? {'kind': kind, 'endpoint': endpoint}
      : {'kind': kind, 'endpoint': endpoint, 'bucket': bucket, 'region': region, 'accessKeyId': accessKeyId};

  Map<String, Object?> toJson() => kind == 'folder'
      ? {'kind': kind, 'folder': folder}
      : kind == 'worker'
      ? {'kind': kind, 'endpoint': endpoint}
      : {
          'kind': kind,
          'endpoint': endpoint,
          'bucket': bucket,
          'region': region,
          'accessKeyId': accessKeyId,
          'secretAccessKey': secretAccessKey,
        };

  @override
  String toString() => 'StorageSettings(${describe()})';
}

/// This device's sync secrets, in `secrets.json` (mode 0600) in the Relay
/// home folder: the device's X25519 seed, the team key ring, and the
/// storage credentials. Nothing here is ever synced or logged.
class Secrets {
  Secrets({required this.deviceSeed, this.teamId, this.teamName, Map<int, Uint8List>? keyring, this.storage, Map<String, Uint8List>? companions, this.pairing})
    : keyring = keyring ?? {},
      companions = companions ?? {};

  factory Secrets.fresh() => Secrets(deviceSeed: RelayCrypto.randomBytes(32));

  static Secrets load(String path) {
    final f = File(path);
    if (!f.existsSync()) return Secrets.fresh();
    final j = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
    return Secrets(
      deviceSeed: unb64(j['deviceSeed'] as String),
      teamId: j['teamId'] as String?,
      teamName: j['teamName'] as String?,
      keyring: {for (final e in ((j['keyring'] as Map?) ?? {}).entries) int.parse('${e.key}'): unb64(e.value as String)},
      storage: j['storage'] == null ? null : StorageSettings.fromJson((j['storage'] as Map).cast()),
      companions: {for (final e in ((j['companions'] as Map?) ?? {}).entries) '${e.key}': unb64(e.value as String)},
      pairing: j['pairing'] == null ? null : Pairing.fromJson((j['pairing'] as Map).cast()),
    );
  }

  final Uint8List deviceSeed;
  String? teamId;
  String? teamName;

  /// Team key per epoch. New members get the whole ring so they can read
  /// history; a removed device never gets keys for later epochs.
  final Map<int, Uint8List> keyring;
  StorageSettings? storage;

  /// On a Mac: pairing id → key of each phone paired with it.
  final Map<String, Uint8List> companions;

  /// On a phone: the Mac it is paired with.
  Pairing? pairing;

  int get currentEpoch => keyring.isEmpty ? 0 : keyring.keys.reduce((a, b) => a > b ? a : b);
  bool get inTeam => teamId != null && storage != null && keyring.isNotEmpty;

  /// The Worker token for the newest key this device holds.
  Future<String?> workerToken() async =>
      teamId == null || keyring.isEmpty ? null : RelayCrypto.workerToken(keyring[currentEpoch]!, teamId!);

  void save(String path) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode({
      'deviceSeed': b64(deviceSeed),
      'teamId': ?teamId,
      'teamName': ?teamName,
      'keyring': {for (final e in keyring.entries) '${e.key}': b64(e.value)},
      if (storage != null) 'storage': storage!.toJson(),
      if (companions.isNotEmpty) 'companions': {for (final e in companions.entries) e.key: b64(e.value)},
      if (pairing != null) 'pairing': pairing!.toJson(),
    }));
    // Phones sandbox the app's files; desktops get owner-only access.
    if (!Platform.isWindows && !Platform.isIOS && !Platform.isAndroid) Process.runSync('chmod', ['600', tmp.path]);
    tmp.renameSync(path);
  }

  void leave() {
    companions.clear();
    pairing = null;
    teamId = null;
    teamName = null;
    keyring.clear();
    storage = null;
  }
}

/// A phone's link to its Mac: which Mac, and the key that signs commands.
class Pairing {
  Pairing({required this.id, required this.key, required this.mac, required this.macName, required this.person});

  factory Pairing.fromJson(Map<String, Object?> j) => Pairing(
    id: j['id'] as String,
    key: unb64(j['k'] as String),
    mac: j['mac'] as String,
    macName: j['macName'] as String? ?? 'Mac',
    person: j['person'] as String? ?? '',
  );

  final String id;
  final Uint8List key;
  final String mac;
  final String macName;
  final String person;

  Map<String, Object?> toJson() => {'id': id, 'k': b64(key), 'mac': mac, 'macName': macName, 'person': person};

  static const prefix = 'relay-pair:';

  /// The QR / paste code: the team invite plus this pairing.
  String encode(String invite) => '$prefix${b64(utf8.encode(jsonEncode({...toJson(), 'invite': invite})))}';

  /// (pairing, invite code).
  static (Pairing, String) parse(String code) {
    final c = code.trim();
    if (!c.startsWith(prefix)) throw const FormatException('Not a Relay pairing code.');
    final j = (jsonDecode(utf8.decode(unb64(c.substring(prefix.length)))) as Map).cast<String, Object?>();
    return (Pairing.fromJson(j), j['invite'] as String);
  }
}
