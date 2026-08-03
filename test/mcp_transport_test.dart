import 'dart:convert';
import 'dart:io';

import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/mcp/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'mcp_client.dart';

const token = 'test-token-0123456789abcdef';

late McpTransport transport;
late Uri endpoint;

Future<http.Response> post(
  Object body, {
  String? bearer = token,
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
    transport = McpTransport(
      onSession: () => buildMcpServer([
        ToolDef(
          name: 'echo',
          description: 'Echoes.',
          inputSchema: const {
            'type': 'object',
            'properties': <String, Object?>{},
          },
          handler: (args) async => {'ok': true},
        ),
      ]),
      bearerToken: token,
    );
    final port = await transport.start();
    endpoint = Uri.parse('http://127.0.0.1:$port$mcpPath');
  });

  tearDown(() => transport.stop());

  group('binding', () {
    test(
      'binds loopback only, so the port is not reachable off-host',
      () async {
        // InternetAddress.anyIPv4 would accept this connection; loopback will
        // not.
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: InternetAddressType.IPv4,
        );
        if (interfaces.isEmpty) return; // no external interface to test against
        final external = interfaces.first.addresses.first.address;
        await expectLater(
          Socket.connect(
            external,
            transport.port!,
            timeout: const Duration(milliseconds: 500),
          ),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test('reports the port it actually bound', () {
      expect(transport.port, isNotNull);
      expect(transport.endpoint.path, mcpPath);
    });
  });

  group('authentication', () {
    test('accepts a correct bearer token', () async {
      // `initialize` rather than `ping`: it is the one call that legitimately
      // needs no prior session, so a 200 here means auth passed rather than
      // that the request happened to be sessionless.
      final r = await post(
        rpc(
          'initialize',
          params: {
            'protocolVersion': mcpProtocolVersion,
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        ),
      );
      expect(r.statusCode, 200);
    });

    test('rejects a missing token with 401', () async {
      final r = await post(rpc('ping'), bearer: null);
      expect(r.statusCode, 401);
    });

    test('rejects a wrong token with 401', () async {
      final r = await post(rpc('ping'), bearer: 'wrong-token-aaaaaaaaaaaaaaa');
      expect(r.statusCode, 401);
    });

    test('rejects a token that is a prefix of the real one', () async {
      final r = await post(rpc('ping'), bearer: token.substring(0, 10));
      expect(r.statusCode, 401);
    });

    test(
      'rejects before parsing, so bad json with a bad token is still 401',
      () async {
        final r = await post('{not json', bearer: null);
        expect(r.statusCode, 401);
      },
    );

    test('never echoes the expected token in a rejection body', () async {
      final r = await post(rpc('ping'), bearer: null);
      expect(r.body, isNot(contains(token)));
    });

    test(
      'rejects before path routing, so an unknown path is still 401 not 404',
      () async {
        // If auth ran after routing, an unauthenticated caller could probe
        // for valid paths by reading 404 vs. non-404 off an unauthenticated
        // response.
        final r = await http.post(
          Uri.parse('http://127.0.0.1:${transport.port}/wrong'),
          body: jsonEncode(rpc('ping')),
        );
        expect(r.statusCode, 401);
      },
    );
  });

  group('origin validation', () {
    test('rejects a foreign origin, blocking dns rebinding', () async {
      final r = await post(
        rpc('ping'),
        extra: {'Origin': 'https://evil.example.com'},
      );
      expect(r.statusCode, 403);
    });

    test('accepts a localhost origin', () async {
      final r = await post(
        rpc(
          'initialize',
          params: {
            'protocolVersion': mcpProtocolVersion,
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        ),
        extra: {'Origin': 'http://localhost:5173'},
      );
      expect(r.statusCode, 200);
    });

    test('accepts no origin, which is what native clients send', () async {
      final r = await post(
        rpc(
          'initialize',
          params: {
            'protocolVersion': mcpProtocolVersion,
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        ),
      );
      expect(r.statusCode, 200);
    });

    test('isAllowedOrigin covers the shapes directly', () {
      expect(isAllowedOrigin(null), isTrue);
      expect(isAllowedOrigin('http://localhost'), isTrue);
      expect(isAllowedOrigin('http://localhost:3000'), isTrue);
      expect(isAllowedOrigin('http://127.0.0.1:8080'), isTrue);
      expect(isAllowedOrigin('http://[::1]:8080'), isTrue);
      expect(isAllowedOrigin('null'), isFalse);
      expect(isAllowedOrigin('https://evil.com'), isFalse);
      // A host that merely starts with localhost must not pass.
      expect(isAllowedOrigin('http://localhost.evil.com'), isFalse);
    });
  });

  group('protocol over http', () {
    /// Opens a session and returns a client already past the handshake.
    Future<McpTestClient> session() async {
      final client = McpTestClient(endpoint, bearer: token);
      await client.initialize();
      addTearDown(client.close);
      return client;
    }

    test('initialize opens a session and returns the server info', () async {
      final client = McpTestClient(endpoint, bearer: token);
      addTearDown(client.close);
      final reply = await client.initialize();

      // A session id is what every later request is routed by, so its absence
      // would strand the client on its second call rather than its first.
      expect(client.sessionId, isNotNull);
      final info = (reply['result']! as Map)['serverInfo']! as Map;
      expect(info['name'], serverName);
    });

    test('a request is answered over sse, per streamable http', () async {
      final client = await session();
      final response = await client.post(rpc('ping'));

      // The package answers any JSON-RPC *request* on an SSE stream rather
      // than with a bare JSON body. That is a wire-format change from the
      // hand-rolled transport, and clients must handle it.
      expect(response.headers['content-type'], contains('text/event-stream'));
      expect(parseSse(response.body).single['id'], 1);
    });

    test('a notification is accepted with 202 and no body', () async {
      final client = await session();
      final r = await client.post(
        rpc('notifications/cancelled', id: null, params: {'requestId': 99}),
      );
      expect(r.statusCode, 202);
      expect(r.body, isEmpty);
    });

    test(
      'a request before initialize is refused, not silently served',
      () async {
        // Without a session the server has no state to answer from; saying so
        // lets the client start one instead of retrying the same call.
        final r = await http.post(
          endpoint,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(rpc('tools/list')),
        );
        expect(r.statusCode, 400);
        expect(jsonDecode(r.body)['error'], isNotNull);
      },
    );

    test(
      'an unknown session id is refused so the client can start over',
      () async {
        final r = await http.post(
          endpoint,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
            sessionHeader: 'not-a-real-session',
          },
          body: jsonEncode(rpc('tools/list')),
        );
        expect(r.statusCode, 404);
      },
    );

    test('malformed json is rejected before it reaches a session', () async {
      final r = await http.post(
        endpoint,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: '{ not json',
      );
      expect(r.statusCode, 400);
    });

    test('tools/call round-trips through http', () async {
      final client = await session();
      expect(await client.callTool('echo'), {'ok': true});
    });

    test('an unknown path is 404 for an authenticated caller', () async {
      // Uses a valid bearer token deliberately: this test is about routing,
      // not auth. The unauthenticated case is covered separately by
      // 'rejects before path routing, so an unknown path is still 401 not
      // 404' above, since auth runs first and must win.
      final r = await http.post(
        Uri.parse('http://127.0.0.1:${transport.port}/wrong'),
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode(rpc('ping')),
      );
      expect(r.statusCode, 404);
    });

    test('an unrecognised http method is 405', () async {
      final r = await http.patch(
        endpoint,
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode(rpc('ping')),
      );
      expect(r.statusCode, 405);
    });

    test('GET with an event-stream accept opens an sse stream', () async {
      final client = await session();
      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));

      final request = await httpClient.getUrl(endpoint);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Accept', 'text/event-stream');
      request.headers.set(sessionHeader, client.sessionId!);
      final response = await request.close();

      expect(response.statusCode, 200);
      expect(response.headers.contentType!.mimeType, 'text/event-stream');
      // SSE is defined as UTF-8, and the charset is what makes the response
      // sink encode it — without it non-ASCII payloads kill the stream.
      expect(response.headers.contentType!.charset, 'utf-8');
    });

    test('GET without an event-stream accept is 405', () async {
      final r = await http.get(
        endpoint,
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(r.statusCode, 405);
    });

    test('DELETE ends the session and is idempotent', () async {
      final client = McpTestClient(endpoint, bearer: token);
      await client.initialize();
      final id = client.sessionId!;
      expect(transport.sessionIds, contains(id));

      Future<int> del() async => (await http.delete(
        endpoint,
        headers: {'Authorization': 'Bearer $token', sessionHeader: id},
      )).statusCode;

      expect(await del(), anyOf(200, 204));
      expect(transport.sessionIds, isNot(contains(id)));
      // A client retrying its shutdown must not have to special-case the
      // second attempt.
      expect(await del(), anyOf(200, 204));
    });

    test('a session is dropped once it goes idle', () async {
      final idle = McpTransport(
        onSession: () => buildMcpServer(const []),
        bearerToken: token,
        idleTimeout: const Duration(milliseconds: 50),
      );
      final port = await idle.start();
      addTearDown(idle.stop);

      final client = McpTestClient(
        Uri.parse('http://127.0.0.1:$port$mcpPath'),
        bearer: token,
      );
      await client.initialize();
      expect(idle.sessionIds, isNotEmpty);

      // Otherwise an agent that exits without a DELETE leaks its session, and
      // with it the tools closing over the Store, until the app quits.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(idle.sessionIds, isEmpty);
    });
  });

  group('constantTimeEquals', () {
    test('matches equal strings and rejects differences', () {
      expect(constantTimeEquals('abcdef', 'abcdef'), isTrue);
      expect(constantTimeEquals('abcdef', 'abcdeg'), isFalse);
      expect(constantTimeEquals('abc', 'abcdef'), isFalse);
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('discovery file', () {
    test('writes the port and never the token', () async {
      final tmp = Directory.systemTemp.createTempSync('mcpdisco');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = await writeDiscoveryFile(
        51234,
        env: {'HOME': tmp.path, 'XDG_CONFIG_HOME': tmp.path},
        platform: 'linux',
      );
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(json['port'], 51234);
      expect(json['url'], 'http://127.0.0.1:51234$mcpPath');
      expect(file.readAsStringSync().toLowerCase(), isNot(contains('token')));
      expect(file.path, endsWith('deptracker/mcp.json'));
    });

    test('overwrites a stale file from a previous run', () async {
      final tmp = Directory.systemTemp.createTempSync('mcpdisco');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final env = {'HOME': tmp.path, 'XDG_CONFIG_HOME': tmp.path};
      await writeDiscoveryFile(1111, env: env, platform: 'linux');
      final file = await writeDiscoveryFile(2222, env: env, platform: 'linux');
      expect(jsonDecode(file.readAsStringSync())['port'], 2222);
    });
  });
}
