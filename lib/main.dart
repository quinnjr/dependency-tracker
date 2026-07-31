import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'mcp/protocol.dart';
import 'mcp/tools.dart';
import 'mcp/transport.dart';
import 'net.dart';
import 'paths.dart';
import 'refresh.dart';
import 'scanner.dart';
import 'secrets.dart';
import 'store.dart';
import 'ui/app.dart';
import 'ui/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ensureDir(dataDir());
  final store = Store.open(databasePath());
  final secrets = Secrets(KeyringBackend());
  // Store implements EtagCache with its persistent http_cache table, so a
  // launch-time refresh reuses etags across restarts instead of burning
  // registry quota re-fetching everything every time the app opens.
  final net = Net(cache: store);

  Future<RefreshReport> refresh(int? watchId) async => refreshAll(
    store,
    net,
    token: await _githubTokenOrNull(secrets),
    onlyWatchId: watchId,
  );

  // The MCP server needs a bearer token, and the token lives in the keyring.
  // With no keyring there is no authenticated server, and the spec forbids
  // running an unauthenticated one — so the app runs without MCP and says why.
  McpTransport? transport;
  int? mcpPort;
  Object? mcpError;
  try {
    final token = await secrets.mcpToken();
    transport = McpTransport(
      server: McpServer(buildTools(store, refresh: refresh)),
      bearerToken: token,
    );
    mcpPort = await transport.start();
    await writeDiscoveryFile(mcpPort);
  } catch (e) {
    mcpError = e;
  }

  runApp(
    TrackerApp(
      store: store,
      secrets: secrets,
      net: net,
      refresh: refresh,
      transport: transport,
      mcpPort: mcpPort,
      mcpError: mcpError,
    ),
  );
}

/// A missing keyring must not cost the optional GitHub PAT path: a refresh
/// with no token simply falls back to public Atom feeds for release notes.
Future<String?> _githubTokenOrNull(Secrets secrets) async {
  try {
    return await secrets.githubToken();
  } on KeyringUnavailable {
    return null;
  }
}

class TrackerApp extends StatefulWidget {
  const TrackerApp({
    super.key,
    required this.store,
    required this.secrets,
    required this.net,
    required this.refresh,
    required this.transport,
    required this.mcpPort,
    required this.mcpError,
  });

  final Store store;
  final Secrets secrets;
  final Net net;
  final Future<RefreshReport> Function(int? watchId) refresh;
  final McpTransport? transport;
  final int? mcpPort;
  final Object? mcpError;

  @override
  State<TrackerApp> createState() => _TrackerAppState();
}

class _TrackerAppState extends State<TrackerApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // The MCP server exists only while the window is open, so releasing the
    // port on exit matters: a leaked listener would collide on next launch.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.transport?.stop();
        widget.net.close();
        widget.store.close();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dependency Tracker',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: AppShell(
        store: widget.store,
        onRefresh: widget.refresh,
        settingsPane: SettingsPane(
          store: widget.store,
          secrets: widget.secrets,
          pickDirectory: () => FilePicker.platform.getDirectoryPath(),
          onScan: () => scanRoots(widget.store),
          mcpPort: widget.mcpPort,
          mcpError: widget.mcpError,
        ),
      ),
    );
  }
}
