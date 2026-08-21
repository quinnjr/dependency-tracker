import 'package:file_picker/file_picker.dart';

import '../api_keys.dart';
import '../mcp/protocol.dart';
import '../mcp/tools.dart';
import '../mcp/transport.dart';
import '../net.dart';
import '../paths.dart';
import '../refresh.dart';
import '../scanner.dart';
import '../secrets.dart';
import '../secrets_keyring.dart';
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

  // MCP authenticates against hashed API keys in the store, so unlike the
  // old keyring-token model there is no secret to acquire before starting —
  // the failures left for mcpError are real ones (the port would not bind,
  // the discovery file would not write).
  final transport = McpTransport(
    // A factory, not an instance: every MCP session gets its own server, and
    // the tools close over the live [store] so a session opened an hour ago
    // still reads current data.
    onSession: () => buildMcpServer(buildTools(store, refresh: refresh)),
    authenticate: (k) => authenticateApiKey(store, k),
  );
  int? mcpPort;
  Object? mcpError;
  try {
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
    mcpKeys: McpKeyOps.local(store),
    mutations: StoreMutations.local(store),
    shutdown: () async {
      await transport.stop();
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
