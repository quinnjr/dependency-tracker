import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../api_keys.dart' show hashApiKey;
import '../store.dart';
import 'jwt.dart';

/// How long an access JWT lives. Short on purpose: the browser holds it in
/// page memory only, and the refresh cookie makes renewal invisible.
const Duration accessTokenTtl = Duration(minutes: 15);

/// How long a refresh token lives. Each use rotates it, so an active user
/// never hits this; it bounds how long an abandoned session stays warm.
const Duration refreshTokenTtl = Duration(days: 30);

/// Thrown by [Auth.register] when an admin has closed registration. A typed
/// exception rather than a null so the HTTP layer can map it to 403, not
/// the uniform 401 that covers credential failures.
class RegistrationClosed implements Exception {
  @override
  String toString() => 'registration is closed';
}

/// Thrown by [Auth.register] when the username is already taken. Typed so
/// the HTTP layer answers a clean 409 rather than letting the UNIQUE
/// violation escape as a 500 that leaks SQL text.
class UsernameTaken implements Exception {
  @override
  String toString() => 'username is taken';
}

class AuthResult {
  const AuthResult({
    required this.accessJwt,
    required this.refreshToken,
    required this.userId,
    required this.role,
  });

  final String accessJwt;

  /// The clear refresh token for the cookie. Only its SHA-256 lands in the
  /// database, same argument as the MCP API keys: 32 CSPRNG bytes need no
  /// stretching, and a stolen DB must not contain usable session material.
  final String refreshToken;

  final int userId;
  final String role;
}

/// Registration, login, and the two-token session scheme.
///
/// OWASP's minimum interactive Argon2id profile: 19 MiB, 2 iterations,
/// single lane. Heavier settings would be nice, but this runs on whatever
/// box hosts the tracker, and login is not the hot path.
class Auth {
  Auth(this._store, List<int> jwtKey, {DateTime Function()? now})
    : _jwtKey = List<int>.from(jwtKey),
      _now = now ?? DateTime.now;

  final Store _store;
  final List<int> _jwtKey;
  final DateTime Function() _now;
  final Random _rng = Random.secure();

  static final Argon2id _argon2 = Argon2id(
    parallelism: 1,
    memory: 19 * 1024,
    iterations: 2,
    hashLength: 32,
  );

  bool get registrationOpen =>
      _store.metaGet('registration_disabled') != '1' || _store.userCount() == 0;

  /// Only an admin may close (or reopen) registration: with registration
  /// open to anyone, a self-service switch would let any fresh registrant
  /// lock the owner's team out.
  void setRegistrationOpen(bool open, {required String byRole}) {
    if (byRole != 'admin') {
      throw StateError('only an admin may change registration');
    }
    _store.metaSet('registration_disabled', open ? '0' : '1');
  }

  /// First account becomes admin; zero users may always register, because
  /// the only way to have the closed flag with no users is a restored
  /// backup, and a server nobody can enter would be bricked.
  Future<AuthResult?> register(String username, String password) async {
    final name = username.trim().toLowerCase();
    if (name.isEmpty || password.length < 8) {
      throw ArgumentError('username required; password of at least 8 chars');
    }
    if (!registrationOpen) throw RegistrationClosed();
    // Reject a taken name before hashing, so a UNIQUE violation cannot
    // escape as a 500 leaking SQL. Registration is inherently an
    // enumeration surface (the user must be told a name is free), so this
    // adds no oracle login does not already have to defend against.
    if (_store.userByName(name) != null) throw UsernameTaken();
    final role = _store.userCount() == 0 ? 'admin' : 'member';
    final id = _store.insertUser(name, await _hashPassword(password), role);
    return _issue(id, role);
  }

