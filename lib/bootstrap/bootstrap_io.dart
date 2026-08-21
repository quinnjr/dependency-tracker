import 'package:file_picker/file_picker.dart';

import '../mcp/protocol.dart';
import '../mcp/tools.dart';
import '../mcp/transport.dart';
import '../net.dart';
import '../paths.dart';
import '../refresh.dart';
import '../scanner.dart';
import '../secrets.dart';
import '../store.dart';
import 'app_resources.dart';

// Everything below assembles real resources: the database at the user's data
// path, the OS keyring, and a listening socket. A test that ran it would touch
// the developer's own watchlist and keyring, so it is excluded rather than
// faked — the widget it assembles resources for (TrackerApp) and every
// collaborator it wires are injectable and are covered by test/main_test.dart.
// coverage:ignore-start
Future<AppResources> bootstrap() async {
  ensureDir(dataDir());
  final store = Store.open(databasePath());
  final secrets = Secrets(KeyringBackend());
  // Store implements EtagCache with its persistent http_cache table, so a
  // launch-time refresh reuses etags across restarts instead of burning
  // registry quota re-fetching everything every time the app opens.
  final net = Net(cache: store);

  Future<RefreshReport> refresh(int? watchId) async => refreshAll(
    store,
    net,
    token: await _githubTokenOrNull(secrets),
    onlyWatchId: watchId,
  );

  // The MCP server needs a bearer token, and the token lives in the keyring.
  // With no keyring there is no authenticated server, and the spec forbids
  // running an unauthenticated one — so the app runs without MCP and says why.
  McpTransport? transport;
  int? mcpPort;
  Object? mcpError;
  try {
    final token = await secrets.mcpToken();
    transport = McpTransport(
      // A factory, not an instance: every MCP session gets its own server, and
      // the tools close over the live [store] so a session opened an hour ago
      // still reads current data.
      onSession: () => buildMcpServer(buildTools(store, refresh: refresh)),
      bearerToken: token,
    );
    mcpPort = await transport.start();
    await writeDiscoveryFile(mcpPort);
  } catch (e) {
    mcpError = e;
  }

  return AppResources(
    store: store,
    secrets: secrets,
    net: net,
    refresh: refresh,
    onScan: () => scanRoots(store),
    pickDirectory: () => FilePicker.platform.getDirectoryPath(),
    mcpPort: mcpPort,
    mcpError: mcpError,
    shutdown: () async {
      await transport?.stop();
      net.close();
      store.close();
    },
  );
}

/// A missing keyring must not cost the optional GitHub PAT path: a refresh
/// with no token simply falls back to public Atom feeds for release notes.
Future<String?> _githubTokenOrNull(Secrets secrets) async {
  try {
    return await secrets.githubToken();
  } on KeyringUnavailable {
    return null;
  }
}

// coverage:ignore-end
