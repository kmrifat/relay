// Adapted from DevVault (packages/vault_core and vault_s3), same author.
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Where a team syncs to: an R2/S3 bucket, or a shared folder. Keys are
/// `/`-separated paths such as `relay/TEAM/ops/DEVICE/000000000001.op`
/// (docs/format/sync.md). Values are opaque bytes; everything but
/// `team.json` and member public keys is encrypted before it gets here.
abstract interface class StorageBackend {
  /// Every object whose key starts with [prefix] (and sorts after
  /// [startAfter], when given), sorted by key. Paging is the backend's
  /// business; this returns the whole listing.
  Future<List<RemoteObject>> list(String prefix, {String? startAfter});

  /// The object at [key], or null when there is none.
  Future<RemoteBody?> get(String key);

  /// Writes [bytes] at [key] if [condition] holds and returns the new etag.
  /// Throws [PreconditionFailed] when it doesn't.
  Future<String> put(
    String key,
    Uint8List bytes, {
    WriteCondition condition = const WriteCondition.always(),
  });

  /// Removes [key]. Deleting a missing key is not an error unless
  /// [ifMatch] is given, which must equal the current etag.
  Future<void> delete(String key, {String? ifMatch});
}

/// A stored object as a listing reports it.
@immutable
class RemoteObject {
  const RemoteObject({
    required this.key,
    required this.etag,
    required this.size,
  });

  final String key;

  /// Changes whenever the bytes change; compared as an opaque string.
  final String etag;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is RemoteObject &&
      other.key == key &&
      other.etag == etag &&
      other.size == size;

  @override
  int get hashCode => Object.hash(key, etag, size);

  @override
  String toString() => 'RemoteObject($key, $etag, $size bytes)';
}

/// An object's bytes and the etag they were read at.
@immutable
class RemoteBody {
  const RemoteBody(this.bytes, this.etag);

  final Uint8List bytes;
  final String etag;

  /// Never prints the bytes.
  @override
  String toString() => 'RemoteBody(${bytes.length} bytes, $etag)';
}

/// When a [StorageBackend.put] may go ahead.
@immutable
sealed class WriteCondition {
  const WriteCondition();

  /// Unconditionally (last writer wins). Only for objects that can't race:
  /// immutable blobs under a fresh id.
  const factory WriteCondition.always() = WriteAlways;

  /// Only if nothing exists at the key yet (`If-None-Match: *`).
  const factory WriteCondition.ifAbsent() = WriteIfAbsent;

  /// Only if the object is still at [etag] (`If-Match`).
  const factory WriteCondition.ifMatch(String etag) = WriteIfMatch;
}

final class WriteAlways extends WriteCondition {
  const WriteAlways();
}

final class WriteIfAbsent extends WriteCondition {
  const WriteIfAbsent();
}

final class WriteIfMatch extends WriteCondition {
  const WriteIfMatch(this.etag);

  final String etag;
}

/// Something went wrong talking to storage. Messages never include object
/// bytes or credentials.
sealed class StorageException implements Exception {
  const StorageException(this.message);

  final String message;

  /// Whether trying the same request again later may succeed.
  bool get isRetryable => false;

  @override
  String toString() => '$runtimeType: $message';
}

/// A conditional write or delete lost a race: someone else changed the
/// object first (HTTP 412, or 409 on some providers). Pull, merge, retry.
final class PreconditionFailed extends StorageException {
  const PreconditionFailed(super.message);
}

/// The credentials aren't allowed to do this (HTTP 403), or are wrong.
final class StorageAccessDenied extends StorageException {
  const StorageAccessDenied(super.message);
}

/// The bucket or endpoint doesn't exist (HTTP 404 on the bucket, DNS).
final class StorageNotFound extends StorageException {
  const StorageNotFound(super.message);
}

/// Offline, throttled (429) or a server error (5xx) that didn't clear up
/// after retries.
final class StorageUnavailable extends StorageException {
  const StorageUnavailable(super.message);

  @override
  bool get isRetryable => true;
}

/// Keys are relative, `/`-separated, and made of a safe alphabet, so no
/// backend can be steered outside its root (`..`, absolute paths).
abstract final class StorageKeys {
  static final _segment = RegExp(r'^[A-Za-z0-9._-]+$');

  static bool isValid(String key) {
    if (key.isEmpty || key.length > 512) return false;
    final segments = key.split('/');
    return segments.every(
      (s) => s.isNotEmpty && s != '.' && s != '..' && _segment.hasMatch(s),
    );
  }

  /// Throws [ArgumentError] for an invalid key.
  static String check(String key) {
    if (!isValid(key)) {
      throw ArgumentError.value(key, 'key', 'not a valid storage key');
    }
    return key;
  }

  /// A prefix is a key, a key followed by `/`, or empty (everything).
  static String checkPrefix(String prefix) {
    if (prefix.isEmpty) return prefix;
    final trimmed = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    check(trimmed);
    return prefix;
  }
}
