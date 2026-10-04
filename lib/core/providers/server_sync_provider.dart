import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../utils/app_directories.dart';
import '../database/app_database.dart';
import '../database/business_preferences.dart';
import '../database/chat_database_repository.dart';
import '../services/backup/backup_activity.dart';
import '../services/sync/server_sync_client.dart';
import '../services/sync/server_sync_service.dart';

/// Drives sync against a self-hosted server and exposes its state to the UI.
///
/// Two things make this feel immediate rather than periodic. Outbound, the
/// local database's file signature is sampled on a short timer, so a message
/// typed here is published within about a second. Inbound, the server pushes
/// over a WebSocket, so the other device hears about it rather than asking.
class ServerSyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  ServerSyncProvider({
    required ChatDatabaseRepository repository,
    required BusinessPreferences preferences,
    required bool Function()? shouldSkip,
    ServerSyncClient? debugClient,
    @visibleForTesting Duration? debugPollInterval,
  }) : _preferences = preferences,
       _client = debugClient ?? ServerSyncClient(),
       _pollInterval = debugPollInterval ?? const Duration(milliseconds: 1500),
       _shouldSkip = shouldSkip {
    _service = ServerSyncService(
      repository: repository,
      deviceId: _deviceId,
    );
    _loadPersistedState();
  }

  /// Persisted keys. Both are registered as device state, so they never travel
  /// to another install through a backup or through sync itself.
  static const String configKey = 'server_sync_config_v1';
  static const String stateKey = 'server_sync_state_v1';
  static const String _deviceIdKey = 'server_sync_device_id_v1';

  final BusinessPreferences _preferences;
  final ServerSyncClient _client;
  final Duration _pollInterval;
  final bool Function()? _shouldSkip;
  late final ServerSyncService _service;
  String? _cachedDeviceId;

  // ===== Persisted =====
  String _serverUrl = '';
  String _token = '';
  bool _enabled = false;
  int _localRev = 0;
  Map<String, int> _cursors = <String, int>{};
  String _publishedSignature = '';

  // ===== Runtime =====
  bool _syncing = false;
  bool _connected = false;
  bool _started = false;
  bool _disposed = false;
  DateTime? _lastSyncAt;
  String? _lastError;
  Timer? _pollTimer;
  StreamSubscription<int>? _watchSubscription;

  String get serverUrl => _serverUrl;
  bool get enabled => _enabled;
  bool get syncing => _syncing;
  bool get connected => _connected;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastError => _lastError;
  bool get loggedIn => _token.isNotEmpty && _serverUrl.isNotEmpty;

  /// A stable, random id for this install.
  ///
  /// Random rather than derived from the platform, so two devices of the same
  /// kind do not collide when the server breaks a timestamp tie. Cached in
  /// memory as well as persisted, so a preferences write that fails cannot
  /// change this device's identity mid-session.
  String get _deviceId {
    final cached = _cachedDeviceId;
    if (cached != null) return cached;
    var id = _preferences.getString(_deviceIdKey);
    if (id == null || id.isEmpty) {
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      id = 'dev-${base64Url.encode(bytes).replaceAll('=', '')}';
      unawaited(_preferences.setString(_deviceIdKey, id));
    }
    _cachedDeviceId = id;
    return id;
  }

  // ===== Lifecycle =====

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    if (_enabled && loggedIn) {
      _connectLiveChannel();
      _startPolling();
      unawaited(syncNow());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    unawaited(_watchSubscription?.cancel());
    _client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _enabled && loggedIn) {
      _connectLiveChannel();
      unawaited(syncNow());
    }
  }

  // ===== Configuration =====

  /// Logs in and turns sync on. Throws [SyncServerException] on failure so the
  /// settings page can show the server's own message.
  Future<void> connect({required String url, required String password}) async {
    final base = normalizeBaseUrl(url);
    final token = await _client.login(base: base, password: password);
    _serverUrl = base.toString();
    _token = token;
    _enabled = true;
    _lastError = null;
    await _persistConfig();
    notifyListeners();

    _connectLiveChannel();
    _startPolling();
    unawaited(syncNow());
  }

  Future<void> disconnect() async {
    _enabled = false;
    _token = '';
    await _persistConfig();
    _pollTimer?.cancel();
    _pollTimer = null;
    await _watchSubscription?.cancel();
    _watchSubscription = null;
    _connected = false;
    notifyListeners();
  }

  /// Accepts `host`, `host:port` or a full URL and returns a usable base.
  static Uri normalizeBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) {
      throw const SyncServerException('请填写服务器地址');
    }
    if (!text.contains('://')) {
      text = 'https://$text';
    }
    final uri = Uri.parse(text);
    if (uri.host.isEmpty) {
      throw const SyncServerException('服务器地址无法解析');
    }
    return uri.replace(path: '', query: '', fragment: '');
  }

  // ===== Sync =====

  /// One full pass: take everything the server has, then publish what is local.
  Future<void> syncNow() async {
    if (!_enabled || !loggedIn || _syncing) return;
    if (BackupActivity.isActive || (_shouldSkip?.call() ?? false)) return;

    _syncing = true;
    _lastError = null;
    notifyListeners();
    try {
      await _pull();
      await _push();
      _lastSyncAt = DateTime.now();
      _connected = true;
      _lastError = null;
    } on SyncServerException catch (error) {
      _lastError = error.message;
      _connected = false;
      if (error.isUnauthorized) {
        // The token aged out or the password changed on the server.
        _token = '';
        await _persistConfig();
      }
    } catch (error) {
      _lastError = error.toString();
      _connected = false;
    } finally {
      _syncing = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Applies everything the server has that this device has not seen.
  Future<void> _pull() async {
    final base = Uri.parse(_serverUrl);
    var guard = 0;
    while (guard < 1000) {
      guard += 1;
      final page = await _client.fetchChanges(
        base: base,
        token: _token,
        since: _localRev,
      );
      if (page.records.isEmpty) {
        if (page.rev > _localRev) _localRev = page.rev;
        await _persistState();
        break;
      }

      var report = await _service.applyRemote(page.records);
      // Anything whose parent had not arrived yet gets one more chance now
      // that the rest of the page has landed.
      if (report.retryable.isNotEmpty) {
        report = await _service.applyRemote(report.retryable);
      }

      _localRev = page.rev;
      await _persistState();
      if (!page.hasMore) break;
    }

    // The database moved because of what the server sent, not because of
    // anything the user did. Re-baseline so this does not look like a local
    // edit and bounce straight back out again.
    _publishedSignature = await _signature();
    await _persistState();
  }

  /// Publishes local changes the server has not seen.
  Future<void> _push() async {
    final base = Uri.parse(_serverUrl);
    final collected = await _service.collectChanges(cursors: _cursors);
    if (collected.records.isEmpty) {
      final signature = await _signature();
      if (signature != _publishedSignature) {
        _publishedSignature = signature;
        await _persistState();
      }
      return;
    }

    final result = await _client.push(
      base: base,
      token: _token,
      records: collected.records,
    );
    if (result.rev > _localRev) _localRev = result.rev;

    // Whatever the server kept instead of what was sent is the current truth;
    // writing it back is what stops this device from disagreeing forever.
    if (result.rejected.isNotEmpty) {
      await _service.applyRemote(result.rejected);
    }

    _cursors = {..._cursors, ...collected.cursors};
    _publishedSignature = await _signature();
    await _persistState();
  }

  // ===== Local change detection =====

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_disposed || !_enabled || !loggedIn || _syncing) return;
    try {
      final signature = await _signature();
      if (signature == _publishedSignature) return;
      await syncNow();
    } catch (_) {
      // A failed probe is not worth surfacing; the next tick retries.
    }
  }

  /// Size and mtime of the live database and its WAL: cheap enough to sample
  /// every tick, and it moves exactly when the user's data does.
  Future<String> _signature() async {
    final directory = await AppDirectories.getAppDataDirectory();
    final base = '${directory.path}/${AppDatabase.databaseFileName}';
    final buffer = StringBuffer();
    for (final suffix in const ['', '-wal']) {
      final file = File('$base$suffix');
      try {
        if (await file.exists()) {
          final stat = await file.stat();
          buffer.write('$suffix:${stat.size}:${stat.modified.millisecondsSinceEpoch};');
        } else {
          buffer.write('$suffix:-;');
        }
      } catch (_) {
        buffer.write('$suffix:?;');
      }
    }
    return buffer.toString();
  }

  // ===== Live channel =====

  void _connectLiveChannel() {
    if (_watchSubscription != null || !_enabled || !loggedIn) return;
    final base = Uri.parse(_serverUrl);
    _watchSubscription = _client
        .watch(base: base, token: _token)
        .listen(
          (rev) {
            _connected = true;
            // The server spoke first: pull what it has.
            unawaited(syncNow());
          },
          onError: (Object _) {},
          onDone: () {
            _watchSubscription = null;
            _connected = false;
          },
        );
  }

  // ===== Persistence =====

  void _loadPersistedState() {
    final config = _preferences.getString(configKey);
    if (config != null && config.isNotEmpty) {
      try {
        final decoded = jsonDecode(config);
        if (decoded is Map<String, dynamic>) {
          _serverUrl = (decoded['url'] as String?) ?? '';
          _token = (decoded['token'] as String?) ?? '';
          _enabled = decoded['enabled'] == true;
        }
      } catch (_) {}
    }

    final state = _preferences.getString(stateKey);
    if (state != null && state.isNotEmpty) {
      try {
        final decoded = jsonDecode(state);
        if (decoded is Map<String, dynamic>) {
          _localRev = switch (decoded['rev']) {
            int v => v,
            num v => v.toInt(),
            _ => 0,
          };
          final cursors = decoded['cursors'];
          if (cursors is Map) {
            _cursors = {
              for (final entry in cursors.entries)
                if (entry.key is String && entry.value is int)
                  entry.key as String: entry.value as int,
            };
          }
          _publishedSignature = (decoded['signature'] as String?) ?? '';
        }
      } catch (_) {}
    }
  }

  Future<void> _persistConfig() async {
    try {
      await _preferences.setString(
        configKey,
        jsonEncode({'url': _serverUrl, 'token': _token, 'enabled': _enabled}),
      );
    } catch (_) {}
  }

  Future<void> _persistState() async {
    try {
      await _preferences.setString(
        stateKey,
        jsonEncode({
          'rev': _localRev,
          'cursors': _cursors,
          'signature': _publishedSignature,
        }),
      );
    } catch (_) {}
  }
}
