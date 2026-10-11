// Adapted from DevVault (packages/vault_core and vault_s3), same author.
import 'dart:async';
import 'dart:io' show SocketException, HttpException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'sigv4.dart';
import 'storage.dart';

/// Where a bucket is and how to address it.
@immutable
class S3Config {
  const S3Config({
    required this.endpoint,
    required this.bucket,
    this.region = 'us-east-1',
    this.pathStyle = true,
  });

  /// Cloudflare R2: one endpoint per account, region `auto`, path-style.
  factory S3Config.r2({required String accountId, required String bucket}) =>
      S3Config(
        endpoint: Uri.parse('https://$accountId.r2.cloudflarestorage.com'),
        bucket: bucket,
        region: 'auto',
      );

  /// The service root, e.g. `https://s3.eu-west-1.amazonaws.com` or
  /// `http://127.0.0.1:9000` for MinIO.
  final Uri endpoint;
  final String bucket;
  final String region;

  /// `https://endpoint/bucket/key` rather than `https://bucket.endpoint/key`.
  /// Most S3-compatible stores want path-style; AWS accepts both.
  final bool pathStyle;

  /// The URL for [key] (or the bucket itself when null), with [query].
  Uri url({String? key, Map<String, String> query = const {}}) {
    final segments = [
      if (pathStyle) bucket,
      if (key != null) ...key.split('/'),
    ];
    final host = pathStyle ? endpoint.host : '$bucket.${endpoint.host}';
    final path = SigV4Signer.encodePath(segments);
    final queryString = [
      for (final MapEntry(key: k, value: v) in query.entries)
        '${SigV4Signer.encode(k)}=${SigV4Signer.encode(v)}',
    ].join('&');
    return Uri.parse(
      '${endpoint.scheme}://$host${endpoint.hasPort ? ':${endpoint.port}' : ''}'
      '${path == '/' && !pathStyle ? '/' : path}'
      '${queryString.isEmpty ? '' : '?$queryString'}',
    );
  }
}

/// A [StorageBackend] on S3 or an S3-compatible store (R2, B2, MinIO).
///
/// - Lists with ListObjectsV2, following continuation tokens.
/// - Writes conditionally with `If-None-Match: *` and `If-Match`; deletes
///   with `If-Match`. A 412 is [PreconditionFailed]; a 409 (a conditional
///   write racing another) is retried, then reported the same way.
/// - 429, 5xx and network errors are retried with exponential backoff, then
///   reported as [StorageUnavailable]; 403 is [StorageAccessDenied].
/// - [onLog] gets one line per request (method, key, status, time) and
///   never a body, header or credential.
class S3Backend implements StorageBackend {
  S3Backend({
    required this.config,
    required AwsCredentials credentials,
    http.Client? client,
    DateTime Function()? clock,
    this.maxAttempts = 5,
    this.backoff = defaultBackoff,
    this.onLog,
  }) : _signer = SigV4Signer(credentials: credentials, region: config.region),
       _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final S3Config config;
  final SigV4Signer _signer;
  final http.Client _client;
  final DateTime Function() _clock;

  /// Tries per request, including the first.
  final int maxAttempts;

  /// The wait before retry number `attempt` (1-based).
  final Duration Function(int attempt) backoff;
  final void Function(String line)? onLog;

  static Duration defaultBackoff(int attempt) =>
      Duration(milliseconds: 200 * (1 << (attempt - 1)).clamp(1, 32));

  /// Closes the HTTP client.
  void close() => _client.close();

  @override
  Future<List<RemoteObject>> list(String prefix, {String? startAfter}) async {
    StorageKeys.checkPrefix(prefix);
    final objects = <RemoteObject>[];
    String? token;
    do {
      final response = await _send(
        'GET',
        config.url(
          query: {
            'list-type': '2',
            'prefix': prefix,
            'start-after': ?startAfter,
            'continuation-token': ?token,
          },
        ),
        logKey: 'list $prefix',
      );
      _expectOk(response, 'list $prefix');
      final page = ListPage.parse(response.body);
      objects.addAll(page.objects.where((o) => StorageKeys.isValid(o.key)));
      token = page.nextToken;
    } while (token != null);
    return objects..sort((a, b) => a.key.compareTo(b.key));
  }

  @override
  Future<RemoteBody?> get(String key) async {
    StorageKeys.check(key);
    final response = await _send('GET', config.url(key: key), logKey: key);
    if (response.statusCode == 404 && !_isNoSuchBucket(response)) return null;
    _expectOk(response, key);
    return RemoteBody(response.bodyBytes, _etag(response, key));
  }

  @override
  Future<String> put(
    String key,
    Uint8List bytes, {
    WriteCondition condition = const WriteCondition.always(),
  }) async {
    StorageKeys.check(key);
    final response = await _send(
      'PUT',
      config.url(key: key),
      body: bytes,
      headers: {
        'content-type': 'application/octet-stream',
        ...switch (condition) {
          WriteAlways() => const <String, String>{},
          WriteIfAbsent() => const {'if-none-match': '*'},
          WriteIfMatch(:final etag) => {'if-match': etag},
        },
      },
      logKey: key,
    );
    // If-Match on a key that's gone: S3 and MinIO answer 404, but for the
    // caller it's the same lost race as a 412.
    if (response.statusCode == 404 &&
        condition is WriteIfMatch &&
        !_isNoSuchBucket(response)) {
      throw PreconditionFailed('$key changed');
    }
    _expectOk(response, key);
    return _etag(response, key);
  }

