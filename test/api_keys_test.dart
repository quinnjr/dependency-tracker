import 'package:deptracker/api_keys.dart';
import 'package:deptracker/redact.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Store store;
  setUp(() => store = Store.openInMemory());
  tearDown(() => store.close());

  test('minting stores only a hash and the key authenticates', () {
    final minted = mintApiKey(store, 'claude-code');
    expect(minted.key, startsWith('dtk_'));
    expect(store.apiKeys().single.name, 'claude-code');
    expect(authenticateApiKey(store, minted.key), minted.id);
  });

  test('a wrong or revoked key does not authenticate', () {
    final minted = mintApiKey(store, 'a');
    expect(authenticateApiKey(store, 'dtk_wrong'), isNull);
    store.revokeApiKey(minted.id);
    expect(authenticateApiKey(store, minted.key), isNull);
  });

  test('successful auth stamps last_used_at without notifying', () {
    final minted = mintApiKey(store, 'a');
    var notified = 0;
    store.addListener(() => notified++);
    authenticateApiKey(store, minted.key, now: () => DateTime.utc(2026, 8, 21));
    expect(store.apiKeys().single.lastUsedAt, DateTime.utc(2026, 8, 21));
    expect(notified, 0);
  });

  test('mint and revoke notify (settings renders the key list)', () {
    var notified = 0;
    store.addListener(() => notified++);
    final minted = mintApiKey(store, 'a');
    store.revokeApiKey(minted.id);
    expect(notified, 2);
  });

  test('duplicate names are refused', () {
    mintApiKey(store, 'a');
    expect(() => mintApiKey(store, 'a'), throwsA(anything));
  });

  test('a minted key is registered for redaction, like the old token was', () {
    addTearDown(clearSecrets);
    final minted = mintApiKey(store, 'a');
    expect(redact('bearer ${minted.key} failed'), 'bearer «redacted» failed');
  });

  group('randomToken (the shape the old mcpToken tests guarded)', () {
    test('is long enough to resist guessing', () {
      // 32 random bytes, base64url without padding.
      expect(randomToken().length, greaterThanOrEqualTo(43));
    });

    test('is url-safe so it survives a header and a config file', () {
      expect(randomToken(), matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    });

    test('two tokens differ', () {
      expect(randomToken(), isNot(randomToken()));
    });

    test('the byte count scales the length', () {
      // A shorter token would be a regression the mint/refresh callers rely
      // on not happening.
      expect(randomToken(8).length, lessThan(randomToken(32).length));
    });
  });
}
