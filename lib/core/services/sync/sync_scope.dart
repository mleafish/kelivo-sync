/// Which local tables travel to the sync server, and how each is keyed.
///
/// The server never learns what any of this means -- it stores opaque
/// `(namespace, id, payload)` records. This file is the only place that knows
/// which of the app's tables those correspond to, so adding a table to sync is
/// a one-line change here rather than a protocol change.
///
/// Tables deliberately absent are the ones describing *this* install:
/// `chat_storage_meta_rows` (database identity and migration receipts),
/// `generation_run_rows` (a live generation is not something to replicate),
/// `asset_gc_rows`, `gc_audit_rows` and `asset_reference_dirty_rows` (all
/// queues of local pending work, meaningless on another device).
class SyncTableSpec {
  const SyncTableSpec({
    required this.namespace,
    required this.table,
    required this.keyColumns,
    this.cursorExpression,
    this.excludeColumns = const <String>[],
    this.parentNamespace,
    this.parentColumn,
    this.rowFilter,
  });

  /// Record name used on the wire and in the server's store.
  final String namespace;

  /// SQLite table this mirrors.
  final String table;

  /// Columns that identify a row for reconciliation.
  ///
  /// Not always the declared primary key: `message_part_rows` is keyed by an
  /// autoincrement `part_id` that means nothing on another device, so parts are
  /// matched on the pair that actually identifies them.
  final List<String> keyColumns;

  /// SQL expression producing a microsecond timestamp for incremental reads.
  ///
  /// Null means the table has no usable timestamp and is compared in full.
  /// `message_rows` needs the COALESCE because `updated_at` is null until a
  /// message is first edited; reading it directly would silently skip every
  /// message that has never been touched.
  final String? cursorExpression;

  /// Columns not sent: local autoincrement ids and the like.
  final List<String> excludeColumns;

  /// For a table with no timestamp of its own: the parent whose changes it
  /// follows, and the column linking back to it.
  ///
  /// Without this the only way to publish such a table is in full, which turns
  /// every sent message into a re-upload of every attachment link in the
  /// database.
  final String? parentNamespace;
  final String? parentColumn;

  /// Rows this table must not carry, decided from the row itself.
  ///
  /// Applies to both directions: such a row is neither published nor accepted
  /// from another device.
  final bool Function(Map<String, dynamic> payload)? rowFilter;
}

/// Preference keys that describe the running install rather than the user's
/// data.
///
/// These must never travel. Beyond sitting next to credentials the user did not
/// mean to publish, several of them are rewritten on every sync -- carrying
/// them makes the engine push its own bookkeeping back and forth, and the
/// server's revision counter climbs forever while real changes drown in it.
const List<String> localOnlyPreferencePrefixes = <String>[
  'server_sync_',
  's3_sync_',
  'local_snapshot_',
];

bool _preferenceIsSyncable(Map<String, dynamic> payload) {
  final key = payload['key'];
  if (key is! String || key.isEmpty) return false;
  for (final prefix in localOnlyPreferencePrefixes) {
    if (key.startsWith(prefix)) return false;
  }
  return true;
}

const List<SyncTableSpec> syncTableSpecs = <SyncTableSpec>[
  // ===== Chats =====
  SyncTableSpec(
    namespace: 'conversation',
    table: 'conversation_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'message',
    table: 'message_rows',
    keyColumns: ['id'],
    cursorExpression: 'COALESCE(updated_at, timestamp)',
  ),
  SyncTableSpec(
    namespace: 'message_part',
    table: 'message_part_rows',
    keyColumns: ['revision_id', 'ordinal'],
    cursorExpression: 'updated_at',
    excludeColumns: ['part_id'],
  ),
  SyncTableSpec(
    namespace: 'message_prompt',
    table: 'message_prompt_rows',
    keyColumns: ['revision_id'],
    cursorExpression: 'created_at',
  ),
  SyncTableSpec(
    namespace: 'provider_artifact',
    table: 'provider_artifact_rows',
    keyColumns: ['revision_id', 'kind'],
    cursorExpression: 'updated_at',
  ),
  // No timestamp: a join table, published by following the messages it links.
  SyncTableSpec(
    namespace: 'message_asset',
    table: 'message_asset_rows',
    keyColumns: ['revision_id', 'asset_id', 'kind'],
    parentNamespace: 'message',
    parentColumn: 'revision_id',
  ),
  SyncTableSpec(
    namespace: 'conversation_mcp_server',
    table: 'conversation_mcp_server_rows',
    keyColumns: ['conversation_id', 'server_id'],
    parentNamespace: 'conversation',
    parentColumn: 'conversation_id',
  ),
  SyncTableSpec(
    namespace: 'asset',
    table: 'asset_rows',
    keyColumns: ['id'],
    // `last_referenced_at` moves on every read; `created_at` is the point at
    // which the asset's own data was fixed.
    cursorExpression: 'created_at',
  ),

  // ===== Configuration =====
  SyncTableSpec(
    namespace: 'assistant',
    table: 'assistant_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  // Primary key column is `provider_key`, not `id`.
  SyncTableSpec(
    namespace: 'provider',
    table: 'provider_rows',
    keyColumns: ['provider_key'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'provider_group',
    table: 'provider_group_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'mcp_server',
    table: 'mcp_server_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'world_book',
    table: 'world_book_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'assistant_memory',
    table: 'assistant_memory_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'quick_phrase',
    table: 'quick_phrase_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'search_service',
    table: 'search_service_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'tts_service',
    table: 'tts_service_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'instruction_injection',
    table: 'instruction_injection_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'assistant_tag',
    table: 'assistant_tag_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'memory_entry',
    table: 'memory_entry_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'user_profile_field',
    table: 'user_profile_field_rows',
    keyColumns: ['id'],
    cursorExpression: 'updated_at',
  ),
  SyncTableSpec(
    namespace: 'preference',
    table: 'preference_rows',
    keyColumns: ['key'],
    cursorExpression: 'updated_at',
    rowFilter: _preferenceIsSyncable,
  ),
  SyncTableSpec(
    namespace: 'extension_entity',
    table: 'extension_entity_rows',
    keyColumns: ['kind', 'id'],
    cursorExpression: 'updated_at',
  ),

  // Deletions. `deleteConversation` has always written these so that a delete
  // could outlive the row; this is what carries them to another device.
  SyncTableSpec(
    namespace: 'tombstone',
    table: 'tombstone_rows',
    keyColumns: ['scope', 'entity_id'],
    cursorExpression: 'deleted_at',
  ),
];

/// Specs looked up by namespace, for the receive path.
final Map<String, SyncTableSpec> syncSpecsByNamespace = {
  for (final spec in syncTableSpecs) spec.namespace: spec,
};
