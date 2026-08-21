import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../secrets.dart';
import '../store.dart';

/// SecretBackend for the server: values AES-256-GCM-encrypted into the
/// store's `secret` table, keyed by the file beside the database. A leaked
/// database or backup is useless without that file; a fully compromised
/// host is out of scope, as for any keyring-less server.
class SqliteSecretBackend implements SecretBackend {
  SqliteSecretBackend(this._store, List<int> aesKey)
    : _key = SecretKey(List<int>.from(aesKey));

  final Store _store;
  final SecretKey _key;
  final AesGcm _cipher = AesGcm.with256bits();

  @override
  Future<String?> read(String key) async {
    final row = _store.secretGet(key);
    if (row == null) return null;
    final box = SecretBox.fromConcatenation(
      [...row.nonce, ...row.ciphertext],
      nonceLength: 12,
      macLength: 16,
    );
    // A wrong key throws (GCM tag mismatch) rather than returning garbage —
    // failing closed is the point of authenticated encryption.
    final clear = await _cipher.decrypt(box, secretKey: _key);
    return utf8.decode(clear);
  }

  @override
  Future<void> write(String key, String value) async {
    final box = await _cipher.encrypt(utf8.encode(value), secretKey: _key);
    _store.secretPut(key, box.nonce, [...box.cipherText, ...box.mac.bytes]);
  }

  @override
  Future<void> delete(String key) async => _store.secretDelete(key);
}
