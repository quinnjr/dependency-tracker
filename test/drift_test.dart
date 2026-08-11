import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/store.dart';
import 'package:deptracker/ui/drift_axis.dart';
import 'package:deptracker/ui/theme.dart';

late Store store;

/// One watch, pinned at [pins] across one project each, with [releases]
/// fetched. Each pin gets its own project path so they land as separate usage
/// rows rather than replacing each other.
int seed({
  String name = 'http',
  List<String> pins = const [],
  List<String> ranges = const [],
  List<String> releases = const [],
}) {
  final id = store.upsertWatch(WatchKind.pub, name);
  var n = 0;
  for (final p in pins) {
    final path = '/repos/$name-p${n++}';
    store.replaceUsagesForProject(path, 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: path,
        manifestFile: 'pubspec.lock',
        pinnedVersion: p,
        isResolved: true,
        isDevDep: false,
      ),
    ]);
  }
  for (final r in ranges) {
    final path = '/repos/$name-r${n++}';
    store.replaceUsagesForProject(path, 'pubspec.yaml', [
      Usage(
        watchId: id,
        projectPath: path,
        manifestFile: 'pubspec.yaml',
        pinnedVersion: r,
        isResolved: false,
        isDevDep: false,
      ),
    ]);
  }
  store.insertReleases(id, [
    for (final v in releases) Release(watchId: id, version: v),
  ]);
  return id;
}

