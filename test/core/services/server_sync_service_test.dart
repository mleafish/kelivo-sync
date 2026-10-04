import 'dart:io';

import 'package:Kelivo/core/database/chat_database_repository.dart';
import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/core/models/conversation.dart';
import 'package:Kelivo/core/services/sync/server_sync_client.dart';
import 'package:Kelivo/core/services/sync/server_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the two ways this engine can lose data silently.
///
/// Both are runtime-only failures: the statements are assembled from table and
/// column names at run time, so neither the compiler nor the analyzer can see
/// them. They are also the two the design deliberately works around, which is
/// exactly why they are worth pinning down.
void main() {
  late Directory directory;
  late ChatDatabaseRepository repository;
  late ServerSyncService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kelivo_sync_test_');
    repository = ChatDatabaseRepository.open(
      file: File('${directory.path}/chat.sqlite'),
    );
    await repository.ensureReady();
    service = ServerSyncService(repository: repository, deviceId: 'device-a');
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<void> seed() async {
    final message = ChatMessage(
      id: 'message-1',
      role: 'user',
      content: 'hello',
      conversationId: 'conversation-1',
      groupId: 'message-1',
      version: 0,
      isStreaming: false,
    );
    await repository.putMigrationBatch(
      conversations: [
        Conversation(
          id: 'conversation-1',
          title: 'Original',
        ).copyWith(messageIds: const ['message-1']),
      ],
      messages: [(message: message, messageOrder: 0)],
      toolEventsByMessageId: const {},
      geminiSignaturesByMessageId: const {},
    );
  }

  Future<int> messageCount() async {
    final rows = await repository.syncSelect(
      'SELECT id FROM message_rows WHERE conversation_id = ?',
      ['conversation-1'],
    );
    return rows.length;
  }

  test('a conversation and its message are both exported', () async {
    await seed();

    final collected = await service.collectChanges();

    final namespaces = collected.records.map((r) => r.namespace).toSet();
    expect(namespaces, contains('conversation'));
    expect(namespaces, contains('message'));
    // The cursor must advance, or the next pass would re-send the same rows.
    final messageCursor = collected.cursors['message'];
    expect(messageCursor, isNotNull);
    expect(messageCursor!, greaterThan(0));
  });

  test('a message that was never edited is still exported', () async {
    // message_rows.updated_at stays null until a message is first edited, so a
    // reader that compares it directly skips every untouched message -- which
    // is most of them.
    await seed();

    final rows = await repository.syncSelect(
      'SELECT updated_at, timestamp FROM message_rows '
      'WHERE conversation_id = ?',
      ['conversation-1'],
    );
    expect(rows, hasLength(1));
    final direct = rows.first['updated_at'];
    final fallback = rows.first['timestamp'];
    expect(direct, isNull, reason: 'fixture should leave updated_at null');
    expect(fallback, isNotNull);

    final collected = await service.collectChanges();
    final message = collected.records.firstWhere(
      (r) => r.namespace == 'message',
    );
    expect(message.updatedAt, fallback);
  });

  test('updating a conversation does not take its messages with it', () async {
    // The reason writes go UPDATE-then-INSERT rather than INSERT OR REPLACE:
    // replacing a conversation row deletes it first, and the schema's cascades
    // would then remove every message underneath it.
    await seed();
    expect(await messageCount(), 1);

    final collected = await service.collectChanges();
    final original = collected.records.firstWhere(
      (r) => r.namespace == 'conversation',
    );

    final renamed = ServerSyncRecord(
      namespace: 'conversation',
      id: original.id,
      payload: {
        ...original.payload,
        'title': 'Renamed elsewhere',
        'updated_at': original.updatedAt + 10000,
      },
      updatedAt: original.updatedAt + 10000,
      deviceId: 'device-b',
    );

    final report = await service.applyRemote([renamed]);

    expect(report.applied, 1);
    expect(report.retryable, isEmpty);
    expect(await messageCount(), 1, reason: 'the cascade must not have fired');

    final titles = await repository.syncSelect(
      'SELECT title FROM conversation_rows WHERE id = ?',
      ['conversation-1'],
    );
    expect(titles.single['title'], 'Renamed elsewhere');
  });

  test(
    'applying the same batch twice changes nothing the second time',
    () async {
      await seed();
      final collected = await service.collectChanges();

      await service.applyRemote(collected.records);
      final snapshotAfterFirst = await repository.syncSelect(
        'SELECT id, title FROM conversation_rows ORDER BY id',
      );
      final messagesAfterFirst = await messageCount();

      await service.applyRemote(collected.records);

      expect(
        await repository.syncSelect(
          'SELECT id, title FROM conversation_rows ORDER BY id',
        ),
        snapshotAfterFirst,
      );
      expect(await messageCount(), messagesAfterFirst);
    },
  );

  test('a conversation deleted elsewhere is removed locally', () async {
    await seed();

    final report = await service.applyRemote([
      ServerSyncRecord(
        namespace: 'tombstone',
        id: '["conversation","conversation-1"]',
        payload: {
          'scope': 'conversation',
          'entity_id': 'conversation-1',
          'deleted_at': DateTime.now().microsecondsSinceEpoch + 10000,
        },
        updatedAt: DateTime.now().microsecondsSinceEpoch + 10000,
        deviceId: 'device-b',
      ),
    ]);

    expect(report.deletedConversations, 1);
    final remaining = await repository.syncSelect(
      'SELECT id FROM conversation_rows WHERE id = ?',
      ['conversation-1'],
    );
    expect(remaining, isEmpty);
  });

  test('per-install preferences are never published', () async {
    // These sit next to credentials and several are rewritten on every sync.
    // Publishing them made the engine push its own bookkeeping back and forth:
    // the server's revision counter climbed every second while the user's real
    // changes were lost in the noise.
    final now = DateTime.now().microsecondsSinceEpoch;
    for (final key in const [
      'server_sync_state_v1',
      'server_sync_config_v1',
      's3_sync_state_v1',
      'local_snapshot_last_success_at_v1',
      'webdav_config_v1',
      'user_name',
    ]) {
      await repository.syncExecute(
        'INSERT INTO preference_rows (key, value, updated_at) VALUES (?, ?, ?)',
        [key, '"x"', now],
      );
    }

    final collected = await service.collectChanges();
    final published = collected.records
        .where((r) => r.namespace == 'preference')
        .map((r) => r.payload['key'])
        .toSet();

    expect(published, contains('user_name'));
    expect(published, contains('webdav_config_v1'));
    expect(published, isNot(contains('server_sync_state_v1')));
    expect(published, isNot(contains('server_sync_config_v1')));
    expect(published, isNot(contains('s3_sync_state_v1')));
    expect(published, isNot(contains('local_snapshot_last_success_at_v1')));
  });

  test('a per-install preference from another device is ignored', () async {
    await service.applyRemote([
      ServerSyncRecord(
        namespace: 'preference',
        id: '["server_sync_state_v1"]',
        payload: {
          'key': 'server_sync_state_v1',
          'value': '{"rev":99999}',
          'updated_at': DateTime.now().microsecondsSinceEpoch,
        },
        updatedAt: DateTime.now().microsecondsSinceEpoch,
        deviceId: 'device-b',
      ),
    ]);

    final rows = await repository.syncSelect(
      'SELECT key FROM preference_rows WHERE key = ?',
      ['server_sync_state_v1'],
    );
    expect(rows, isEmpty);
  });
}
