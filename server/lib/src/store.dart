import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// One versioned piece of client data.
///
/// Everything a client syncs is expressed in these terms, so that adding a new
/// kind of local data never requires a change here. [updatedAt] is the client's
/// own timestamp in microseconds; ties are broken by [deviceId] so that every
/// replica reaches the same answer without needing to talk to the others.
class SyncRecord {
  const SyncRecord({
    required this.namespace,
    required this.id,
    required this.payload,
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
  });

  final String namespace;
  final String id;
  final Map<String, dynamic> payload;
  final int updatedAt;
  final String deviceId;
  final bool deleted;

  static SyncRecord? fromJson(Map<String, dynamic> json) {
    final namespace = (json['namespace'] as String?)?.trim();
    final id = (json['id'] as String?)?.trim();
    final deviceId = (json['deviceId'] as String?)?.trim();
    if (namespace == null || namespace.isEmpty) return null;
    if (id == null || id.isEmpty) return null;
    final rawUpdatedAt = json['updatedAt'];
    final updatedAt = switch (rawUpdatedAt) {
      int v => v,
      num v => v.toInt(),
      String v => int.tryParse(v.trim()) ?? 0,
      _ => 0,
    };
    final payload = json['payload'];
    return SyncRecord(
      namespace: namespace,
      id: id,
      payload: payload is Map
          ? payload.cast<String, dynamic>()
          : const <String, dynamic>{},
      updatedAt: updatedAt,
      deviceId: deviceId ?? '',
      deleted: json['deleted'] == true,
    );
  }

  Map<String, dynamic> toJson({int? rev}) => {
    'namespace': namespace,
    'id': id,
    'payload': payload,
    'updatedAt': updatedAt,
    'deviceId': deviceId,
    if (deleted) 'deleted': true,
    if (rev != null) 'rev': rev,
  };
}

/// A record as the server currently holds it.
class StoredRecord {
  const StoredRecord({required this.record, required this.rev});

  final SyncRecord record;
  final int rev;
}

/// SQLite-backed record store.
///
/// SQLite rather than files because the whole point of this server is to be
/// the single ordering authority: writes must be serialized and survive a
/// crash, and a WAL-mode database gives both without an external service.
class SyncStore {
  SyncStore._(this._db, this._blobRoot);

  final Database _db;
  final Directory _blobRoot;