void main() {
  setUp(() => store = Store.openInMemory());
  tearDown(() => store.close());

  group('Store.driftFor', () {
    test('has no entry for a watch with nothing fetched yet', () {
      // The distinction matters: "no releases known" must not be reported as
      // "zero drift", or a watch that has never been checked looks identical
      // to one that is genuinely up to date.
      final id = seed(pins: ['1.0.0']);
      expect(store.driftFor([id]), isEmpty);
    });

    test('has no entry for an id that does not exist', () {
      expect(store.driftFor([9999]), isEmpty);
    });

    test('returns nothing for an empty id list without querying', () {
      expect(store.driftFor(const []), isEmpty);
    });

    test('reports the pin spread across projects', () {
      final id = seed(
        pins: ['1.0.0', '1.2.0', '1.2.0'],
        releases: ['1.0.0', '1.1.0', '1.2.0'],
      );
      final d = store.driftFor([id])[id]!;
      expect(d.pinnedProjects, 3);
      expect(d.lowestPin, '1.0.0');
      expect(d.highestPin, '1.2.0');
      expect(d.newestRelease, '1.2.0');
      expect(d.isSplit, isTrue);
    });

    test('is not split when every project agrees', () {
      final id = seed(pins: ['1.2.0', '1.2.0'], releases: ['1.2.0']);
      final d = store.driftFor([id])[id]!;
      expect(d.isSplit, isFalse);
      expect(d.isCurrent, isTrue);
      expect(d.behindBy, 0);
    });

    test('measures drift from the stalest pin, not the newest', () {
      // One project already on 2.0.0 must not mask five still on 1.0.0.
      final id = seed(
        pins: ['1.0.0', '2.0.0'],
        releases: ['1.0.0', '1.5.0', '2.0.0'],
      );
      final d = store.driftFor([id])[id]!;
      expect(d.behindBy, 2, reason: '1.5.0 and 2.0.0 are newer than 1.0.0');
      expect(d.isCurrent, isFalse);
    });

    test('ignores ranges when measuring drift', () {
      // A range names no single version, so treating it as a pin would invent
      // a position it does not have.
      final id = seed(ranges: ['^1.0.0'], releases: ['1.0.0', '2.0.0']);
      final d = store.driftFor([id])[id]!;
      expect(d.pinnedProjects, 0);
      expect(d.lowestPin, isNull);
      expect(d.highestPin, isNull);
      expect(d.behindBy, 0);
      expect(d.isCurrent, isFalse, reason: 'nothing is known, so not current');
      expect(d.isSplit, isFalse);
      expect(d.newestRelease, '2.0.0');
    });

    test('orders versions structurally rather than as strings', () {
      // '10.0.0' sorts before '9.0.0' lexically. If the projection sorted as
      // text it would report the newest release as 9.0.0 and call a repo on
      // 10.0.0 behind.
      final id = seed(pins: ['9.0.0'], releases: ['9.0.0', '10.0.0']);
      final d = store.driftFor([id])[id]!;
      expect(d.newestRelease, '10.0.0');
      expect(d.behindBy, 1);
    });

    test('keys results by the right watch across many watches', () {
      final behind = seed(
        name: 'behind',
        pins: ['1.0.0'],
        releases: ['1.0.0', '2.0.0'],
      );
      final current = seed(
        name: 'current',
        pins: ['3.0.0'],
        releases: ['3.0.0'],
      );
      final unfetched = seed(name: 'unfetched', pins: ['1.0.0']);

      final all = store.driftFor([behind, current, unfetched]);
      expect(all[behind]!.behindBy, 1);
      expect(all[current]!.behindBy, 0);
      expect(all.containsKey(unfetched), isFalse);
    });
  });

  group('DriftAxis', () {
    Future<void> pumpAxis(
      WidgetTester tester, {
      required List<String> releases,
      List<String> pins = const [],
      int ranges = 0,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: DriftAxis(
            releaseVersions: releases,
            resolvedPins: pins,
            unresolvedPinCount: ranges,
          ),
        ),
      ),
    );

    testWidgets('labels both ends of the axis', (tester) async {
      await pumpAxis(
        tester,
        releases: ['2.0.0', '1.0.0', '1.5.0'],
        pins: ['1.0.0'],
      );
      expect(find.text('1.0.0'), findsOneWidget);
      expect(find.text('2.0.0'), findsOneWidget);
    });

    testWidgets('names the stalest pin and how far behind it is', (
      tester,
    ) async {
      await pumpAxis(
        tester,
        releases: ['1.0.0', '1.5.0', '2.0.0'],
        pins: ['1.0.0', '2.0.0'],
      );
      expect(
        find.text('2 projects pinned · stalest 1.0.0, 2 releases behind'),
        findsOneWidget,
      );
    });

    testWidgets('says so when every project is on the newest release', (
      tester,
    ) async {
      await pumpAxis(tester, releases: ['1.0.0', '2.0.0'], pins: ['2.0.0']);
      expect(
        find.text('1 project pinned · on the newest release'),
        findsOneWidget,
      );
    });

    testWidgets('says when no project pins a version', (tester) async {
      await pumpAxis(tester, releases: ['1.0.0'], ranges: 2);
      expect(
        find.text('no pinned version in your projects · 2 ranges unplotted'),
        findsOneWidget,
      );
    });

    testWidgets('counts a pin the registry no longer lists as off-axis', (
      tester,
    ) async {
      // A yanked version, or one from a private mirror, has no rank on the
      // axis. Dropping it silently would understate how many projects use the
      // package.
      await pumpAxis(
        tester,
        releases: ['2.0.0', '3.0.0'],
        pins: ['2.0.0', '1.9.9'],
      );
      expect(find.textContaining('1 pin off-axis'), findsOneWidget);
      expect(find.textContaining('1 project pinned'), findsOneWidget);
    });

    testWidgets('renders a single-release axis without dividing by zero', (
      tester,
    ) async {
      await pumpAxis(tester, releases: ['1.0.0'], pins: ['1.0.0']);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('on the newest release'), findsOneWidget);
    });

    testWidgets('renders nothing when there are no releases', (tester) async {
      await pumpAxis(tester, releases: const []);
      expect(tester.getSize(find.byType(DriftAxis)), Size.zero);
    });

    testWidgets('carries a spoken summary, since the ruler itself is painted', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAxis(
        tester,
        releases: ['1.0.0', '2.0.0'],
        pins: ['1.0.0', '1.0.0'],
      );
      expect(
        find.bySemanticsLabel(
          '2 releases known, newest 2.0.0. 2 projects pinned at 1.0.0. '
          '1 release behind the stalest pin.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('spoken summary reports a spread and unplotted ranges', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpAxis(
        tester,
        releases: ['1.0.0', '2.0.0', '3.0.0'],
        pins: ['1.0.0', '2.0.0', '9.9.9'],
        ranges: 1,
      );
      expect(
        find.bySemanticsLabel(
          '3 releases known, newest 3.0.0. 2 projects pinned between 1.0.0 and '
          '2.0.0. 2 releases behind the stalest pin. 1 pin not among known '
          'releases. 1 project uses a range.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('spoken summary says when nothing is pinned', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAxis(tester, releases: ['1.0.0']);
      expect(
        find.bySemanticsLabel(
          '1 release known, newest 1.0.0. no project pins a specific version.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
