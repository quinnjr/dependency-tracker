import 'dart:convert';

import '../redact.dart';
import 'tools.dart';

/// MCP revision this server implements.
const String mcpProtocolVersion = '2025-06-18';
const String serverName = 'dependency-tracker';
const String serverVersion = '0.1.0';

// JSON-RPC 2.0 error codes.
const int _invalidRequest = -32600;
const int _methodNotFound = -32601;
const int _invalidParams = -32602;

class McpServer {
  McpServer(List<ToolDef> tools)
    : _tools = {for (final t in tools) t.name: t},
      _order = tools.map((t) => t.name).toList();

  final Map<String, ToolDef> _tools;
  final List<String> _order;

  /// Handles one JSON-RPC request. Returns null when the message is a
  /// notification, which must not be answered — the transport replies 202.
  Future<Map<String, Object?>?> handle(Map<String, Object?> request) async {
    final id = request['id'];
    final method = request['method'];
    final isNotification = id == null;

    if (method is! String) {
      if (isNotification) return null;
      return _error(id, _invalidRequest, 'request has no method');
    }

    // Notifications carry no id and get no reply, whether or not we know them.
    if (isNotification) return null;

    switch (method) {
      case 'initialize':
        return _result(id, {
          'protocolVersion': mcpProtocolVersion,
          // Only what is actually implemented: no resources, prompts, or
          // sampling. Advertising an unimplemented capability makes clients
          // call methods that then fail.
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': serverName, 'version': serverVersion},
        });

      case 'ping':
        return _result(id, <String, Object?>{});

      case 'tools/list':
        return _result(id, {
          'tools': [
            for (final name in _order)
              {
                'name': name,
                'description': _tools[name]!.description,
                'inputSchema': _tools[name]!.inputSchema,
              },
          ],
        });

      case 'tools/call':
        return _callTool(id, request['params']);

      default:
        return _error(id, _methodNotFound, 'unknown method: $method');
    }
  }

  Future<Map<String, Object?>> _callTool(Object? id, Object? params) async {
    final args = params is Map ? params : const <String, Object?>{};
    final name = args['name'];
    final tool = name is String ? _tools[name] : null;
    if (tool == null) {
      return _error(id, _invalidParams, 'unknown tool: $name');
    }

    final rawArguments = args['arguments'];
    final arguments = rawArguments is Map
        ? Map<String, Object?>.from(rawArguments)
        : <String, Object?>{};

    try {
      final value = await tool.handler(arguments);
      return _result(id, _content(_encode(value), isError: false));
    } catch (e) {
      // A tool failure is a result the model can read and react to, not a
      // protocol error. Redacted because a failing refresh can carry a
      // registry error string.
      return _result(
        id,
        _content('Error: ${redact(e.toString())}', isError: true),
      );
    }
  }

  Map<String, Object?> _content(String text, {required bool isError}) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': isError,
  };

  String _encode(Object? value) {
    if (value is String) return value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': redact(message)},
  };
}
