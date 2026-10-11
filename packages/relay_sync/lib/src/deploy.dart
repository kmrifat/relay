import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'crypto.dart';
import 'engine.dart' show SyncError;
import 'settings.dart';
import 'worker_backend.dart';
import 'worker_source.dart';

/// Deploys the team Worker to the team's own Cloudflare account through the
/// API (no wrangler): creates the R2 bucket, uploads the Worker with its
/// R2 and Durable Object bindings and a one-time setup token, and turns on
/// its workers.dev URL.
///
/// The API token needs Account → Workers Scripts: Edit and Workers R2
/// Storage: Edit. Relay uses it for this call only and never stores it.
class WorkerDeployer {
  WorkerDeployer({required this.accountId, required this.apiToken, http.Client? client, Uri? api, this.urlFor = _workersDev})
    : _http = client ?? http.Client(),
      _api = api ?? Uri.parse('https://api.cloudflare.com/client/v4');

  static String _workersDev(String script, String subdomain) => 'https://$script.$subdomain.workers.dev';

  final String accountId;
  final String apiToken;
  final http.Client _http;
  final Uri _api;

  /// The Worker's address from its name and the account's subdomain.
  final FutureOr<String> Function(String script, String subdomain) urlFor;

  static const compatibilityDate = '2026-07-01';
  static const migrationTag = 'v1';

