import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'bootstrap/app_resources.dart';
import 'bootstrap/bootstrap.dart';
import 'ui/app.dart';
import 'ui/login.dart';
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

  Widget _shell(AppResources r) => AppShell(
    store: r.store,
    mutations: r.mutations,
    onRefresh: r.refresh,
    settingsPane: SettingsPane(
      store: r.store,
      secrets: r.secrets,
      pickDirectory: r.pickDirectory,
      onScan: r.onScan,
      mcpKeys: r.mcpKeys,
      mutations: r.mutations,
      auth: r.auth,
      mcpPort: r.mcpPort,
      mcpError: r.mcpError,
      isWeb: r.isWeb,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.resources;
    return MaterialApp(
      title: 'Dependency Tracker',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: r.auth == null
          ? _shell(r)
          : _AuthGate(resources: r, shell: () => _shell(r)),
    );
  }
}

/// Web only: the shell appears once a session exists; until then, the login
/// screen. Also surfaces the SyncClient's last failed round trip as a
/// dismissible banner — a mutation that silently never reached the server
/// would otherwise look like a UI bug.
class _AuthGate extends StatelessWidget {
  const _AuthGate({required this.resources, required this.shell});

  final AppResources resources;
  final Widget Function() shell;

  @override
  Widget build(BuildContext context) {
    final auth = resources.auth!;
    final syncError = resources.syncError;
    return NotifierBuilder(
      listenable: auth.changes,
      builder: (context) {
        if (!auth.authenticated) return LoginScreen(auth: auth);
        final body = shell();
        if (syncError == null) return body;
        return NotifierBuilder(
          listenable: syncError,
          builder: (context) => Column(
            children: [
              if (syncError.value != null)
                MaterialBanner(
                  content: Text(syncError.value!),
                  actions: [
                    TextButton(
                      onPressed: () => syncError.value = null,
                      child: const Text('Dismiss'),
                    ),
                  ],
                ),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }
}
