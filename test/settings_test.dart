import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/scanner.dart';
import 'package:deptracker/secrets.dart';
import 'package:deptracker/store.dart';
import 'package:deptracker/ui/settings.dart';

/// A backend whose `write` throws with the secret embedded in the message,
/// so I4's redaction fix can be observed: `Secrets.setGithubToken` calls
/// `registerSecret` before this write is attempted, so the value is
/// redactable at the moment of failure — the only question is whether the
/// caller applies `redact()` before rendering it.
/// A backend that fails every read the way an absent secret service does, so
/// the pane's PAT probe takes its KeyringUnavailable arm.
class _UnavailableBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async =>
      throw Exception('no secret service');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('no secret service');

  @override
  Future<void> delete(String key) async {}
}

class _ThrowingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw Exception('backend rejected token $value');
  }

  @override
  Future<void> delete(String key) async {}
}

late Store store;
late Secrets secrets;
late int scans;
String? pick;

Widget pane({int? mcpPort = 51234, Object? mcpError}) => MaterialApp(
  home: Scaffold(
    body: SettingsPane(
      store: store,
      secrets: secrets,
      pickDirectory: () async => pick,
      onScan: () async {
        scans++;
        return const ScanResult(projectsScanned: 2, depsFound: 9, errors: []);
      },
      mcpPort: mcpPort,
      mcpError: mcpError,
    ),
  ),
);

void main() {
  settingsEdgeTests();
  setUp(() {
    store = Store.openInMemory();
    secrets = Secrets(MemorySecretBackend());
    scans = 0;
    pick = null;
  });

  tearDown(() => store.close());

  testWidgets('lists existing scan roots', (tester) async {
    store.addScanRoot('/home/me/projects');
    await tester.pumpWidget(pane());
    expect(find.text('/home/me/projects'), findsOneWidget);
  });

  testWidgets('adding a root through the picker persists it', (tester) async {
    pick = '/home/me/work';
    await tester.pumpWidget(pane());
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add folder'));
    await tester.pumpAndSettle();
    expect(store.scanRoots(), ['/home/me/work']);
    expect(find.text('/home/me/work'), findsOneWidget);
  });

  testWidgets('a cancelled picker changes nothing', (tester) async {
    pick = null;
    await tester.pumpWidget(pane());
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add folder'));
    await tester.pumpAndSettle();
    expect(store.scanRoots(), isEmpty);
  });

  testWidgets('removing a root works', (tester) async {
    store.addScanRoot('/home/me/projects');
    await tester.pumpWidget(pane());
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(store.scanRoots(), isEmpty);
  });

  testWidgets('scan now reports what it found', (tester) async {
    await tester.pumpWidget(pane());
    await tester.tap(find.widgetWithText(FilledButton, 'Scan now'));
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.textContaining('2 projects'), findsOneWidget);
    expect(find.textContaining('9'), findsWidgets);
  });

  testWidgets('saving a github token stores it in the keyring', (tester) async {
    await tester.pumpWidget(pane());
    await tester.enterText(
      find.byKey(const Key('pat-field')),
      'ghp_abcdefghijklmnop',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save token'));
    await tester.pumpAndSettle();
    expect(await secrets.githubToken(), 'ghp_abcdefghijklmnop');
  });

  testWidgets('a too-short token is explained, not thrown', (tester) async {
    await tester.pumpWidget(pane());
    await tester.enterText(find.byKey(const Key('pat-field')), 'short');
    await tester.tap(find.widgetWithText(TextButton, 'Save token'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('too short'), findsOneWidget);
    expect(await secrets.githubToken(), isNull);
  });

  testWidgets('the pat field is obscured', (tester) async {
    await tester.pumpWidget(pane());
    final field = tester.widget<TextField>(find.byKey(const Key('pat-field')));
    expect(field.obscureText, isTrue);
  });

  testWidgets('the pat field never renders a stored token back', (
    tester,
  ) async {
    await secrets.setGithubToken('ghp_abcdefghijklmnop');
    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('pat-field')));
    expect(field.controller!.text, isEmpty);
    expect(find.textContaining('ghp_'), findsNothing);
    // It should say a token exists without showing it.
    expect(find.textContaining('token is set'), findsOneWidget);
  });

  testWidgets('shows the mcp port', (tester) async {
    await tester.pumpWidget(pane(mcpPort: 51234));
    expect(find.textContaining('51234'), findsOneWidget);
  });

  testWidgets('the mcp token is not displayed until asked for', (tester) async {
    final token = await secrets.mcpToken();
    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();
    expect(find.textContaining(token), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Reveal token'));
    await tester.pumpAndSettle();
    expect(find.textContaining(token), findsOneWidget);
  });

  testWidgets('rotating the mcp token replaces it with a new one (M3)', (
    tester,
  ) async {
    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reveal token'));
    await tester.pumpAndSettle();
    final before = await secrets.mcpToken();
    expect(find.textContaining(before), findsOneWidget);

    await tester.tap(
      find.byTooltip('Rotate token — invalidates the current one'),
    );
    await tester.pumpAndSettle();

    final after = await secrets.mcpToken();
    expect(after, isNot(before));
    expect(find.textContaining(after), findsOneWidget);
    expect(find.textContaining(before), findsNothing);
  });

  testWidgets('an mcp startup failure is explained, not hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      pane(mcpPort: null, mcpError: KeyringUnavailable('no secret service')),
    );
    expect(find.textContaining('MCP server is not running'), findsOneWidget);
    expect(find.textContaining('keyring'), findsWidgets);
  });

  testWidgets(
    'an mcp startup failure whose cause embeds a registered secret is '
    'redacted (I4)',
    (tester) async {
      const token = 'ghp_abcdefghijklmnop';
      await secrets.setGithubToken(token); // registers `token` for redact().
      await tester.pumpWidget(
        pane(
          mcpPort: null,
          mcpError: KeyringUnavailable('write failed: token=$token'),
        ),
      );
      expect(find.textContaining(token), findsNothing);
      expect(find.textContaining('«redacted»'), findsOneWidget);
    },
  );

  testWidgets(
    'a keyring failure while saving a pat is redacted, not echoed raw (I4)',
    (tester) async {
      const token = 'ghp_abcdefghijklmnop';
      secrets = Secrets(_ThrowingBackend());
      await tester.pumpWidget(pane());
      await tester.enterText(find.byKey(const Key('pat-field')), token);
      await tester.tap(find.widgetWithText(TextButton, 'Save token'));
      await tester.pumpAndSettle();
      // The failed save leaves the token in the input field (obscured on
      // screen, but still visible to a text finder) — clear it so the
      // assertion below is only about the rendered status text.
      await tester.enterText(find.byKey(const Key('pat-field')), '');
      await tester.pumpAndSettle();
      expect(find.textContaining(token), findsNothing);
      expect(find.textContaining('«redacted»'), findsOneWidget);
    },
  );
}

