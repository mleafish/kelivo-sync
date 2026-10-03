import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../database/app_database.dart';
import '../../database/business_preferences.dart';
import '../../database/business_repository.dart';
import '../../models/backup.dart';
import '../../../utils/app_directories.dart';
import '../backup/backup_cancel_token.dart';
import '../backup/backup_task_progress.dart';
import '../backup/data_sync.dart';
import '../backup/s3_client.dart';
import '../backup/temporary_restore_file.dart';
import '../chat/chat_service.dart';

/// What one device publishes about the snapshot it owns.
///
/// Kept deliberately small: every other device reads all of these on each tick,
/// so this is the sync protocol's only per-device metadata.
class S3SyncDeviceMeta {
  const S3SyncDeviceMeta({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.updatedAt,
    required this.size,
    required this.sha256,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String appVersion;
  final DateTime updatedAt;
  final int size;
  final String sha256;

  Map<String, dynamic> toJson() => {
    'format': 'kelivo-sync-device-v1',
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'appVersion': appVersion,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'size': size,
    'sha256': sha256,
  };

  static S3SyncDeviceMeta? fromJsonString(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final deviceId = (decoded['deviceId'] as String?)?.trim() ?? '';
      final updatedRaw = (decoded['updatedAt'] as String?)?.trim() ?? '';
      if (deviceId.isEmpty || updatedRaw.isEmpty) return null;
      final updatedAt = DateTime.tryParse(updatedRaw);
      if (updatedAt == null) return null;
      final sizeValue = decoded['size'];
      final size = switch (sizeValue) {
        int v => v,
        num v => v.toInt(),
        String v => int.tryParse(v.trim()) ?? 0,
        _ => 0,
      };
      return S3SyncDeviceMeta(
        deviceId: deviceId,
        deviceName: (decoded['deviceName'] as String?)?.trim() ?? deviceId,
        platform: (decoded['platform'] as String?)?.trim() ?? '',
        appVersion: (decoded['appVersion'] as String?)?.trim() ?? '',
        updatedAt: updatedAt.toUtc(),
        size: size,
        sha256: (decoded['sha256'] as String?)?.trim() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// What a single sync pass did, for status reporting.
class S3SyncOutcome {
  const S3SyncOutcome({
    this.pulledDevices = 0,
    this.pushed = false,
    this.merged = 0,
  });

  final int pulledDevices;
  final bool pushed;
  final int merged;

  bool get didAnything => pulledDevices > 0 || pushed;
}

/// Two-way sync between installs that share one S3 bucket.
///
/// Each install publishes a full snapshot of itself at
/// `<prefix>sync/devices/<deviceId>.zip`, alongside a small JSON sidecar
/// describing it. On every pass a device first reconciles whatever other
/// devices published, then republishes its own snapshot if it changed.
///
/// The local change signal is the database file's size and mtime, so any write
/// to any table counts and nothing has to be threaded through the repository.
/// What a device has already published is remembered as the signature it had
/// at upload time; applying a remote snapshot changes the local file, which
/// makes the signature differ again and republishes the reconciled result. That
/// single comparison is what makes the loop converge without a separate dirty
/// flag.
class S3SyncService {
  S3SyncService({
    required ChatService chatService,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    this._client = const S3BackupClient(),
  }) : _dataSync = DataSync(
         chatService: chatService,
         businessRepository: businessRepository,
         businessPreferences: businessPreferences,
       ),
       _chatService = chatService,
       _preferences = businessPreferences;

  static const String _stateKey = 's3_sync_state_v1';
  static const String _devicesFolder = 'devices/';

  final DataSync _dataSync;
  final ChatService _chatService;
  final BusinessPreferences _preferences;
  final S3BackupClient _client;

  /// Device id -> the `updatedAt` of the newest remote snapshot already applied.
  final Map<String, DateTime> _applied = {};

  /// Local database signature at the moment the device last published.
  String? _publishedSignature;

  /// sha256 of the archive the device last published, so a locally unchanged
  /// database that merely had its mtime touched does not re-upload.
  String? _publishedSha;

  bool _loadedState = false;
  bool _running = false;

  bool get busy => _running;

  Future<void> _ensureStateLoaded() async {
    if (_loadedState) return;
    _loadedState = true;
    final raw = _preferences.getString(_stateKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      _publishedSignature = decoded['publishedSignature'] as String?;
      _publishedSha = decoded['publishedSha'] as String?;
      final applied = decoded['applied'];
      if (applied is Map) {
        applied.forEach((key, value) {
          if (key is! String || value is! String) return;
          final parsed = DateTime.tryParse(value);
          if (parsed != null) _applied[key] = parsed.toUtc();
        });
      }
    } catch (_) {}
  }

  Future<void> _persistState() async {
    final payload = jsonEncode({
      if (_publishedSignature != null)
        'publishedSignature': _publishedSignature,
      if (_publishedSha != null) 'publishedSha': _publishedSha,
      'applied': {
        for (final entry in _applied.entries)
          entry.key: entry.value.toUtc().toIso8601String(),
      },
    });
    try {
      await _preferences.setString(_stateKey, payload);
    } catch (_) {}
  }

  // ===== Key layout =====

  static String _prefixWithSlash(String prefix) {
    var s = prefix.trim().replaceAll(RegExp(r'^/+'), '');
    if (s.isEmpty) return '';
    if (!s.endsWith('/')) s = '$s/';
    return s;
  }

  static String _syncRoot(S3Config cfg) =>
      '${_prefixWithSlash(cfg.prefix)}sync/';

  static String _devicesPrefix(S3Config cfg) =>
      '${_syncRoot(cfg)}$_devicesFolder';

  static String _snapshotKey(S3Config cfg, String deviceId) =>
      '${_devicesPrefix(cfg)}$deviceId.zip';

  static String _metaKey(S3Config cfg, String deviceId) =>
      '${_devicesPrefix(cfg)}$deviceId.json';

  // ===== Local state =====

  /// Size and mtime of the live database and its WAL.
  ///
  /// Any commit touches both, so this changes exactly when the user's data
  /// does. Deliberately not a content hash: it has to be cheap enough to call
  /// on every tick.
  Future<String> _localSignature() async {
    final dir = await AppDirectories.getAppDataDirectory();
    final base = p.join(dir.path, AppDatabase.databaseFileName);
    final buffer = StringBuffer();
    for (final suffix in const ['', '-wal']) {
      final file = File('$base$suffix');
      try {
        if (await file.exists()) {
          final stat = await file.stat();
          buffer.write(
            '$suffix:${stat.size}:${stat.modified.millisecondsSinceEpoch};',
          );
        } else {
          buffer.write('$suffix:-;');
        }
      } catch (_) {
        buffer.write('$suffix:?;');
      }
    }
    return buffer.toString();
  }

  String _platformTag() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  Future<String> _appVersionTag() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.buildNumber.trim().isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }

  /// Whether this device holds conversations of its own.
  ///
  /// Only asked on the very first pass. A fresh install has nothing to protect,
  /// so it should adopt the cloud copy outright rather than announce itself as
  /// a second source of truth and fork every conversation in the merge.
  bool _hasLocalData() {
    try {
      return _chatService.getAllConversations().isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  // ===== Remote metadata =====

  /// Reads every device sidecar under the sync folder.
  Future<List<S3SyncDeviceMeta>> listDevices(
    S3Config cfg, {
    BackupCancelToken? cancelToken,
  }) async {
    final keys = await _client.listKeys(
      cfg,
      prefix: _devicesPrefix(cfg),
      cancelToken: cancelToken,
    );
    final metas = <S3SyncDeviceMeta>[];
    for (final key in keys) {
      if (!key.toLowerCase().endsWith('.json')) continue;
      try {
        final raw = await _client.getObjectText(
          cfg,
          key: key,
          cancelToken: cancelToken,
        );
        if (raw == null || raw.isEmpty) continue;
        final meta = S3SyncDeviceMeta.fromJsonString(raw);
        if (meta != null) metas.add(meta);
      } catch (_) {
        // A single unreadable sidecar must not stop the pass; the next tick
        // retries it.
      }
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  // ===== Snapshot build / upload =====

  /// Builds a snapshot archive of the live data, honouring [syncFiles].
  Future<File> _buildSnapshot(
    S3SyncConfig sync, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) {
    return _dataSync.prepareBackupFile(
      WebDavConfig(includeChats: true, includeFiles: sync.syncFiles),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// Publishes the local snapshot when it differs from what was last published.
  ///
  /// Returns true when an upload actually happened.
  Future<bool> _pushIfChanged(
    S3Config cfg,
    S3SyncConfig sync, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    final signature = await _localSignature();
    if (signature == _publishedSignature) return false;

    File? snapshot;
    try {
      snapshot = await _buildSnapshot(
        sync,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      final digest = await _sha256OfFile(snapshot);
      if (digest == _publishedSha) {
        // The database's mtime moved without its contents changing.
        _publishedSignature = signature;
        await _persistState();
        return false;
      }
      final size = await snapshot.length();
      await _client.uploadFile(
        cfg,
        key: _snapshotKey(cfg, sync.deviceId),
        file: snapshot,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      final meta = S3SyncDeviceMeta(
        deviceId: sync.deviceId,
        deviceName: sync.deviceName,
        platform: _platformTag(),
        appVersion: await _appVersionTag(),
        updatedAt: DateTime.now().toUtc(),
        size: size,
        sha256: digest,
      );
      await _client.putBytes(
        cfg,
        key: _metaKey(cfg, sync.deviceId),
        bytes: utf8.encode(jsonEncode(meta.toJson())),
        contentType: 'application/json',
        cancelToken: cancelToken,
      );
      _publishedSignature = signature;
      _publishedSha = digest;
      await _persistState();
      return true;
    } finally {
      await DataSync.cleanupTemporaryBackupFile(snapshot);
    }
  }

  static Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  // ===== Pull =====

  Future<File> _downloadSnapshot(
    S3Config cfg,
    S3SyncDeviceMeta meta, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    final tmp = await Directory.systemTemp.createTemp('kelivo_sync_');
    final file = await createTemporaryRestoreFile(tmp);
    await _client.downloadToFile(
      cfg,
      key: _snapshotKey(cfg, meta.deviceId),
      destination: file,
      onProgress: onProgress,
      cancelToken: cancelToken,
      expectedSize: meta.size,
    );
    return file;
  }

  /// Applies one remote snapshot to the live database.
  ///
  /// Stays on the merge path rather than overwrite: an overwrite restore is
  /// staged and only lands on the next launch, which is indistinguishable from
  /// sync doing nothing. Merge applies immediately, and with `preferNewer` it
  /// settles each conversation by `updated_at` instead of forking a duplicate
  /// copy every time the other device has appended a message.
  Future<S3SyncOutcome> _applyRemote(
    S3Config cfg,
    S3SyncConfig sync,
    S3SyncDeviceMeta meta, {
    required bool localDirty,
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    File? file;
    try {
      if (localDirty) {
        // Publish what this device has first, so a conversation the remote
        // side is about to win is still recoverable from this device's
        // snapshot rather than only existing in memory.
        await _pushIfChanged(
          cfg,
          sync,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      }
      file = await _downloadSnapshot(
        cfg,
        meta,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      await _dataSync.restoreFromLocalFile(
        file,
        WebDavConfig(includeChats: true, includeFiles: sync.syncFiles),
        mode: RestoreMode.merge,
        preferNewer: true,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      return const S3SyncOutcome(pulledDevices: 1, merged: 1);
    } finally {
      try {
        if (file != null && await file.exists()) {
          final parent = file.parent;
          await file.delete();
          if (p.basename(parent.path).startsWith('kelivo_sync_')) {
            await parent.delete(recursive: true);
          }
        }
      } catch (_) {}
    }
  }

  // ===== Public entry point =====

  /// One full pass: reconcile remote changes, then publish local ones.
  Future<S3SyncOutcome> sync(
    S3Config cfg,
    S3SyncConfig sync, {
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    if (!sync.enabled || sync.deviceId.isEmpty) {
      return const S3SyncOutcome();
    }
    if (_running) return const S3SyncOutcome();
    _running = true;
    try {
      await _ensureStateLoaded();
      var pulledDevices = 0;
      var merged = 0;

      final remote = await listDevices(cfg, cancelToken: cancelToken);
      for (final meta in remote) {
        if (meta.deviceId == sync.deviceId) continue;
        final appliedAt = _applied[meta.deviceId];
        if (appliedAt != null && !meta.updatedAt.isAfter(appliedAt)) continue;

        final signature = await _localSignature();
        final localDirty = _publishedSignature == null
            ? _hasLocalData()
            : signature != _publishedSignature;
        final outcome = await _applyRemote(
          cfg,
          sync,
          meta,
          localDirty: localDirty,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        pulledDevices += outcome.pulledDevices;
        merged += outcome.merged;
        _applied[meta.deviceId] = meta.updatedAt;
        await _persistState();
      }

      // Reconciling above changed the local database, so this republishes the
      // result for the next device to see.
      final pushed = await _pushIfChanged(
        cfg,
        sync,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

      return S3SyncOutcome(
        pulledDevices: pulledDevices,
        pushed: pushed,
        merged: merged,
      );
    } finally {
      _running = false;
    }
  }

  /// Forgets which remote snapshots were applied, forcing the next pass to
  /// reconcile against everything again. Used when the connection or identity
  /// changes.
  Future<void> resetState() async {
    _applied.clear();
    _publishedSignature = null;
    _publishedSha = null;
    _loadedState = true;
    await _persistState();
  }
}
