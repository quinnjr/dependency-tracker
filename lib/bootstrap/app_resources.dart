import '../api_keys.dart';
import '../models.dart';
import '../net.dart';
import '../refresh.dart';
import '../secrets.dart';
import '../store.dart';

/// The three key-manager operations settings needs, injected so the web
/// build can back them with REST instead of the local store.
class McpKeyOps {
  const McpKeyOps({
    required this.list,
    required this.create,
    required this.revoke,
  });

  final List<ApiKeyInfo> Function() list;
  final MintedKey Function(String name) create;
  final void Function(int id) revoke;
}

/// Everything main.dart's platform bootstrap assembled, in one bag, so the
/// widget tree never has to know which platform assembled it. The io
/// variant fills every field; the web variant leaves the scanner and MCP
/// fields null, which is how the UI knows those subsystems do not exist
/// rather than merely failed.
class AppResources {
  const AppResources({
    required this.store,
    required this.secrets,
    required this.net,
    required this.refresh,
    required this.shutdown,
    required this.mcpKeys,
    this.onScan,
    this.pickDirectory,
    this.mcpPort,
    this.mcpError,
    this.isWeb = false,
  });

  final Store store;
  final Secrets secrets;
  final Net net;
  final Future<RefreshReport> Function(int? watchId) refresh;

  /// Releases what bootstrap acquired (MCP port, database, HTTP client) —
  /// the platform that opened the resources is the one that knows how to
  /// close them.
  final Future<void> Function() shutdown;

  /// Key-manager operations for the settings pane's MCP section.
  final McpKeyOps mcpKeys;

  final Future<ScanResult> Function()? onScan;
  final Future<String?> Function()? pickDirectory;
  final int? mcpPort;
  final Object? mcpError;
  final bool isWeb;
}