// The three remaining branches: a keyring that fails while probing for a
// stored PAT, copying the revealed MCP token, and the pre-startup state.
void settingsEdgeTests() {
  testWidgets('a keyring failure while probing for a stored PAT is swallowed, '
      'not shown twice', (tester) async {
    // The MCP error banner already explains an unavailable keyring, so this
    // probe must not surface a second, redundant error — but it also must not
    // take the pane down.
    secrets = Secrets(_UnavailableBackend());

    await tester.pumpWidget(
      pane(mcpPort: null, mcpError: KeyringUnavailable('no secret service')),
    );
    await tester.pumpAndSettle();

    // The pane still renders, and the single explanation is the banner's.
    expect(find.textContaining('GitHub'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the mcp token can be copied to the clipboard', (tester) async {
    // The token is never displayed until asked for, so copy is the only
    // practical way to get it into an agent's config.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(pane());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reveal token'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithIcon(IconButton, Icons.copy));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, isNotEmpty);
    // What lands on the clipboard must be the token itself, not a label.
    expect(copied.single, await secrets.mcpToken());
  });

  testWidgets('before the server has a port, the pane says it is starting', (
    tester,
  ) async {
    // mcpPort null with no error is the window between launch and bind.
    await tester.pumpWidget(pane(mcpPort: null));
    await tester.pumpAndSettle();

    expect(find.text('Starting…'), findsOneWidget);
  });
}
