import 'dart:io';

import 'package:deptracker/models.dart';
import 'package:deptracker/net.dart';
import 'package:deptracker/redact.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/scanner.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

Store _store() => Store.openInMemory();

/// pub.dev payload with the given versions and no GitHub repository, so
/// refresh takes the registry-only path.
String pubBody(List<String> versions) {
  final entries = versions
      .map((v) => '{"version": "$v", "published": "2024-01-01T00:00:00.000Z"}')
      .join(',');
  return '{"name":"http","latest":{"version":"${versions.last}"},'
      '"versions":[$entries]}';
}

Net pubNet(List<String> versions) =>
    Net(client: MockClient((_) async => http.Response(pubBody(versions), 200)));

void main() {
  setUp(clearSecrets);

  test(
    'first fetch marks everything at or below the pinned version read',
    () async {
      final s = _store();
      final id = s.upsertWatch(WatchKind.pub, 'http');
      s.replaceUsagesForProject('/a', 'pubspec.lock', [
        Usage(
          watchId: id,
          projectPath: '/a',
          manifestFile: 'pubspec.lock',
          pinnedVersion: '1.2.0',
          isResolved: true,
          isDevDep: false,
        ),
      ]);

      await refreshAll(s, pubNet(['1.1.0', '1.2.0', '1.3.0']));

      final unread = s
          .releasesFor(id)
          .where((r) => !r.read)
          .map((r) => r.version)
          .toList();
      expect(unread, ['1.3.0']);
    },
  );

  test('first fetch of a watch with no usage marks everything read', () async {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    await refreshAll(s, pubNet(['1.1.0', '1.2.0', '1.3.0']));
    expect(s.releasesFor(id).every((r) => r.read), isTrue);
  });

  test('a later refresh leaves genuinely new versions unread', () async {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    await refreshAll(s, pubNet(['1.1.0', '1.2.0']));
    expect(s.releasesFor(id).where((r) => !r.read), isEmpty);

    await refreshAll(s, pubNet(['1.1.0', '1.2.0', '1.3.0']));
    expect(s.releasesFor(id).where((r) => !r.read).map((r) => r.version), [
      '1.3.0',
    ]);
  });

  test('refresh records the high-water mark', () async {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    await refreshAll(s, pubNet(['1.1.0', '1.10.0', '1.9.0']));
    expect(s.watchById(id)!.lastSeenVersion, '1.10.0');
  });

  test('refresh stamps last_checked_at and clears a previous error', () async {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    s.setWatchMeta(id, lastError: 'stale failure');
    await refreshAll(s, pubNet(['1.0.0']));
    final w = s.watchById(id)!;
    expect(w.lastError, isNull);
    expect(w.lastCheckedAt, isNotNull);
  });

  test('one failing watch does not stop the others', () async {
    final s = _store();
    final good = s.upsertWatch(WatchKind.pub, 'http');
    final bad = s.upsertWatch(WatchKind.pub, 'nope');
    final net = Net(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/nope')) {
          return http.Response('no such package', 404);
        }
        return http.Response(pubBody(['1.0.0']), 200);
      }),
    );

    final report = await refreshAll(s, net);
    expect(report.refreshed, 1);
    expect(report.failed, 1);
    expect(s.watchById(bad)!.lastError, contains('404'));
    expect(s.releasesFor(good), isNotEmpty);
  });

  test('a failure message never contains a registered secret', () async {
    registerSecret('ghp_abcdefghijklmnop');
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    final net = Net(
      client: MockClient(
        (_) async => http.Response('token ghp_abcdefghijklmnop rejected', 500),
      ),
    );

    await refreshAll(s, net, token: 'ghp_abcdefghijklmnop');
    final error = s.watchById(id)!.lastError!;
    expect(error, isNot(contains('ghp_')));
    expect(error, contains('«redacted»'));
  });

  test('a FormatException from a malformed payload is redacted too, '
      'not just NetException', () async {
    // NetException redacts at construction; a FormatException raised while
    // decoding a registry payload does not, since dart:convert has no idea
    // secrets exist. This is the branch refreshAll's own redact() call
    // exists for.
    registerSecret('fake_secret_token_00000000');
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    final net = Net(
      client: MockClient(
        // Status 200 so Net returns normally and jsonDecode is what throws,
        // not NetException from a 4xx/5xx status.
        (_) async =>
            http.Response('not json at all fake_secret_token_00000000', 200),
      ),
    );

    await refreshAll(s, net);
    final error = s.watchById(id)!.lastError!;
    expect(error, isNot(contains('fake_secret_token_00000000')));
    expect(error, contains('«redacted»'));
  });

  test('a discovered repo url is persisted', () async {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    final net = Net(
      client: MockClient((req) async {
        if (req.url.host == 'pub.dev') {
          return http.Response(
            '{"name":"http","latest":{"version":"1.0.0"},"versions":['
            '{"version":"1.0.0","published":"2024-01-01T00:00:00.000Z",'
            '"pubspec":{"repository":"https://github.com/dart-lang/http"}}]}',
            200,
          );
        }
        return http.Response(
          '<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>',
          200,
        );
      }),
    );
    await refreshAll(s, net);
    expect(s.watchById(id)!.repoUrl, 'https://github.com/dart-lang/http');
  });

  test(
    'a second refresh performs no more requests than the first, because '
    'repo_url resolution rides for free on the registry call (M12)',
    () async {
      // M12 asked whether "a resolved repository URL is cached forever" is
      // actually kept. It is, but not through a separate cache to add: the
      // registry response (pub.dev/npm/crates.io/pypi) already carries
      // repository info, and that response is fetched unconditionally every
      // refresh anyway because it is also the only source of the version
      // list -- there is no separate "resolve the repo" request to skip.
      // store.setWatchMeta already never overwrites a stored repo_url with
      // null, and _fromRegistry only reports a changed repoUrl when it
      // actually differs from what is stored, so no redundant write
      // happens either. What's left is the GitHub notes fetch, which fires
      // once a slug is derivable regardless of whether the repo_url came
      // from this response or a prior one -- that's the already-known,
      // deliberately out-of-scope M12 amplifier, not a caching gap.
      final s = _store();
      final id = s.upsertWatch(WatchKind.npm, 'left-pad');
      var calls = 0;
      final net = Net(
        client: MockClient((req) async {
          calls++;
          if (req.url.host == 'registry.npmjs.org') {
            return http.Response(
              '{"versions":{"1.0.0":{}},'
              '"time":{"1.0.0":"2020-01-01T00:00:00Z"},'
              '"repository":{"url":"https://github.com/foo/bar"}}',
              200,
            );
          }
          return http.Response(
            '<feed xmlns="http://www.w3.org/2005/Atom"></feed>',
            200,
          );
        }),
      );

      await refreshAll(s, net);
      final firstRefreshCalls = calls;
      expect(s.watchById(id)!.repoUrl, 'https://github.com/foo/bar');

      calls = 0;
      await refreshAll(s, net);
      final secondRefreshCalls = calls;

      expect(secondRefreshCalls, firstRefreshCalls);
      expect(s.watchById(id)!.repoUrl, 'https://github.com/foo/bar');
    },
  );

  test(
    'newReleases counts genuinely new rows via insertReleases\' return '
    'value, matching what a before/after releasesFor diff would report',
    () async {
      final s = _store();
      s.upsertWatch(WatchKind.pub, 'http');

      final firstReport = await refreshAll(s, pubNet(['1.1.0', '1.2.0']));
      expect(firstReport.newReleases, 2);

      // Re-fetching the same two plus one genuinely new version must
      // report exactly 1 new release, not 3 (the whole table) and not 0.
      final secondReport = await refreshAll(
        s,
        pubNet(['1.1.0', '1.2.0', '1.3.0']),
      );
      expect(secondReport.newReleases, 1);
    },
  );

  test('onlyWatchId refreshes a single watch', () async {
    final s = _store();
    final a = s.upsertWatch(WatchKind.pub, 'http');
    s.upsertWatch(WatchKind.pub, 'provider');
    final report = await refreshAll(s, pubNet(['1.0.0']), onlyWatchId: a);
    expect(report.refreshed, 1);
  });

  test('onProgress reports done and total', () async {
    final s = _store();
    s.upsertWatch(WatchKind.pub, 'http');
    s.upsertWatch(WatchKind.pub, 'provider');
    final seen = <String>[];
    await refreshAll(
      s,
      pubNet(['1.0.0']),
      onProgress: (d, t) => seen.add('$d/$t'),
    );
    expect(seen, ['1/2', '2/2']);
  });

  test(
    'a rate-limited github lookup rethrows rather than being swallowed',
    () async {
      final s = _store();
      s.upsertWatch(WatchKind.pub, 'http');
      final net = Net(
        client: MockClient((req) async {
          if (req.url.host == 'pub.dev') {
            return http.Response(
              '{"name":"http","latest":{"version":"1.0.0"},"versions":['
              '{"version":"1.0.0","published":"2024-01-01T00:00:00.000Z",'
              '"pubspec":{"repository":"https://github.com/dart-lang/http"}}]}',
              200,
            );
          }
          return http.Response('rate limited', 429);
        }),
      );

      final report = await refreshAll(s, net);
      expect(report.failed, 1);
      expect(report.refreshed, 0);
    },
  );

  test('a rate limit stops the refresh and leaves the rest stale, not '
      'errored (I5)', () async {
    final s = _store();
    final a = s.upsertWatch(WatchKind.pub, 'aaa');
    final b = s.upsertWatch(WatchKind.pub, 'bbb');
    final c = s.upsertWatch(WatchKind.pub, 'ccc');
    var calls = 0;
    final net = Net(
      client: MockClient((req) async {
        calls++;
        if (req.url.path.endsWith('/aaa')) {
          return http.Response(pubBody(['1.0.0']), 200);
        }
        return http.Response('rate limited', 429);
      }),
    );

    final report = await refreshAll(s, net);

    expect(report.rateLimited, isTrue);
    expect(report.refreshed, 1);
    // Exactly two requests: the watch that succeeded and the one that hit
    // the rate limit. Nothing further is issued once that happens.
    expect(calls, 2);
    expect(s.watchById(a)!.lastError, isNull);
    expect(s.watchById(b)!.lastError, contains('429'));
    expect(s.watchById(c)!.lastError, contains('rate limit'));
  });

  test('a rate limit still returns a truthful report when the stale-marking '
      'write itself fails', () async {
    // Forces store.markUnattemptedStale to throw without touching store.dart
    // or subclassing Store (its constructor is private to store.dart): close
    // the store's connection from onProgress, which refreshAll calls
    // after the per-watch error is already recorded but before it reaches
    // the batched markUnattemptedStale write. Store.close() is public, and
    // sqlite3 throws a StateError ("database has already been closed")
    // for any statement executed afterwards, which is exactly the kind of
    // failure (a closed store) the finding calls out.
    //
    // This test's ordering depends on refresh.dart's exact call sequence:
    // the `done++`/`onProgress?.call(done, targets.length)` pair right
    // after the rate-limit branch is entered (currently lines 136-137 of
    // lib/refresh.dart) fires *before* the `store.markUnattemptedStale(...)`
    // call below it (currently around line 149). If a future refactor
    // reorders those two so onProgress fires after the stale-marking write,
    // closing the store from onProgress here would no longer land mid-loop
    // and this test would silently stop testing what it claims to.
    final s = _store();
    s.upsertWatch(WatchKind.pub, 'aaa');
    s.upsertWatch(WatchKind.pub, 'bbb');
    // A third, untouched watch so markUnattemptedStale's skip(i + 1) list is
    // non-empty (it no-ops on an empty list, which would never exercise
    // the write we are trying to break).
    s.upsertWatch(WatchKind.pub, 'ccc');
    final net = Net(
      client: MockClient((req) async {
        if (req.url.path.endsWith('/aaa')) {
          return http.Response(pubBody(['1.0.0']), 200);
        }
        return http.Response('rate limited', 429);
      }),
    );

    final report = await refreshAll(
      s,
      net,
      // Fires right after 'bbb' (the rate-limited watch) is processed —
      // after its own last_error write already succeeded, but before
      // refreshAll reaches the batched markUnattemptedStale call for 'ccc'.
      onProgress: (done, total) {
        if (done == 2) s.close();
      },
    );

    expect(report.rateLimited, isTrue);
    expect(report.staleMarkingFailed, isTrue);
    expect(report.refreshed, 1);
    expect(report.failed, 1);
  });

  group('applyFirstFetchBaseline', () {
    List<Release> rel(List<String> vs) =>
        vs.map((v) => Release(watchId: 1, version: v)).toList();

    test('marks at-or-below the baseline read', () {
      final out = applyFirstFetchBaseline(
        rel(['1.0.0', '2.0.0', '3.0.0']),
        '2.0.0',
      );
      expect(out.where((r) => r.read).map((r) => r.version), [
        '1.0.0',
        '2.0.0',
      ]);
    });

    test('with no baseline everything is read, so a new watch is quiet', () {
      final out = applyFirstFetchBaseline(rel(['1.0.0', '2.0.0']), null);
      expect(out.every((r) => r.read), isTrue);
    });

    test('handles a v-prefixed baseline', () {
      final out = applyFirstFetchBaseline(rel(['v1.0.0', 'v2.0.0']), '1.0.0');
      expect(out.where((r) => !r.read).map((r) => r.version), ['v2.0.0']);
    });

    test('an empty list is not an error', () {
      expect(applyFirstFetchBaseline(const [], '1.0.0'), isEmpty);
    });
  });

  test(
    'a scanned == pin quiets its whole release history on first fetch (C1)',
    () async {
      // Seam regression for C1: manifest-on-disk -> parseManifest ->
      // upsertWatch -> applyFirstFetchBaseline. Before the fix, the stored
      // baseline was "==2.31.0" (operator attached), which compareVersions
      // treats as malformed and therefore sorts BELOW every clean release —
      // so every historical release compared greater than the baseline and
      // arrived unread, defeating the point of the baseline.
      final tmp = Directory.systemTemp.createTempSync('refresh_c1_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(
        p.join(tmp.path, 'requirements.txt'),
      ).writeAsStringSync('requests==2.31.0\n');

      final s = _store();
      await scanDirectory(s, tmp.path);
      final watch = s.watches().single;
      expect(watch.kind, WatchKind.pypi);

      final net = Net(
        client: MockClient(
          (_) async => http.Response(
            '{"info":{},"releases":{'
            '"2.28.0":[{"upload_time_iso_8601":"2022-01-01T00:00:00Z"}],'
            '"2.29.0":[{"upload_time_iso_8601":"2022-06-01T00:00:00Z"}],'
            '"2.30.0":[{"upload_time_iso_8601":"2023-01-01T00:00:00Z"}],'
            '"2.31.0":[{"upload_time_iso_8601":"2023-06-01T00:00:00Z"}]'
            '}}',
            200,
          ),
        ),
      );
      await refreshAll(s, net);
      expect(s.releasesFor(watch.id!).every((r) => r.read), isTrue);
    },
  );

  test('a scanned rc pin reports outdated once a newer release exists '
      '(C1 regression)', () async {
    // Seam regression for the C1 *fix*, not just the original bug:
    // _pep440Pin used to gate on _isExactVersion, which rejects PEP 440's
    // own pin spellings ("1.0rc1" has no hyphen before "rc"). That
    // silently reclassified the pin as isResolved: false, so it could
    // never be compared and could never report outdated — a false
    // negative replacing the original false positive. Manifest on disk ->
    // scan -> release inserted -> outdated verdict must go end-to-end.
    final tmp = Directory.systemTemp.createTempSync('refresh_c1_rc_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File(
      p.join(tmp.path, 'requirements.txt'),
    ).writeAsStringSync('requests==1.0rc1\n');

    final s = _store();
    await scanDirectory(s, tmp.path);
    final watch = s.watches().single;
    expect(watch.kind, WatchKind.pypi);

    final net = Net(
      client: MockClient(
        (_) async => http.Response(
          '{"info":{},"releases":{'
          '"1.0rc1":[{"upload_time_iso_8601":"2022-01-01T00:00:00Z"}],'
          '"2.0.0":[{"upload_time_iso_8601":"2023-06-01T00:00:00Z"}]'
          '}}',
          200,
        ),
      ),
    );
    await refreshAll(s, net);

    expect(
      s.watches(filter: WatchFilter.outdated).map((w) => w.id),
      contains(watch.id),
    );
  });

  test('highestResolvedUsage ignores unresolved ranges', () {
    final s = _store();
    final id = s.upsertWatch(WatchKind.pub, 'http');
    s.replaceUsagesForProject('/a', 'pubspec.yaml', [
      Usage(
        watchId: id,
        projectPath: '/a',
        manifestFile: 'pubspec.yaml',
        pinnedVersion: '^9.0.0',
        isResolved: false,
        isDevDep: false,
      ),
    ]);
    s.replaceUsagesForProject('/b', 'pubspec.lock', [
      Usage(
        watchId: id,
        projectPath: '/b',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '1.2.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    expect(highestResolvedUsage(s, id), '1.2.0');
  });
}
