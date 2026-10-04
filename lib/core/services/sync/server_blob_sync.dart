import 'dart:io';

import '../../../utils/sandbox_path_resolver.dart';
import '../../database/chat_database_repository.dart';
import 'server_sync_client.dart';

/// Moves attachment bytes between this device and the server.
///
/// Only content travels. A file's path is local by nature -- iOS rewrites the
/// app container path on every update -- so each device resolves the path it
/// already holds in `asset_rows` and stores the bytes there. Identity is the
/// sha256, which is also why the same photo on two devices costs one object.
class ServerBlobSync {
  ServerBlobSync({required this._repository, required this._client});

  final ChatDatabaseRepository _repository;
  final ServerSyncClient _client;

  /// Hashes this run has confirmed are on the server.
  ///
  /// Held for the session rather than persisted: it is rebuilt with one bulk
  /// request, and a stale copy would mean silently skipping a file that was
  /// deleted server-side.
  final Set<String> _confirmed = <String>{};

  /// Every content hash this device knows about.
  Future<List<String>> localHashes() async {
    final rows = await _repository.syncSelect(
      "SELECT DISTINCT content_hash FROM asset_rows "
      "WHERE content_hash IS NOT NULL AND content_hash != ''",
    );
    return [
      for (final row in rows)
        if (row['content_hash'] is String) row['content_hash']! as String,
    ];
  }

  /// Uploads assets the server does not have yet.
  ///
  /// Returns how many were uploaded. Called with the full local hash list first
  /// so the steady state costs one request and no transfers at all.
  Future<int> push({
    required Uri base,
    required String token,
    int maxUploads = 40,
  }) async {
    final hashes = await localHashes();
    if (hashes.isEmpty) return 0;

    final unknown = hashes.where((h) => !_confirmed.contains(h)).toList();
    if (unknown.isEmpty) return 0;
    if (unknown.length > 500) {
      // Ask about a slice at a time so a large library does not build one
      // enormous request body.
      final slice = unknown.sublist(0, 500);
      final present = await _client.checkBlobs(
        base: base,
        token: token,
        hashes: slice,
      );
      _confirmed.addAll(present);
    } else {
      final present = await _client.checkBlobs(
        base: base,
        token: token,
        hashes: unknown,
      );
      _confirmed.addAll(present);
    }

    var uploads = 0;
    for (final hash in unknown) {
      if (uploads >= maxUploads) break;
      if (_confirmed.contains(hash)) continue;
      final file = await _localFileForHash(hash);
      if (file == null) continue;
      try {
        final uploaded = await _client.uploadBlob(
          base: base,
          token: token,
          file: file,
        );
        _confirmed.add(uploaded);
        uploads += 1;
      } catch (_) {
        // Unreadable or interrupted: the next pass retries it.
      }
    }
    return uploads;
  }

  /// Downloads content for [assetIds] whose files this device does not have.
  ///
  /// Returns how many were written.
  Future<int> pull({
    required Uri base,
    required String token,
    required List<String> assetIds,
    int maxDownloads = 40,
  }) async {
    if (assetIds.isEmpty) return 0;
    final ids = assetIds.take(400).toList(growable: false);
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _repository.syncSelect(
      'SELECT content_hash, path FROM asset_rows WHERE id IN ($placeholders)',
      ids,
    );

    var downloads = 0;
    for (final row in rows) {
      if (downloads >= maxDownloads) break;
      final hash = row['content_hash'];
      final path = row['path'];
      if (hash is! String || hash.isEmpty) continue;
      if (path is! String || path.isEmpty) continue;
      if (SandboxPathResolver.localFileExists(path)) continue;

      final absolute = SandboxPathResolver.resolveForIo(path);
      if (absolute == null) continue;
      try {
        await _client.downloadBlob(
          base: base,
          token: token,
          hash: hash,
          destination: File(absolute),
        );
        _confirmed.add(hash);
        downloads += 1;
      } catch (_) {
        // Retried next pass.
      }
    }
    return downloads;
  }

  /// The local file holding [hash], if this device still has it.
  Future<File?> _localFileForHash(String hash) async {
    final rows = await _repository.syncSelect(
      'SELECT path FROM asset_rows WHERE content_hash = ? LIMIT 1',
      [hash],
    );
    if (rows.isEmpty) return null;
    final path = rows.first['path'];
    if (path is! String || path.isEmpty) return null;
    if (!SandboxPathResolver.localFileExists(path)) return null;
    final absolute = SandboxPathResolver.resolveForIo(path);
    return absolute == null ? null : File(absolute);
  }
}
