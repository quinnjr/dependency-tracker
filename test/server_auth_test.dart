import 'dart:convert';

import 'package:deptracker/server/auth.dart';
import 'package:deptracker/server/jwt.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';

final key = List<int>.generate(32, (i) => i * 3 % 256);

void main() {
  group('jwt', () {
    test('sign/verify round trip carries the claims', () {
      final exp =
          DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch ~/
          1000;
      final token = signJwt({'sub': 7, 'role': 'admin', 'exp': exp}, key);
      final claims = verifyJwt(token, key)!;
      expect(claims['sub'], 7);
      expect(claims['role'], 'admin');
    });

    test('an expired token verifies to null', () {
      final exp =
          DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch ~/
          1000;
      final token = signJwt({'sub': 7, 'exp': exp}, key);
      expect(verifyJwt(token, key), isNull);
    });

    test('a token without exp is rejected outright', () {
      expect(verifyJwt(signJwt({'sub': 7}, key), key), isNull);
    });

    test('tampered payload and alg:none are rejected', () {
      final exp =
          DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch ~/
          1000;
      final token = signJwt({'sub': 1, 'exp': exp}, key);
      final parts = token.split('.');
      final forgedPayload = base64Url
          .encode(utf8.encode('{"sub":2,"exp":$exp}'))
          .replaceAll('=', '');
      expect(verifyJwt('${parts[0]}.$forgedPayload.${parts[2]}', key), isNull);

      final noneHeader = base64Url
          .encode(utf8.encode('{"alg":"none","typ":"JWT"}'))
          .replaceAll('=', '');
      expect(verifyJwt('$noneHeader.${parts[1]}.', key), isNull);
      expect(verifyJwt('$noneHeader.${parts[1]}.${parts[2]}', key), isNull);
    });

    test('a wrong key does not verify', () {
      final exp =
          DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch ~/
          1000;
      final other = List<int>.generate(32, (i) => 255 - i);
      expect(verifyJwt(signJwt({'sub': 1, 'exp': exp}, key), other), isNull);
    });
  });

  group('auth', () {
    late Store store;
    late Auth auth;
    setUp(() {
      store = Store.openInMemory();
      auth = Auth(store, key);
    });
    tearDown(() => store.close());

    test('first registrant is admin, second is member', () async {
      final a = (await auth.register('owner', 'a-strong-password'))!;
      final b = (await auth.register('teammate', 'another-password'))!;
      expect(a.role, 'admin');
      expect(b.role, 'member');
      expect(auth.verifyAccess(a.accessJwt)!['role'], 'admin');
    });

    test(
      'closed registration throws RegistrationClosed; only admin toggles',
      () async {
        await auth.register('owner', 'a-strong-password');
        auth.setRegistrationOpen(false, byRole: 'admin');
        expect(auth.registrationOpen, isFalse);
        await expectLater(
          auth.register('intruder', 'whatever-password'),
          throwsA(isA<RegistrationClosed>()),
        );
        expect(
          () => auth.setRegistrationOpen(true, byRole: 'member'),
          throwsA(isA<StateError>()),
        );
        auth.setRegistrationOpen(true, byRole: 'admin');
        expect(auth.registrationOpen, isTrue);
      },
    );

    test(
      'zero users may always register, even if the flag was left closed',
      () async {
        // The flag can only outlive its users via a restored backup; a server
        // nobody can log in to or register on would be bricked.
        store.metaSet('registration_disabled', '1');
        expect((await auth.register('owner', 'a-strong-password')), isNotNull);
      },
    );

    test(
      'login failure is uniform: unknown user and wrong password both null',
      () async {
        await auth.register('owner', 'a-strong-password');
        expect(await auth.login('owner', 'wrong-password'), isNull);
        expect(await auth.login('nobody', 'a-strong-password'), isNull);
      },
    );

    test('login succeeds with the right password', () async {
      await auth.register('owner', 'a-strong-password');
      final r = (await auth.login('owner', 'a-strong-password'))!;
      expect(auth.verifyAccess(r.accessJwt)!['sub'], r.userId);
    });

    test('usernames are case-folded to one account', () async {
      await auth.register('Owner', 'a-strong-password');
      expect(await auth.login('owner', 'a-strong-password'), isNotNull);
      await expectLater(
        auth.register('OWNER', 'other-password-42'),
        throwsA(isA<UsernameTaken>()),
      );
    });

    test(
      'a duplicate registration is UsernameTaken, not a raw DB error',
      () async {
        await auth.register('owner', 'a-strong-password');
        await expectLater(
          auth.register('owner', 'a-different-password'),
          throwsA(isA<UsernameTaken>()),
        );
      },
    );

    test('concurrent first-registrations do not both become admin', () async {
      // Both start before either inserts; the role is decided at insert time
      // (after the hash await), so exactly one ends up admin.
      final results = await Future.wait([
        auth.register('alice', 'password-alice'),
        auth.register('bob', 'password-bob'),
      ]);
      final roles = results.map((r) => r!.role).toList()..sort();
      expect(roles, ['admin', 'member']);
    });

    test(
      'createAccount bypasses closed registration without touching the flag',
      () async {
        await auth.register('owner', 'a-strong-password'); // first = admin
        auth.setRegistrationOpen(false, byRole: 'admin');
        expect(await auth.createAccount('cli', 'password-cli'), 'member');
        // Registration stays closed the whole time — no flag flip window.
        expect(auth.registrationOpen, isFalse);
        await expectLater(
          auth.register('web', 'password-web'),
          throwsA(isA<RegistrationClosed>()),
        );
      },
    );

    test('createAccount refuses a duplicate name', () async {
      await auth.createAccount('owner', 'a-strong-password');
      await expectLater(
        auth.createAccount('owner', 'another-password'),
        throwsA(isA<UsernameTaken>()),
      );
    });

    test(
      'refresh rotates: old token dead on second use, new one works',
      () async {
        final r = (await auth.register('owner', 'a-strong-password'))!;
        final second = auth.refresh(r.refreshToken)!;
        expect(auth.refresh(r.refreshToken), isNull);
        expect(auth.refresh(second.refreshToken), isNotNull);
      },
    );

    test('logout revokes the refresh token', () async {
      final r = (await auth.register('owner', 'a-strong-password'))!;
      auth.logout(r.refreshToken);
      expect(auth.refresh(r.refreshToken), isNull);
    });

    test('an expired refresh token is refused', () async {
      var now = DateTime.now();
      final clocked = Auth(store, key, now: () => now);
      final r = (await clocked.register('owner', 'a-strong-password'))!;
      now = now.add(refreshTokenTtl + const Duration(days: 1));
      expect(clocked.refresh(r.refreshToken), isNull);
    });

    test('verifyAccess rejects an expired access token', () async {
      var now = DateTime.now();
      final clocked = Auth(store, key, now: () => now);
      final r = (await clocked.register('owner', 'a-strong-password'))!;
      expect(clocked.verifyAccess(r.accessJwt), isNotNull);
      now = now.add(accessTokenTtl + const Duration(minutes: 1));
      expect(clocked.verifyAccess(r.accessJwt), isNull);
    });

    test(
      'resetPassword swaps the credential and refuses unknown users',
      () async {
        await auth.register('owner', 'a-strong-password');
        expect(
          await auth.resetPassword('owner', 'a-brand-new-password'),
          isTrue,
        );
        expect(await auth.login('owner', 'a-strong-password'), isNull);
        expect(await auth.login('owner', 'a-brand-new-password'), isNotNull);
        expect(await auth.resetPassword('ghost', 'whatever-password'), isFalse);
      },
    );

    test('password hashes at rest are argon2id, not the password', () async {
      await auth.register('owner', 'a-strong-password');
      final u = store.userByName('owner')!;
      expect(u.passwordHash, startsWith('argon2id\$'));
      expect(u.passwordHash, isNot(contains('a-strong-password')));
    });
  });
}
