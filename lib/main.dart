import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'bootstrap/app_resources.dart';
import 'bootstrap/bootstrap.dart';
import 'ui/app.dart';
import 'ui/settings.dart';
import 'ui/theme.dart';

// coverage:ignore-start
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(TrackerApp(resources: await bootstrap()));
}
// coverage:ignore-end

class TrackerApp extends StatefulWidget {
  const TrackerApp({super.key, required this.resources});

  final AppResources resources;

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
    // What exactly gets released is the bootstrap's business — the platform
    // that opened the resources is the one that knows how to close them.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await widget.resources.shutdown();
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
    final r = widget.resources;
    return MaterialApp(
      title: 'Dependency Tracker',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: AppShell(
        store: r.store,
        onRefresh: r.refresh,
        settingsPane: SettingsPane(
          store: r.store,
          secrets: r.secrets,
          pickDirectory: r.pickDirectory,
          onScan: r.onScan,
          mcpKeys: r.mcpKeys,
          mcpPort: r.mcpPort,
          mcpError: r.mcpError,
          isWeb: r.isWeb,
        ),
      ),
    );
  }
}
