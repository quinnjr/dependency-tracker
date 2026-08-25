import '../client/rest_secrets.dart';
import '../client/sync_client.dart';
import '../secrets.dart';
import '../store.dart';
import 'app_resources.dart';

// The web build assembles a thin client: an in-memory mirror Store the
// SyncClient hydrates from the server's snapshot, and REST-backed versions
// of every operation with a side effect. No scanner closure of its own —
// scanning happens on the server's filesystem, triggered over REST — no
// keyring, no Net (the server does all fetching), and no local MCP.
// coverage:ignore-start
Future<AppResources> bootstrap() async {
  // In-memory on purpose, where the static build used IndexedDB: the server
  // is the persistence now, and a locally persisted mirror could only ever
  // misrepresent it after someone else's mutation.
  final store = await Store.openAsync(':memory:');
  final sync = SyncClient(Uri.base, store);
  await sync.initialize();

  return AppResources(
    store: store,
    secrets: Secrets(RestSecretBackend(sync)),
    refresh: sync.refresh,
    onScan: sync.scan,
    mcpKeys: sync.mcpKeys,
    mutations: sync.mutations,
    auth: sync,
    syncError: sync.syncError,
    isWeb: true,
    shutdown: () async {
      store.close();
    },
  );
}

// coverage:ignore-end
