import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secrets.dart';

/// The only backend the shipped desktop app may construct: wraps the OS
/// keyring via `flutter_secure_storage` (libsecret on Linux, Keychain on
/// macOS, DPAPI on Windows).
///
/// Lives apart from lib/secrets.dart because `flutter_secure_storage` pulls
/// in `dart:ui` through the Flutter framework, and the server binary — a
/// plain-VM process that uses [SqliteSecretBackend] instead — must be able
/// to import the rest of the secrets machinery without it.
class KeyringBackend implements SecretBackend {
  KeyringBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
