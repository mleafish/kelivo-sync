import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// One record as it travels to or from the server.
///
/// Mirrors the server's own shape. [updatedAt] is microseconds since the epoch
/// and is what decides who wins when the same record changed in two places.
class ServerSyncRecord {
  const ServerSyncRecord({
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

  Map<String, dynamic> toJson() => {
    'namespace': namespace,
    'id': id,
    'payload': payload,
    'updatedAt': updatedAt,
    'deviceId': deviceId,
    if (deleted) 'deleted': true,
  };

  static ServerSyncRecord? fromJson(Map<String, dynamic> json) {
    final namespace = (json['namespace'] as String?)?.trim();
    final id = (json['id'] as String?)?.trim();
    if (namespace == null || namespace.isEmpty) return null;
    if (id == null || id.isEmpty) return null;
    final payload = json['payload'];
    return ServerSyncRecord(
      namespace: namespace,
      id: id,
      payload: payload is Map
          ? payload.cast<String, dynamic>()
          : const <String, dynamic>{},
      updatedAt: _asInt(json['updatedAt']),
      deviceId: (json['deviceId'] as String?) ?? '',
      deleted: json['deleted'] == true,
    );
  }

  static int _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v.trim()) ?? 0,
    _ => 0,
  };
}

/// A page of changes plus the cursor to continue from.
class ServerChangePage {
  const ServerChangePage({
    required this.records,
    required this.rev,
    required this.serverRev,
    required this.hasMore,
  });

  final List<ServerSyncRecord> records;
  final int rev;
  final int serverRev;
  final bool hasMore;
}

/// What the server did with a push.
class ServerPushResult {
  const ServerPushResult({
    required this.rev,
    required this.accepted,
    required this.rejected,
  });

  final int rev;
  final int accepted;

  /// Records the server kept its own version of. Applying these locally is what
  /// stops a losing device from continuing to believe its copy is current.
  final List<ServerSyncRecord> rejected;
}

class SyncServerException implements Exception {
  const SyncServerException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// Talks to a Kelivo sync server.
///
/// Holds no state of its own beyond the HTTP client: tokens and cursors belong
/// to the caller, so a token can be replaced without rebuilding this.
class ServerSyncClient {
  ServerSyncClient({http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
    : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Duration timeout;

  void close() => _http.close();

  /// Exchanges the shared password for a token.
  Future<String> login({
    required Uri base,
    required String password,
  }) async {
    final response = await _http
        .post(
          _endpoint(base, '/api/login'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'password': password}),
        )
        .timeout(timeout);
    if (response.statusCode == 401) {
      throw const SyncServerException('密码不正确', statusCode: 401);
    }
    if (response.statusCode != 200) {
      throw SyncServerException(
        '登录失败：${_describe(response)}',
        statusCode: response.statusCode,
      );
    }
    final body = _decodeObject(response);
    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw const SyncServerException('服务器没有返回登录令牌');
    }
    return token;
  }

  Future<ServerChangePage> fetchChanges({
    required Uri base,
    required String token,
    required int since,
    int limit = 200,
  }) async {
    final uri = _endpoint(base, '/api/changes').replace(
      queryParameters: {'since': '$since', 'limit': '$limit'},
    );
    final response = await _http
        .get(uri, headers: _authHeaders(token))
        .timeout(timeout);
    _ensureOk(response);
    final body = _decodeObject(response);
    final rawChanges = body['changes'];
    final records = <ServerSyncRecord>[];
    if (rawChanges is List) {
      for (final raw in rawChanges) {
        if (raw is! Map) continue;
        final record = ServerSyncRecord.fromJson(raw.cast<String, dynamic>());
        if (record != null) records.add(record);
      }
    }
    return ServerChangePage(
      records: records,
      rev: _asInt(body['rev']),
      serverRev: _asInt(body['serverRev']),
      hasMore: body['hasMore'] == true,
    );
  }

  Future<ServerPushResult> push({
    required Uri base,
    required String token,
    required List<ServerSyncRecord> records,
  }) async {
    final response = await _http
        .post(
          _endpoint(base, '/api/push'),
          headers: {..._authHeaders(token), 'content-type': 'application/json'},
          body: jsonEncode({
            'records': [for (final record in records) record.toJson()],
          }),
        )
        .timeout(timeout);
    _ensureOk(response);
    final body = _decodeObject(response);
    final rawRejected = body['rejected'];
    final rejected = <ServerSyncRecord>[];
    if (rawRejected is List) {
      for (final raw in rawRejected) {
        if (raw is! Map) continue;
        final record = ServerSyncRecord.fromJson(raw.cast<String, dynamic>());
        if (record != null) rejected.add(record);
      }
    }
    return ServerPushResult(
      rev: _asInt(body['rev']),
      accepted: _asInt(body['accepted']),
      rejected: rejected,
    );
  }

