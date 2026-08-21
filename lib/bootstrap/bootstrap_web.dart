import '../net.dart';
import '../refresh.dart';
import '../secrets.dart';
import '../store.dart';
import 'app_resources.dart';

// The web build assembles less on purpose: no scanner (no filesystem), no
// MCP server (no listening socket), no keyring (no OS secret service). The
// GitHub token lives in MemorySecretBackend for the tab session — the
// README's no-plaintext-at-rest rule rules out localStorage-backed stores.
// coverage:ignore-start
Future<AppResources> bootstrap() async {
  final store = await Store.openAsync('deptracker.db');
  final secrets = Secrets(MemorySecretBackend());
  final net = Net(cache: store);

  // No KeyringUnavailable guard around githubToken(): MemorySecretBackend
  // cannot throw it, unlike the io bootstrap's keyring path.
  Future<RefreshReport> refresh(int? watchId) async => refreshAll(
    store,
    net,
    token: await secrets.githubToken(),
    onlyWatchId: watchId,
  );

  return AppResources(
    store: store,
    secrets: secrets,
    net: net,
    refresh: refresh,
    isWeb: true,
    shutdown: () async {
      net.close();
      store.close();
    },
  );
}

// coverage:ignore-end
