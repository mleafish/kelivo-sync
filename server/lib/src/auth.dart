import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Password check and token issuing.
///
/// Tokens are self-contained (`payload.signature`) so the server keeps no
/// session table: a token is valid until it expires, and a restart does not
/// sign everyone out because the signing key is persisted.
class Auth {
  Auth({required this.password, required this.secret, required this.ttl});

  final String password;
  final String secret;
  final Duration ttl;

  /// Constant-time comparison, so that a wrong guess cannot be narrowed down by
  /// how long the rejection took.
  bool passwordMatches(String candidate) {
    final a = utf8.encode(candidate);
    final b = utf8.encode(password);
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  String issueToken({DateTime? now}) {
    final issuedAt = (now ?? DateTime.now()).toUtc();
    final payload = jsonEncode({
      'iat': issuedAt.millisecondsSinceEpoch,
      'exp': issuedAt.add(ttl).millisecondsSinceEpoch,
    });
    final encoded = base64Url.encode(utf8.encode(payload));
    return '$encoded.${_sign(encoded)}';
  }

  /// Returns true when [token] was issued by this server and has not expired.
  bool tokenIsValid(String token, {DateTime? now}) {
    final separator = token.lastIndexOf('.');
    if (separator <= 0) return false;
    final encoded = token.substring(0, separator);
    final signature = token.substring(separator + 1);
    if (!_constantTimeEquals(signature, _sign(encoded))) return false;

    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (decoded is! Map<String, dynamic>) return false;
      final exp = decoded['exp'];
      if (exp is! int) return false;
      final nowMillis = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
      return nowMillis < exp;
    } catch (_) {
      return false;
    }
  }

  String _sign(String encoded) {
    final mac = Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(encoded));
    return base64Url.encode(mac.bytes);
  }

  static bool _constantTimeEquals(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  /// A stable path-safe device label, used only for diagnostics.
  static String randomId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