  /// Uploads a file body and gets back its content hash.
  Future<String> uploadBlob({
    required Uri base,
    required String token,
    required File file,
  }) async {
    final length = await file.length();
    final request = http.StreamedRequest('POST', _endpoint(base, '/api/blob'));
    request.headers.addAll({
      ..._authHeaders(token),
      'content-type': 'application/octet-stream',
    });
    request.contentLength = length;
    unawaited(
      file
          .openRead()
          .pipe(request.sink)
          .catchError((Object error) {
            request.sink.addError(error);
          }),
    );
    final streamed = await _http.send(request).timeout(
      // Generous: this is bounded by the file's size, not by latency.
      Duration(seconds: 30 + length ~/ (256 * 1024)),
    );
    final response = await http.Response.fromStream(streamed);
    _ensureOk(response);
    final body = _decodeObject(response);
    final hash = body['hash'];
    if (hash is! String || hash.isEmpty) {
      throw const SyncServerException('服务器没有返回文件哈希');
    }
    return hash;
  }

  Future<bool> hasBlob({
    required Uri base,
    required String token,
    required String hash,
  }) async {
    final response = await _http
        .head(_endpoint(base, '/api/blob/$hash'), headers: _authHeaders(token))
        .timeout(timeout);
    if (response.statusCode == 404) return false;
    _ensureOk(response);
    return true;
  }

  Future<void> downloadBlob({
    required Uri base,
    required String token,
    required String hash,
    required File destination,
  }) async {
    final request = http.Request(
      'GET',
      _endpoint(base, '/api/blob/$hash'),
    )..headers.addAll(_authHeaders(token));
    final streamed = await _http.send(request).timeout(timeout);
    if (streamed.statusCode == 404) {
      throw const SyncServerException('服务器上找不到该文件', statusCode: 404);
    }
    if (streamed.statusCode != 200) {
      throw SyncServerException(
        '下载文件失败：HTTP ${streamed.statusCode}',
        statusCode: streamed.statusCode,
      );
    }
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    try {
      await streamed.stream.pipe(sink);
    } catch (_) {
      await sink.close();
      rethrow;
    }
  }

  /// Connects to the server's live channel.
  ///
  /// Yields the server revision each time something changes. This is what makes
  /// sync immediate rather than polled: the server speaks first.
  Stream<int> watch({required Uri base, required String token}) {
    late StreamController<int> controller;
    WebSocket? socket;
    var closed = false;
    Timer? retry;
    var attempt = 0;

    Future<void> connect() async {
      if (closed) return;
      try {
        socket = await WebSocket.connect(
          _websocketUri(base, token).toString(),
        ).timeout(timeout);
        attempt = 0;
        socket!.listen(
          (dynamic message) {
            if (message is! String) return;
            try {
              final decoded = jsonDecode(message);
              if (decoded is Map && decoded['rev'] is int) {
                controller.add(decoded['rev'] as int);
              }
            } catch (_) {
              // Ignore anything that is not a revision notice.
            }
          },
          onDone: () => _scheduleReconnect(),
          onError: (Object _) => _scheduleReconnect(),
          cancelOnError: true,
        );
      } catch (_) {
        _scheduleReconnect();
      }
    }

    void _scheduleReconnect() {
      if (closed) return;
      socket = null;
      attempt += 1;
      // Backs off to a minute so a server that is down does not become a
      // request flood, and so a phone that lost signal stops retrying hot.
      final seconds = (1 << (attempt - 1)).clamp(1, 60);
      retry?.cancel();
      retry = Timer(Duration(seconds: seconds), connect);
    }

    controller = StreamController<int>(
      onListen: connect,
      onCancel: () async {
        closed = true;
        retry?.cancel();
        await socket?.close();
        socket = null;
      },
    );
    return controller.stream;
  }

  // ===== Helpers =====

  Map<String, String> _authHeaders(String token) => {
    'authorization': 'Bearer $token',
  };

  static Uri _endpoint(Uri base, String path) =>
      base.replace(path: path, query: '');

  static Uri _websocketUri(Uri base, String token) {
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(
      scheme: scheme,
      path: '/api/ws',
      queryParameters: {'token': token},
    );
  }

  static void _ensureOk(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 401) {
      throw const SyncServerException('登录已失效，请重新登录', statusCode: 401);
    }
    throw SyncServerException(
      _describe(response),
      statusCode: response.statusCode,
    );
  }

  static Map<String, dynamic> _decodeObject(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    throw const SyncServerException('服务器返回了无法解析的数据');
  }

  static String _describe(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {}
    return 'HTTP ${response.statusCode}';
  }

  static int _asInt(Object? value) => switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v.trim()) ?? 0,
    _ => 0,
  };
}