  static SyncStore open(String dataDir) {
    final blobRoot = Directory('$dataDir/blobs');
    blobRoot.createSync(recursive: true);
    final db = sqlite3.open('$dataDir/sync.sqlite');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('''
      CREATE TABLE IF NOT EXISTS records (
        namespace  TEXT    NOT NULL,
        id         TEXT    NOT NULL,
        payload    TEXT    NOT NULL,
        updated_at INTEGER NOT NULL,
        device_id  TEXT    NOT NULL,
        deleted    INTEGER NOT NULL DEFAULT 0,
        rev        INTEGER NOT NULL,
        PRIMARY KEY (namespace, id)
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_records_rev ON records (rev);',
    );
    db.execute('''
      CREATE TABLE IF NOT EXISTS blobs (
        hash       TEXT PRIMARY KEY,
        size       INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    return SyncStore._(db, blobRoot);
  }

  /// Current server revision. Clients poll with the value they last saw.
  int get currentRev {
    final rows = _db.select(
      "SELECT value FROM meta WHERE key = 'rev';",
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  int _bumpRev() {
    final next = currentRev + 1;
    _db.execute(
      "INSERT INTO meta (key, value) VALUES ('rev', ?) "
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value;',
      [next.toString()],
    );
    return next;
  }

  /// Records with `rev > sinceRev`, oldest first.
  ///
  /// Paged by revision rather than offset so that a client catching up on a
  /// large history makes progress even while other devices keep writing.
  List<StoredRecord> changesSince(int sinceRev, {int limit = 500}) {
    final rows = _db.select(
      'SELECT namespace, id, payload, updated_at, device_id, deleted, rev '
      'FROM records WHERE rev > ? ORDER BY rev ASC LIMIT ?;',
      [sinceRev, limit],
    );
    return rows.map(_storedFromRow).toList(growable: false);
  }

  StoredRecord _storedFromRow(Row row) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(row['payload'] as String);
      payload = decoded is Map
          ? decoded.cast<String, dynamic>()
          : const <String, dynamic>{};
    } catch (_) {
      payload = const <String, dynamic>{};
    }
    return StoredRecord(
      record: SyncRecord(
        namespace: row['namespace'] as String,
        id: row['id'] as String,
        payload: payload,
        updatedAt: row['updated_at'] as int,
        deviceId: row['device_id'] as String,
        deleted: (row['deleted'] as int) != 0,
      ),
      rev: row['rev'] as int,
    );
  }

  /// Outcome of reconciling one incoming record.
  static const String accepted = 'accepted';
  static const String superseded = 'superseded';
  static const String stale = 'stale';

  /// Merges [incoming] into the store, last-writer-wins.
  ///
  /// Returns the outcome and, when the incoming record did not win, the version
  /// the server kept -- the client needs it to correct itself, which is what
  /// stops two devices from disagreeing indefinitely.
  ({String outcome, StoredRecord? current}) merge(SyncRecord incoming) {
    final existing = _db.select(
      'SELECT namespace, id, payload, updated_at, device_id, deleted, rev '
      'FROM records WHERE namespace = ? AND id = ?;',
      [incoming.namespace, incoming.id],
    );

    if (existing.isEmpty) {
      final rev = _bumpRev();
      _write(incoming, rev);
      return (outcome: accepted, current: null);
    }

    final current = _storedFromRow(existing.first);
    final winner = _wins(incoming, current.record);
    if (winner == 0) {
      // Byte-identical after normalization: nothing to record.
      return (outcome: superseded, current: current);
    }
    if (winner < 0) {
      return (outcome: stale, current: current);
    }
    final rev = _bumpRev();
    _write(incoming, rev);
    return (outcome: accepted, current: null);
  }

  /// 1 when [incoming] wins, -1 when [current] does, 0 when they agree.
  ///
  /// Comparing the device id on a timestamp tie is what makes the outcome
  /// deterministic: both replicas compute the same winner without coordinating,
  /// so they cannot each believe the other's value lost.
  static int _wins(SyncRecord incoming, SyncRecord current) {
    if (incoming.updatedAt != current.updatedAt) {
      return incoming.updatedAt > current.updatedAt ? 1 : -1;
    }
    if (incoming.deleted != current.deleted) {
      // A delete and an edit at the same instant: the delete wins, so that a
      // removal is never silently undone by an equally-timed edit.
      return incoming.deleted ? 1 : -1;
    }
    if (incoming.deviceId == current.deviceId) {
      return _payloadEquals(incoming, current) ? 0 : 1;
    }
    return incoming.deviceId.compareTo(current.deviceId) > 0 ? 1 : -1;
  }

  static bool _payloadEquals(SyncRecord a, SyncRecord b) =>
      jsonEncode(a.payload) == jsonEncode(b.payload);

  void _write(SyncRecord record, int rev) {
    _db.execute(
      'INSERT INTO records '
      '(namespace, id, payload, updated_at, device_id, deleted, rev) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, id) DO UPDATE SET '
      'payload = excluded.payload, updated_at = excluded.updated_at, '
      'device_id = excluded.device_id, deleted = excluded.deleted, '
      'rev = excluded.rev;',
      [
        record.namespace,
        record.id,
        jsonEncode(record.payload),
        record.updatedAt,
        record.deviceId,
        record.deleted ? 1 : 0,
        rev,
      ],
    );
  }

  // ===== Blobs =====

  /// Stores bytes under their own sha256, so uploading the same image twice
  /// costs one object and a client can always ask whether it needs to send one.
  String putBlob(List<int> bytes) {
    final hash = sha256.convert(bytes).toString();
    final rows = _db.select('SELECT hash FROM blobs WHERE hash = ?;', [hash]);
    if (rows.isNotEmpty) return hash;
    final file = _blobFile(hash);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
    _db.execute(
      'INSERT OR IGNORE INTO blobs (hash, size, created_at) VALUES (?, ?, ?);',
      [hash, bytes.length, DateTime.now().millisecondsSinceEpoch],
    );
    return hash;
  }

  bool hasBlob(String hash) =>
      _db.select('SELECT hash FROM blobs WHERE hash = ?;', [hash]).isNotEmpty;

  /// Which of [hashes] the server already holds.
  ///
  /// Batched so a client bringing up a large library answers "what do you still
  /// need from me" in one round trip instead of one per file.
  Set<String> filterExistingBlobs(List<String> hashes) {
    final present = <String>{};
    const chunkSize = 400;
    for (var start = 0; start < hashes.length; start += chunkSize) {
      final end = start + chunkSize > hashes.length
          ? hashes.length
          : start + chunkSize;
      final slice = hashes.sublist(start, end);
      if (slice.isEmpty) continue;
      final placeholders = List.filled(slice.length, '?').join(', ');
      final rows = _db.select(
        'SELECT hash FROM blobs WHERE hash IN ($placeholders);',
        slice,
      );
      for (final row in rows) {
        present.add(row['hash'] as String);
      }
    }
    return present;
  }

  File? blobFile(String hash) {
    if (!hasBlob(hash)) return null;
    final file = _blobFile(hash);
    return file.existsSync() ? file : null;
  }

  File _blobFile(String hash) {
    final safe = hash.replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (safe.length < 4) {
      throw ArgumentError.value(hash, 'hash', 'not a sha256 hex digest');
    }
    return File('${_blobRoot.path}/${safe.substring(0, 2)}/$safe');
  }

  void close() => _db.dispose();
}
