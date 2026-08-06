import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/store.dart';
import 'package:deptracker/ui/app.dart';

late Store store;
late int refreshCount;

Widget app() => AppShell(
  store: store,
  settingsPane: const Text('settings pane'),
  onRefresh: (id) async {
    refreshCount++;
    return const RefreshReport(refreshed: 1, failed: 0, newReleases: 0);
  },
);

int seed({
  String name = 'http',
  String pinned = '1.2.0',
  List<String> releases = const [],
  bool read = false,
}) {
  final id = store.upsertWatch(WatchKind.pub, name);
  store.replaceUsagesForProject('/repos/app', 'pubspec.lock', [
    Usage(
      watchId: id,
      projectPath: '/repos/app',
      manifestFile: 'pubspec.lock',
      pinnedVersion: pinned,
      isResolved: true,
      isDevDep: false,
    ),
  ]);
  store.insertReleases(
    id,
    releases
        .map(
          (v) => Release(
            watchId: id,
            version: v,
            notesMd: 'Notes for $v',
            read: read,
          ),
        )
        .toList(),
  );
  return id;
}

void main() {
  detailPaneTests();
  setUp(() {
    store = Store.openInMemory();
    refreshCount = 0;
  });

  testWidgets('lists watched packages', (tester) async {
    seed(name: 'http');
    seed(name: 'provider');
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('http'), findsOneWidget);
    expect(find.text('provider'), findsOneWidget);
  });

  testWidgets('shows an unread count badge', (tester) async {
    seed(releases: ['1.3.0', '1.4.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('shows no badge when everything is read', (tester) async {
    seed(releases: ['1.3.0'], read: true);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.byKey(const Key('unread-badge')), findsNothing);
  });

  testWidgets('filter chips narrow the list', (tester) async {
    seed(name: 'quiet', releases: ['1.2.0'], read: true);
    seed(name: 'noisy', releases: ['9.9.9']);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('quiet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Unread'));
    await tester.pumpAndSettle();
    expect(find.text('noisy'), findsOneWidget);
    expect(find.text('quiet'), findsNothing);
  });

  testWidgets('selecting a watch shows its usages across projects', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    for (final path in ['/repos/a', '/repos/b']) {
      store.replaceUsagesForProject(path, 'pubspec.lock', [
        Usage(
          watchId: id,
          projectPath: path,
          manifestFile: 'pubspec.lock',
          pinnedVersion: path.endsWith('a') ? '1.2.0' : '1.1.0',
          isResolved: true,
          isDevDep: false,
        ),
      ]);
    }
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();
    expect(find.textContaining('/repos/a'), findsOneWidget);
    expect(find.textContaining('/repos/b'), findsOneWidget);
  });

  testWidgets('a watch with no usages explains it is not scanned', (
    tester,
  ) async {
    store.upsertWatch(WatchKind.pub, 'http');
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(
      find.textContaining('not used by any scanned project'),
      findsOneWidget,
    );
  });

  testWidgets('a watch with usages shows the usage count, not the zero case', (
    tester,
  ) async {
    seed(name: 'http');
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.textContaining('used in 1 project'), findsOneWidget);
    expect(
      find.textContaining('not used by any scanned project'),
      findsNothing,
    );
  });

  testWidgets('detail shows release notes', (tester) async {
    seed(releases: ['1.3.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Notes for 1.3.0'), findsOneWidget);
  });

  testWidgets('a range is labelled as unresolved rather than shown as a pin', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.replaceUsagesForProject('/repos/a', 'pubspec.yaml', [
      Usage(
        watchId: id,
        projectPath: '/repos/a',
        manifestFile: 'pubspec.yaml',
        pinnedVersion: '^1.2.0',
        isResolved: false,
        isDevDep: false,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();
    expect(find.textContaining('^1.2.0 (range)'), findsOneWidget);
  });

  testWidgets('a watch with an error shows a warning icon', (tester) async {
    final id = seed();
    store.setWatchMeta(id, lastError: 'pub.dev returned 500');
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('mark read from the detail pane clears the badge', (
    tester,
  ) async {
    seed(releases: ['1.3.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Mark read'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unread-badge')), findsNothing);
  });

  testWidgets('the refresh button calls the callback', (tester) async {
    seed();
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(refreshCount, 1);
  });

  testWidgets('a store change from outside the ui rebuilds the list', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('http'), findsNothing);

    // Exactly what an MCP add_watch call does.
    store.upsertWatch(WatchKind.pub, 'http');
    await tester.pumpAndSettle();
    expect(find.text('http'), findsOneWidget);
  });

  testWidgets('unread badges and usage text stay correct per-row across many '
      'watches, proving the batched counts query keys results by the right '
      'watch id rather than mixing rows up', (tester) async {
    seed(name: 'zero-unread', releases: ['1.0.0'], read: true);
    seed(name: 'two-unread', releases: ['1.3.0', '1.4.0']);
    seed(name: 'one-unread', releases: ['9.9.9']);
    store.upsertWatch(WatchKind.pub, 'no-releases-no-usages');

    await tester.pumpWidget(MaterialApp(home: app()));

    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('zero-unread'),
          matching: find.byType(ListTile),
        ),
        matching: find.byKey(const Key('unread-badge')),
      ),
      findsNothing,
    );

    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('two-unread'),
          matching: find.byType(ListTile),
        ),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('one-unread'),
          matching: find.byType(ListTile),
        ),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('no-releases-no-usages'),
          matching: find.byType(ListTile),
        ),
        matching: find.textContaining('not used by any scanned project'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty list explains what to do instead of showing blank', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.textContaining('No watches'), findsOneWidget);
  });

  testWidgets('the settings pane is reachable', (tester) async {
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('settings pane'), findsOneWidget);
  });
}

