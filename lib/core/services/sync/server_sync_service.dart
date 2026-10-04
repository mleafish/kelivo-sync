import 'dart:convert';

import '../../database/chat_database_repository.dart';
import 'server_sync_client.dart';
import 'sync_scope.dart';

/// One pass's worth of local changes, plus the cursors that produced them.
class ServerCollectResult {
  const ServerCollectResult({required this.records, required this.cursors});

  final List<ServerSyncRecord> records;

  /// namespace -> highest cursor value read. Persisted only once the server has
  /// accepted the push, so a failed push is simply read again next time.
  final Map<String, int> cursors;
}

/// What applying a batch did.
class ServerApplyReport {
  const ServerApplyReport({
    required this.applied,
    required this.retryable,
    required this.deletedConversations,
  });

  final int applied;

  /// Records whose parent had not arrived yet. Retried after the next page
  /// rather than dropped, which is what stops a message page that overtook its
  /// conversation from losing those messages for good.
  final List<ServerSyncRecord> retryable;

  final int deletedConversations;
}

/// Reads local rows out as records, and writes incoming records back.
///
/// Entirely table-driven off [syncTableSpecs]: it never names a column of its
/// own, so a payload always has exactly the shape of the row it describes and
/// the two ends cannot drift apart as the schema changes.
class ServerSyncService {
  ServerSyncService({
    required ChatDatabaseRepository repository,
    required this.deviceId,
  }) : _repository = repository;

  /// Names this install when the server has to break a timestamp tie.
  final String deviceId;

  final ChatDatabaseRepository _repository;

  // ===== Outgoing =====

  /// Reads everything changed since [cursors].
  ///
  /// Each table is read with `>` on its own cursor column. Tables without one
  /// are published by following whichever parents changed this pass, so sending
  /// a message does not re-upload every attachment link in the database.
  Future<ServerCollectResult> collectChanges({
    Map<String, int> cursors = const <String, int>{},
    int limitPerTable = 500,
  }) async {
    final records = <ServerSyncRecord>[];
    final nextCursors = <String, int>{};
    final changedParents = <String, List<String>>{};

    for (final spec in syncTableSpecs) {
      final cursorColumn = _cursorColumn(spec);
      if (cursorColumn == null) continue;

      final since = cursors[spec.namespace] ?? 0;
      final rows = await _repository.syncSelect(
        'SELECT * FROM ${spec.table} WHERE ${spec.cursorExpression} > ? '
        'ORDER BY ${spec.cursorExpression} ASC LIMIT ?',
        [since, limitPerTable],
      );
      if (rows.isEmpty) continue;

      final parentKeys = <String>[];
      var highest = since;
      for (final row in rows) {
        records.add(_recordFromRow(spec, row));
        final value = row[cursorColumn];
        if (value is int && value > highest) highest = value;
        final key = row[spec.keyColumns.first];
        if (key != null) parentKeys.add('$key');
      }
      nextCursors[spec.namespace] = highest;
      changedParents[spec.namespace] = parentKeys;
    }

    for (final spec in syncTableSpecs) {
      if (spec.cursorExpression != null) continue;
      final parentNamespace = spec.parentNamespace;
      final parentColumn = spec.parentColumn;
      if (parentNamespace == null || parentColumn == null) continue;
      final keys = changedParents[parentNamespace];
      if (keys == null || keys.isEmpty) continue;

      // Bounded: a very large pass falls back to skipping this table, which
      // the next pass picks up rather than building an enormous IN clause.
      if (keys.length > 400) continue;
      final placeholders = List.filled(keys.length, '?').join(', ');
      final rows = await _repository.syncSelect(
        'SELECT * FROM ${spec.table} WHERE $parentColumn IN ($placeholders)',
        keys,
      );
      for (final row in rows) {
        records.add(_recordFromRow(spec, row));
      }
    }

    return ServerCollectResult(records: records, cursors: nextCursors);
  }

  /// Every row of every synced table, for a first run.
  Future<ServerCollectResult> collectEverything({int limitPerTable = 5000}) async {
    final records = <ServerSyncRecord>[];
    for (final spec in syncTableSpecs) {
      final rows = await _repository.syncSelect(
        'SELECT * FROM ${spec.table} LIMIT ?',
        [limitPerTable],
      );
      for (final row in rows) {
        records.add(_recordFromRow(spec, row));
      }
    }
    return ServerCollectResult(
      records: records,
      cursors: const <String, int>{},
    );
  }

  ServerSyncRecord _recordFromRow(
    SyncTableSpec spec,
    Map<String, Object?> row,
  ) {
    final payload = <String, dynamic>{};
    for (final entry in row.entries) {
      if (spec.excludeColumns.contains(entry.key)) continue;
      payload[entry.key] = entry.value;
    }
    return ServerSyncRecord(
      namespace: spec.namespace,
      id: idFromRow(spec, row),
      payload: payload,
      updatedAt: _orderingValue(spec, row),
      deviceId: deviceId,
    );
  }

  /// The value the server orders this record by.
  ///
  /// Prefers the table's own timestamp. A join table has none, so it borrows
  /// whatever timestamp its columns carry and otherwise falls back to now --
  /// it is published only because its parent moved, and the parent carries the
  /// real ordering.
  static int _orderingValue(SyncTableSpec spec, Map<String, Object?> row) {
    final cursorColumn = _cursorColumn(spec);
    if (cursorColumn != null) {
      final value = row[cursorColumn];
      if (value is int) return value;
    }
    for (final column in const ['updated_at', 'created_at', 'deleted_at']) {
      final value = row[column];
      if (value is int) return value;
    }
    return DateTime.now().microsecondsSinceEpoch;
  }

