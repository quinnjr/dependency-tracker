// End-to-end coverage for the wiring in lib/main.dart: a real McpTransport on
// a real loopback port, in front of the real tool set built by buildTools(),
// operating on a real Store — the same objects main.dart assembles, not
// stand-ins. Unit-level transport behavior (auth edge cases, batching,
// SSE, ...) is already covered by test/mcp_transport_test.dart; this file
// exists for the properties that only show up once the whole stack is
// wired together, above all: does an MCP mutation actually land in the
// Store the UI renders from.

import 'dart:convert';
import 'dart:io';

import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/mcp/transport.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _token = 'e2e-test-token-0123456789abcdef';

late Store store;
late McpTransport transport;
late Uri endpoint;

Future<RefreshReport> _noopRefresh(int? watchId) async =>
    const RefreshReport(refreshed: 0, failed: 0, newReleases: 0);

Map<String, Object?> _rpc(String method, [Map<String, Object?>? params]) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': method,
  if (params != null) 'params': params,
};

Future<http.Response> _post(
  Object body, {
  String? bearer = _token,
  Map<String, String> extra = const {},
}) => http.post(
  endpoint,
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    if (bearer != null) 'Authorization': 'Bearer $bearer',
    ...extra,
  },
  body: body is String ? body : jsonEncode(body),
);

void main() {
  setUp(() async {
    store = Store.openInMemory();
    transport = McpTransport(
      server: McpServer(buildTools(store, refresh: _noopRefresh)),
      bearerToken: _token,
    );
    final port = await transport.start();
    endpoint = Uri.parse('http://127.0.0.1:$port$mcpPath');
  });

  tearDown(() async {
    await transport.stop();
    store.close();
  });

  test('an unauthenticated request is rejected with 401', () async {
    final r = await _post(_rpc('tools/list'), bearer: null);
    expect(r.statusCode, 401);
  });

  test(
    'a browser-style origin is rejected with 403, blocking dns rebinding',
    () async {
      final r = await _post(
        _rpc('tools/list'),
        extra: {'Origin': 'https://evil.example.com'},
      );
      expect(r.statusCode, 403);
    },
  );

  test('tools/list returns all ten tools this server implements', () async {
    final r = await _post(_rpc('tools/list'));
    expect(r.statusCode, 200);
    final body = jsonDecode(r.body) as Map<String, Object?>;
    final tools = (body['result'] as Map)['tools'] as List;
    final names = tools.map((t) => (t as Map)['name'] as String).toSet();
    expect(names, {
      'list_watches',
      'get_watch',
      'get_release_notes',
      'search_watches',
      'add_watch',
      'add_rss_watch',
      'remove_watch',
      'mark_read',
      'snooze',
      'refresh_now',
    });
    expect(tools, hasLength(10));
  });

  test('the port is unreachable from a non-loopback address', () async {
    // InternetAddress.anyIPv4 would accept a connection here; loopback-only
    // binding must not.
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    if (interfaces.isEmpty) {
      // Explicit, loud skip: a host with no external interface cannot
      // exercise this assertion, and a silent pass would be
      // indistinguishable from the check never having run at all.
      // ignore: avoid_print
      print(
        'SKIPPED: no non-loopback IPv4 interface on this host — the '
        'off-loopback unreachability check could not run.',
      );
      return;
    }
    final external = interfaces.first.addresses.first.address;
    await expectLater(
      Socket.connect(
        external,
        transport.port!,
        timeout: const Duration(milliseconds: 500),
      ),
      throwsA(isA<SocketException>()),
    );
  });

  test(
    'an add_watch call through the transport lands in the shared Store',
    () async {
      // This is the live-store guarantee: an MCP client mutating the
      // watchlist must be indistinguishable from a user doing it by hand,
      // because both the transport and the UI hold the *same* Store
      // instance — main.dart wires it that way deliberately.
      expect(store.watches(), isEmpty);

      final r = await _post(
        _rpc('tools/call', {
          'name': 'add_watch',
          'arguments': {'kind': 'pub', 'name': 'http'},
        }),
      );
      expect(r.statusCode, 200);
      final body = jsonDecode(r.body) as Map<String, Object?>;
      final result = body['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse);

      final text = (result['content'] as List).first['text'] as String;
      final id = (jsonDecode(text) as Map<String, Object?>)['id'] as int;

      final watch = store.watchById(id);
      expect(watch, isNotNull);
      expect(watch!.displayName, 'http');

      final watches = store.watches();
      expect(watches, hasLength(1));
      expect(watches.single.id, id);
    },
  );

  test('a tool error returns isError without killing the session', () async {
    // get_watch with neither `id` nor `name` throws ArgumentError inside
    // the handler. That must come back as a normal (200, isError: true)
    // result the model can read, not a broken connection, and the very
    // next call on the same server must still succeed.
    final failing = await _post(
      _rpc('tools/call', {
        'name': 'get_watch',
        'arguments': <String, Object?>{},
      }),
    );
    expect(failing.statusCode, 200);
    final failingBody = jsonDecode(failing.body) as Map<String, Object?>;
    final failingResult = failingBody['result'] as Map<String, Object?>;
    expect(failingResult['isError'], isTrue);

    final following = await _post(_rpc('tools/list'));
    expect(following.statusCode, 200);
    final followingBody = jsonDecode(following.body) as Map<String, Object?>;
    expect((followingBody['result'] as Map)['tools'], hasLength(10));
  });

  group('discovery file', () {
    test('contains the port and never the token', () async {
      final tmp = Directory.systemTemp.createTempSync('mcpe2edisco');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final env = {'HOME': tmp.path, 'XDG_CONFIG_HOME': tmp.path};
      final file = await writeDiscoveryFile(
        transport.port!,
        env: env,
        platform: 'linux',
      );
      final contents = file.readAsStringSync();
      final json = jsonDecode(contents) as Map<String, Object?>;
      expect(json['port'], transport.port);
      expect(contents.toLowerCase(), isNot(contains('token')));
      expect(contents, isNot(contains(_token)));
    });
  });
}
