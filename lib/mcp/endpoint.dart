/// The one MCP fact the UI needs (the settings pane prints the endpoint
/// URL). Separated from transport.dart so importing it does not pull in
/// dart:io's HttpServer on the web build.
const String mcpPath = '/mcp';
