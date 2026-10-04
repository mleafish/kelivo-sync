import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Server configuration, loaded from a JSON file and overridable by
/// environment variables.
///
/// The login password deliberately has no default. A server that starts with a
/// built-in password is a server anyone can read, so a missing password is a
/// startup failure rather than a fallback.
class ServerConfig {
  const ServerConfig({
    required this.password,
    required this.tokenSecret,
    required this.dataDir,
    this.host = '0.0.0.0',
    this.port = 8787,
    this.tokenTtl = const Duration(days: 90),
    this.maxBlobBytes = 512 * 1024 * 1024,
    this.tlsCertPath,
    this.tlsKeyPath,
  });

  /// Shared login password. Every client presents this once, then gets a token.
  final String password;

  /// HMAC key for issued tokens. Kept out of the config file when possible so
  /// that leaking the config does not also let someone mint tokens.
  final String tokenSecret;

  final String dataDir;
  final String host;
  final int port;
  final Duration tokenTtl;
  final int maxBlobBytes;
  final String? tlsCertPath;
  final String? tlsKeyPath;

  bool get usesTls => tlsCertPath != null && tlsKeyPath != null;

  static Future<ServerConfig> load({String? configPath}) async {
    final env = Platform.environment;
    final path =
        configPath ?? env['KELIVO_SYNC_CONFIG'] ?? 'config.json';

    Map<String, dynamic> raw = const {};
    final file = File(path);
    if (await file.exists()) {
      final text = await file.readAsString();
      if (text.trim().isNotEmpty) {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('config.json must be a JSON object');
        }
        raw = decoded;
      }
    }

    final password = (env['KELIVO_SYNC_PASSWORD'] ?? raw['password'] as String?)
        ?.trim();
    if (password == null || password.isEmpty) {
      throw StateError(
        'No login password configured. Set "password" in $path or the '
        'KELIVO_SYNC_PASSWORD environment variable.',
      );
    }

    final dataDir = (raw['dataDir'] as String?)?.trim();
    if (dataDir == null || dataDir.isEmpty) {
      throw StateError('"dataDir" is required in $path');
    }
    await Directory(dataDir).create(recursive: true);

    final secret = await _resolveSecret(raw['tokenSecret'] as String?, dataDir);

    final tls = raw['tls'];
    final tlsMap = tls is Map ? tls.cast<String, dynamic>() : const {};

    return ServerConfig(
      password: password,
      tokenSecret: secret,
      dataDir: dataDir,
      host: (raw['host'] as String?)?.trim().isNotEmpty == true
          ? (raw['host'] as String).trim()
          : '0.0.0.0',
      port: _intOr(env['KELIVO_SYNC_PORT'], raw['port'], 8787),
      tokenTtl: Duration(
        days: _intOr(null, raw['tokenTtlDays'], 90),
      ),
      maxBlobBytes: _intOr(null, raw['maxBlobBytes'], 512 * 1024 * 1024),
      tlsCertPath: (tlsMap['cert'] as String?)?.trim(),
      tlsKeyPath: (tlsMap['key'] as String?)?.trim(),
    );
  }

  /// Returns the configured secret, or a generated one persisted beside the
  /// data so that tokens survive a restart.
  static Future<String> _resolveSecret(String? configured, String dataDir) async {
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    final file = File('$dataDir/token_secret');
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final secret = base64Url.encode(bytes);
    await file.writeAsString(secret, flush: true);
    await _restrictToOwner(file);
    return secret;
  }

  /// Best effort: a no-op on Windows, which has no POSIX mode bits.
  static Future<void> _restrictToOwner(File file) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['600', file.path]);
    } catch (_) {}
  }

  static int _intOr(String? envValue, Object? raw, int fallback) {
    final fromEnv = envValue == null ? null : int.tryParse(envValue.trim());
    if (fromEnv != null) return fromEnv;
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }
}
