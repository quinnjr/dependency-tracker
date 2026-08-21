import 'dart:convert';

import 'package:deptracker/client/sync_client.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server-side store standing in for the real server: handlers read and
/// mutate it and answer with its exportSnapshot, which is exactly the
/// contract AppServer implements (covered by test/server_http_test.dart).
late Store serverStore;
late Store mirror;
late List<String> requests;

MockClient handler({
  int Function()? statusFor401s,
  bool refreshSucceeds = true,
}) => MockClient((request) async {
  requests.add('${request.method} ${request.url.path}');
  final path = request.url.path;

  if (statusFor401s != null &&
      path.startsWith('/api/') &&
      !path.contains('auth')) {
    final code = statusFor401s();
    if (code != 200) return http.Response('{"error":"nope"}', code);
  }

  if (path == '/api/auth/refresh') {
    return refreshSucceeds
        ? http.Response(
            jsonEncode({'accessToken': 'jwt-2', 'role': 'member'}),
            200,
          )
        : http.Response('{"error":"expired"}', 401);
  }
  if (path == '/api/auth/login') {
    final body = jsonDecode(request.body) as Map;
    return body['password'] == 'right-password'
        ? http.Response(
            jsonEncode({'accessToken': 'jwt-1', 'role': 'admin', 'userId': 1}),
            200,
          )
        : http.Response('{"error":"invalid credentials"}', 401);
  }
  if (path == '/api/status') {
    return http.Response(
      jsonEncode({
        'users': 1,
        'registrationOpen': true,
        'githubTokenSet': false,
        'mcpPath': '/mcp',
      }),
      200,
    );
  }
  if (path == '/api/snapshot') {
    return http.Response(
      jsonEncode({'snapshot': serverStore.exportSnapshot()}),
      200,
    );
  }
  final readMatch = RegExp(r'^/api/watches/(\d+)/read$').firstMatch(path);
  if (readMatch != null) {
    final id = int.parse(readMatch.group(1)!);
    final version = (jsonDecode(request.body) as Map)['version'] as String?;
    serverStore.markRead(id, version: version);
    serverStore.bumpRevision();
    return http.Response(
      jsonEncode({'snapshot': serverStore.exportSnapshot()}),
      200,
    );
  }
  if (path == '/api/refresh') {
    serverStore.bumpRevision();
    return http.Response(
      jsonEncode({
        'report': {'refreshed': 4, 'failed': 1, 'newReleases': 2},
        'snapshot': serverStore.exportSnapshot(),
      }),
      200,
    );
  }
  return http.Response('{"error":"not found"}', 404);
});

void main() {
  setUp(() {
    serverStore = Store.openInMemory();
    mirror = Store.openInMemory();
    requests = [];
  });
  tearDown(() {
    serverStore.close();
    mirror.close();
  });

  test('hydrate applies the server snapshot to the mirror', () async {
    serverStore.upsertWatch(WatchKind.pub, 'http');
    final sync = SyncClient(
      Uri.parse('http://server/'),
      mirror,
      client: handler(),
    );
    await sync.hydrate();
    expect(mirror.watches().single.displayName, 'http');
  });

  test('a mutation POSTs and applies the returned snapshot', () async {
    final id = serverStore.upsertWatch(WatchKind.pub, 'http');
    serverStore.insertReleases(id, [Release(watchId: id, version: '1.1.0')]);
    final sync = SyncClient(
      Uri.parse('http://server/'),
      mirror,
      client: handler(),
    );
    await sync.hydrate();
    expect(mirror.releasesFor(id).single.read, isFalse);

    sync.mutations.markRead(id, version: '1.1.0');
    await Future<void>.delayed(Duration.zero);

    expect(requests, contains('POST /api/watches/$id/read'));
    expect(mirror.releasesFor(id).single.read, isTrue);
  });

  test('a 401 triggers exactly one refresh and a retry', () async {
    var first = true;
    final sync = SyncClient(
      Uri.parse('http://server/'),
      mirror,
      client: handler(
        statusFor401s: () {
          if (first) {
            first = false;
            return 401;
          }
          return 200;
        },
      ),
    );
    await sync.hydrate();
    expect(requests.where((r) => r == 'POST /api/auth/refresh').length, 1);
    expect(requests.where((r) => r == 'GET /api/snapshot').length, 2);
  });

  test('a failed refresh ends the session and notifies the gate', () async {
    var notified = 0;
    final sync = SyncClient(
      Uri.parse('http://server/'),
      mirror,
      client: handler(statusFor401s: () => 401, refreshSucceeds: false),
    );
    final error = await sync.login('joseph', 'right-password');
    expect(error, isNull);
    sync.changes.addListener(() => notified++);
    await sync.hydrate();
    expect(sync.authenticated, isFalse);
    expect(notified, greaterThan(0));
  });

  test(
    'login failure returns the server message and keeps no session',
    () async {
      final sync = SyncClient(
        Uri.parse('http://server/'),
        mirror,
        client: handler(),
      );
      final error = await sync.login('joseph', 'wrong');
      expect(error, contains('invalid credentials'));
      expect(sync.authenticated, isFalse);
    },
  );

  test('refresh() parses the report and applies the snapshot', () async {
    serverStore.upsertWatch(WatchKind.pub, 'http');
    final sync = SyncClient(
      Uri.parse('http://server/'),
      mirror,
      client: handler(),
    );
    final report = await sync.refresh(null);
    expect(report.refreshed, 4);
    expect(report.failed, 1);
    expect(report.newReleases, 2);
    expect(mirror.watches(), hasLength(1));
  });

  test(
    'a failed mutation records syncError and leaves the mirror alone',
    () async {
      final sync = SyncClient(
        Uri.parse('http://server/'),
        mirror,
        client: handler(statusFor401s: () => 500),
      );
      sync.mutations.addScanRoot('/srv/code');
      await Future<void>.delayed(Duration.zero);
      expect(sync.syncError.value, isNotNull);
      expect(mirror.scanRoots(), isEmpty);
    },
  );

  test(
    'a transport error becomes a banner, not an escaping async error',
    () async {
      final throwing = MockClient(
        (_) async => throw Exception('connection refused'),
      );
      final sync = SyncClient(
        Uri.parse('http://server/'),
        mirror,
        client: throwing,
      );
      // A void-returning mutation must not leak the throw into the zone.
      sync.mutations.addScanRoot('/srv/code');
      await Future<void>.delayed(Duration.zero);
      expect(sync.syncError.value, contains('could not reach the server'));
      expect(mirror.scanRoots(), isEmpty);
    },
  );

  test(
    'concurrent 401s spend the rotating refresh token exactly once',
    () async {
      var refreshes = 0;
      var refreshed = false;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/auth/refresh') {
          refreshes++;
          refreshed = true;
          return http.Response(
            jsonEncode({'accessToken': 'jwt-2', 'role': 'member'}),
            200,
          );
        }
        // Data requests 401 until the single refresh lands, then succeed.
        if (!refreshed) return http.Response('{"error":"expired"}', 401);
        return http.Response(
          jsonEncode({'snapshot': serverStore.exportSnapshot()}),
          200,
        );
      });
      final sync = SyncClient(
        Uri.parse('http://server/'),
        mirror,
        client: client,
      );
      // Two requests race the same expiry; both see 401 and both want a refresh.
      await Future.wait([sync.hydrate(), sync.hydrate()]);
      expect(refreshes, 1);
    },
  );
}
