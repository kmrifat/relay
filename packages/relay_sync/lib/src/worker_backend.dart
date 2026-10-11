import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'storage.dart';

/// A [StorageBackend] through the team's own Worker (worker/src/index.js)
/// instead of R2 credentials. Members authenticate with a token derived
/// from the team key, so removing a device also cuts its storage access.
class WorkerBackend implements StorageBackend {
  WorkerBackend(this.base, {required this.token, http.Client? client}) : _http = client ?? http.Client();

  /// e.g. `https://relay-binarycastle.rifat.workers.dev`.
  final Uri base;

  /// The current epoch's token, or null before this device has a team key
  /// (only invites can be read then).
  final Future<String?> Function() token;
  final http.Client _http;

  Uri _url(String path, [Map<String, String>? query]) =>
      base.replace(path: '${base.path.replaceAll(RegExp(r'/$'), '')}/v1/$path', queryParameters: query);

  Uri _object(String key) => _url('o/${Uri.encodeComponent(StorageKeys.check(key))}');

  @override
  Future<List<RemoteObject>> list(String prefix, {String? startAfter}) async {
    StorageKeys.checkPrefix(prefix);
    final out = <RemoteObject>[];
    String? cursor;
    do {
      final res = await _send('GET', _url('list', {'prefix': prefix, 'start-after': ?startAfter, 'cursor': ?cursor}), what: prefix);
      final j = jsonDecode(res.body) as Map<String, Object?>;
      for (final o in (j['objects'] as List).cast<Map<String, Object?>>()) {
        out.add(RemoteObject(key: o['key'] as String, etag: o['etag'] as String, size: (o['size'] as num).toInt()));
      }
      cursor = j['truncated'] == true ? j['cursor'] as String? : null;
    } while (cursor != null);
    return out..sort((a, b) => a.key.compareTo(b.key));
  }

  @override
  Future<RemoteBody?> get(String key) async {
    final res = await _send('GET', _object(key), what: key, allow404: true);
    if (res.statusCode == 404) return null;
    return RemoteBody(res.bodyBytes, res.headers['etag'] ?? '');
  }

  @override
  Future<String> put(String key, Uint8List bytes, {WriteCondition condition = const WriteCondition.always()}) async {
    final res = await _send('PUT', _object(key), what: key, body: bytes, headers: switch (condition) {
      WriteAlways() => const {},
      WriteIfAbsent() => const {'if-none-match': '*'},
      WriteIfMatch(:final etag) => {'if-match': etag},
    });
    return res.headers['etag'] ?? (throw StorageUnavailable('$key: the Worker sent no ETag'));
  }

  @override
  Future<void> delete(String key, {String? ifMatch}) async {
    await _send('DELETE', _object(key), what: key, headers: {'if-match': ?ifMatch});
  }

  /// `{ok, version, configured}`; throws when it isn't a Relay Worker.
  Future<Map<String, Object?>> health() async {
    final res = await _send('GET', _url('health'), what: 'health');
    try {
      return (jsonDecode(res.body) as Map).cast<String, Object?>();
    } on FormatException {
      throw const StorageNotFound('That URL is not a Relay Worker.');
    }
  }

  /// First use of a freshly deployed Worker: binds it to [teamId] and the
  /// epoch's token hash. The setup token works once.
  Future<void> setup({required String setupToken, required String teamId, required int epoch, required String hash}) async {
    await _send('POST', _url('setup'), what: 'setup', bearer: setupToken,
        body: utf8.encode(jsonEncode({'teamId': teamId, 'epoch': epoch, 'hash': hash})));
  }

  /// A revoke: writes [teamJson] if team.json is still at [ifMatch] and
  /// switches the Worker to the new epoch's token, atomically.
  Future<String> publishEpoch({required int epoch, required String hash, required Uint8List teamJson, required String ifMatch}) async {
    final res = await _send('POST', _url('epoch'), what: 'team.json',
        body: utf8.encode(jsonEncode({'epoch': epoch, 'hash': hash, 'teamJson': utf8.decode(teamJson), 'ifMatch': ifMatch})));
    return res.headers['etag'] ?? '';
  }

  // ------------------------------------------------------------ push

  /// Stores the team's APNs key in the Worker (it never comes back out).
  Future<void> pushConfig({required String keyId, required String teamId, required String bundleId, required String p8}) async {
    await _send('POST', _url('push/config'), what: 'push setup', body: utf8.encode(jsonEncode({'keyId': keyId, 'teamId': teamId, 'bundleId': bundleId, 'p8': p8})));
  }

  /// `{configured, keyId, bundleId, devices}`.
  Future<Map<String, Object?>> pushStatus() async => (jsonDecode((await _send('GET', _url('push/config'), what: 'push status')).body) as Map).cast();

  /// A phone's APNs device token.
  Future<void> pushRegister({required String device, required String token, bool sandbox = false}) async {
    await _send('POST', _url('push/register'), what: 'push registration', body: utf8.encode(jsonEncode({'device': device, 'token': token, 'sandbox': sandbox})));
  }

  /// Sends a notification to [to]'s phone through APNs.
  Future<void> push({required String to, required String title, String body = '', Map<String, Object?> data = const {}}) async {
    await _send('POST', _url('push'), what: 'push', body: utf8.encode(jsonEncode({'to': to, 'title': title, 'body': body, 'data': data})));
  }

  /// The live room (`wss://…/v1/ws?device=…`).
  Uri socketUrl(String deviceId) =>
      _url('ws', {'device': deviceId}).replace(scheme: base.scheme == 'https' ? 'wss' : 'ws');

  Future<http.Response> _send(
    String method,
    Uri url, {
    required String what,
    Map<String, String> headers = const {},
    List<int>? body,
    String? bearer,
    bool allow404 = false,
  }) async {
    final auth = bearer ?? await token();
    for (var attempt = 1;; attempt++) {
      http.Response? res;
      Object? failure;
      try {
        final req = http.Request(method, url)..headers.addAll({...headers, 'authorization': ?(auth == null ? null : 'Bearer $auth')});
        if (body != null) req.bodyBytes = body;
        res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 30)));
      } on SocketException catch (e) {
        failure = e.message;
      } on HttpException catch (e) {
        failure = e.message;
      } on http.ClientException catch (e) {
        failure = e.message;
      } on TimeoutException {
        failure = 'timed out';
      }
      final retryable = res == null || res.statusCode == 429 || res.statusCode >= 500;
      if (!retryable || attempt >= 4) {
        if (res == null) throw StorageUnavailable('$what: cannot reach the Worker ($failure)');
        final code = res.statusCode;
        if (code < 300 || (code == 404 && allow404)) return res;
        final msg = '$what: ${res.body.isEmpty ? 'HTTP $code' : res.body}';
        throw switch (code) {
          412 || 409 when method != 'GET' => PreconditionFailed(msg),
          401 || 403 => StorageAccessDenied(msg),
          404 => StorageNotFound(msg),
          _ => StorageUnavailable(msg),
        };
      }
      await Future<void>.delayed(Duration(milliseconds: 200 * attempt * attempt));
    }
  }
}
