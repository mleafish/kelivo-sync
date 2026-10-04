import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth.dart';
import 'config.dart';
import 'hub.dart';
import 'store.dart';

/// HTTP and WebSocket surface of the sync server.
///
/// Deliberately small and dumb: it stores records, orders them, and tells the
/// other clients when something changed. It never interprets chat data, which
/// is what lets one server carry every kind of client data without knowing
/// what any of it means.
class SyncApi {
  SyncApi({required this.config, required this.store, required this.hub})
    : _auth = Auth(
        password: config.password,
        secret: config.tokenSecret,
        ttl: config.tokenTtl,
      );

  final ServerConfig config;
  final SyncStore store;
  final SyncHub hub;
  final Auth _auth;

  HttpServer? _server;

  Future<void> start() async {
    final server = config.usesTls
        ? await HttpServer.bindSecure(
            config.host,
            config.port,
            SecurityContext()
              ..useCertificateChain(config.tlsCertPath!)
              ..usePrivateKey(config.tlsKeyPath!),
          )
        : await HttpServer.bind(config.host, config.port);
    _server = server;
    server.listen(_handle, onError: (Object error) => stderr.writeln(error));
  }

  Future<void> stop() async {
    await hub.closeAll();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      await _route(request);
    } catch (error, stackTrace) {
      stderr.writeln('[request] $error\n$stackTrace');
      await _replyJson(
        request,
        HttpStatus.internalServerError,
        {'error': 'internal_error'},
      );
    }
  }

  Future<void> _route(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    if (method == 'GET' && path == '/api/health') {
      return _replyJson(request, HttpStatus.ok, {
        'ok': true,
        'rev': store.currentRev,
        'connections': hub.connectionCount,
      });
    }

    if (method == 'POST' && path == '/api/login') {
      return _login(request);
    }

    if (method == 'GET' && path == '/api/ws') {
      return _websocket(request);
    }

    // Everything past this point needs a valid token.
    if (!_isAuthorized(request)) {
      return _replyJson(request, HttpStatus.unauthorized, {
        'error': 'unauthorized',
      });
    }

    if (method == 'GET' && path == '/api/changes') {
      return _changes(request);
    }
    if (method == 'POST' && path == '/api/push') {
      return _push(request);
    }
    if (path.startsWith('/api/blob/')) {
      final hash = path.substring('/api/blob/'.length);
      if (method == 'GET' || method == 'HEAD') return _getBlob(request, hash);
    }
    if (method == 'POST' && path == '/api/blob') {
      return _putBlob(request);
    }
    if (method == 'POST' && path == '/api/blobs/check') {
      return _checkBlobs(request);
    }

    return _replyJson(request, HttpStatus.notFound, {'error': 'not_found'});
  }

  // ===== Auth =====

  bool _isAuthorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header != null && header.toLowerCase().startsWith('bearer ')) {
      if (_auth.tokenIsValid(header.substring(7).trim())) return true;
    }
    final token = request.uri.queryParameters['token'];
    if (token != null && _auth.tokenIsValid(token)) return true;
    return false;
  }

  Future<void> _login(HttpRequest request) async {
    final body = await _readJsonObject(request);
    if (body == null) {
      return _replyJson(request, HttpStatus.badRequest, {
        'error': 'invalid_body',
      });
    }
    final candidate = body['password'];
    if (candidate is! String || !_auth.passwordMatches(candidate)) {
      // Deliberately slow enough that guessing cannot be parallelized cheaply.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return _replyJson(request, HttpStatus.unauthorized, {
        'error': 'bad_password',
      });
    }
    return _replyJson(request, HttpStatus.ok, {
      'token': _auth.issueToken(),
      'expiresInSeconds': config.tokenTtl.inSeconds,
      'rev': store.currentRev,
    });
  }

  // ===== Records =====

  Future<void> _changes(HttpRequest request) async {
    final since =
        int.tryParse(request.uri.queryParameters['since'] ?? '0') ?? 0;
    final limit = (int.tryParse(request.uri.queryParameters['limit'] ?? '') ??
            200)
        .clamp(1, 1000);
    final records = store.changesSince(since, limit: limit);
    final nextRev = records.isEmpty ? store.currentRev : records.last.rev;
    return _replyJson(request, HttpStatus.ok, {
      'rev': nextRev,
      'serverRev': store.currentRev,
      'hasMore': nextRev < store.currentRev,
      'changes': [
        for (final stored in records) stored.record.toJson(rev: stored.rev),
      ],
    });
  }

  Future<void> _push(HttpRequest request) async {
    final body = await _readJsonObject(request);
    if (body == null) {
      return _replyJson(request, HttpStatus.badRequest, {
        'error': 'invalid_body',
      });
    }
    final rawRecords = body['records'];
    if (rawRecords is! List) {
      return _replyJson(request, HttpStatus.badRequest, {
        'error': 'invalid_records',
      });
    }

    var accepted = 0;
    final rejected = <Map<String, dynamic>>[];
    for (final raw in rawRecords) {
      if (raw is! Map) continue;
      final record = SyncRecord.fromJson(raw.cast<String, dynamic>());
      if (record == null) continue;
      final result = store.merge(record);
      switch (result.outcome) {
        case SyncStore.accepted:
          accepted += 1;
        case SyncStore.stale:
          // Tell the client what actually won so it can correct itself. Without
          // this the loser would keep believing its own version is current.
          rejected.add(result.current!.record.toJson(rev: result.current!.rev));
        case SyncStore.superseded:
          break;
      }
    }

    if (accepted > 0) {
      hub.broadcastRevision(store.currentRev);
    }
    return _replyJson(request, HttpStatus.ok, {
      'rev': store.currentRev,
      'accepted': accepted,
      'rejected': rejected,
    });
  }

  // ===== Blobs =====

  /// Streams the body to a temporary file so that a large upload never has to
  /// fit in memory, then stores it under its own sha256.
  Future<void> _putBlob(HttpRequest request) async {
    final tempDir = Directory('${config.dataDir}/tmp');
    await tempDir.create(recursive: true);
    final temp = File(
      '${tempDir.path}/${DateTime.now().microsecondsSinceEpoch}'
      '_${Random().nextInt(1 << 32)}.part',
    );
    var received = 0;
    final sink = temp.openWrite();
    try {
      await for (final chunk in request) {
        received += chunk.length;
        if (received > config.maxBlobBytes) {
          await sink.close();
          await temp.delete().catchError((Object _) => temp);
          await _replyJson(request, HttpStatus.requestEntityTooLarge, {
            'error': 'blob_too_large',
          });
          return;
        }
        sink.add(chunk);
      }
      await sink.close();

      final digest = await sha256.bind(temp.openRead()).first;
      final hash = digest.toString();
      if (!store.hasBlob(hash)) {
        final bytes = await temp.readAsBytes();
        store.putBlob(bytes);
      }
      await _replyJson(request, HttpStatus.ok, {
        'hash': hash,
        'size': received,
      });
      return;
    } finally {
      if (await temp.exists()) {
        await temp.delete().catchError((Object _) => temp);
      }
    }
  }

  Future<void> _getBlob(HttpRequest request, String hash) async {    final file = store.blobFile(hash);
    if (file == null) {
      return _replyJson(request, HttpStatus.notFound, {'error': 'no_blob'});
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.binary;
    request.response.headers.contentLength = await file.length();
    if (request.method == 'HEAD') {
      await request.response.close();
      return;
    }
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  /// Reports which of the offered hashes the server already stores.
  ///
  /// Lets a client ask once, in bulk, what it still needs to send, instead of
  /// probing file by file.
  Future<void> _checkBlobs(HttpRequest request) async {
    final body = await _readJsonObject(request);
    final hashes = body?['hashes'];
    if (hashes is! List) {
      return _replyJson(request, HttpStatus.badRequest, {
        'error': 'invalid_hashes',
      });
    }
    final wanted = <String>[
      for (final hash in hashes)
        if (hash is String && hash.isNotEmpty) hash,
    ];
    final present = store.filterExistingBlobs(wanted);
    return _replyJson(request, HttpStatus.ok, {'present': present.toList()});
  }

  // ===== WebSocket =====

  Future<void> _websocket(HttpRequest request) async {
    if (!_isAuthorized(request)) {
      return _replyJson(request, HttpStatus.unauthorized, {
        'error': 'unauthorized',
      });
    }
    final socket = await WebSocketTransformer.upgrade(request);
    hub.add(socket);
    socket.add(
      jsonEncode({'type': 'welcome', 'rev': store.currentRev}),
    );
  }

  // ===== Helpers =====

  Future<Map<String, dynamic>?> _readJsonObject(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _replyJson(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
