import '../api_keys.dart';
import '../models.dart';
import '../net.dart';
import '../notify.dart';
import '../refresh.dart';
import '../secrets.dart';
import '../store.dart';

/// The three key-manager operations settings needs, injected so the web
/// build can back them with REST instead of the local store. Async even on
/// desktop (where the store answers instantly), because the web build's
/// answers cross the network and one signature must serve both.
class McpKeyOps {
  const McpKeyOps({
    required this.list,
    required this.create,
    required this.revoke,
  });

  final Future<List<ApiKeyInfo>> Function() list;
  final Future<MintedKey> Function(String name) create;
  final Future<void> Function(int id) revoke;

  /// The desktop wiring: the local store, wrapped in immediate futures.
  factory McpKeyOps.local(Store store) => McpKeyOps(
    list: () async => store.apiKeys(),
    create: (name) async => mintApiKey(store, name),
    revoke: (id) async => store.revokeApiKey(id),
  );
}

/// The mutations UI widgets perform directly on watches and scan roots.
/// Desktop wires them straight to [Store]; web wires them to the SyncClient,
/// which POSTs to the server and applies the returned snapshot to the
/// mirror. Reads stay direct Store calls in both modes — that is the point
/// of the mirror.
class StoreMutations {
  const StoreMutations({
    required this.markRead,
    required this.snooze,
    required this.addScanRoot,
    required this.removeScanRoot,
  });

  final void Function(int watchId, {String? version}) markRead;
  final void Function(int watchId, DateTime until) snooze;
  final void Function(String path) addScanRoot;
  final void Function(String path) removeScanRoot;

  factory StoreMutations.local(Store store) => StoreMutations(
    markRead: store.markRead,
    snooze: store.snooze,
    addScanRoot: store.addScanRoot,
    removeScanRoot: store.removeScanRoot,
  );
}

/// What the web build's login screen and account section need from the
/// session layer. Abstract here so the widgets can be tested against a fake
/// with no HTTP; the real implementation lives with the SyncClient.
abstract interface class AuthController {
  /// Fires on any session-state change (login, logout, status load).
  StoreListenable get changes;

  bool get authenticated;
  String? get username;
  String? get role;

  /// True while the server reports zero accounts — the first-run state the
  /// UI answers with a create-the-admin-account form.
  bool get zeroUsers;
  bool get registrationOpen;

  /// Null on success, a rendered error message on failure.
  Future<String?> login(String username, String password);
  Future<String?> register(String username, String password);
  Future<void> logout();
  Future<void> setRegistrationOpen(bool open);
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
    required this.refresh,
    required this.shutdown,
    required this.mcpKeys,
    required this.mutations,
    this.net,
    this.auth,
    this.syncError,
    this.onScan,
    this.pickDirectory,
    this.mcpPort,
    this.mcpError,
    this.isWeb = false,
  });

  final Store store;
  final Secrets secrets;

  /// Null on web: the browser fetches nothing itself — the server does all
  /// registry work — so there is no HTTP client to own or close.
  final Net? net;

  final Future<RefreshReport> Function(int? watchId) refresh;

  /// Releases what bootstrap acquired (MCP port, database, HTTP client) —
  /// the platform that opened the resources is the one that knows how to
  /// close them.
  final Future<void> Function() shutdown;

  /// Key-manager operations for the settings pane's MCP section.
  final McpKeyOps mcpKeys;

  /// Watch/scan-root mutations for the widgets that perform them directly.
  final StoreMutations mutations;

  /// Present only on web: the session layer the login screen and account
  /// section drive. Desktop has no accounts.
  final AuthController? auth;

  /// Present only on web: the SyncClient's last failed round trip, for the
  /// shell to surface. Cleared by setting null.
  final ValueCell<String?>? syncError;

  final Future<ScanResult> Function()? onScan;
  final Future<String?> Function()? pickDirectory;
  final int? mcpPort;
  final Object? mcpError;
  final bool isWeb;
}
