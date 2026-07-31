import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'redact.dart';

const String _githubKey = 'github_pat';
const String _mcpKey = 'mcp_bearer_token';

/// Raised when the host has no usable keyring.
///
/// The spec forbids falling back to a plaintext file or to an unauthenticated
/// MCP server, so this is fatal for the MCP server and surfaced to the user
/// rather than swallowed.
class KeyringUnavailable implements Exception {
  KeyringUnavailable(this.cause);
  final Object cause;

  @override
  String toString() =>
      'KeyringUnavailable: no usable host keyring (${redact(cause.toString())}). '
      'On Linux, ensure a secret service such as gnome-keyring is running.';
}

abstract interface class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The only backend the shipped app may construct: wraps the OS keyring via
/// `flutter_secure_storage` (libsecret on Linux, Keychain on macOS, DPAPI on
/// Windows).
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

/// In-memory backend for tests, where no secret service is reachable. Never
/// used by the shipped app.
class MemorySecretBackend implements SecretBackend {
  final Map<String, String> _values = {};

  void seed(String key, String value) => _values[key] = value;
  bool contains(String key) => _values.containsKey(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// The only module that touches the host keyring.
///
/// Every secret read here is immediately handed to [registerSecret], so a
/// value cannot be in memory without also being redactable from error text.
/// Neither the GitHub PAT nor the MCP bearer token is ever passed to `Store`,
/// written to a config file, or logged — both live only through this class.
class Secrets {
  Secrets(this._backend);

  final SecretBackend _backend;

  Future<String?> githubToken() async {
    final value = await _guard(() => _backend.read(_githubKey));
    registerSecret(value);
    return (value == null || value.isEmpty) ? null : value;
  }

  /// An empty or whitespace-only token clears the entry rather than storing
  /// an empty string, so "no token" has exactly one representation.
  ///
  /// A non-empty token shorter than [minRedactableSecretLength] is rejected:
  /// `registerSecret` would silently decline to track it, so it could later
  /// appear verbatim in `watch.last_error` (which the UI shows and MCP tools
  /// return) with no way to redact it. Refusing to store it loses the user
  /// nothing, since a token that short cannot authenticate against GitHub
  /// anyway.
  Future<void> setGithubToken(String? token) async {
    if (token == null || token.trim().isEmpty) {
      await _guard(() => _backend.delete(_githubKey));
      return;
    }
    final trimmed = token.trim();
    if (trimmed.length < minRedactableSecretLength) {
      throw ArgumentError(
        'github token is too short to be redactable if it ever leaked '
        '(minimum $minRedactableSecretLength characters)',
      );
    }
    registerSecret(trimmed);
    await _guard(() => _backend.write(_githubKey, trimmed));
  }

  /// Returns the MCP bearer token, generating and storing one on first use.
  ///
  /// Generating on read means there is no separate provisioning step that
  /// could be skipped, leaving the server running without a token.
  Future<String> mcpToken() async {
    final existing = await _guard(() => _backend.read(_mcpKey));
    if (existing != null && existing.isNotEmpty) {
      registerSecret(existing);
      return existing;
    }
    return _generateMcpToken();
  }

  Future<void> rotateMcpToken() async {
    await _guard(() => _backend.delete(_mcpKey));
    await _generateMcpToken();
  }

  Future<String> _generateMcpToken() async {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    // base64url without padding: safe in an Authorization header and in JSON.
    final token = base64Url.encode(bytes).replaceAll('=', '');
    registerSecret(token);
    await _guard(() => _backend.write(_mcpKey, token));
    return token;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on KeyringUnavailable {
      rethrow;
    } catch (e) {
      throw KeyringUnavailable(e);
    }
  }
}