// Detail-pane controls and states nothing opened: snooze, the error banner,
// the no-usages case, release dates, and the per-release Read button.
void detailPaneTests() {
  testWidgets('a snoozed watch shows a snooze icon in the list', (
    tester,
  ) async {
    // Without it a snoozed watch is indistinguishable from one that simply
    // has no news, and the user cannot tell why it stopped appearing under
    // the Unread filter.
    final id = seed(name: 'http', releases: ['2.0.0']);
    store.snooze(id, DateTime.now().toUtc().add(const Duration(days: 7)));

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.snooze), findsOneWidget);
  });

  testWidgets('snoozing from the detail pane hides the watch from Unread', (
    tester,
  ) async {
    seed(name: 'http', releases: ['2.0.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Snooze 30d'));
    await tester.pumpAndSettle();

    // Snoozing is a store mutation, so it must land in the database rather
    // than only in widget state.
    final watch = store.watches().single;
    expect(watch.snoozedUntil, isNotNull);
    expect(watch.snoozedUntil!.isAfter(DateTime.now().toUtc()), isTrue);
  });

  testWidgets('a refresh error is surfaced in the detail pane', (tester) async {
    // Otherwise a watch that has been failing for weeks looks identical to
    // one that is simply quiet.
    final id = seed(name: 'http');
    store.setWatchMeta(id, lastError: 'pub.dev: 500 Internal Server Error');

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Last refresh failed:'), findsOneWidget);
    expect(find.textContaining('500 Internal Server Error'), findsOneWidget);
  });

  testWidgets('a watch no project depends on says so instead of showing an '
      'empty list', (tester) async {
    // Manually added watches, and watches whose last consumer was removed,
    // both land here.
    final id = store.upsertWatch(WatchKind.pub, 'orphan');
    store.insertReleases(id, [Release(watchId: id, version: '1.0.0')]);

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('orphan'));
    await tester.pumpAndSettle();

    expect(find.text('No scanned project depends on this.'), findsOneWidget);
  });

  testWidgets('a release shows its publish date', (tester) async {
    final id = seed(name: 'http');
    store.insertReleases(id, [
      Release(
        watchId: id,
        version: '2.0.0',
        publishedAt: DateTime.utc(2024, 6, 1, 12, 30),
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    // Date only: the time of day is noise for a release list.
    expect(find.text('2024-06-01'), findsOneWidget);
  });

  testWidgets('the per-release Read button marks only that release', (
    tester,
  ) async {
    final id = seed(name: 'http');
    store.insertReleases(id, [
      Release(watchId: id, version: '2.0.0'),
      Release(watchId: id, version: '3.0.0'),
    ]);

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    // Two unread releases, so two Read buttons.
    expect(find.widgetWithText(TextButton, 'Read'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(TextButton, 'Read').first);
    await tester.pumpAndSettle();

    final unread = store.releasesFor(id).where((r) => !r.read).toList();
    expect(unread, hasLength(1), reason: 'only one release should be read');
    // And the remaining button belongs to the one still unread.
    expect(find.widgetWithText(TextButton, 'Read'), findsOneWidget);
  });

  testWidgets('a watch with no releases shows the empty-releases note', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'brandnew');
    expect(store.releasesFor(id), isEmpty);

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('brandnew'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing fetched yet.'), findsOneWidget);
  });
}
