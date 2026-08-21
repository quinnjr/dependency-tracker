import 'dart:convert';
import 'dart:io';

import 'package:deptracker/api_keys.dart';
import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/mcp/transport.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/secrets.dart';
import 'package:deptracker/server/auth.dart';
import 'package:deptracker/server/http.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

final jwtKey = List<int>.generate(32, (i) => (i * 7) % 256);

late Directory webRoot;
late Store store;
late Auth auth;
late AppServer server;
late Uri base;
late int refreshCalls;

Uri u(String path) => base.resolve(path);

Future<http.Response> get(
  String path, {
  String? jwt,
  Map<String, String>? headers,
}) => http.get(
  u(path),
  headers: {if (jwt != null) 'Authorization': 'Bearer $jwt', ...?headers},
);

Future<http.Response> send(
  String method,
  String path, {
  Object? body,
  String? jwt,
  Map<String, String>? headers,
}) async {
  final request = http.Request(method, u(path));
  request.headers['content-type'] = 'application/json';
  if (jwt != null) request.headers['authorization'] = 'Bearer $jwt';
  headers?.forEach((k, v) => request.headers[k] = v);
  if (body != null) request.body = jsonEncode(body);
  return http.Response.fromStream(await request.send());
}

/// Registers a user and returns (accessToken, refresh cookie header value).
Future<({String jwt, String cookie, String role})> register(
  String username, [
  String password = 'a-strong-password',
]) async {
  final r = await send(
    'POST',
    '/api/auth/register',
    body: {'username': username, 'password': password},
  );
  expect(r.statusCode, 200, reason: r.body);
  final cookie = r.headers['set-cookie']!;
  final body = jsonDecode(r.body) as Map;
  return (
    jwt: body['accessToken'] as String,
    cookie: cookie.split(';').first,
    role: body['role'] as String,
  );
}

