import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
import 'folder_backend.dart';
import 's3_backend.dart';
import 'sigv4.dart';
import 'storage.dart';

/// Where the team's encrypted op log lives.
class StorageSettings {
  const StorageSettings.folder(this.folder)
    : kind = 'folder',
      endpoint = null,
      bucket = null,
      region = 'auto',
      accessKeyId = null,
      secretAccessKey = null;

  const StorageSettings.s3({
    required String this.endpoint,
    required String this.bucket,
    this.region = 'auto',
    required String this.accessKeyId,
    required String this.secretAccessKey,
  }) : kind = 's3',
       folder = null;

  /// Cloudflare R2: `https://<account>.r2.cloudflarestorage.com`, region auto.
  factory StorageSettings.r2({required String accountId, required String bucket, required String accessKeyId, required String secretAccessKey}) =>
      StorageSettings.s3(
        endpoint: 'https://$accountId.r2.cloudflarestorage.com',
        bucket: bucket,
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
      );

  factory StorageSettings.fromJson(Map<String, Object?> j) => j['kind'] == 'folder'
      ? StorageSettings.folder(j['folder'] as String)
      : StorageSettings.s3(
          endpoint: j['endpoint'] as String,
          bucket: j['bucket'] as String,
          region: j['region'] as String? ?? 'auto',
          accessKeyId: j['accessKeyId'] as String,
          secretAccessKey: j['secretAccessKey'] as String,
        );

  /// `folder` (a shared folder, e.g. iCloud Drive) or `s3` (R2, S3, MinIO).
  final String kind;
  final String? folder;
  final String? endpoint;
  final String? bucket;
  final String region;
  final String? accessKeyId;
  final String? secretAccessKey;

  StorageBackend backend() => kind == 'folder'
      ? FolderBackend(Directory(folder!))
      : S3Backend(
          config: S3Config(endpoint: Uri.parse(endpoint!), bucket: bucket!, region: region),
          credentials: AwsCredentials(accessKeyId: accessKeyId!, secretAccessKey: secretAccessKey!),
        );

  /// What the UI may show: no secret.
  Map<String, Object?> describe() => kind == 'folder'
      ? {'kind': kind, 'folder': folder}
      : {'kind': kind, 'endpoint': endpoint, 'bucket': bucket, 'region': region, 'accessKeyId': accessKeyId};

  Map<String, Object?> toJson() => kind == 'folder'
      ? {'kind': kind, 'folder': folder}
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
  Secrets({required this.deviceSeed, this.teamId, this.teamName, Map<int, Uint8List>? keyring, this.storage})
    : keyring = keyring ?? {};

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
    );
  }

  final Uint8List deviceSeed;
  String? teamId;
  String? teamName;

  /// Team key per epoch. New members get the whole ring so they can read
  /// history; a removed device never gets keys for later epochs.
  final Map<int, Uint8List> keyring;
  StorageSettings? storage;

  int get currentEpoch => keyring.isEmpty ? 0 : keyring.keys.reduce((a, b) => a > b ? a : b);
  bool get inTeam => teamId != null && storage != null && keyring.isNotEmpty;

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
    }));
    if (!Platform.isWindows) Process.runSync('chmod', ['600', tmp.path]);
    tmp.renameSync(path);
  }

  void leave() {
    teamId = null;
    teamName = null;
    keyring.clear();
    storage = null;
  }
}
