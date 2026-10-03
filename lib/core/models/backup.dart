import 'dart:convert';

enum RestoreMode {
  overwrite, // 完全覆盖：清空本地后恢复
  merge, // 增量合并：智能去重
}

class WebDavConfig {
  final String url;
  final String username;
  final String password;
  final String path;
  final String userAgent;
  final bool includeChats; // Hive boxes
  final bool includeFiles; // uploads/

  const WebDavConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.path = 'kelivo_backups',
    this.userAgent = '',
    this.includeChats = true,
    this.includeFiles = true,
  });

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? path,
    String? userAgent,
    bool? includeChats,
    bool? includeFiles,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      path: path ?? this.path,
      userAgent: userAgent ?? this.userAgent,
      includeChats: includeChats ?? this.includeChats,
      includeFiles: includeFiles ?? this.includeFiles,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'password': password,
    'path': path,
    'userAgent': userAgent,
    'includeChats': includeChats,
    'includeFiles': includeFiles,
  };

  static WebDavConfig fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: (json['url'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      password: (json['password'] as String?) ?? '',
      path: (json['path'] as String?)?.trim().isNotEmpty == true
          ? (json['path'] as String).trim()
          : 'kelivo_backups',
      userAgent: (json['userAgent'] as String?) ?? '',
      includeChats: json['includeChats'] as bool? ?? true,
      includeFiles: json['includeFiles'] as bool? ?? true,
    );
  }

  static WebDavConfig fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return WebDavConfig.fromJson(map);
    } catch (_) {
      return const WebDavConfig();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

class S3Config {
  final String
  endpoint; // e.g. https://s3.amazonaws.com or https://<accountid>.r2.cloudflarestorage.com
  final String
  region; // e.g. us-east-1 / auto (for some S3-compatible providers)
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final String sessionToken; // optional
  final String prefix; // object key prefix/folder
  final bool
  pathStyle; // safer for custom endpoints (no bucket subdomain TLS mismatch)
  final String userAgent;
  final bool includeChats;
  final bool includeFiles;

  const S3Config({
    this.endpoint = '',
    this.region = 'us-east-1',
    this.bucket = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.sessionToken = '',
    this.prefix = 'kelivo_backups',
    this.pathStyle = true,
    this.userAgent = '',
    this.includeChats = true,
    this.includeFiles = true,
  });

  S3Config copyWith({
    String? endpoint,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    String? prefix,
    bool? pathStyle,
    String? userAgent,
    bool? includeChats,
    bool? includeFiles,
  }) {
    return S3Config(
      endpoint: endpoint ?? this.endpoint,
      region: region ?? this.region,
      bucket: bucket ?? this.bucket,
      accessKeyId: accessKeyId ?? this.accessKeyId,
      secretAccessKey: secretAccessKey ?? this.secretAccessKey,
      sessionToken: sessionToken ?? this.sessionToken,
      prefix: prefix ?? this.prefix,
      pathStyle: pathStyle ?? this.pathStyle,
      userAgent: userAgent ?? this.userAgent,
      includeChats: includeChats ?? this.includeChats,
      includeFiles: includeFiles ?? this.includeFiles,
    );
  }

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'region': region,
    'bucket': bucket,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'sessionToken': sessionToken,
    'prefix': prefix,
    'pathStyle': pathStyle,
    'userAgent': userAgent,
    'includeChats': includeChats,
    'includeFiles': includeFiles,
  };

  static S3Config fromJson(Map<String, dynamic> json) {
    return S3Config(
      endpoint: (json['endpoint'] as String?)?.trim() ?? '',
      region: (json['region'] as String?)?.trim().isNotEmpty == true
          ? (json['region'] as String).trim()
          : 'us-east-1',
      bucket: (json['bucket'] as String?)?.trim() ?? '',
      accessKeyId: (json['accessKeyId'] as String?)?.trim() ?? '',
      secretAccessKey: (json['secretAccessKey'] as String?) ?? '',
      sessionToken: (json['sessionToken'] as String?) ?? '',
      prefix: (json['prefix'] as String?)?.trim().isNotEmpty == true
          ? (json['prefix'] as String).trim()
          : 'kelivo_backups',
      pathStyle: json['pathStyle'] as bool? ?? true,
      userAgent: (json['userAgent'] as String?) ?? '',
      includeChats: json['includeChats'] as bool? ?? true,
      includeFiles: json['includeFiles'] as bool? ?? true,
    );
  }

  static S3Config fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return S3Config.fromJson(map);
    } catch (_) {
      return const S3Config();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

/// Configuration for real-time, bidirectional S3 sync between devices.
///
/// Connection details are shared with [S3Config]; this only carries what the
/// sync engine adds on top: which device this install is, how often to check
/// for remote changes, and how much data to move.
class S3SyncConfig {
  final bool enabled;
  final String
  deviceId; // stable per install, generated on first enable
  final String deviceName; // user-facing label, e.g. "iPhone" / "PC"
  final bool syncFiles; // include uploaded assets (images, files)
  final int intervalSeconds; // how often to look for remote changes

  const S3SyncConfig({
    this.enabled = false,
    this.deviceId = '',
    this.deviceName = '',
    this.syncFiles = false,
    this.intervalSeconds = 20,
  });

  S3SyncConfig copyWith({
    bool? enabled,
    String? deviceId,
    String? deviceName,
    bool? syncFiles,
    int? intervalSeconds,
  }) {
    return S3SyncConfig(
      enabled: enabled ?? this.enabled,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      syncFiles: syncFiles ?? this.syncFiles,
      intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'syncFiles': syncFiles,
    'intervalSeconds': intervalSeconds,
  };

  static S3SyncConfig fromJson(Map<String, dynamic> json) {
    final rawInterval = json['intervalSeconds'];
    final interval = switch (rawInterval) {
      int v => v,
      num v => v.toInt(),
      String v => int.tryParse(v.trim()) ?? 20,
      _ => 20,
    };
    return S3SyncConfig(
      enabled: json['enabled'] as bool? ?? false,
      deviceId: (json['deviceId'] as String?)?.trim() ?? '',
      deviceName: (json['deviceName'] as String?)?.trim() ?? '',
      syncFiles: json['syncFiles'] as bool? ?? false,
      intervalSeconds: interval.clamp(10, 3600),
    );
  }

  static S3SyncConfig fromJsonString(String s) {
    try {
      final map = jsonDecode(s) as Map<String, dynamic>;
      return S3SyncConfig.fromJson(map);
    } catch (_) {
      return const S3SyncConfig();
    }
  }

  String toJsonString() => jsonEncode(toJson());
}

class BackupFileItem {
  final Uri href; // absolute
  final String displayName;
  final int size;
  final DateTime? lastModified;
  const BackupFileItem({
    required this.href,
    required this.displayName,
    required this.size,
    required this.lastModified,
  });
}
