import 'dart:convert';
import 'dart:io';

import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/mcp/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

Map<String, Object?> rpc(String method, [Map<String, Object?>? params]) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': method,
  if (params != null) 'params': params,
};

void main() {
  setUp(() async {
    transport = McpTransport(
      server: McpServer([
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
      final r = await post(rpc('ping'));
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
        rpc('ping'),
        extra: {'Origin': 'http://localhost:5173'},
      );
      expect(r.statusCode, 200);
    });

    test('accepts no origin, which is what native clients send', () async {
      final r = await post(rpc('ping'));
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
    test('answers a request with json', () async {
      final r = await post(
        rpc('initialize', {'protocolVersion': mcpProtocolVersion}),
      );
      expect(r.statusCode, 200);
      expect(r.headers['content-type'], contains('application/json'));
      final body = jsonDecode(r.body) as Map<String, Object?>;
      expect((body['result'] as Map)['protocolVersion'], mcpProtocolVersion);
    });

    test('answers a notification with 202 and no body', () async {
      final r = await post({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(r.statusCode, 202);
      expect(r.body, isEmpty);
    });

    test('malformed json is a -32700 parse error', () async {
      final r = await post('{ not json');
      expect(r.statusCode, 400);
      expect((jsonDecode(r.body)['error'] as Map)['code'], -32700);
    });

    test(
      'a json array batch is rejected clearly rather than half-handled',
      () async {
        final r = await post([rpc('ping')]);
        expect(r.statusCode, 400);
      },
    );

    test('tools/call round-trips through http', () async {
      final r = await post(
        rpc('tools/call', {'name': 'echo', 'arguments': <String, Object?>{}}),
      );
      final result = jsonDecode(r.body)['result'] as Map<String, Object?>;
      expect(result['isError'], isFalse);
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
      final client = HttpClient();
      final request = await client.getUrl(endpoint);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Accept', 'text/event-stream');
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType!.mimeType, 'text/event-stream');
      client.close(force: true);
    });

    test('GET without an event-stream accept is 405', () async {
      final r = await http.get(
        endpoint,
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(r.statusCode, 405);
    });

    test('DELETE is accepted so clients can end a session cleanly', () async {
      final r = await http.delete(
        endpoint,
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(r.statusCode, anyOf(200, 204));
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
