import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Live connections, so a write on one device reaches the others immediately.
///
/// This is what makes sync feel instant rather than polled: without it a client
/// can only discover changes by asking, so latency is whatever the poll
/// interval is. With it, the other device is told the moment a revision lands.
class SyncHub {
  final Set<WebSocket> _sockets = <WebSocket>{};

  int get connectionCount => _sockets.length;

  void add(WebSocket socket) {
    _sockets.add(socket);
    socket.pingInterval = const Duration(seconds: 20);
    socket.listen(
      (dynamic message) => _handleMessage(socket, message),
      onDone: () => _sockets.remove(socket),
      onError: (Object _) {
        _sockets.remove(socket);
        socket.close();
      },
      cancelOnError: true,
    );
  }

  void _handleMessage(WebSocket socket, dynamic message) {
    if (message is! String) return;
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map && decoded['type'] == 'ping') {
        socket.add(jsonEncode({'type': 'pong'}));
      }
    } catch (_) {
      // A malformed frame is not worth dropping the connection over.
    }
  }

  /// Tells every connected client that new revisions are available.
  ///
  /// Only the revision number is sent, never the payloads: each client decides
  /// what it still needs, so a slow or reconnecting device cannot be sent a
  /// partial update it has no way to complete.
  void broadcastRevision(int rev) {
    if (_sockets.isEmpty) return;
    final frame = jsonEncode({'type': 'changed', 'rev': rev});
    for (final socket in _sockets.toList(growable: false)) {
      try {
        socket.add(frame);
      } catch (_) {
        _sockets.remove(socket);
      }
    }
  }

  Future<void> closeAll() async {
    for (final socket in _sockets.toList(growable: false)) {
      try {
        await socket.close(WebSocketStatus.goingAway);
      } catch (_) {}
    }
    _sockets.clear();
  }
}
