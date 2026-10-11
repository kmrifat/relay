// Adapted from DevVault (packages/vault_core and vault_s3), same author.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;

import 'storage.dart';

/// A [StorageBackend] on a folder: for tests, and for teams that sync
/// through a folder another tool already syncs (iCloud Drive, Dropbox).
///
/// Etags are the SHA-256 of the bytes. Operations run one at a time, so a
/// conditional write is atomic within this process; it is not a lock
/// between processes.
class FolderBackend implements StorageBackend {
  FolderBackend(this.root);

  final Directory root;

  /// Partial writes, skipped by [list] and never visible under a key.
  static const _tempPrefix = '.tmp-';

  Future<void> _queue = Future.value();

  /// Runs [action] after every earlier operation has finished.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  File _file(String key) => File('${root.path}/${StorageKeys.check(key)}');

  static String _etag(List<int> bytes) =>
      '"${hashes.sha256.convert(bytes).toString().substring(0, 32)}"';

  @override
  Future<List<RemoteObject>> list(String prefix, {String? startAfter}) => _serial(() async {
    StorageKeys.checkPrefix(prefix);
    if (!root.existsSync()) return const [];
    final objects = <RemoteObject>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final key = entity.path
          .substring(root.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final name = key.split('/').last;
      if (name.startsWith(_tempPrefix) || !key.startsWith(prefix)) continue;
      if (startAfter != null && key.compareTo(startAfter) <= 0) continue;
      if (!StorageKeys.isValid(key)) continue;
      final bytes = await entity.readAsBytes();
      objects.add(
        RemoteObject(key: key, etag: _etag(bytes), size: bytes.length),
      );
    }
    return objects..sort((a, b) => a.key.compareTo(b.key));
  });

  @override
  Future<RemoteBody?> get(String key) => _serial(() async {
    final file = _file(key);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    return RemoteBody(bytes, _etag(bytes));
  });

  @override
  Future<String> put(
    String key,
    Uint8List bytes, {
    WriteCondition condition = const WriteCondition.always(),
  }) => _serial(() async {
    final file = _file(key);
    final exists = file.existsSync();
    switch (condition) {
      case WriteAlways():
        break;
      case WriteIfAbsent():
        if (exists) throw PreconditionFailed('$key already exists');
      case WriteIfMatch(:final etag):
        if (!exists || _etag(await file.readAsBytes()) != etag) {
          throw PreconditionFailed('$key changed');
        }
    }
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.parent.path}/$_tempPrefix${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    return _etag(bytes);
  });

  @override
  Future<void> delete(String key, {String? ifMatch}) => _serial(() async {
    final file = _file(key);
    final exists = file.existsSync();
    if (ifMatch != null &&
        (!exists || _etag(await file.readAsBytes()) != ifMatch)) {
      throw PreconditionFailed('$key changed');
    }
    if (exists) await file.delete();
  });
}
