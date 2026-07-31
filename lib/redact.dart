/// Secrets that must never appear in an error message, a log line, an MCP tool
/// response, or `watch.last_error`.
///
/// The spec requires both the GitHub PAT and the MCP bearer token be stripped
/// from error text. Registering them in one leaf module means every caller of
/// [redact] is covered without each one having to know which secrets exist.
///
/// This file must have no imports from this package: it sits at the bottom of
/// the dependency graph deliberately, so nothing has an excuse to skip it.
final Set<String> _secrets = {};

/// Below this length a "secret" is more likely to be a substring of ordinary
/// text than an actual credential, and redacting it would corrupt messages.
///
/// Public so callers that store secrets (see `lib/secrets.dart`) can refuse
/// to persist a value this module could never redact, rather than the two
/// thresholds drifting independently.
const int minRedactableSecretLength = 8;

void registerSecret(String? secret) {
  if (secret == null) return;
  if (secret.length < minRedactableSecretLength) return;
  _secrets.add(secret);
}

void clearSecrets() => _secrets.clear();

String redact(String text) {
  var out = text;
  for (final s in _secrets) {
    // Plain string replacement, not a regex: secrets may contain metacharacters
    // and escaping them correctly is more work than not needing to.
    out = out.replaceAll(s, '«redacted»');
  }
  return out;
}