  @override
  Future<void> delete(String key, {String? ifMatch}) async {
    StorageKeys.check(key);
    if (ifMatch != null) {
      // Some stores (MinIO) ignore If-Match on DELETE, so check the etag
      // first too. Where If-Match is honoured the delete stays atomic;
      // elsewhere a write landing between the two requests can still be
      // lost, which the capability probe (P2-04) reports.
      final head = await _send('HEAD', config.url(key: key), logKey: key);
      if (head.statusCode == 404 && !_isNoSuchBucket(head)) {
        throw PreconditionFailed('$key changed');
      }
      _expectOk(head, key);
      if (head.headers['etag'] != ifMatch) {
        throw PreconditionFailed('$key changed');
      }
    }
    final response = await _send(
      'DELETE',
      config.url(key: key),
      headers: {'if-match': ?ifMatch},
      logKey: key,
    );
    // Deleting what isn't there is fine, unless an etag was promised.
    if (response.statusCode == 404 && ifMatch == null) return;
    if (response.statusCode == 404) throw PreconditionFailed('$key changed');
    _expectOk(response, key);
  }

  /// Checks the bucket can be read and written, and that it refuses to
  /// overwrite an object on `If-None-Match: *` (which sync relies on).
  /// Returns problems, one sentence each; empty means ready.
  Future<List<String>> testConnection(String prefix) async {
    final key = '${prefix.endsWith('/') ? prefix : '$prefix/'}probe.bin';
    final problems = <String>[];
    try {
      await put(key, Uint8List.fromList('one'.codeUnits));
      try {
        await put(key, Uint8List.fromList('two'.codeUnits), condition: const WriteCondition.ifAbsent());
        problems.add('The store overwrote an object despite If-None-Match: *, so two devices could collide.');
      } on PreconditionFailed {
        // Expected.
      }
      if ((await get(key)) == null) problems.add('An object written was not readable.');
    } on StorageException catch (e) {
      problems.add(e.message);
    } finally {
      try {
        await delete(key);
      } on StorageException {
        // Best effort.
      }
    }
    return problems;
  }

  /// Sends a signed request, retrying throttling, server errors, races
  /// on conditional writes (409) and network failures.
  Future<http.Response> _send(
    String method,
    Uri url, {
    Uint8List? body,
    Map<String, String> headers = const {},
    required String logKey,
  }) async {
    final payload = body ?? Uint8List(0);
    final payloadHash = SigV4Signer.hexSha256(payload);
    for (var attempt = 1; ; attempt++) {
      final started = DateTime.now();
      http.Response? response;
      Object? failure;
      try {
        final request = http.Request(method, url)
          ..headers.addAll(
            _signer.sign(
              method: method,
              uri: url,
              headers: headers,
              payloadHash: payloadHash,
              now: _clock(),
            )..remove('host'),
          )
          ..bodyBytes = payload;
        response = await http.Response.fromStream(await _client.send(request));
      } on SocketException catch (e) {
        failure = e;
      } on HttpException catch (e) {
        failure = e;
      } on http.ClientException catch (e) {
        failure = e;
      } on TimeoutException catch (e) {
        failure = e;
      }
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final status = response?.statusCode;
      onLog?.call(
        '$method $logKey ${status ?? 'network error'} ${elapsed}ms'
        '${attempt > 1 ? ' (try $attempt)' : ''}',
      );
      final retryable =
          failure != null ||
          status == 409 ||
          status == 429 ||
          (status != null && status >= 500);
      if (!retryable) return response!;
      if (attempt >= maxAttempts) {
        if (status == 409) {
          throw PreconditionFailed('$logKey: conditional write conflict');
        }
        throw StorageUnavailable(
          '$logKey: ${status != null ? 'HTTP $status' : 'network error'} '
          'after $attempt tries',
        );
      }
      await Future<void>.delayed(backoff(attempt));
    }
  }

  void _expectOk(http.Response response, String key) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    final code = _errorCode(response.body);
    throw switch (status) {
      412 => PreconditionFailed('$key changed'),
      403 || 401 => StorageAccessDenied('$key: ${code ?? 'access denied'}'),
      404 => StorageNotFound('${config.bucket}: ${code ?? 'not found'}'),
      _ => StorageUnavailable(
        '$key: HTTP $status${code == null ? '' : ' $code'}',
      ),
    };
  }

  static bool _isNoSuchBucket(http.Response response) =>
      _errorCode(response.body) == 'NoSuchBucket';

  static String? _errorCode(String body) =>
      RegExp(r'<Code>([^<]+)</Code>').firstMatch(body)?.group(1);

  static String _etag(http.Response response, String key) {
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw StorageUnavailable('$key: the server sent no ETag');
    }
    return etag;
  }
}

/// One page of a ListObjectsV2 response.
@visibleForTesting
class ListPage {
  ListPage(this.objects, this.nextToken);

  final List<RemoteObject> objects;

  /// Set while the listing is truncated.
  final String? nextToken;

  static final _contents = RegExp(r'<Contents>([\s\S]*?)</Contents>');

  static ListPage parse(String xml) {
    String? field(String block, String name) =>
        RegExp('<$name>([\\s\\S]*?)</$name>').firstMatch(block)?.group(1);
    final objects = [
      for (final match in _contents.allMatches(xml))
        RemoteObject(
          key: _unescape(field(match.group(1)!, 'Key') ?? ''),
          etag: _unescape(field(match.group(1)!, 'ETag') ?? ''),
          size: int.tryParse(field(match.group(1)!, 'Size') ?? '') ?? 0,
        ),
    ];
    final truncated = field(xml, 'IsTruncated') == 'true';
    final token = field(xml, 'NextContinuationToken');
    return ListPage(objects, truncated ? _unescape(token ?? '') : null);
  }

  static String _unescape(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#34;', '"')
      .replaceAll('&amp;', '&');
}
