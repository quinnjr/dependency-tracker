import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'redact.dart';
import 'store.dart';

/// Named, revocable MCP API keys. The key itself is returned exactly once at
/// minting and stored only as a SHA-256 hash, so neither a leaked database
/// nor the UI can reproduce it. SHA-256 without salt or stretching is right
/// here: the input is 32 CSPRNG bytes, not a password — there is nothing to
/// dictionary-attack.
class MintedKey {
  const MintedKey({required this.id, required this.name, required this.key});

  final int id;
  final String name;

  /// The one and only copy. Callers show it and drop it.
  final String key;
}

String hashApiKey(String key) => sha256.convert(utf8.encode(key)).toString();

MintedKey mintApiKey(Store store, String name) {
  final rng = Random.secure();
  final key =
      'dtk_${base64Url.encode(List<int>.generate(32, (_) => rng.nextInt(256))).replaceAll('=', '')}';
  // The plaintext key exists only here and in the one response that returns
  // it; register it so it is scrubbed from any error text it might reach
  // (the settings pane, the MCP transport's 500 path, the gateway's) —
  // the redaction the old single-token model gave the MCP credential.
  registerSecret(key);
  final id = store.insertApiKey(name, hashApiKey(key));
  return MintedKey(id: id, name: name, key: key);
}

/// Hash-then-lookup is constant-time by construction: the presented key is
/// hashed unconditionally, and the UNIQUE index probe does not leak which
/// byte differed the way a string compare could.
int? authenticateApiKey(
  Store store,
  String presented, {
  DateTime Function()? now,
}) {
  final id = store.apiKeyIdForHash(hashApiKey(presented));
  if (id != null) store.touchApiKey(id, (now ?? DateTime.now)());
  return id;
}
