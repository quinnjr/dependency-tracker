import '../secrets.dart';
import 'sync_client.dart';

/// Thrown when the web build cannot reach the server to store a secret.
/// A [SecretStoreUnavailable] so `Secrets` passes it through unwrapped and
/// the settings pane catches the same type it catches for the keyring — but
/// with a message about the server, never about gnome-keyring.
class ServerSecretUnavailable implements SecretStoreUnavailable {
  ServerSecretUnavailable(this.cause);
  @override
  final Object cause;

  @override
  String toString() => 'could not reach the server to save the token';
}

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
  Future<String?> read(String key) async {
    // Degrade to "not set" rather than surfacing an error: a status probe
    // that cannot reach the server should leave the presence indicator
    // neutral, not desynced into a keyring message.
    try {
      return await _sync.githubTokenSet() ? 'is-set' : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _sync.putGithubToken(value);
    } catch (e) {
      throw ServerSecretUnavailable(e);
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _sync.putGithubToken(null);
    } catch (e) {
      throw ServerSecretUnavailable(e);
    }
  }
}