  /// Deploys (or updates) [scriptName] bound to [bucket] and waits until it
  /// answers. Returns storage settings carrying the setup token, ready for
  /// `SyncEngine.createTeam`.
  Future<StorageSettings> deploy({
    required String scriptName,
    String bucket = 'relay',
    void Function(String step)? onStep,
    Duration waitUpTo = const Duration(seconds: 90),
  }) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$').hasMatch(scriptName)) {
      throw SyncError('Worker names use lowercase letters, digits and dashes.');
    }
    onStep?.call('Creating the R2 bucket $bucket…');
    await _ensureBucket(bucket);

    onStep?.call('Uploading the Worker…');
    final existing = await _call('GET', 'workers/scripts');
    final current = ((existing as List?) ?? const []).cast<Map<String, Object?>>().where((s) => s['id'] == scriptName).firstOrNull;
    final setupToken = b64(RelayCrypto.randomBytes(32));
    await _upload(scriptName, bucket, setupToken, migrate: current?['migration_tag'] != migrationTag);

    onStep?.call('Turning on its workers.dev address…');
    final sub = await _subdomain();
    await _call('POST', 'workers/scripts/$scriptName/subdomain', body: {'enabled': true, 'previews_enabled': false});
    final url = await urlFor(scriptName, sub);

    onStep?.call('Waiting for $url…');
    await _waitHealthy(Uri.parse(url), waitUpTo);
    return StorageSettings.worker(url, setupToken: setupToken);
  }

  /// Checks the token can manage Workers and R2 on this account, without
  /// changing anything. Returns problems; empty means ready.
  Future<List<String>> check() async {
    final problems = <String>[];
    for (final (path, what) in [('workers/scripts', 'Workers Scripts'), ('r2/buckets', 'Workers R2 Storage')]) {
      try {
        await _call('GET', path);
      } on SyncError catch (e) {
        problems.add(e.message.contains('refused') ? 'The token can\'t use $what on this account.' : e.message);
      } on Exception catch (e) {
        problems.add('Cannot reach Cloudflare: $e');
        break;
      }
    }
    return problems;
  }

  /// A Worker name from a team name: `relay-binarycastle`.
  static String nameFor(String team) {
    final slug = team.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final s = 'relay-${slug.isEmpty ? 'team' : slug}';
    return s.length > 54 ? s.substring(0, 54) : s;
  }

  Future<void> _ensureBucket(String bucket) async {
    try {
      await _call('POST', 'r2/buckets', body: {'name': bucket});
    } on _CloudflareError catch (e) {
      // 10004: the bucket exists (in this account); reuse it.
      if (!e.codes.contains(10004) && e.status != 409) rethrow;
    }
  }

  Future<void> _upload(String name, String bucket, String setupToken, {required bool migrate}) async {
    final metadata = {
      'main_module': 'index.js',
      'compatibility_date': compatibilityDate,
      'bindings': [
        {'type': 'r2_bucket', 'name': 'BUCKET', 'bucket_name': bucket},
        {'type': 'durable_object_namespace', 'name': 'ROOM', 'class_name': 'TeamRoom'},
        {'type': 'secret_text', 'name': 'SETUP_TOKEN', 'text': setupToken},
      ],
      if (migrate) 'migrations': {'new_tag': migrationTag, 'new_sqlite_classes': ['TeamRoom']},
    };
    final req = http.MultipartRequest('PUT', _url('workers/scripts/$name'))
      ..headers['authorization'] = 'Bearer $apiToken'
      ..files.add(http.MultipartFile.fromString('metadata', jsonEncode(metadata), filename: 'metadata.json', contentType: _type('application/json')))
      ..files.add(http.MultipartFile.fromString('index.js', workerSource, filename: 'index.js', contentType: _type('application/javascript+module')));
    _unwrap(await http.Response.fromStream(await _http.send(req)));
  }

  /// The account's workers.dev subdomain; a fresh account gets one.
  Future<String> _subdomain() async {
    try {
      final r = await _call('GET', 'workers/subdomain') as Map?;
      final s = r?['subdomain'] as String?;
      if (s != null && s.isNotEmpty) return s;
    } on _CloudflareError catch (e) {
      if (e.status != 404) rethrow;
    }
    final wanted = 'relay-${b64(RelayCrypto.randomBytes(4)).toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '')}';
    final r = await _call('PUT', 'workers/subdomain', body: {'subdomain': wanted}) as Map?;
    return r?['subdomain'] as String? ?? wanted;
  }

  Future<void> _waitHealthy(Uri url, Duration upTo) async {
    final backend = WorkerBackend(url, token: () async => null, client: _http);
    final end = DateTime.now().add(upTo);
    Object? last;
    while (DateTime.now().isBefore(end)) {
      try {
        final h = await backend.health();
        if (h['ok'] == true) return;
      } catch (e) {
        last = e; // a new workers.dev name takes a moment to resolve
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw SyncError('The Worker deployed but $url did not answer ($last). Try again in a minute.');
  }

  Uri _url(String path) => _api.replace(path: '${_api.path}/accounts/$accountId/$path');

  Future<Object?> _call(String method, String path, {Object? body}) async {
    final req = http.Request(method, _url(path))..headers['authorization'] = 'Bearer $apiToken';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    return _unwrap(await http.Response.fromStream(await _http.send(req)));
  }

  Object? _unwrap(http.Response res) {
    Map<String, Object?> j;
    try {
      j = (jsonDecode(res.body) as Map).cast<String, Object?>();
    } on FormatException {
      throw _CloudflareError(res.statusCode, const [], 'Cloudflare answered HTTP ${res.statusCode}.');
    }
    if (res.statusCode >= 300 || j['success'] == false) {
      final errors = ((j['errors'] as List?) ?? const []).cast<Map<String, Object?>>();
      final msg = errors.map((e) => e['message']).join('; ');
      final codes = [for (final e in errors) (e['code'] as num?)?.toInt() ?? 0];
      throw _CloudflareError(res.statusCode, codes, switch (res.statusCode) {
        401 || 403 => 'Cloudflare refused the API token ($msg). It needs Workers Scripts: Edit and Workers R2 Storage: Edit on this account.',
        _ => 'Cloudflare: ${msg.isEmpty ? 'HTTP ${res.statusCode}' : msg}',
      });
    }
    return j['result'];
  }
}

class _CloudflareError extends SyncError {
  _CloudflareError(this.status, this.codes, super.message);
  final int status;
  final List<int> codes;
}

MediaType _type(String t) => MediaType.parse(t);
