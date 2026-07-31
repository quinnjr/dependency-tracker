import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:flutter_test/flutter_test.dart';

McpServer server() => McpServer([
  ToolDef(
    name: 'echo',
    description: 'Echoes its argument.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
      },
      'required': ['text'],
    },
    handler: (args) async => {'echoed': args['text']},
  ),
  ToolDef(
    name: 'explode',
    description: 'Always throws.',
    inputSchema: const {'type': 'object', 'properties': {}},
    handler: (args) async => throw StateError('boom'),
  ),
]);

Map<String, Object?> req(String method, [Map<String, Object?>? params]) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': method,
  if (params != null) 'params': params,
};

void main() {
  test(
    'initialize advertises the protocol version and tools capability',
    () async {
      final r = await server().handle(
        req('initialize', {
          'protocolVersion': mcpProtocolVersion,
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'test', 'version': '1'},
        }),
      );
      final result = r!['result'] as Map<String, Object?>;
      expect(result['protocolVersion'], mcpProtocolVersion);
      expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
      expect((result['serverInfo'] as Map)['name'], 'dependency-tracker');
    },
  );

  test(
    'initialize does not advertise capabilities it does not implement',
    () async {
      final r = await server().handle(
        req('initialize', {'protocolVersion': mcpProtocolVersion}),
      );
      final caps = ((r!['result'] as Map)['capabilities'] as Map).keys.toSet();
      expect(caps, {'tools'});
    },
  );

  test(
    'an unsupported client protocol version still gets our version',
    () async {
      final r = await server().handle(
        req('initialize', {'protocolVersion': '1999-01-01'}),
      );
      expect((r!['result'] as Map)['protocolVersion'], mcpProtocolVersion);
    },
  );

  test('notifications/initialized produces no response', () async {
    final r = await server().handle({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
    });
    expect(r, isNull);
  });

  test('ping returns an empty result', () async {
    final r = await server().handle(req('ping'));
    expect(r!['result'], isEmpty);
  });

  test('tools/list returns names, descriptions, and schemas', () async {
    final r = await server().handle(req('tools/list'));
    final tools = (r!['result'] as Map)['tools'] as List;
    expect(tools.map((t) => (t as Map)['name']), ['echo', 'explode']);
    final echo = tools.first as Map;
    expect(echo['description'], isNotEmpty);
    expect((echo['inputSchema'] as Map)['type'], 'object');
  });

  test('tools/call returns the handler result as json text content', () async {
    final r = await server().handle(
      req('tools/call', {
        'name': 'echo',
        'arguments': {'text': 'hi'},
      }),
    );
    final result = r!['result'] as Map<String, Object?>;
    expect(result['isError'], isFalse);
    final content = (result['content'] as List).single as Map;
    expect(content['type'], 'text');
    expect(content['text'], contains('"echoed"'));
    expect(content['text'], contains('hi'));
  });

  test('tools/call with missing arguments defaults to an empty map', () async {
    final r = await server().handle(req('tools/call', {'name': 'explode'}));
    expect(((r!['result']) as Map)['isError'], isTrue);
  });

  test(
    'a throwing handler becomes an isError result, not a protocol error',
    () async {
      final r = await server().handle(
        req('tools/call', {
          'name': 'explode',
          'arguments': <String, Object?>{},
        }),
      );
      expect(r!.containsKey('error'), isFalse);
      final result = r['result'] as Map<String, Object?>;
      expect(result['isError'], isTrue);
      expect(
        ((result['content'] as List).single as Map)['text'],
        contains('boom'),
      );
    },
  );

  test('an unknown tool name is an invalid-params error', () async {
    final r = await server().handle(req('tools/call', {'name': 'nope'}));
    expect((r!['error'] as Map)['code'], -32602);
  });

  test('an unknown method is a method-not-found error', () async {
    final r = await server().handle(req('resources/list'));
    expect((r!['error'] as Map)['code'], -32601);
  });

  test('an unknown notification is ignored rather than answered', () async {
    final r = await server().handle({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
    });
    expect(r, isNull);
  });

  test('the response echoes the request id, including a string id', () async {
    final r = await server().handle({
      'jsonrpc': '2.0',
      'id': 'abc',
      'method': 'ping',
    });
    expect(r!['id'], 'abc');
    expect(r['jsonrpc'], '2.0');
  });

  test('a request with no method is an invalid request', () async {
    final r = await server().handle({'jsonrpc': '2.0', 'id': 1});
    expect((r!['error'] as Map)['code'], -32600);
  });

  test('a request with an id but a non-String method is an invalid request, '
      'not dropped', () async {
    final r = await server().handle({'jsonrpc': '2.0', 'id': 1, 'method': 123});
    expect(r, isNotNull);
    expect((r!['error'] as Map)['code'], -32600);
  });
}
