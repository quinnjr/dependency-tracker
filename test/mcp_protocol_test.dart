// The JSON-RPC framing, the initialize handshake, capability advertisement,
// and the error codes for malformed requests all belong to
// package:mcp_sse_server now, and are covered by its own suite — the tests
// this file used to carry for them were testing a dispatcher this app no
// longer owns.
//
// What remains ours is the seam: buildMcpServer adapting ToolDefs onto the
// package's Tool, and specifically the three behaviours a client depends on —
// that every tool arrives with its schema intact, how a tool's return value is
// encoded, and what happens to a tool that throws.
//
// It runs over MemoryTransport rather than HTTP so it exercises the real
// protocol path without a socket; mcp_transport_test.dart covers the socket.
import 'dart:async';
import 'dart:convert';

import 'package:deptracker/mcp/protocol.dart';
import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/redact.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_sse_server/mcp_sse_server.dart' as mcp;

const String _secret = 'sup3r-s3cret-value-01234567';

List<ToolDef> _tools() => [
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
    name: 'plain',
    description: 'Returns a bare string.',
    inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
    handler: (args) async => 'just text',
  ),
  ToolDef(
    name: 'explode',
    description: 'Always throws.',
    inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
    handler: (args) async => throw StateError('boom'),
  ),
  ToolDef(
    name: 'leaks',
    description: 'Throws with a registered secret in the message.',
    inputSchema: const {'type': 'object', 'properties': <String, Object?>{}},
    handler: (args) async => throw StateError('token=$_secret failed'),
  ),
];

/// A client speaking to [buildMcpServer] in-process.
class _Client {
  _Client._(this._transport, this._replies);

  static Future<_Client> connect() async {
    final (serverSide, clientSide) = mcp.MemoryTransport.pair();
    final server = buildMcpServer(_tools());
    await server.connect(serverSide);

    final replies = StreamController<mcp.JsonRpcMessage>.broadcast();
    clientSide.messages.listen(replies.add);
    await clientSide.start();

    final client = _Client._(clientSide, replies);
    await client._handshake();
    return client;
  }

  final mcp.MemoryTransport _transport;
  final StreamController<mcp.JsonRpcMessage> _replies;
  int _nextId = 1;

  Future<void> _handshake() async {
    await call('initialize', {
      'protocolVersion': mcp.latestProtocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'test', 'version': '1'},
    });
    await _transport.send(
      mcp.JsonRpcNotification(method: 'notifications/initialized'),
    );
  }

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final id = _nextId++;
    final reply = _replies.stream
        .firstWhere((m) => m is mcp.JsonRpcResponse && m.id == id)
        .timeout(const Duration(seconds: 5));
    await _transport.send(
      mcp.JsonRpcRequest(id: id, method: method, params: params),
    );
    return ((await reply) as mcp.JsonRpcResponse).result;
  }

  /// The single text block a tool result carries, with its isError flag.
  Future<({String text, bool isError})> callTool(
    String name, [
    Map<String, Object?>? args,
  ]) async {
    final result = await call('tools/call', {
      'name': name,
      if (args != null) 'arguments': args,
    });
    final content = (result['content']! as List).single as Map;
    return (
      text: content['text']! as String,
      isError: result['isError'] == true,
    );
  }

  Future<void> close() => _transport.close();
}

void main() {
  setUp(clearSecrets);

  test('every ToolDef is registered with its schema intact', () async {
    final client = await _Client.connect();
    addTearDown(client.close);

    final result = await client.call('tools/list');
    final tools = (result['tools']! as List).cast<Map<String, Object?>>();

    expect(
      tools.map((t) => t['name']),
      containsAll(['echo', 'plain', 'explode', 'leaks']),
    );
    final echo = tools.firstWhere((t) => t['name'] == 'echo');
    expect(echo['description'], 'Echoes its argument.');
    // The schema is what tells an agent how to call the tool, so a lossy
    // adaptation would stay invisible until a client sent wrong arguments.
    expect((echo['inputSchema']! as Map)['required'], ['text']);
  });

  test('a non-String return is encoded as pretty-printed JSON', () async {
    final client = await _Client.connect();
    addTearDown(client.close);

    final r = await client.callTool('echo', {'text': 'hi'});
    expect(r.isError, isFalse);
    // Clients read content[0].text, so this encoding is part of the contract
    // rather than a formatting preference.
    expect(jsonDecode(r.text), {'echoed': 'hi'});
    expect(r.text, contains('\n'), reason: 'should be indented');
  });

  test('a String return is passed through as the text itself', () async {
    final client = await _Client.connect();
    addTearDown(client.close);

    expect((await client.callTool('plain')).text, 'just text');
  });

  test(
    'a throwing tool becomes an isError result, not a protocol error',
    () async {
      final client = await _Client.connect();
      addTearDown(client.close);

      // The distinction matters: a model can read and react to a tool result,
      // whereas a JSON-RPC error is not attributable to the call it came from.
      final r = await client.callTool('explode');
      expect(r.isError, isTrue);
      expect(r.text, contains('boom'));
    },
  );

  test(
    'a secret in a tool failure is redacted before it reaches the client',
    () async {
      registerSecret(_secret);
      addTearDown(clearSecrets);

      final client = await _Client.connect();
      addTearDown(client.close);

      final r = await client.callTool('leaks');
      expect(r.isError, isTrue);
      expect(r.text, isNot(contains(_secret)));
    },
  );

  test('non-ASCII tool text survives the round trip', () async {
    // The em dashes in this app's real tool descriptions are what exposed the
    // Latin-1 SSE sink in mcp_sse_server 0.2.0; pinning it here keeps a
    // dependency downgrade from silently reintroducing it.
    final client = await _Client.connect();
    addTearDown(client.close);

    final r = await client.callTool('echo', {'text': 'em — dash'});
    expect(jsonDecode(r.text), {'echoed': 'em — dash'});
  });
}
