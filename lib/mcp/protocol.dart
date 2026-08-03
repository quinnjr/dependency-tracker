import 'dart:convert';

import 'package:mcp_sse_server/mcp_sse_server.dart' as mcp;

import '../redact.dart';
import 'tools.dart';

/// MCP revision this server speaks.
///
/// Comes from `package:mcp_sse_server` rather than being asserted here; kept as
/// a named constant because the settings pane and the docs quote it.
const String mcpProtocolVersion = mcp.latestProtocolVersion;
const String serverName = 'dependency-tracker';
const String serverVersion = '0.1.0';

/// Builds the MCP server for one session.
///
/// The protocol itself — JSON-RPC framing, the `initialize` handshake,
/// capability advertisement, pagination, cancellation — belongs to
/// `package:mcp_sse_server`. What stays here is the adaptation of this app's
/// [ToolDef]s onto its [mcp.Tool], because the tools are the part that is
/// actually about dependency tracking.
///
/// A fresh server per session is deliberate: [mcp.McpServer] carries
/// per-session state (initialization, subscriptions, in-flight requests), so
/// sharing one across clients would make a second client's `initialize`
/// collide with the first's session.
mcp.McpServer buildMcpServer(List<ToolDef> tools) {
  final server = mcp.McpServer(
    name: serverName,
    version: serverVersion,
    title: 'Dependency Tracker',
    instructions:
        'Tracks dependency versions across the projects on this machine. '
        'Use list_watches to see what is tracked and get_watch for detail.',
  );
  for (final tool in tools) {
    server.addTool(_asMcpTool(tool));
  }
  return server;
}

mcp.Tool _asMcpTool(ToolDef def) => mcp.Tool(
  name: def.name,
  description: def.description,
  inputSchema: def.inputSchema,
  handler: (arguments, context) async {
    try {
      return _resultOf(await def.handler(Map<String, Object?>.from(arguments)));
    } catch (e) {
      // A tool failure is a result the model can read and react to, not a
      // protocol error — an agent that asked about a package that no longer
      // exists should be told so, not handed a JSON-RPC error it cannot
      // attribute to a call. Redacted because a failing refresh can carry a
      // registry error string, and redact() is the only thing standing between
      // a keyring token and the transcript.
      return mcp.CallToolResult.error('Error: ${redact(e.toString())}');
    }
  },
);

/// Mirrors the pre-package encoding: a String is the text itself, anything else
/// is pretty-printed JSON. Clients and the e2e tests read `content[0].text`, so
/// changing this would be a visible protocol change, not a refactor.
mcp.CallToolResult _resultOf(Object? value) {
  if (value is String) return mcp.CallToolResult.text(value);
  return mcp.CallToolResult.text(
    const JsonEncoder.withIndent('  ').convert(value),
  );
}
