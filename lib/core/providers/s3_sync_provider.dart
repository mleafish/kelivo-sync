import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../models/backup.dart';
import '../services/backup/backup_activity.dart';
import '../services/backup/backup_cancel_token.dart';
import '../services/backup/backup_task_progress.dart';
import '../services/chat/chat_service.dart';
import '../services/sync/s3_sync_service.dart';

/// Drives background two-way S3 sync and exposes its state to the UI.
///
/// Deliberately plain about scheduling: one timer at the user's chosen
/// interval, plus one pass whenever the app comes back to the foreground,
/// which is when a phone is most likely to have missed changes made on the
/// other device.
class S3SyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  S3SyncProvider({
    required ChatService chatService,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
    required Future<void> Function(S3SyncConfig) persist,
    S3Config? initialS3Config,
    S3SyncConfig? initialConfig,
    bool Function()? shouldSkip,
    @visibleForTesting S3SyncService? debugService,
  }) : _service =
           debugService ??
           S3SyncService(
             chatService: chatService,
             businessRepository: businessRepository,
             businessPreferences: businessPreferences,
           ),
       _persist = persist,
       _s3Config = initialS3Config ?? const S3Config(),
       _config = initialConfig ?? const S3SyncConfig(),
       _shouldSkip = shouldSkip;

  final S3SyncService _service;
  final Future<void> Function(S3SyncConfig) _persist;
  final bool Function()? _shouldSkip;

  S3Config _s3Config;
  S3SyncConfig _config;

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _syncing = false;
  DateTime? _lastSyncAt;
  String? _lastError;
  S3SyncOutcome? _lastOutcome;

  S3Config get s3Config => _s3Config;
  S3SyncConfig get config => _config;
  bool get syncing => _syncing;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastError => _lastError;
  S3SyncOutcome? get lastOutcome => _lastOutcome;
  bool get enabled => _config.enabled;
  bool get configured => _hasConnection(_s3Config);

  static bool _hasConnection(S3Config cfg) =>
      cfg.endpoint.trim().isNotEmpty &&
      cfg.bucket.trim().isNotEmpty &&
      cfg.accessKeyId.trim().isNotEmpty &&
      cfg.secretAccessKey.isNotEmpty;

  /// Begins periodic sync. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _reschedule();
    if (_config.enabled) {
      // Let startup settle before competing for the database. Deliberately not
      // assigned to [_timer], which the periodic schedule already owns.
      unawaited(
        Future<void>.delayed(const Duration(seconds: 8), () {
          if (!_disposed && _config.enabled) unawaited(syncNow());
        }),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _config.enabled) {
      unawaited(syncNow());
    }
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;
    if (!_config.enabled) return;
    final seconds = _config.intervalSeconds.clamp(10, 3600);
    _timer = Timer.periodic(
      Duration(seconds: seconds),
      (_) => unawaited(syncNow()),
    );
  }

  void updateS3Config(S3Config cfg) {
    _s3Config = cfg;
    notifyListeners();
  }

  /// Applies a new sync configuration, persisting it and restarting the timer.
  ///
  /// Turning sync on for the first time assigns this install its device id,
  /// which is what every other device uses to tell snapshots apart.
  Future<void> updateConfig(S3SyncConfig cfg) async {
    var next = cfg;
    if (next.enabled && next.deviceId.isEmpty) {
      next = next.copyWith(deviceId: const Uuid().v4());
    }
    final wasEnabled = _config.enabled;
    _config = next;
    notifyListeners();
    await _persist(next);
    _reschedule();
    if (next.enabled && !wasEnabled) {
      unawaited(syncNow());
    }
  }

  /// Runs one sync pass now, reporting failures instead of throwing.
  Future<S3SyncOutcome?> syncNow({
    BackupProgressSink? onProgress,
    BackupCancelToken? cancelToken,
  }) async {
    if (!_config.enabled || _config.deviceId.isEmpty) return null;
    if (!_hasConnection(_s3Config)) {
      _lastError = 'incomplete_s3_config';
      notifyListeners();
      return null;
    }
    if (_syncing || _service.busy) return null;
    if (BackupActivity.isActive || (_shouldSkip?.call() ?? false)) return null;

    _syncing = true;
    _lastError = null;
    notifyListeners();
    try {
      final outcome = await _service.sync(
        _s3Config,
        _config,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      _lastOutcome = outcome;
      _lastSyncAt = DateTime.now();
      return outcome;
    } catch (error) {
      _lastError = error.toString();
      return null;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Drops the record of what has already been applied, so the next pass
  /// reconciles against every device again.
  Future<void> resetState() => _service.resetState();
}