  /// Stable identity of a row, built from its key columns.
  ///
  /// JSON-encoded rather than joined with a separator, because key values are
  /// user data and any separator chosen here could occur inside one.
  static String idFromRow(SyncTableSpec spec, Map<String, Object?> row) =>
      jsonEncode([for (final column in spec.keyColumns) row[column]]);

  /// The bare column behind a cursor expression: `COALESCE(updated_at,
  /// timestamp)` reads `updated_at`.
  static String? _cursorColumn(SyncTableSpec spec) {
    final expression = spec.cursorExpression;
    if (expression == null) return null;
    final open = expression.indexOf('(');
    final source = open >= 0 ? expression.substring(open + 1) : expression;
    return RegExp(r'[a-zA-Z_][a-zA-Z0-9_]*').firstMatch(source)?.group(0);
  }

  // ===== Incoming =====

  /// Writes [records] into the local database.
  ///
  /// Applied in spec order so a conversation always lands before the messages
  /// that reference it, and deletions last so an insert and a delete arriving
  /// together cannot undo each other.
  Future<ServerApplyReport> applyRemote(List<ServerSyncRecord> records) async {
    final byNamespace = <String, List<ServerSyncRecord>>{};
    for (final record in records) {
      if (!syncSpecsByNamespace.containsKey(record.namespace)) continue;
      byNamespace.putIfAbsent(record.namespace, () => []).add(record);
    }

    var applied = 0;
    final retryable = <ServerSyncRecord>[];

    await _repository.syncTransaction(() async {
      for (final spec in syncTableSpecs) {
        final batch = byNamespace[spec.namespace];
        if (batch == null) continue;
        for (final record in batch) {
          try {
            await _upsert(spec, record);
            applied += 1;
          } catch (error) {
            // Almost always a row whose parent has not arrived yet. Anything
            // else is a real defect and should surface rather than be retried
            // forever.
            if (!_looksLikeMissingParent(error)) rethrow;
            retryable.add(record);
          }
        }
      }
    });

    final tombstones = byNamespace['tombstone'] ?? const <ServerSyncRecord>[];
    final deleted = await _applyConversationTombstones(tombstones);

    return ServerApplyReport(
      applied: applied,
      retryable: retryable,
      deletedConversations: deleted,
    );
  }

  static bool _looksLikeMissingParent(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('foreign key') || text.contains('constraint');
  }

  Future<void> _upsert(SyncTableSpec spec, ServerSyncRecord record) async {
    final payload = record.payload;
    final keyValues = <Object?>[];
    for (final column in spec.keyColumns) {
      if (!payload.containsKey(column)) {
        throw FormatException('${spec.namespace} record has no $column');
      }
      keyValues.add(_toColumnValue(payload[column]));
    }

    final assignments = <String>[];
    final assignmentValues = <Object?>[];
    payload.forEach((column, value) {
      if (spec.keyColumns.contains(column)) return;
      if (spec.excludeColumns.contains(column)) return;
      assignments.add('$column = ?');
      assignmentValues.add(_toColumnValue(value));
    });

    final where = spec.keyColumns.map((column) => '$column = ?').join(' AND ');

    // UPDATE first, never INSERT OR REPLACE: replacing a conversation or a
    // message deletes the old row, and the schema's cascades would take every
    // message underneath it with it.
    if (assignments.isNotEmpty) {
      final updated = await _repository.syncExecute(
        'UPDATE ${spec.table} SET ${assignments.join(', ')} WHERE $where',
        [...assignmentValues, ...keyValues],
      );
      if (updated > 0) return;
    } else {
      final existing = await _repository.syncSelect(
        'SELECT 1 FROM ${spec.table} WHERE $where LIMIT 1',
        keyValues,
      );
      if (existing.isNotEmpty) return;
    }

    final columns = <String>[];
    final values = <Object?>[];
    payload.forEach((column, value) {
      if (spec.excludeColumns.contains(column)) return;
      columns.add(column);
      values.add(_toColumnValue(value));
    });
    final placeholders = List.filled(columns.length, '?').join(', ');
    await _repository.syncExecute(
      'INSERT INTO ${spec.table} (${columns.join(', ')}) '
      'VALUES ($placeholders)',
      values,
    );
  }

  /// Converts a decoded JSON value into something a column will accept.
  ///
  /// A nested map or list has no column type, so it is stored as JSON text,
  /// which is how the app already keeps its own `extras_json` columns.
  static Object? _toColumnValue(Object? value) {
    if (value == null) return null;
    if (value is num || value is String || value is bool) return value;
    if (value is List<int>) return value;
    return jsonEncode(value);
  }

  /// Removes conversations another device deleted.
  ///
  /// A tombstone only wins when the local conversation has not been edited
  /// since it was written, so a delete can never silently discard newer work.
  Future<int> _applyConversationTombstones(
    List<ServerSyncRecord> tombstones,
  ) async {
    var deleted = 0;
    for (final record in tombstones) {
      final payload = record.payload;
      if (payload['scope'] != 'conversation') continue;
      final id = payload['entity_id'];
      final deletedAt = payload['deleted_at'];
      if (id is! String || deletedAt is! int) continue;

      final local = await _repository.syncSelect(
        'SELECT updated_at FROM conversation_rows WHERE id = ?',
        [id],
      );
      if (local.isEmpty) continue;
      final updatedAt = local.first['updated_at'];
      if (updatedAt is int && updatedAt > deletedAt) continue;

      await _repository.deleteConversation(id);
      deleted += 1;
    }
    return deleted;
  }
}
