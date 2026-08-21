import '../secrets.dart';
import 'sync_client.dart';

/// The web build's SecretBackend: writes go to the server (which encrypts
/// them into its SQLite), reads only answer the "is a token set?" question
/// the settings pane asks. The GitHub token itself never comes back — the
/// API is write-only by design — so a set token reads as the placeholder
/// `is-set`, deliberately shorter than `minRedactableSecretLength` so
/// `Secrets.githubToken`'s registerSecret call ignores it instead of
/// registering a constant string for redaction.
class RestSecretBackend implements SecretBackend {
  RestSecretBackend(this._sync);

  final SyncClient _sync;

  @override
  Future<String?> read(String key) async =>
      await _sync.githubTokenSet() ? 'is-set' : null;

  @override
  Future<void> write(String key, String value) => _sync.putGithubToken(value);

  @override
  Future<void> delete(String key) => _sync.putGithubToken(null);
}
