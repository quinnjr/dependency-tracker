import '../models.dart';
import '../net.dart';
import '../refresh.dart';
import '../secrets.dart';
import '../store.dart';

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

  final Future<ScanResult> Function()? onScan;
  final Future<String?> Function()? pickDirectory;
  final int? mcpPort;
  final Object? mcpError;
  final bool isWeb;
}
