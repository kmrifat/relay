import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'hlc.dart';
import 'ids.dart';
import 'models.dart';

/// One change to one record: the fields that were set (a `null` value
/// removes the field), with the timestamp and device that set them.
class Op {
  Op({
    required this.hlc,
    required this.kind,
    required this.id,
    required this.patch,
    this.seq,
  });

  factory Op.fromJson(Map<String, Object?> j) => Op(
    hlc: Hlc.parse(j['hlc'] as String),
    kind: j['kind'] as String,
    id: j['id'] as String,
    patch: (j['patch'] as Map).cast<String, Object?>(),
  );

  final Hlc hlc;
  final String kind;
  final String id;
  final Map<String, Object?> patch;

  /// Local row number, for [Store.markSynced]. Not part of the wire form.
  final int? seq;

  Map<String, Object?> toJson() => {
    'hlc': hlc.toString(),
    'kind': kind,
    'id': id,
    'patch': patch,
  };
}

/// Emitted after a record changes, locally or from sync.
class EntityChange {
  EntityChange(this.entity, {this.remote = false});
  final Entity entity;
  final bool remote;
}

/// The local database: every record, the op log, and run events.
///
/// Records live in one table keyed by (kind, id) with their JSON. Every
/// write goes through [patch], which stores the op and, per field, the
/// timestamp that last set it. Remote ops merge with [applyRemote]: a field
/// takes the remote value only if the remote timestamp is newer.
class Store {
  Store._(this._db, this.deviceId) : clock = HlcClock(deviceId) {
    _migrate();
    final last = _db.select('SELECT hlc FROM ops ORDER BY hlc DESC LIMIT 1');
    if (last.isNotEmpty) clock.receive(Hlc.parse(last.first['hlc'] as String));
  }

