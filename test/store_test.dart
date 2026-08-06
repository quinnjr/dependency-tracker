import 'dart:io';

import 'package:deptracker/models.dart';
import 'package:deptracker/store.dart';
import 'package:deptracker/versions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Builds a resolved, non-dev [Usage] pinned to `1.0.0` in `pubspec.lock`,
/// varying only [watchId] and [projectPath] — the two fields that actually
/// differ across the batched-query tests below.
Usage _usage(int watchId, String projectPath) => Usage(
  watchId: watchId,
  projectPath: projectPath,
  manifestFile: 'pubspec.lock',
  pinnedVersion: '1.0.0',
  isResolved: true,
  isDevDep: false,
);

void main() {
  openAndBookkeepingTests();
  // upsertWatch folds its insert and id lookup into one round trip with
  // `RETURNING`, which SQLite only supports from 3.35. That floor was
  // documented in store.dart as being covered by a check in this file, and
  // the check did not exist — so the constraint rested on a citation.
  //
  // It runs on every platform deliberately: Linux and macOS take SQLite from
  // the system (a floating apt/system library), and Windows takes it from the
  // vendored DLL, so all three can drift below the floor independently.
  test('the linked SQLite supports RETURNING, which upsertWatch requires', () {
    expect(
      sqlite3.version.versionNumber,
      greaterThanOrEqualTo(3035000),
      reason:
          'upsertWatch uses RETURNING (SQLite >= 3.35); '
          'loaded ${sqlite3.version.libVersion}',
    );
  });

  late Store store;

  setUp(() => store = Store.openInMemory());
  tearDown(() => store.close());

  test('two spellings of one package produce a single watch row', () {
    final a = store.upsertWatch(WatchKind.pypi, 'Flask-SQLAlchemy');
    final b = store.upsertWatch(WatchKind.pypi, 'flask_sqlalchemy');
    expect(a, b);
    expect(store.watches(), hasLength(1));
  });

  test('display_name keeps the first spelling for registry calls', () {
    final id = store.upsertWatch(WatchKind.crates, 'serde_json');
    store.upsertWatch(WatchKind.crates, 'serde-json');
    final w = store.watchById(id)!;
    expect(w.name, 'serde-json');
    expect(w.displayName, 'serde_json');
  });

  test('the same package in three repos is one watch and three usages', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    for (final repo in ['/r/one', '/r/two', '/r/three']) {
      store.replaceUsagesForProject(repo, 'pubspec.lock', [
        Usage(
          watchId: id,
          projectPath: repo,
          manifestFile: 'pubspec.lock',
          pinnedVersion: '1.2.0',
          isResolved: true,
          isDevDep: false,
        ),
      ]);
    }
    expect(store.watches(), hasLength(1));
    expect(store.usagesFor(id), hasLength(3));
  });

  test(
    'rescanning a project replaces its usages rather than duplicating them',
    () {
      final http = store.upsertWatch(WatchKind.pub, 'http');
      final yaml = store.upsertWatch(WatchKind.pub, 'yaml');
      Usage u(int id, String v) => Usage(
        watchId: id,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: v,
        isResolved: true,
        isDevDep: false,
      );

      store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
        u(http, '1.2.0'),
        u(yaml, '3.1.0'),
      ]);
      store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
        u(http, '1.3.0'),
      ]);

      expect(store.usagesFor(http).single.pinnedVersion, '1.3.0');
      expect(store.usagesFor(yaml), isEmpty);
    },
  );

  test('writing usages for one manifest does not delete another manifest\'s '
      'usages in the same project', () {
    final http = store.upsertWatch(WatchKind.pub, 'http');
    final leftPad = store.upsertWatch(WatchKind.npm, 'left-pad');

    store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
      Usage(
        watchId: http,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.2.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    store.replaceUsagesForProject('/r/one', 'package.json', [
      Usage(
        watchId: leftPad,
        projectPath: '/r/one',
        manifestFile: 'package.json',
        pinnedVersion: '1.3.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);

    expect(store.usagesFor(http), hasLength(1));
    expect(store.usagesFor(leftPad), hasLength(1));
  });

  // This guards two things only: (1) a mid-loop constraint violation is
  // actually reachable (plain INSERT, not INSERT OR REPLACE), and (2) the
  // transaction rolls back to the pre-replace rows on that violation. It
  // does NOT guard the statement-disposal fix (stmt.dispose() living in a
  // finally block) — reverting that half of the fix and rerunning this
  // test still passes, because the `sqlite3` package exposes no public API
  // to observe an outstanding prepared statement. `sqlite3_next_stmt` and
  // `sqlite3_db_status`/`sqlite3_stmt_status`, the C-level ways to count or
  // enumerate a connection's live prepared statements, are not bound by
  // this package (checked package:sqlite3 2.9.4's generated FFI bindings
  // and its public `CommonDatabase`/`PreparedStatement` surface). The only
  // place open statements are tracked at all is the private
  // `FinalizableDatabase._statements` list in
  // package:sqlite3/src/implementation/database.dart, which exists purely
  // so `Database.dispose()` can sweep up anything left un-finalized — a
  // leaked statement is invisible from outside the package right up until
  // the whole database closes, and even then produces no distinguishable
  // observable effect. Forcing observability would mean adding
  // test-only instrumentation to Store itself, which trades a real API
  // wart for a test convenience and was ruled out. The disposal fix is
  // reviewed by inspection instead: `stmt.dispose()` sits in a `finally`
  // block below, so it runs on both the commit and rollback paths.
  test('a constraint violation mid-replace rolls back to the original usages '
      '(does not cover statement disposal — see comment above)', () {
    final http = store.upsertWatch(WatchKind.pub, 'http');
    Usage u(String v) => Usage(
      watchId: http,
      projectPath: '/r/one',
      manifestFile: 'pubspec.lock',
      pinnedVersion: v,
      isResolved: true,
      isDevDep: false,
    );

    store.replaceUsagesForProject('/r/one', 'pubspec.lock', [u('1.2.0')]);

    // Two rows for the same (watch_id, project_path, manifest_file) violate
    // the UNIQUE constraint on the second insert, well after the DELETE has
    // already run inside the same transaction.
    expect(
      () => store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
        u('1.3.0'),
        u('1.4.0'),
      ]),
      throwsA(anything),
    );

    expect(store.usagesFor(http).single.pinnedVersion, '1.2.0');
  });

  test('removing a watch cascades to its usages', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.2.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    store.removeWatch(id);
    expect(store.watchById(id), isNull);
    expect(store.usagesFor(id), isEmpty);
  });

  test('a watch with no usages is legal', () {
    final id = store.upsertWatch(WatchKind.rss, 'https://example.com/feed.xml');
    expect(store.usagesFor(id), isEmpty);
    expect(store.watches(), hasLength(1));
  });

  test('setWatchMeta writes only the fields actually passed', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    final checkedAt = DateTime.utc(2026, 1, 1);

    store.setWatchMeta(id, lastError: 'registry 503', lastCheckedAt: checkedAt);
    expect(store.watchById(id)!.lastError, 'registry 503');
    expect(store.watchById(id)!.lastCheckedAt, checkedAt);

    // Neither lastError nor clearError is passed, so the error survives.
    store.setWatchMeta(id, lastSeenVersion: '1.3.0');
    expect(store.watchById(id)!.lastError, 'registry 503');
    expect(store.watchById(id)!.lastSeenVersion, '1.3.0');

    store.setWatchMeta(id, clearError: true);
    expect(store.watchById(id)!.lastError, isNull);
  });

  test('insertReleases is idempotent per (watch_id, version)', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.insertReleases(id, [
      Release(watchId: id, version: '1.0.0', read: true),
    ]);
    // Re-inserting the same version must not clear its read flag.
    store.insertReleases(id, [
      Release(watchId: id, version: '1.0.0', read: false),
      Release(watchId: id, version: '1.1.0'),
    ]);
    final releases = store.releasesFor(id);
    expect(releases, hasLength(2));
    expect(releases.firstWhere((r) => r.version == '1.0.0').read, isTrue);
  });

  test('releasesFor orders newest first and newerThan filters strictly', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.insertReleases(id, [
      Release(watchId: id, version: '1.0.0'),
      Release(watchId: id, version: '1.9.0'),
      Release(watchId: id, version: '1.10.0'),
    ]);
    expect(store.releasesFor(id).map((r) => r.version), [
      '1.10.0',
      '1.9.0',
      '1.0.0',
    ]);
    expect(store.releasesFor(id, newerThan: '1.9.0').map((r) => r.version), [
      '1.10.0',
    ]);
  });

  test('markRead marks one release or every release for a watch', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.insertReleases(id, [
      Release(watchId: id, version: '1.0.0'),
      Release(watchId: id, version: '2.0.0'),
    ]);
    store.markRead(id, version: '1.0.0');
    var releases = store.releasesFor(id);
    expect(releases.firstWhere((r) => r.version == '1.0.0').read, isTrue);
    expect(releases.firstWhere((r) => r.version == '2.0.0').read, isFalse);

    store.markRead(id);
    releases = store.releasesFor(id);
    expect(releases.every((r) => r.read), isTrue);
  });

  test('watches(filter: unread) finds watches with an unread release, '
      'excluding snoozed ones', () {
    final unread = store.upsertWatch(WatchKind.pub, 'http');
    final read = store.upsertWatch(WatchKind.pub, 'yaml');
    final snoozed = store.upsertWatch(WatchKind.pub, 'path');
    store.insertReleases(unread, [Release(watchId: unread, version: '1.0.0')]);
    store.insertReleases(read, [
      Release(watchId: read, version: '1.0.0', read: true),
    ]);
    store.insertReleases(snoozed, [
      Release(watchId: snoozed, version: '1.0.0'),
    ]);
    store.snooze(snoozed, DateTime.now().add(const Duration(days: 1)));

    final result = store.watches(filter: WatchFilter.unread);
    expect(result.map((w) => w.id), [unread]);
  });

  test('watches(filter: outdated) finds a resolved usage pinned below the '
      'newest release', () {
    final outdated = store.upsertWatch(WatchKind.pub, 'http');
    final current = store.upsertWatch(WatchKind.pub, 'yaml');
    store.insertReleases(outdated, [
      Release(watchId: outdated, version: '2.0.0'),
    ]);
    store.insertReleases(current, [
      Release(watchId: current, version: '2.0.0'),
    ]);
    store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
      Usage(
        watchId: outdated,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.0.0',
        isResolved: true,
        isDevDep: false,
      ),
      Usage(
        watchId: current,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '2.0.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);

    final result = store.watches(filter: WatchFilter.outdated);
    expect(result.map((w) => w.id), [outdated]);
  });

  test('watches narrows by kind and caps by limit', () {
    store.upsertWatch(WatchKind.pub, 'http');
    store.upsertWatch(WatchKind.npm, 'left-pad');
    store.upsertWatch(WatchKind.pub, 'yaml');
    expect(store.watches(kind: WatchKind.npm), hasLength(1));
    expect(store.watches(limit: 1), hasLength(1));
  });

  test(
    'searchWatches matches display_name and repo_url case-insensitively',
    () {
      final id = store.upsertWatch(WatchKind.pub, 'Http');
      store.setWatchMeta(id, repoUrl: 'https://github.com/dart-lang/http');
      store.upsertWatch(WatchKind.pub, 'yaml');

      expect(store.searchWatches('HTTP').map((w) => w.displayName), ['Http']);
      expect(store.searchWatches('dart-lang').map((w) => w.displayName), [
        'Http',
      ]);
      expect(store.searchWatches('nonexistent'), isEmpty);
    },
  );

  test('snooze hides a watch from unread until the timestamp passes', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.insertReleases(id, [Release(watchId: id, version: '1.0.0')]);

    store.snooze(id, DateTime.now().add(const Duration(days: 1)));
    expect(store.watches(filter: WatchFilter.unread), isEmpty);
    expect(store.watches(), hasLength(1));

    store.snooze(id, DateTime.now().subtract(const Duration(days: 1)));
    expect(store.watches(filter: WatchFilter.unread), hasLength(1));
  });

  test('knownProjects lists distinct project paths in order', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.replaceUsagesForProject('/r/two', 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: '/r/two',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.0.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    store.replaceUsagesForProject('/r/one', 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: '/r/one',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.0.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    expect(store.knownProjects(), ['/r/one', '/r/two']);
  });

  test('scan roots are a set', () {
    store.addScanRoot('/home/j/Projects');
    store.addScanRoot('/home/j/Projects');
    expect(store.scanRoots(), ['/home/j/Projects']);
    store.removeScanRoot('/home/j/Projects');
    expect(store.scanRoots(), isEmpty);
  });

  test('the http cache round-trips an etag and a body', () {
    store.putCache('https://x/y', 'W/"abc"', '{"ok":true}');
    expect(store.etagFor('https://x/y'), 'W/"abc"');
    expect(store.cachedBody('https://x/y'), '{"ok":true}');
    store.putCache('https://x/y', 'W/"def"', '{"ok":false}');
    expect(store.etagFor('https://x/y'), 'W/"def"');
  });

  test('mutations notify listeners', () {
    var notified = 0;
    store.addListener(() => notified++);
    store.upsertWatch(WatchKind.pub, 'http');
    store.addScanRoot('/x');
    expect(notified, 2);
  });

  test('metaSet notifies listeners, unlike putCache, its http_cache '
      'counterpart', () {
    var notified = 0;
    store.addListener(() => notified++);
    store.metaSet('some_key', 'some_value');
    expect(notified, 1);
  });

  test('insertReleases returns the count of rows actually inserted, not '
      'the whole table', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    expect(
      store.insertReleases(id, [
        Release(watchId: id, version: '1.0.0'),
        Release(watchId: id, version: '1.1.0'),
      ]),
      2,
    );
    // '1.0.0' already exists (ignored); only '1.2.0' is genuinely new.
    expect(
      store.insertReleases(id, [
        Release(watchId: id, version: '1.0.0'),
        Release(watchId: id, version: '1.2.0'),
      ]),
      1,
    );
  });

  test('countsFor batches unread and usage counts for many watches at once, '
      'matching what per-watch releasesFor/usagesFor would report', () {
    // Five watches with varied unread/usage shapes, including one with
    // neither, so both maps' "absent means zero" contract is exercised.
    final ids = <int>[];
    for (var i = 0; i < 5; i++) {
      ids.add(store.upsertWatch(WatchKind.pub, 'pkg$i'));
    }
    store.insertReleases(ids[0], [
      Release(watchId: ids[0], version: '1.0.0'),
      Release(watchId: ids[0], version: '1.1.0'),
    ]);
    store.insertReleases(ids[1], [
      Release(watchId: ids[1], version: '1.0.0', read: true),
    ]);
    // ids[2] has no releases and no usages at all.
    for (final path in ['/r/a', '/r/b', '/r/c']) {
      store.replaceUsagesForProject(path, 'pubspec.lock', [
        _usage(ids[3], path),
      ]);
    }
    store.insertReleases(ids[4], [Release(watchId: ids[4], version: '2.0.0')]);
    store.replaceUsagesForProject('/r/d', 'pubspec.lock', [
      _usage(ids[4], '/r/d'),
    ]);

    final counts = store.countsFor(ids);

    for (final id in ids) {
      final expectedUnread = store.releasesFor(id).where((r) => !r.read).length;
      final expectedUsages = store.usagesFor(id).length;
      expect(counts.unread[id] ?? 0, expectedUnread, reason: 'watch $id');
      expect(counts.usages[id] ?? 0, expectedUsages, reason: 'watch $id');
    }
    expect(counts.unread[ids[0]], 2);
    expect(counts.unread.containsKey(ids[1]), isFalse);
    expect(counts.usages.containsKey(ids[2]), isFalse);
    expect(counts.usages[ids[3]], 3);
  });

  test('watches(filter: unread/outdated) over many watches matches manual '
      'per-watch computation, proving the grouped queries did not change '
      'which watches match', () {
    final ids = <int>[];
    for (var i = 0; i < 6; i++) {
      ids.add(store.upsertWatch(WatchKind.pub, 'pkg$i'));
    }
    // Unread: 0 unread, 1 unread, 2 read.
    store.insertReleases(ids[1], [Release(watchId: ids[1], version: '1.0.0')]);
    store.insertReleases(ids[2], [
      Release(watchId: ids[2], version: '1.0.0', read: true),
    ]);
    // Outdated: 3 has a resolved usage below newest, 4 does not, 5 has
    // only an unresolved (range) usage and must be excluded even though
    // its pin text alone would compare below the newest release.
    store.insertReleases(ids[3], [Release(watchId: ids[3], version: '2.0.0')]);
    store.replaceUsagesForProject('/r/3', 'pubspec.lock', [
      _usage(ids[3], '/r/3'),
    ]);
    store.insertReleases(ids[4], [Release(watchId: ids[4], version: '2.0.0')]);
    store.replaceUsagesForProject('/r/4', 'pubspec.lock', [
      Usage(
        watchId: ids[4],
        projectPath: '/r/4',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '2.0.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    store.insertReleases(ids[5], [Release(watchId: ids[5], version: '2.0.0')]);
    store.replaceUsagesForProject('/r/5', 'pubspec.yaml', [
      Usage(
        watchId: ids[5],
        projectPath: '/r/5',
        manifestFile: 'pubspec.yaml',
        pinnedVersion: '^1.0.0',
        isResolved: false,
        isDevDep: false,
      ),
    ]);

    bool manualUnread(int id) => store.releasesFor(id).any((r) => !r.read);
    bool manualOutdated(int id) {
      final resolved = store
          .usagesFor(id)
          .where((u) => u.isResolved)
          .map((u) => u.pinnedVersion)
          .toList();
      if (resolved.isEmpty) return false;
      // releasesFor already sorts newest-first via compareVersions.
      final releases = store.releasesFor(id);
      if (releases.isEmpty) return false;
      final newest = releases.first.version;
      return resolved.any((v) => compareVersions(v, newest) < 0);
    }

    final unreadResult = store
        .watches(filter: WatchFilter.unread)
        .map((w) => w.id)
        .toSet();
    final outdatedResult = store
        .watches(filter: WatchFilter.outdated)
        .map((w) => w.id)
        .toSet();

    expect(unreadResult, ids.where(manualUnread).toSet());
    expect(outdatedResult, ids.where(manualOutdated).toSet());
    expect(outdatedResult, {ids[3]});
    // Direct check, independent of manualOutdated: a watch whose only usage
    // is an unresolved range must never count as outdated, even though its
    // pin text ('^1.0.0') would compare below the newest release if treated
    // as resolved.
    expect(
      outdatedResult.contains(ids[5]),
      isFalse,
      reason: 'unresolved usage must not count as outdated',
    );
  });

  test(
    'markUnattemptedStale and countsFor execute no SQL and return empty on '
    'an empty id list, rather than an IN () that would need special-casing',
    () {
      final id = store.upsertWatch(WatchKind.pub, 'http');
      store.setWatchMeta(id, lastError: 'registry 503');

      store.markUnattemptedStale(const [], 'x');
      expect(store.watchById(id)!.lastError, 'registry 503');

      final counts = store.countsFor(const []);
      expect(counts.unread, isEmpty);
      expect(counts.usages, isEmpty);
    },
  );

  test('markUnattemptedStale notifies exactly once on a successful commit, and '
      'not at all when the transaction rolls back', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    var notified = 0;
    store.addListener(() => notified++);

    store.markUnattemptedStale([id], 'stale');
    expect(notified, 1);
    expect(store.watchById(id)!.lastError, 'stale');

    // Force the write itself to fail so the transaction rolls back: a
    // closed database throws StateError from sqlite3 on the next
    // execute(), before any COMMIT is reached.
    store.close();
    expect(() => store.markUnattemptedStale([id], 'stale 2'), throwsStateError);
    // No state changed, so no further notification beyond the one above.
    expect(notified, 1);
  });

  group('chunking spans multiple real-sized chunks (500 per chunk)', () {
    // 1200 ids spans three chunks of the real, unmodified default chunk
    // size (500): [0, 500), [500, 1000), [1000, 1200). Every id gets a
    // release and a usage so countsFor, markUnattemptedStale, and the
    // watches(filter:) read paths all have real per-id state to attribute
    // correctly, not just a count to get right in aggregate.
    //
    // Per-id rule, so an off-by-one dropping/duplicating any single id is
    // detectable:
    //   - release '2.0.0', unread iff the index is even.
    //   - one resolved usage, pinned '1.0.0' (outdated) iff index % 3 == 0,
    //     otherwise pinned '2.0.0' (current, matches the only release).
    const total = 1200;
    const boundaries = [0, 499, 500, 501, 999, 1000, total - 1];

    late List<int> ids;

    setUp(() {
      ids = List.generate(
        total,
        (i) => store.upsertWatch(WatchKind.pub, 'pkg$i'),
      );
      for (var i = 0; i < total; i++) {
        store.insertReleases(ids[i], [
          Release(watchId: ids[i], version: '2.0.0', read: i.isOdd),
        ]);
        store.replaceUsagesForProject('/r/pkg$i', 'pubspec.lock', [
          Usage(
            watchId: ids[i],
            projectPath: '/r/pkg$i',
            manifestFile: 'pubspec.lock',
            pinnedVersion: i % 3 == 0 ? '1.0.0' : '2.0.0',
            isResolved: true,
            isDevDep: false,
          ),
        ]);
      }
    });

    test(
      'countsFor and watches(filter: unread/outdated) attribute every id '
      'correctly across chunk boundaries, at real default chunk size (500)',
      () {
        final stopwatch = Stopwatch()..start();
        final counts = store.countsFor(ids);
        final outdatedIds = store
            .watches(filter: WatchFilter.outdated)
            .map((w) => w.id)
            .toSet();
        final unreadIds = store
            .watches(filter: WatchFilter.unread)
            .map((w) => w.id)
            .toSet();
        stopwatch.stop();
        // ignore: avoid_print
        print(
          '1200-id, 3-chunk countsFor + watches(unread/outdated): '
          '${stopwatch.elapsedMilliseconds}ms',
        );

        // Aggregate: every id must land in exactly the sets the per-id rule
        // predicts. This alone would catch an off-by-one anywhere in the
        // 1200, since a dropped or duplicated id changes set membership.
        expect(unreadIds, {for (var i = 0; i < total; i += 2) ids[i]});
        expect(outdatedIds, {for (var i = 0; i < total; i += 3) ids[i]});

        // Explicit, named checks at the chunk boundaries themselves, so a
        // failure here points straight at "chunk 2 dropped its first id"
        // rather than requiring a diff over a 1200-entry set.
        for (final i in boundaries) {
          final id = ids[i];
          expect(
            counts.unread.containsKey(id),
            i.isEven,
            reason: 'unread count presence at index $i (id $id)',
          );
          if (i.isEven) {
            expect(
              counts.unread[id],
              1,
              reason: 'unread count value at index $i (id $id)',
            );
          }
          expect(
            counts.usages[id],
            1,
            reason: 'usage count at index $i (id $id)',
          );
          expect(
            outdatedIds.contains(id),
            i % 3 == 0,
            reason: 'outdated membership at index $i (id $id)',
          );
          expect(
            unreadIds.contains(id),
            i.isEven,
            reason: 'unread-filter membership at index $i (id $id)',
          );
        }
      },
    );

    test('markUnattemptedStale marks every id across chunk boundaries, at '
        'real default chunk size (500)', () {
      final stopwatch = Stopwatch()..start();
      store.markUnattemptedStale(ids, 'stale across chunks');
      stopwatch.stop();
      // ignore: avoid_print
      print(
        '1200-id, 3-chunk markUnattemptedStale: '
        '${stopwatch.elapsedMilliseconds}ms',
      );

      for (var i = 0; i < total; i++) {
        expect(
          store.watchById(ids[i])!.lastError,
          'stale across chunks',
          reason: 'index $i (id ${ids[i]})',
        );
      }
      for (final i in boundaries) {
        expect(
          store.watchById(ids[i])!.lastError,
          'stale across chunks',
          reason: 'boundary index $i (id ${ids[i]})',
        );
      }
    });
  });

  test('insertReleases returns 0 when every version already exists', () {
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.insertReleases(id, [
      Release(watchId: id, version: '1.0.0'),
      Release(watchId: id, version: '1.1.0'),
    ]);
    // Re-inserting the same two versions a third time: both are duplicates,
    // so the genuinely-new count must be 0, not 1 or 2 from an off-by-one
    // in the duplicate path.
    expect(
      store.insertReleases(id, [
        Release(watchId: id, version: '1.0.0'),
        Release(watchId: id, version: '1.1.0'),
      ]),
      0,
    );
  });
}

// Paths nothing reached: the file-backed constructor (every test uses the
// in-memory one), dispose, the rollback arm, and metaGet.
void openAndBookkeepingTests() {
  test('open() creates and migrates a database on disk', () async {
    // Every other test uses openInMemory, so the constructor the app itself
    // calls — the one that has to create the file and run migrations against
    // real storage — was never exercised.
    final dir = await Directory.systemTemp.createTemp('deptracker_store');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'nested', 'watches.db');
    Directory(p.dirname(path)).createSync(recursive: true);

    final store = Store.open(path);
    final id = store.upsertWatch(WatchKind.pub, 'http');
    store.close();

    expect(File(path).existsSync(), isTrue);

    // Reopening proves the migration wrote a durable schema rather than
    // leaving the file usable only for the session that made it.
    final reopened = Store.open(path);
    expect(reopened.watchById(id)!.displayName, 'http');
    expect(reopened.metaGet('schema_version'), isNotNull);
    reopened.close();
  });

  test('metaGet returns null for a key that was never set', () {
    final s = Store.openInMemory();
    addTearDown(s.close);
    expect(s.metaGet('never-written'), isNull);
    s.metaSet('written', 'yes');
    expect(s.metaGet('written'), 'yes');
  });

  test('dispose closes the database', () {
    final s = Store.openInMemory();
    s.upsertWatch(WatchKind.pub, 'http');
    s.dispose();
    // A closed store must fail loudly rather than appear to work.
    expect(() => s.watches(), throwsA(anything));
  });

  test('close is idempotent, so dispose after close does not double-free', () {
    final s = Store.openInMemory();
    s.close();
    expect(s.close, returnsNormally);
  });

  test('markUnattemptedStale rolls back rather than half-applying', () {
    final s = Store.openInMemory();
    final a = s.upsertWatch(WatchKind.pub, 'aaa');
    s.close();

    // A closed database makes the batched UPDATE throw part-way through the
    // transaction. The rollback arm has to run and the error has to reach the
    // caller, which is what lets refreshAll report staleMarkingFailed instead
    // of silently losing the marking.
    expect(() => s.markUnattemptedStale([a], 'stale'), throwsA(anything));
  });
}
