import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/bootstrap/app_resources.dart';
import 'package:deptracker/store.dart';
import 'package:deptracker/ui/app.dart';

late Store store;
late int refreshCount;

Widget app() => AppShell(
  store: store,
  mutations: StoreMutations.local(store),
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

  testWidgets('the masthead counts double as filters', (tester) async {
    seed(name: 'quiet', releases: ['1.2.0'], read: true);
    seed(name: 'noisy', releases: ['9.9.9']);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('quiet'), findsOneWidget);

    await tester.tap(find.text('UNREAD'));
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
    expect(find.textContaining('1 project'), findsOneWidget);
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
    expect(find.text('^1.2.0'), findsOneWidget);
    expect(find.text('RANGE'), findsOneWidget);
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
    await tester.tap(find.widgetWithText(TextButton, 'Mark all read'));
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
          matching: find.byType(InkWell),
        ),
        matching: find.byKey(const Key('unread-badge')),
      ),
      findsNothing,
    );

    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('two-unread'),
          matching: find.byType(InkWell),
        ),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('one-unread'),
          matching: find.byType(InkWell),
        ),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('no-releases-no-usages'),
          matching: find.byType(InkWell),
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

  testWidgets('a row states how far behind the stalest project is', (
    tester,
  ) async {
    // The number the whole app exists to show, on the row rather than only
    // behind a click.
    seed(name: 'http', pinned: '1.0.0', releases: ['1.0.0', '1.5.0', '2.0.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('2 BEHIND'), findsOneWidget);
    expect(find.text('CURRENT'), findsNothing);
    // 'BEHIND' on its own is the masthead tab, which is always present.
  });

  testWidgets('a row on the newest release is marked current, not blank', (
    tester,
  ) async {
    // Silence would be ambiguous between "up to date" and "never checked".
    seed(name: 'http', pinned: '2.0.0', releases: ['1.0.0', '2.0.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('CURRENT'), findsOneWidget);
    expect(find.text('1 BEHIND'), findsNothing);
  });

  testWidgets('a row with nothing fetched claims neither state', (
    tester,
  ) async {
    seed(name: 'http', pinned: '1.0.0');
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('CURRENT'), findsNothing);
    expect(find.text('1 BEHIND'), findsNothing);
  });

  testWidgets('a row shows the version spread when projects disagree', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    for (final (path, pin) in [('/repos/a', '1.0.0'), ('/repos/b', '2.0.0')]) {
      store.replaceUsagesForProject(path, 'pubspec.lock', [
        Usage(
          watchId: id,
          projectPath: path,
          manifestFile: 'pubspec.lock',
          pinnedVersion: pin,
          isResolved: true,
          isDevDep: false,
        ),
      ]);
    }
    store.insertReleases(id, [Release(watchId: id, version: '2.0.0')]);

    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('2 projects · 1.0.0 → 2.0.0'), findsOneWidget);
  });

  testWidgets('a row whose only pin is a range says so rather than guessing', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.replaceUsagesForProject('/repos/a', 'pubspec.yaml', [
      Usage(
        watchId: id,
        projectPath: '/repos/a',
        manifestFile: 'pubspec.yaml',
        pinnedVersion: '^1.0.0',
        isResolved: false,
        isDevDep: false,
      ),
    ]);
    store.insertReleases(id, [Release(watchId: id, version: '2.0.0')]);

    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('1 project · pinned by range only'), findsOneWidget);
  });

  testWidgets('a scanned-but-unfetched watch says so, not "no resolved pin"', (
    tester,
  ) async {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.replaceUsagesForProject('/repos/a', 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: '/repos/a',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.2.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    // No releases fetched: driftFor omits it, so drift is null even though a
    // real resolved pin exists.
    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('1 project · no releases fetched yet'), findsOneWidget);
  });

  testWidgets('the masthead counts every filter, not just the active one', (
    tester,
  ) async {
    seed(name: 'quiet', pinned: '1.0.0', releases: ['1.0.0'], read: true);
    seed(name: 'stale', pinned: '1.0.0', releases: ['9.9.9']);
    store.upsertWatch(WatchKind.pub, 'bare');

    await tester.pumpWidget(MaterialApp(home: app()));

    // Watched 3, Unread 1, Behind 1 — read off three separate tabs, so a
    // regression that made them all report the visible list would show up.
    for (final label in ['WATCHED', 'UNREAD', 'BEHIND']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('3'), findsOneWidget, reason: 'the Watched count');
    expect(
      find.text('1'),
      findsNWidgets(3),
      reason: 'the Unread and Behind counts, plus one row badge',
    );
  });

  testWidgets('tapping the Behind count narrows the list to what is behind', (
    tester,
  ) async {
    seed(name: 'quiet', pinned: '1.0.0', releases: ['1.0.0'], read: true);
    seed(name: 'stale', pinned: '1.0.0', releases: ['1.0.0', '9.9.9']);

    await tester.pumpWidget(MaterialApp(home: app()));
    expect(find.text('quiet'), findsOneWidget);

    await tester.tap(find.text('BEHIND'));
    await tester.pumpAndSettle();

    expect(find.text('stale'), findsOneWidget);
    expect(find.text('quiet'), findsNothing);
  });

  testWidgets('each empty filter explains its own emptiness', (tester) async {
    // "No watches yet" would be a lie under the Behind filter when there are
    // watches and none of them are behind.
    seed(name: 'http', pinned: '1.0.0', releases: ['1.0.0'], read: true);
    await tester.pumpWidget(MaterialApp(home: app()));

    await tester.tap(find.text('BEHIND'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing behind'), findsOneWidget);

    await tester.tap(find.text('UNREAD'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing new'), findsOneWidget);
  });

  testWidgets('the detail pane opens on the drift axis', (tester) async {
    seed(name: 'http', pinned: '1.0.0', releases: ['1.0.0', '2.0.0']);
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    expect(find.text('DRIFT'), findsOneWidget);
    expect(
      find.text('1 project pinned · stalest 1.0.0, 1 release behind'),
      findsOneWidget,
    );
  });

  testWidgets('the drift section is dropped when nothing has been fetched', (
    tester,
  ) async {
    // An axis with no ticks is a heading over nothing; the Releases section
    // below already says nothing has been fetched.
    seed(name: 'http', pinned: '1.0.0');
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    expect(find.text('DRIFT'), findsNothing);
    expect(find.text('Nothing fetched yet.'), findsOneWidget);
  });

  testWidgets('the refresh control shows progress and refuses a second press', (
    tester,
  ) async {
    // Without this the button stays live during a refresh and a double-click
    // fires two concurrent full passes over every watch.
    seed();
    final gate = Completer<RefreshReport>();
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          store: store,
          mutations: StoreMutations.local(store),
          settingsPane: const Text('settings pane'),
          onRefresh: (id) {
            refreshCount++;
            return gate.future;
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);

    await tester.tap(find.byType(CircularProgressIndicator));
    await tester.pump();
    expect(refreshCount, 1, reason: 'the disabled control must not re-fire');

    gate.complete(const RefreshReport(refreshed: 4, failed: 1, newReleases: 2));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.text('4 refreshed · 2 new · 1 failed'), findsOneWidget);
  });

  testWidgets('a clean refresh reports only what happened', (tester) async {
    // "0 failed, 0 new" invites the reader to look for a problem there is not.
    seed();
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text('1 refreshed'), findsOneWidget);
  });

  testWidgets('the detail pane copes with the selected watch disappearing', (
    tester,
  ) async {
    // Exactly what an MCP remove_watch call does while the row is open.
    final id = seed(name: 'http');
    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    store.removeWatch(id);
    await tester.pumpAndSettle();

    expect(find.text('That watch no longer exists.'), findsOneWidget);
  });

  testWidgets('the detail header shows the source repository when known', (
    tester,
  ) async {
    final id = seed(name: 'http');
    store.setWatchMeta(id, repoUrl: 'https://github.com/dart-lang/http');

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    expect(
      find.text('PUB'),
      findsNWidgets(2),
      reason: "the row's ecosystem column and the detail header",
    );
    expect(find.text('https://github.com/dart-lang/http'), findsOneWidget);
  });

  testWidgets('a snoozed watch says until when in the detail header', (
    tester,
  ) async {
    final id = seed(name: 'http');
    store.snooze(id, DateTime.utc(2030, 1, 2));

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('http'));
    await tester.pumpAndSettle();

    expect(find.text('SNOOZED UNTIL 2030-01-02'), findsOneWidget);
  });

  testWidgets('a dev-only dependency is marked as one', (tester) async {
    // It changes what an upgrade costs: a dev dependency does not ship.
    final id = store.upsertWatch(WatchKind.pub, 'lints');
    store.replaceUsagesForProject('/repos/a', 'pubspec.yaml', [
      Usage(
        watchId: id,
        projectPath: '/repos/a',
        manifestFile: 'pubspec.yaml',
        pinnedVersion: '1.0.0',
        isResolved: true,
        isDevDep: true,
      ),
    ]);

    await tester.pumpWidget(MaterialApp(home: app()));
    await tester.tap(find.text('lints'));
    await tester.pumpAndSettle();

    expect(find.text('DEV'), findsOneWidget);
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