  /// Null on any failure, with no unknown-user/wrong-password distinction.
  /// Both branches run exactly one Argon2id verification — the unknown-user
  /// branch against a cached dummy hash — so an attacker cannot time
  /// `/api/auth/login` to learn which usernames exist. (Computing the dummy
  /// hash fresh each call would itself be a second KDF on that branch, the
  /// very oracle this closes.)
  Future<AuthResult?> login(String username, String password) async {
    final user = _store.userByName(username.trim().toLowerCase());
    final stored = user?.passwordHash ?? await _dummyHash();
    final ok = await _verifyPassword(password, stored);
    if (user == null || !ok) return null;
    return _issue(user.id, user.role);
  }

  Future<String>? _dummyHashFuture;

  /// A well-formed Argon2id hash of a fixed password, computed once and
  /// reused, so the unknown-user login branch costs exactly one
  /// verification and no extra derivation.
  Future<String> _dummyHash() =>
      _dummyHashFuture ??= _hashPassword('a-dummy-password-hashed-for-timing');

  AuthResult? refresh(String presentedRefreshToken) {
    final hash = hashApiKey(presentedRefreshToken);
    final row = _store.refreshTokenByHash(hash);
    if (row == null) return null;
    if (!_now().isBefore(row.expiresAt)) {
      _store.deleteRefreshToken(hash);
      return null;
    }
    final role = _store.userRoleById(row.userId);
    if (role == null) return null;
    // Rotation: the old hash dies in the same transaction the new one is
    // born in, so a crash between the two cannot leave both valid.
    return _store.runInTransaction(() {
      _store.deleteRefreshToken(hash);
      return _issue(row.userId, role);
    });
  }

  void logout(String presentedRefreshToken) =>
      _store.deleteRefreshToken(hashApiKey(presentedRefreshToken));

  /// CLI-only recovery path (`bin/server.dart --reset-password`); there is
  /// deliberately no HTTP route to this. Returns false for an unknown
  /// account.
  Future<bool> resetPassword(String username, String password) async {
    final user = _store.userByName(username.trim().toLowerCase());
    if (user == null) return false;
    if (password.length < 8) {
      throw ArgumentError('password of at least 8 chars required');
    }
    _store.setUserPasswordHash(user.id, await _hashPassword(password));
    return true;
  }

  /// Claims of a valid access JWT, or null.
  Map<String, Object?>? verifyAccess(String jwt) =>
      verifyJwt(jwt, _jwtKey, now: _now);

  AuthResult _issue(int userId, String role) {
    final nowEpoch = _now().millisecondsSinceEpoch ~/ 1000;
    final access = signJwt({
      'sub': userId,
      'role': role,
      'iat': nowEpoch,
      'exp': nowEpoch + accessTokenTtl.inSeconds,
    }, _jwtKey);
    final refreshToken = base64Url
        .encode(List<int>.generate(32, (_) => _rng.nextInt(256)))
        .replaceAll('=', '');
    _store.insertRefreshToken(
      hashApiKey(refreshToken),
      userId,
      _now().add(refreshTokenTtl),
    );
    return AuthResult(
      accessJwt: access,
      refreshToken: refreshToken,
      userId: userId,
      role: role,
    );
  }

  Future<String> _hashPassword(String password) async {
    final salt = List<int>.generate(16, (_) => _rng.nextInt(256));
    final key = await _argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return 'argon2id\$${base64Url.encode(salt)}\$${base64Url.encode(bytes)}';
  }

  Future<bool> _verifyPassword(String password, String stored) async {
    final parts = stored.split(r'$');
    if (parts.length != 3 || parts[0] != 'argon2id') return false;
    final salt = base64Url.decode(parts[1]);
    final key = await _argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return constantTimeBytesEquals(bytes, base64Url.decode(parts[2]));
  }
}

/// Byte-list twin of the transport's constantTimeEquals.
bool constantTimeBytesEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var mismatch = 0;
  for (var i = 0; i < a.length; i++) {
    mismatch |= a[i] ^ b[i];
  }
  return mismatch == 0;
}