void main() {
  setUp(() async {
    webRoot = Directory.systemTemp.createTempSync('webroot');
    File(
      p.join(webRoot.path, 'index.html'),
    ).writeAsStringSync('<html><body>deptracker</body></html>');
    Directory(p.join(webRoot.path, 'sub')).createSync();
    File(p.join(webRoot.path, 'sub', 'app.js')).writeAsStringSync('// js');

    store = Store.openInMemory();
    auth = Auth(store, jwtKey);
    refreshCalls = 0;
    server = AppServer(
      store: store,
      auth: auth,
      secrets: Secrets(MemorySecretBackend()),
      refresh: (id) async {
        refreshCalls++;
        return const RefreshReport(refreshed: 1, failed: 0, newReleases: 2);
      },
      scan: () async =>
          const ScanResult(projectsScanned: 3, depsFound: 12, errors: []),
      mcp: McpTransport(
        onSession: () => buildMcpServer(
          buildTools(
            store,
            refresh: (_) async =>
                const RefreshReport(refreshed: 0, failed: 0, newReleases: 0),
          ),
        ),
        authenticate: (k) => authenticateApiKey(store, k),
      ),
      webRoot: webRoot.path,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    final port = await server.start();
    base = Uri.parse('http://127.0.0.1:$port');
  });

  tearDown(() async {
    await server.stop();
    store.close();
    webRoot.deleteSync(recursive: true);
  });

  group('unauthenticated surface', () {
    test('the frontend is served without auth', () async {
      final r = await get('/');
      expect(r.statusCode, 200);
      expect(r.body, contains('deptracker'));
      expect(r.headers['content-type'], contains('text/html'));
    });

    test('static assets resolve with sane content types', () async {
      final r = await get('/sub/app.js');
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('javascript'));
    });

    test('path traversal cannot escape the web root', () async {
      final secret = File(p.join(webRoot.parent.path, 'outside.txt'))
        ..writeAsStringSync('leak');
      addTearDown(() => secret.deleteSync());
      for (final path in [
        '/../outside.txt',
        '/%2e%2e/outside.txt',
        '/sub/../../outside.txt',
      ]) {
        final r = await http.get(base.resolve(path));
        expect(r.statusCode, isNot(200), reason: path);
        expect(r.body, isNot(contains('leak')), reason: path);
      }
    });

    test('an unknown extensionless path falls back to the app shell', () async {
      final r = await get('/some/spa/route');
      expect(r.statusCode, 200);
      expect(r.body, contains('deptracker'));
    });

    test('an unknown asset stays a 404', () async {
      expect((await get('/missing.js')).statusCode, 404);
    });

    test('the snapshot is gated', () async {
      expect((await get('/api/snapshot')).statusCode, 401);
    });

    test('status reports the zero-user bootstrap state', () async {
      final r = await get('/api/status');
      expect(r.statusCode, 200);
      final body = jsonDecode(r.body) as Map;
      expect(body['users'], 0);
      expect(body['registrationOpen'], true);
      expect(body['githubTokenSet'], false);
      expect(body['mcpPath'], '/mcp');
    });
  });

  group('auth flows', () {
    test('register returns a JWT and a hardened refresh cookie', () async {
      final r = await send(
        'POST',
        '/api/auth/register',
        body: {'username': 'owner', 'password': 'a-strong-password'},
      );
      expect(r.statusCode, 200);
      final cookie = r.headers['set-cookie']!;
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('SameSite=Strict'));
      expect(cookie, contains('Path=/api/auth'));
      expect((jsonDecode(r.body) as Map)['role'], 'admin');
    });

    test('login failure is uniform 401', () async {
      await register('owner');
      final wrongPassword = await send(
        'POST',
        '/api/auth/login',
        body: {'username': 'owner', 'password': 'nope-nope-nope'},
      );
      final wrongUser = await send(
        'POST',
        '/api/auth/login',
        body: {'username': 'ghost', 'password': 'a-strong-password'},
      );
      expect(wrongPassword.statusCode, 401);
      expect(wrongUser.statusCode, 401);
      expect(wrongPassword.body, wrongUser.body);
    });

    test('refresh rotates the cookie and an old cookie replay fails', () async {
      final session = await register('owner');
      final first = await send(
        'POST',
        '/api/auth/refresh',
        headers: {'cookie': session.cookie},
      );
      expect(first.statusCode, 200);
      final rotated = first.headers['set-cookie']!.split(';').first;
      expect(rotated, isNot(session.cookie));

      final replay = await send(
        'POST',
        '/api/auth/refresh',
        headers: {'cookie': session.cookie},
      );
      expect(replay.statusCode, 401);

      final current = await send(
        'POST',
        '/api/auth/refresh',
        headers: {'cookie': rotated},
      );
      expect(current.statusCode, 200);
    });

    test('logout revokes the refresh token', () async {
      final session = await register('owner');
      final out = await send(
        'POST',
        '/api/auth/logout',
        headers: {'cookie': session.cookie},
      );
      expect(out.statusCode, 204);
      final r = await send(
        'POST',
        '/api/auth/refresh',
        headers: {'cookie': session.cookie},
      );
      expect(r.statusCode, 401);
    });

    test('a cross-origin auth request is refused', () async {
      final r = await send(
        'POST',
        '/api/auth/login',
        body: {'username': 'owner', 'password': 'a-strong-password'},
        headers: {'origin': 'https://evil.example'},
      );
      expect(r.statusCode, 403);
    });

    test('a same-host, different-port origin is refused', () async {
      // The server answers as 127.0.0.1:<port>; an Origin on another port is
      // a different origin, and matching host alone would wrongly accept it.
      final r = await send(
        'POST',
        '/api/auth/login',
        body: {'username': 'owner', 'password': 'a-strong-password'},
        headers: {'origin': 'http://127.0.0.1:1'},
      );
      expect(r.statusCode, 403);
    });

    test(
      'register sets Secure only over TLS (via x-forwarded-proto)',
      () async {
        final plain = await send(
          'POST',
          '/api/auth/register',
          body: {'username': 'plain', 'password': 'a-strong-password'},
        );
        expect(plain.headers['set-cookie'], isNot(contains('Secure')));

        final tls = await send(
          'POST',
          '/api/auth/login',
          body: {'username': 'plain', 'password': 'a-strong-password'},
          headers: {'x-forwarded-proto': 'https'},
        );
        expect(tls.headers['set-cookie'], contains('Secure'));
      },
    );

    test(
      'a duplicate username is a clean 409, not a 500 leaking SQL',
      () async {
        await register('owner');
        final dup = await send(
          'POST',
          '/api/auth/register',
          body: {'username': 'owner', 'password': 'another-password'},
        );
        expect(dup.statusCode, 409);
        expect(dup.body, isNot(contains('UNIQUE')));
        expect(dup.body, isNot(contains('constraint')));
      },
    );

    test(
      'the registration toggle is admin-only and closes registration',
      () async {
        final admin = await register('owner');
        final member = await register('teammate');
        expect(member.role, 'member');

        final refused = await send(
          'PUT',
          '/api/auth/registration',
          body: {'enabled': false},
          jwt: member.jwt,
        );
        expect(refused.statusCode, 403);

        final closed = await send(
          'PUT',
          '/api/auth/registration',
          body: {'enabled': false},
          jwt: admin.jwt,
        );
        expect(closed.statusCode, 204);

        final rejected = await send(
          'POST',
          '/api/auth/register',
          body: {'username': 'intruder', 'password': 'whatever-password'},
        );
        expect(rejected.statusCode, 403);
      },
    );
  });

  group('data API', () {
    test('snapshot honors If-None-Match with 304', () async {
      final session = await register('owner');
      final first = await get('/api/snapshot', jwt: session.jwt);
      expect(first.statusCode, 200);
      final revision =
          ((jsonDecode(first.body) as Map)['snapshot'] as Map)['revision'];
      final again = await get(
        '/api/snapshot',
        jwt: session.jwt,
        headers: {'if-none-match': '$revision'},
      );
      expect(again.statusCode, 304);
    });

    test('watch lifecycle: create, snooze, read, delete — each returns the '
        'fresh snapshot', () async {
      final session = await register('owner');
      final created = await send(
        'POST',
        '/api/watches',
        body: {'kind': 'pub', 'name': 'http'},
        jwt: session.jwt,
      );
      expect(created.statusCode, 200);
      final id = (jsonDecode(created.body) as Map)['id'] as int;
      final snap = (jsonDecode(created.body) as Map)['snapshot'] as Map;
      expect((snap['watch'] as List), hasLength(1));

      store.insertReleases(id, [Release(watchId: id, version: '2.0.0')]);

      final snoozed = await send(
        'POST',
        '/api/watches/$id/snooze',
        body: {
          'until': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
        },
        jwt: session.jwt,
      );
      expect(snoozed.statusCode, 200);
      expect(store.watchById(id)!.isSnoozed, isTrue);

      final read = await send(
        'POST',
        '/api/watches/$id/read',
        body: {'version': '2.0.0'},
        jwt: session.jwt,
      );
      expect(read.statusCode, 200);
      expect(store.releasesFor(id).single.read, isTrue);

      final deleted = await send(
        'DELETE',
        '/api/watches/$id',
        jwt: session.jwt,
      );
      expect(deleted.statusCode, 200);
      expect(store.watchById(id), isNull);
    });

    test('mutating an unknown watch is 404', () async {
      final session = await register('owner');
      expect(
        (await send(
          'POST',
          '/api/watches/999/read',
          jwt: session.jwt,
        )).statusCode,
        404,
      );
    });

    test('refresh and scan run the injected engine closures', () async {
      final session = await register('owner');
      final refreshed = await send('POST', '/api/refresh', jwt: session.jwt);
      expect(refreshed.statusCode, 200);
      expect(refreshCalls, 1);
      expect(
        ((jsonDecode(refreshed.body) as Map)['report'] as Map)['newReleases'],
        2,
      );

      final scanned = await send('POST', '/api/scan', jwt: session.jwt);
      expect(scanned.statusCode, 200);
      expect(
        ((jsonDecode(scanned.body) as Map)['result'] as Map)['depsFound'],
        12,
      );
    });

    test('scan roots add and remove through the API', () async {
      final session = await register('owner');
      await send(
        'POST',
        '/api/scan-roots',
        body: {'path': '/srv/code'},
        jwt: session.jwt,
      );
      expect(store.scanRoots(), ['/srv/code']);
      await send(
        'DELETE',
        '/api/scan-roots',
        body: {'path': '/srv/code'},
        jwt: session.jwt,
      );
      expect(store.scanRoots(), isEmpty);
    });

    test('the github token is write-only and status reflects it', () async {
      final session = await register('owner');
      final put = await send(
        'PUT',
        '/api/secrets/github-token',
        body: {'token': 'ghp_abcdefghijklmnop'},
        jwt: session.jwt,
      );
      expect(put.statusCode, 204);
      final status = jsonDecode((await get('/api/status')).body) as Map;
      expect(status['githubTokenSet'], true);
      // No endpoint returns the token: the snapshot must not carry secrets.
      final snap = await get('/api/snapshot', jwt: session.jwt);
      expect(snap.body, isNot(contains('ghp_abcdefghijklmnop')));
    });

    test('a too-short github token is a 400, not a 500', () async {
      final session = await register('owner');
      final put = await send(
        'PUT',
        '/api/secrets/github-token',
        body: {'token': 'short'},
        jwt: session.jwt,
      );
      expect(put.statusCode, 400);
    });

    test('members are 403 on the admin-only surfaces', () async {
      await register('owner'); // first account is admin
      final member = await register('teammate');
      expect(member.role, 'member');

      Future<int> code(String method, String path, [Object? body]) async =>
          (await send(method, path, body: body, jwt: member.jwt)).statusCode;

      // Server-filesystem and server-wide-credential routes: admin only.
      expect(await code('POST', '/api/scan-roots', {'path': '/etc'}), 403);
      expect(await code('DELETE', '/api/scan-roots', {'path': '/etc'}), 403);
      expect(await code('POST', '/api/scan'), 403);
      expect(
        await code('PUT', '/api/secrets/github-token', {'token': 'x' * 20}),
        403,
      );
      expect(await code('GET', '/api/mcp-keys'), 403);
      expect(await code('POST', '/api/mcp-keys', {'name': 'agent'}), 403);

      // But the shared watchlist stays a member power.
      final created = await send(
        'POST',
        '/api/watches',
        body: {'kind': 'pub', 'name': 'http'},
        jwt: member.jwt,
      );
      expect(created.statusCode, 200);
    });

    test('a duplicate mcp-key name is a clean 409, not a 500', () async {
      final session = await register('owner');
      await send(
        'POST',
        '/api/mcp-keys',
        body: {'name': 'agent'},
        jwt: session.jwt,
      );
      final dup = await send(
        'POST',
        '/api/mcp-keys',
        body: {'name': 'agent'},
        jwt: session.jwt,
      );
      expect(dup.statusCode, 409);
      expect(dup.body, isNot(contains('UNIQUE')));
    });
  });

  group('mcp keys and the credential boundary', () {
    test('a minted key opens /mcp; a revoked one stops; metadata only in the '
        'list', () async {
      final session = await register('owner');
      final created = await send(
        'POST',
        '/api/mcp-keys',
        body: {'name': 'agent'},
        jwt: session.jwt,
      );
      expect(created.statusCode, 200);
      final body = jsonDecode(created.body) as Map;
      final key = body['key'] as String;
      expect(key, startsWith('dtk_'));

      Future<int> initialize(String bearer) async {
        final r = await http.post(
          u('/mcp'),
          headers: {
            'content-type': 'application/json',
            'accept': 'application/json, text/event-stream',
            'authorization': 'Bearer $bearer',
          },
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': mcpProtocolVersion,
              'capabilities': <String, Object?>{},
              'clientInfo': {'name': 't', 'version': '1'},
            },
          }),
        );
        return r.statusCode;
      }

      expect(await initialize(key), 200);

      final listed = await get('/api/mcp-keys', jwt: session.jwt);
      expect(listed.body, isNot(contains(key)));
      expect(listed.body, contains('agent'));

      final id = body['id'] as int;
      final revoked = await send(
        'DELETE',
        '/api/mcp-keys/$id',
        jwt: session.jwt,
      );
      expect(revoked.statusCode, 204);
      expect(await initialize(key), 401);
    });

    test(
      'a JWT does not open /mcp and an API key does not open /api',
      () async {
        final session = await register('owner');
        final minted = mintApiKey(store, 'boundary');

        final mcpWithJwt = await http.post(
          u('/mcp'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer ${session.jwt}',
          },
          body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
        );
        expect(mcpWithJwt.statusCode, 401);

        final apiWithKey = await get('/api/snapshot', jwt: minted.key);
        expect(apiWithKey.statusCode, 401);
      },
    );
  });
}
