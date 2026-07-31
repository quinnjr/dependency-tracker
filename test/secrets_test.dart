import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/redact.dart';
import 'package:deptracker/secrets.dart';

void main() {
  setUp(clearSecrets);

  test('github token round-trips', () async {
    final s = Secrets(MemorySecretBackend());
    expect(await s.githubToken(), isNull);
    await s.setGithubToken('ghp_abcdefghijklmnop');
    expect(await s.githubToken(), 'ghp_abcdefghijklmnop');
  });

  test('setting a github token registers it for redaction', () async {
    final s = Secrets(MemorySecretBackend());
    await s.setGithubToken('ghp_abcdefghijklmnop');
    expect(redact('using ghp_abcdefghijklmnop'), 'using «redacted»');
  });

  test('reading a stored github token registers it for redaction', () async {
    final backend = MemorySecretBackend()
      ..seed('github_pat', 'ghp_abcdefghijklmnop');
    final s = Secrets(backend);
    await s.githubToken();
    expect(redact('ghp_abcdefghijklmnop'), '«redacted»');
  });

  test(
    'an empty github token clears the entry rather than storing empty',
    () async {
      final backend = MemorySecretBackend();
      final s = Secrets(backend);
      await s.setGithubToken('ghp_abcdefghijklmnop');
      await s.setGithubToken('');
      expect(await s.githubToken(), isNull);
      expect(backend.contains('github_pat'), isFalse);
    },
  );

  test('null clears the github token', () async {
    final s = Secrets(MemorySecretBackend());
    await s.setGithubToken('ghp_abcdefghijklmnop');
    await s.setGithubToken(null);
    expect(await s.githubToken(), isNull);
  });

  test('mcp token is generated on first read and then stable', () async {
    final s = Secrets(MemorySecretBackend());
    final first = await s.mcpToken();
    expect(first, isNotEmpty);
    expect(await s.mcpToken(), first);
  });

  test('mcp token is long enough to resist guessing', () async {
    final s = Secrets(MemorySecretBackend());
    final token = await s.mcpToken();
    // 32 random bytes, base64url without padding.
    expect(token.length, greaterThanOrEqualTo(43));
  });

  test(
    'mcp token is url-safe so it survives a header and a config file',
    () async {
      final s = Secrets(MemorySecretBackend());
      expect(await s.mcpToken(), matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    },
  );

  test('two generated mcp tokens differ', () async {
    final a = await Secrets(MemorySecretBackend()).mcpToken();
    final b = await Secrets(MemorySecretBackend()).mcpToken();
    expect(a, isNot(b));
  });

  test('mcp token is registered for redaction', () async {
    final s = Secrets(MemorySecretBackend());
    final token = await s.mcpToken();
    expect(redact('Bearer $token'), 'Bearer «redacted»');
  });

  test('rotating replaces the mcp token', () async {
    final s = Secrets(MemorySecretBackend());
    final first = await s.mcpToken();
    await s.rotateMcpToken();
    expect(await s.mcpToken(), isNot(first));
  });

  test('a github token shorter than the redaction floor is rejected', () async {
    final backend = MemorySecretBackend();
    final s = Secrets(backend);
    await expectLater(s.setGithubToken('short'), throwsA(isA<ArgumentError>()));
    expect(backend.contains('github_pat'), isFalse);
  });

  test('empty and whitespace-only tokens still clear the entry', () async {
    final backend = MemorySecretBackend();
    final s = Secrets(backend);
    await s.setGithubToken('ghp_abcdefghijklmnop');
    await s.setGithubToken('   ');
    expect(await s.githubToken(), isNull);
    expect(backend.contains('github_pat'), isFalse);
  });

  test('a token exactly at the redaction floor is accepted', () async {
    final backend = MemorySecretBackend();
    final s = Secrets(backend);
    final token = 'a' * minRedactableSecretLength;
    await s.setGithubToken(token);
    expect(await s.githubToken(), token);
  });

  test('a token one character below the redaction floor is rejected', () async {
    final backend = MemorySecretBackend();
    final s = Secrets(backend);
    final token = 'a' * (minRedactableSecretLength - 1);
    await expectLater(s.setGithubToken(token), throwsA(isA<ArgumentError>()));
    expect(backend.contains('github_pat'), isFalse);
  });

  test('the rejection message does not contain the rejected value', () async {
    final s = Secrets(MemorySecretBackend());
    const rejected = 'xkcd42';
    try {
      await s.setGithubToken(rejected);
      fail('expected ArgumentError');
    } on ArgumentError catch (e) {
      expect(e.toString().contains(rejected), isFalse);
    }
  });

  test('a backend failure surfaces as KeyringUnavailable', () async {
    final s = Secrets(FailingSecretBackend());
    await expectLater(s.mcpToken(), throwsA(isA<KeyringUnavailable>()));
    await expectLater(s.githubToken(), throwsA(isA<KeyringUnavailable>()));
  });

  test(
    'KeyringUnavailable.toString redacts a registered secret in the cause',
    () async {
      const fakeSecret = 'obviously-fake-secret-1234567890';
      registerSecret(fakeSecret);
      final unavailable = KeyringUnavailable(
        Exception('platform error while handling $fakeSecret'),
      );
      expect(unavailable.toString().contains(fakeSecret), isFalse);
    },
  );
}

/// Backend that fails the way a Linux box with no running secret service does.
class FailingSecretBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async =>
      throw Exception('no secret service');
  @override
  Future<void> write(String key, String value) async =>
      throw Exception('no secret service');
  @override
  Future<void> delete(String key) async => throw Exception('no secret service');
}