  factory Store.open(String path, {required String deviceId}) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;');
    return Store._(db, deviceId);
  }

  factory Store.memory({String deviceId = 'test'}) =>
      Store._(sqlite3.openInMemory(), deviceId);

  final Database _db;
  final String deviceId;
  final HlcClock clock;
  final _changes = StreamController<EntityChange>.broadcast(sync: true);
  final _events = StreamController<RunEvent>.broadcast(sync: true);

  Stream<EntityChange> get changes => _changes.stream;
  Stream<RunEvent> get runEvents => _events.stream;

  static const _schemaVersion = 1;

  void _migrate() {
    final v = _db.select('PRAGMA user_version').first.values.first as int;
    if (v >= _schemaVersion) return;
    _db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        json TEXT NOT NULL,
        project_id TEXT,
        task_id TEXT,
        deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (kind, id)
      );
      CREATE INDEX IF NOT EXISTS records_project ON records(kind, project_id);
      CREATE INDEX IF NOT EXISTS records_task ON records(kind, task_id);
      CREATE TABLE IF NOT EXISTS field_clock (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        field TEXT NOT NULL,
        hlc TEXT NOT NULL,
        PRIMARY KEY (kind, id, field)
      );
      CREATE TABLE IF NOT EXISTS ops (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        hlc TEXT NOT NULL,
        device TEXT NOT NULL,
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        patch TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS ops_hlc ON ops(hlc);
      CREATE TABLE IF NOT EXISTS run_events (
        run_id TEXT NOT NULL,
        seq INTEGER NOT NULL,
        json TEXT NOT NULL,
        PRIMARY KEY (run_id, seq)
      );
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      PRAGMA user_version = $_schemaVersion;
    ''');
  }

  void close() {
    _changes.close();
    _events.close();
    _db.dispose();
  }

  // ---------------------------------------------------------------- records

  /// Creates a record. [data] may carry an `id`; otherwise one is made.
  T create<T extends Entity>(String kind, Map<String, Object?> data) {
    final id = (data['id'] as String?) ?? newId();
    final now = DateTime.now().toUtc().toIso8601String();
    return patch<T>(kind, id, {
      ...data,
      'id': id,
      'createdAt': data['createdAt'] ?? now,
      // A chosen id may be one that was deleted (an agent named again).
      if (data['id'] != null) 'deleted': null,
    });
  }

  /// Sets fields on a record (creating it if needed). `null` removes a field.
  T patch<T extends Entity>(String kind, String id, Map<String, Object?> fields) {
    final hlc = clock.now();
    final p = {...fields, 'updatedAt': DateTime.now().toUtc().toIso8601String()};
    late T result;
    _db.execute('BEGIN');
    try {
      result = _apply(kind, id, p, hlc, force: true) as T;
      _db.execute(
        'INSERT INTO ops (hlc, device, kind, id, patch) VALUES (?, ?, ?, ?, ?)',
        [hlc.toString(), deviceId, kind, id, jsonEncode(p)],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _changes.add(EntityChange(result));
    return result;
  }

  /// Merges an op from another device. Fields older than what we have lose.
  Entity applyRemote(Op op) {
    clock.receive(op.hlc);
    late Entity result;
    _db.execute('BEGIN');
    try {
      result = _apply(op.kind, op.id, op.patch, op.hlc, force: false);
      _db.execute(
        'INSERT INTO ops (hlc, device, kind, id, patch, synced) VALUES (?, ?, ?, ?, ?, 1)',
        [op.hlc.toString(), op.hlc.node, op.kind, op.id, jsonEncode(op.patch)],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _changes.add(EntityChange(result, remote: true));
    return result;
  }

  Entity _apply(String kind, String id, Map<String, Object?> patch, Hlc hlc, {required bool force}) {
    final row = _db.select('SELECT json FROM records WHERE kind = ? AND id = ?', [kind, id]);
    final data = row.isEmpty
        ? <String, Object?>{'id': id}
        : (jsonDecode(row.first['json'] as String) as Map).cast<String, Object?>();
    for (final MapEntry(:key, :value) in patch.entries) {
      if (!force) {
        final clockRow = _db.select(
          'SELECT hlc FROM field_clock WHERE kind = ? AND id = ? AND field = ?',
          [kind, id, key],
        );
        if (clockRow.isNotEmpty && (clockRow.first['hlc'] as String).compareTo(hlc.toString()) >= 0) {
          continue;
        }
      }
      if (value == null) {
        data.remove(key);
      } else {
        data[key] = value;
      }
      _db.execute(
        'INSERT INTO field_clock (kind, id, field, hlc) VALUES (?, ?, ?, ?) '
        'ON CONFLICT(kind, id, field) DO UPDATE SET hlc = excluded.hlc',
        [kind, id, key, hlc.toString()],
      );
    }
    _db.execute(
      'INSERT INTO records (kind, id, json, project_id, task_id, deleted) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(kind, id) DO UPDATE SET json = excluded.json, project_id = excluded.project_id, '
      'task_id = excluded.task_id, deleted = excluded.deleted',
      [
        kind,
        id,
        jsonEncode(data),
        data['projectId'] as String?,
        // Messages are looked up by channel; they may also name a task.
        (kind == Kind.message ? data['channelId'] : data['taskId']) as String?,
        data['deleted'] == true ? 1 : 0,
      ],
    );
    return entityFrom(kind, data);
  }

  T? get<T extends Entity>(String kind, String id) {
    final row = _db.select('SELECT json FROM records WHERE kind = ? AND id = ? AND deleted = 0', [kind, id]);
    if (row.isEmpty) return null;
    return entityFrom(kind, (jsonDecode(row.first['json'] as String) as Map).cast()) as T;
  }

  /// [channelId] filters messages (it shares the indexed task column).
  List<T> list<T extends Entity>(String kind, {String? projectId, String? taskId, String? channelId}) {
    taskId ??= channelId;
    final where = StringBuffer('kind = ? AND deleted = 0');
    final args = <Object?>[kind];
    if (projectId != null) {
      where.write(' AND project_id = ?');
      args.add(projectId);
    }
    if (taskId != null) {
      where.write(' AND task_id = ?');
      args.add(taskId);
    }
    return _db
        .select('SELECT json FROM records WHERE $where ORDER BY id', args)
        .map((r) => entityFrom(kind, (jsonDecode(r['json'] as String) as Map).cast()) as T)
        .toList();
  }

  void delete(String kind, String id) => patch(kind, id, {'deleted': true});

  /// Ops not yet uploaded, oldest first (for sync, M6).
  List<Op> pendingOps({int limit = 500}) => _db
      .select('SELECT seq, hlc, kind, id, patch FROM ops WHERE synced = 0 ORDER BY seq LIMIT ?', [limit])
      .map((r) => Op(
            seq: r['seq'] as int,
            hlc: Hlc.parse(r['hlc'] as String),
            kind: r['kind'] as String,
            id: r['id'] as String,
            patch: (jsonDecode(r['patch'] as String) as Map).cast(),
          ))
      .toList();

  int get pendingCount => _db.select('SELECT COUNT(*) AS n FROM ops WHERE synced = 0').first['n'] as int;

  /// Marks ops as uploaded (or as never needing upload).
  void markSynced(Iterable<int> seqs) {
    final list = seqs.toList();
    if (list.isEmpty) return;
    _db.execute('BEGIN');
    try {
      final stmt = _db.prepare('UPDATE ops SET synced = 1 WHERE seq = ?');
      for (final s in list) {
        stmt.execute([s]);
      }
      stmt.dispose();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int get opCount => _db.select('SELECT COUNT(*) AS n FROM ops').first['n'] as int;

  // ---------------------------------------------------------------- tasks

  /// Creates a task with the project's next number.
  Task createTask(String projectId, Map<String, Object?> data) {
    final project = get<Project>(Kind.project, projectId);
    if (project == null) throw ArgumentError('No project $projectId');
    final number = project.nextNumber;
    patch<Project>(Kind.project, projectId, {'nextNumber': number + 1});
    final columnTasks = list<Task>(Kind.task, projectId: projectId)
        .where((t) => t.status == (data['status'] ?? TaskStatus.backlog));
    final maxPos = columnTasks.fold<double>(0, (m, t) => t.position > m ? t.position : m);
    return create<Task>(Kind.task, {
      'status': TaskStatus.backlog,
      'position': maxPos + 1,
      ...data,
      'projectId': projectId,
      'number': number,
    });
  }

  // ---------------------------------------------------------------- run events

  RunEvent appendEvent(String runId, String type, [Map<String, Object?> data = const {}]) {
    final last = _db.select('SELECT MAX(seq) AS s FROM run_events WHERE run_id = ?', [runId]);
    final seq = ((last.first['s'] as int?) ?? 0) + 1;
    final e = RunEvent(runId: runId, seq: seq, at: DateTime.now().toUtc(), type: type, data: data);
    _db.execute('INSERT INTO run_events (run_id, seq, json) VALUES (?, ?, ?)', [runId, seq, jsonEncode(e.toJson())]);
    _events.add(e);
    return e;
  }

  /// Adds events of a run on another device (live from a teammate). Ones
  /// already here are skipped; new ones go out on [runEvents].
  void importEvents(Iterable<RunEvent> events) {
    for (final e in events) {
      _db.execute('INSERT OR IGNORE INTO run_events (run_id, seq, json) VALUES (?, ?, ?)', [e.runId, e.seq, jsonEncode(e.toJson())]);
      if (_db.updatedRows > 0) _events.add(e);
    }
  }

  List<RunEvent> events(String runId, {int after = 0, int? limit}) => _db
      .select(
        'SELECT json FROM run_events WHERE run_id = ? AND seq > ? ORDER BY seq ${limit != null ? 'LIMIT $limit' : ''}',
        [runId, after],
      )
      .map((r) => RunEvent.fromJson((jsonDecode(r['json'] as String) as Map).cast()))
      .toList();

  // ---------------------------------------------------------------- meta

  String? meta(String key) {
    final r = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  /// Every meta key under [prefix], without the prefix.
  Map<String, String> metaWithPrefix(String prefix) => {
    for (final r in _db.select('SELECT key, value FROM meta WHERE key LIKE ?', ['${prefix.replaceAll('%', '')}%']))
      (r['key'] as String).substring(prefix.length): r['value'] as String,
  };

  void setMeta(String key, String value) => _db.execute(
    'INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  void deleteMeta(String key) => _db.execute('DELETE FROM meta WHERE key = ?', [key]);
}
