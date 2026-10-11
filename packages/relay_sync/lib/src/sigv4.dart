// Adapted from DevVault (packages/vault_core and vault_s3), same author.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// An access key pair. [toString] never shows the secret.
@immutable
class AwsCredentials {
  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  final String accessKeyId;
  final String secretAccessKey;

  /// For temporary credentials (STS); sent as `x-amz-security-token`.
  final String? sessionToken;

  @override
  String toString() => 'AwsCredentials($accessKeyId, secret hidden)';
}

/// The SHA-256 of an empty body, in hex.
const String emptyPayloadHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/// Signs HTTP requests with AWS Signature Version 4.
///
/// Used for S3 and S3-compatible stores (R2 signs with region `auto`).
/// The body is always hashed into the signature (`x-amz-content-sha256`),
/// never sent as `UNSIGNED-PAYLOAD`.
class SigV4Signer {
  SigV4Signer({
    required this.credentials,
    required this.region,
    this.service = 's3',
  });

  final AwsCredentials credentials;
  final String region;
  final String service;

  static String hexSha256(List<int> bytes) => sha256.convert(bytes).toString();

  /// The headers to send with the request: [headers] plus `host`,
  /// `x-amz-date`, `Authorization` and, for S3, `x-amz-content-sha256`.
  ///
  /// [uri]'s path is signed as given: callers build it with
  /// [encodePath], which encodes each segment once, as S3 expects.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    String payloadHash = emptyPayloadHash,
    required DateTime now,
  }) {
    final time = now.toUtc();
    final amzDate = _amzDate(time);
    final date = amzDate.substring(0, 8);
    final all = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries)
        key.toLowerCase(): value,
      'host': _host(uri),
      'x-amz-date': amzDate,
      if (service == 's3') 'x-amz-content-sha256': payloadHash,
      'x-amz-security-token': ?credentials.sessionToken,
    };
    final names = all.keys.toList()..sort();
    final canonicalHeaders = [
      for (final name in names) '$name:${_trimValue(all[name]!)}\n',
    ].join();
    final signedHeaders = names.join(';');
    final canonicalRequest = [
      method.toUpperCase(),
      uri.path.isEmpty ? '/' : uri.path,
      _canonicalQuery(uri.query),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      hexSha256(utf8.encode(canonicalRequest)),
    ].join('\n');
    final signature = Hmac(
      sha256,
      _signingKey(date),
    ).convert(utf8.encode(stringToSign)).toString();

    return {
      ...all,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$scope, '
          'SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  Uint8List _signingKey(String date) {
    List<int> mac(List<int> key, String data) =>
        Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    final kDate = mac(utf8.encode('AWS4${credentials.secretAccessKey}'), date);
    final kRegion = mac(kDate, region);
    final kService = mac(kRegion, service);
    return Uint8List.fromList(mac(kService, 'aws4_request'));
  }

  static String _amzDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
        'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  }

  static String _host(Uri uri) {
    final defaultPort =
        (uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80);
    return uri.hasPort && !defaultPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  /// Header values: surrounding space trimmed, inner runs collapsed.
  static String _trimValue(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Query parameters re-encoded the AWS way and sorted by name, then value.
  static String _canonicalQuery(String query) {
    if (query.isEmpty) return '';
    final pairs =
        <(String, String)>[
          for (final part in query.split('&'))
            if (part.isNotEmpty)
              switch (part.indexOf('=')) {
                -1 => (encode(_decode(part)), ''),
                final i => (
                  encode(_decode(part.substring(0, i))),
                  encode(_decode(part.substring(i + 1))),
                ),
              },
        ]..sort((a, b) {
          final byName = a.$1.compareTo(b.$1);
          return byName != 0 ? byName : a.$2.compareTo(b.$2);
        });
    return pairs.map((p) => '${p.$1}=${p.$2}').join('&');
  }

  static String _decode(String text) =>
      Uri.decodeQueryComponent(text.replaceAll('+', '%2B'));

  /// RFC 3986 encoding as AWS wants it: everything but `A-Z a-z 0-9 - _ . ~`
  /// is `%XX` (uppercase hex), including `/` unless [keepSlash].
  static String encode(String text, {bool keepSlash = false}) {
    final out = StringBuffer();
    for (final byte in utf8.encode(text)) {
      final c = String.fromCharCode(byte);
      final unreserved =
          (byte >= 0x41 && byte <= 0x5A) ||
          (byte >= 0x61 && byte <= 0x7A) ||
          (byte >= 0x30 && byte <= 0x39) ||
          c == '-' ||
          c == '_' ||
          c == '.' ||
          c == '~' ||
          (keepSlash && c == '/');
      out.write(
        unreserved
            ? c
            : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
      );
    }
    return out.toString();
  }

  /// A path from unencoded segments, each encoded once: `['b', 'a b']` →
  /// `/b/a%20b`.
  static String encodePath(Iterable<String> segments) =>
      '/${segments.map(encode).join('/')}';
}
