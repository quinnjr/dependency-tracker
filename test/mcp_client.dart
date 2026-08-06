// A minimal MCP client for the transport tests.
//
// Two things changed when the protocol moved to package:mcp_sse_server, and
// both of them live here rather than being repeated in every test:
//
//  * Sessions. A client must `initialize` before anything else, and carry the
//    returned session id on every later request.
//  * Framing. A POST carrying a JSON-RPC *request* is answered with an SSE
//    stream (`event: message` / `data: {...}`), not a bare JSON body — that is
//    what Streamable HTTP specifies. Notifications still get a bare 202.
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The header the MCP spec uses to carry the session id.
const String sessionHeader = 'mcp-session-id';

Map<String, Object?> rpc(
  String method, {
  Object? id = 1,
  Map<String, Object?>? params,
}) => {
  'jsonrpc': '2.0',
  if (id != null) 'id': id,
  'method': method,
  if (params != null) 'params': params,
};

/// Pulls the JSON-RPC payloads out of an SSE body.
///
/// Tolerates comment lines (`: keep-alive`) and multi-line `data:` fields so a
/// heartbeat landing mid-response cannot break a test.
List<Map<String, Object?>> parseSse(String body) {
  final messages = <Map<String, Object?>>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isEmpty) return;
    final text = buffer.toString();
    buffer.clear();
    final decoded = jsonDecode(text);
    if (decoded is Map) messages.add(Map<String, Object?>.from(decoded));
  }

  for (final line in const LineSplitter().convert(body)) {
    if (line.isEmpty) {
      flush();
    } else if (line.startsWith('data:')) {
      buffer.write(line.substring(5).trimLeft());
    }
    // `:` comments and `event:`/`id:` fields carry nothing this needs.
  }
  flush();
  return messages;
}

/// A connected MCP session against a running transport.
class McpTestClient {
  McpTestClient(this.endpoint, {this.bearer});

  final Uri endpoint;
  final String? bearer;
  String? sessionId;

  Map<String, String> headers({Map<String, String> extra = const {}}) => {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    if (bearer != null) 'Authorization': 'Bearer $bearer',
    if (sessionId != null) sessionHeader: sessionId!,
    ...extra,
  };

  Future<http.Response> post(
    Object body, {
    Map<String, String> extra = const {},
  }) => http.post(
    endpoint,
    headers: headers(extra: extra),
    body: body is String ? body : jsonEncode(body),
  );

  /// Performs the `initialize` handshake and adopts the session id.
  Future<Map<String, Object?>> initialize() async {
    final response = await post(
      rpc(
        'initialize',
        params: {
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'test-client', 'version': '1.0.0'},
        },
      ),
    );
    sessionId = response.headers[sessionHeader];
    final reply = parseSse(response.body).first;

    // `notifications/initialized` is what moves the server out of the
    // handshake; without it every later call is refused as uninitialized.
    await post(rpc('notifications/initialized', id: null));
    return reply;
  }

  /// Sends a request and returns the single JSON-RPC reply.
  Future<Map<String, Object?>> call(
    String method, {
    Map<String, Object?>? params,
    Object? id = 1,
  }) async {
    final response = await post(rpc(method, id: id, params: params));
    final messages = parseSse(response.body);
    if (messages.isEmpty) {
      throw StateError(
        'no JSON-RPC reply in ${response.statusCode} body: ${response.body}',
      );
    }
    return messages.last;
  }

  /// The decoded `result` of a successful `tools/call`, which the server sends
  /// as pretty-printed JSON inside a single text content block.
  Future<Object?> callTool(String name, [Map<String, Object?>? args]) async {
    final reply = await call(
      'tools/call',
      params: {'name': name, if (args != null) 'arguments': args},
    );
    final result = reply['result'] as Map<String, Object?>?;
    if (result == null) return reply;
    final content = (result['content'] as List).first as Map;
    final text = content['text'] as String;
    if (result['isError'] == true) throw StateError(text);
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  Future<void> close() async {
    if (sessionId == null) return;
    await http.delete(endpoint, headers: headers());
    sessionId = null;
  }
}
