import 'dart:io';
import 'dart:math';

/// The server's root key material: one 64-byte file beside the database.
/// Bytes 0-31 encrypt secrets at rest (AES-256-GCM); bytes 32-63 sign
/// access JWTs (HMAC-SHA256). One file because they share a lifecycle:
/// losing either means re-entering secrets and re-logging-in, and the
/// threat model for both is "the database file leaked without the disk".
class ServerKeys {
  const ServerKeys({required this.aesKey, required this.jwtKey});

  final List<int> aesKey;
  final List<int> jwtKey;
}

Future<ServerKeys> loadOrCreateServerKeys(String path) async {
  final file = File(path);
  late final List<int> bytes;
  if (file.existsSync()) {
    bytes = await file.readAsBytes();
    if (bytes.length != 64) {
      // Refusing beats regenerating: silently minting fresh keys would make
      // every stored secret undecryptable and every session invalid, and
      // the operator would learn about it only through the wreckage.
      throw StateError('$path exists but is not a 64-byte deptracker key file');
    }
  } else {
    final rng = Random.secure();
    bytes = List<int>.generate(64, (_) => rng.nextInt(256));
    // Create the file empty, tighten it to 0600, and only then write the
    // key bytes — so the secret material never exists on disk at the
    // process umask (typically 0644). dart:io has no chmod, and Windows
    // ACLs already default to per-user profile directories, so the mode
    // step is POSIX-only; there, a chmod that does not succeed is fatal
    // rather than leaving a world-readable key.
    await file.writeAsBytes(const [], flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', path]);
      if (chmod.exitCode != 0) {
        await file.delete();
        throw StateError(
          'could not restrict $path to 0600 (chmod exit ${chmod.exitCode}): '
          '${chmod.stderr}',
        );
      }
    }
    await file.writeAsBytes(bytes, flush: true);
  }
  return ServerKeys(aesKey: bytes.sublist(0, 32), jwtKey: bytes.sublist(32));
}
