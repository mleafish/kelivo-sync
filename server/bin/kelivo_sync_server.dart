import 'dart:async';
import 'dart:io';

import 'package:kelivo_sync_server/src/api.dart';
import 'package:kelivo_sync_server/src/config.dart';
import 'package:kelivo_sync_server/src/hub.dart';
import 'package:kelivo_sync_server/src/store.dart';

/// Entry point for the Kelivo sync server.
///
/// Run it with a config file (`config.json` beside the binary by default), or
/// point at one with `--config` / KELIVO_SYNC_CONFIG.
Future<void> main(List<String> args) async {
  String? configPath;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[i + 1];
    } else if (args[i].startsWith('--config=')) {
      configPath = args[i].substring('--config='.length);
    }
  }

  final ServerConfig config;
  try {
    config = await ServerConfig.load(configPath: configPath);
  } catch (error) {
    stderr.writeln('Configuration error: $error');
    exitCode = 2;
    return;
  }

  final store = SyncStore.open(config.dataDir);
  final hub = SyncHub();
  final api = SyncApi(config: config, store: store, hub: hub);

  try {
    await api.start();
  } catch (error) {
    stderr.writeln('Failed to bind ${config.host}:${config.port}: $error');
    store.close();
    exitCode = 1;
    return;
  }

  final scheme = config.usesTls ? 'https' : 'http';
  stdout.writeln(
    'Kelivo sync server listening on $scheme://${config.host}:${config.port}',
  );
  stdout.writeln('Data directory: ${config.dataDir}');
  stdout.writeln('Current revision: ${store.currentRev}');

  var shuttingDown = false;
  Future<void> shutdown(ProcessSignal signal) async {
    if (shuttingDown) return;
    shuttingDown = true;
    stdout.writeln('Shutting down...');
    await api.stop();
    store.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(shutdown);
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen(shutdown);
  }
}
