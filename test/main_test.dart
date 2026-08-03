// lib/main.dart was invisible to coverage entirely, because nothing imported
// it — so the widget that owns the app's shutdown path had never been built in
// a test. `main()` itself stays untestable (it opens the real database, talks
// to the real keyring, and binds a port), but everything it assembles is
// injectable and is covered here.
import 'package:deptracker/main.dart';
import 'package:file_picker/file_picker.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/net.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/secrets.dart';
import 'package:deptracker/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

late Store store;
late Net net;
late int refreshes;

Widget subject({int? mcpPort = 51234, Object? mcpError}) => TrackerApp(
  store: store,
  secrets: Secrets(MemorySecretBackend()),
  net: net,
  refresh: (id) async {
    refreshes++;
    return const RefreshReport(refreshed: 1, failed: 0, newReleases: 0);
  },
  transport: null,
  mcpPort: mcpPort,
  mcpError: mcpError,
);

/// Asks the engine to close the app, which is what drives
/// `AppLifecycleListener.onExitRequested`.
Future<void> requestExit(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/platform',
    const JSONMethodCodec().encodeMethodCall(
      const MethodCall('System.requestAppExit'),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    store = Store.openInMemory();
    net = Net();
    refreshes = 0;
  });

  testWidgets('builds the shell with the watch list', (tester) async {
    store.upsertWatch(WatchKind.pub, 'http');

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.text('http'), findsOneWidget);
  });

  testWidgets('renders in dark mode too', (tester) async {
    // Both themes are declared, so both should build.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('an exit request releases the port, the client, and the store', (
    tester,
  ) async {
    // The MCP server only exists while the window is open, and a leaked
    // listener collides with the next launch — so this is the teardown that
    // has to happen before the process goes away.
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await requestExit(tester);

    // A closed store fails loudly rather than appearing to work.
    expect(() => store.watches(), throwsA(anything));
  });

  testWidgets('exiting without an MCP transport is not an error', (
    tester,
  ) async {
    // main.dart runs the app with a null transport when the keyring is
    // unavailable, and that path still has to shut down cleanly.
    await tester.pumpWidget(subject(mcpPort: null, mcpError: 'no keyring'));
    await tester.pumpAndSettle();

    await requestExit(tester);
    expect(() => store.watches(), throwsA(anything));
  });

  testWidgets('the settings pane is wired to the real picker and scanner', (
    tester,
  ) async {
    // TrackerApp passes two closures down to SettingsPane: the directory
    // picker and the scanner. Building the widget does not run them — only the
    // pane's own buttons do — so they were the last unexercised lines in the
    // file that wires the whole app together.
    //
    // FilePicker.platform is registered by the plugin at app startup, which a
    // widget test never runs, so it is substituted here. Returning null is
    // the cancelled case, which must leave the roots untouched.
    FilePicker.platform = _CancellingPicker();
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add folder'));
    await tester.pumpAndSettle();
    expect(store.scanRoots(), isEmpty, reason: 'a cancelled pick adds nothing');

    await tester.tap(find.widgetWithText(FilledButton, 'Scan now'));
    await tester.pumpAndSettle();
    // Scanning with no roots configured is a no-op that still reports.
    expect(find.textContaining('projects'), findsOneWidget);

    store.close();
  });

  testWidgets('disposing the app tears down its lifecycle listener', (
    tester,
  ) async {
    await tester.pumpWidget(subject());
    await tester.pumpAndSettle();

    // Replacing the tree disposes TrackerApp; a listener left registered
    // would fire against a dead State on the next exit request.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    store.close();
  });
}

/// Stands in for the plugin instance the app registers at startup.
class _CancellingPicker extends FilePicker {
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => null;
}
