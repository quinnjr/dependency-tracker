import 'package:deptracker/mcp/tools.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/refresh.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';

late Store store;
late List<int?> refreshCalls;

List<ToolDef> tools() {
  refreshCalls = [];
  return buildTools(
    store,
    refresh: (watchId) async {
      refreshCalls.add(watchId);
      return const RefreshReport(refreshed: 1, failed: 0, newReleases: 2);
    },
  );
}

ToolDef tool(String name) => tools().firstWhere((t) => t.name == name);

Future<Object?> call(String name, [Map<String, Object?> args = const {}]) =>
    tool(name).handler(args);

int seedWatch({String name = 'http', String pinned = '1.2.0'}) {
  final id = store.upsertWatch(WatchKind.pub, name);
  store.replaceUsagesForProject('/a', 'pubspec.lock', [
    Usage(
      watchId: id,
      projectPath: '/a',
      manifestFile: 'pubspec.lock',
      pinnedVersion: pinned,
      isResolved: true,
      isDevDep: false,
    ),
  ]);
  return id;
}

void main() {
  validationRejectionTests();
  setUp(() {
    store = Store.openInMemory();
  });

  test('every tool has a name, description, and object schema', () {
    for (final t in tools()) {
      expect(t.name, isNotEmpty);
      expect(t.description, isNotEmpty, reason: t.name);
      expect(t.inputSchema['type'], 'object', reason: t.name);
    }
  });

  test('the tool set is exactly what the spec lists', () {
    expect(tools().map((t) => t.name).toSet(), {
      'list_watches',
      'get_watch',
      'get_release_notes',
      'search_watches',
      'add_watch',
      'add_rss_watch',
      'remove_watch',
      'mark_read',
      'snooze',
      'refresh_now',
    });
  });

  test('list_watches returns rows with usage counts', () async {
    seedWatch();
    final r = await call('list_watches') as List;
    expect(r, hasLength(1));
    final row = r.single as Map;
    expect(row['name'], 'http');
    expect(row['kind'], 'pub');
    expect(row['usage_count'], 1);
  });

  test('list_watches honours the filter', () async {
    final id = seedWatch();
    store.insertReleases(id, [Release(watchId: id, version: '1.3.0')]);
    expect(await call('list_watches', {'filter': 'unread'}), hasLength(1));
    store.markRead(id);
    expect(await call('list_watches', {'filter': 'unread'}), isEmpty);
  });

  test(
    'list_watches rejects an unknown filter rather than silently listing all',
    () async {
      await expectLater(
        call('list_watches', {'filter': 'weird'}),
        throwsArgumentError,
      );
    },
  );

  test('list_watches rejects an out-of-range limit with a clear error naming '
      'the parameter, rather than silently returning an empty list or '
      'throwing a raw RangeError', () async {
    seedWatch();
    await expectLater(
      call('list_watches', {'limit': 0}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('limit'),
        ),
      ),
    );
    await expectLater(
      call('list_watches', {'limit': -1}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('limit'),
        ),
      ),
    );
  });

  test('list_watches honours kind and limit', () async {
    seedWatch(name: 'http');
    seedWatch(name: 'provider');
    store.upsertWatch(WatchKind.npm, 'left-pad');
    expect(await call('list_watches', {'kind': 'pub'}), hasLength(2));
    expect(await call('list_watches', {'limit': 1}), hasLength(1));
  });

  test('list_watches accepts an integral double limit (M5)', () async {
    // jsonDecode hands back a double for any JSON number literal with a
    // decimal point, including a whole one like `2.0` — which is
    // perfectly valid input for an `integer`-typed schema field over the
    // wire. A raw `as int?` cast throws a Dart _TypeError on it instead
    // of producing a usable error; the coercion must accept it.
    seedWatch(name: 'http');
    seedWatch(name: 'provider');
    expect(await call('list_watches', {'limit': 1.0}), hasLength(1));
  });

  test(
    'list_watches rejects a non-integral limit with a clear error (M5)',
    () async {
      await expectLater(
        call('list_watches', {'limit': 1.5}),
        throwsArgumentError,
      );
    },
  );

  test(
    'get_watch shows every usage across projects — the dedupe view',
    () async {
      final id = store.upsertWatch(WatchKind.pub, 'http');
      for (final p in ['/a', '/b']) {
        store.replaceUsagesForProject(p, 'pubspec.lock', [
          Usage(
            watchId: id,
            projectPath: p,
            manifestFile: 'pubspec.lock',
            pinnedVersion: p == '/a' ? '1.2.0' : '1.1.0',
            isResolved: true,
            isDevDep: false,
          ),
        ]);
      }
      final r = await call('get_watch', {'id': id}) as Map;
      final usages = r['usages'] as List;
      expect(usages, hasLength(2));
      expect((usages.first as Map)['project_path'], '/a');
      expect((usages.first as Map)['pinned_version'], '1.2.0');
    },
  );

  test('get_watch accepts a name instead of an id', () async {
    seedWatch();
    final r = await call('get_watch', {'name': 'http'}) as Map;
    expect(r['name'], 'http');
  });

  test('get_watch on a missing watch is an error the model can read', () async {
    await expectLater(call('get_watch', {'id': 999}), throwsArgumentError);
  });

  test(
    'get_watch resolves every spelling add_watch treats as equivalent (I2)',
    () async {
      final added =
          await call('add_watch', {'kind': 'pypi', 'name': 'Flask_SQLAlchemy'})
              as Map;
      // PyPI folds '-_.' together and lowercases, so this is the same watch.
      final r = await call('get_watch', {'name': 'FLASK.SQLALCHEMY'}) as Map;
      expect(r['id'], added['id']);
    },
  );

  test('get_watch does not resolve a Go module path differing only in case '
      '(I2)', () async {
    await call('add_watch', {
      'kind': 'go',
      'name': 'github.com/BurntSushi/toml',
    });
    // Go module paths are case-sensitive identity; a lowercase spelling
    // must not resolve to the differently-cased watch.
    await expectLater(
      call('get_watch', {'name': 'github.com/burntsushi/toml'}),
      throwsArgumentError,
    );
  });

  test('get_release_notes returns notes newest first', () async {
    final id = seedWatch();
    store.insertReleases(id, [
      Release(watchId: id, version: '1.3.0', notesMd: 'newer'),
      Release(watchId: id, version: '1.2.5', notesMd: 'older'),
    ]);
    final r = await call('get_release_notes', {'id': id}) as List;
    expect(r.map((x) => (x as Map)['version']), ['1.3.0', '1.2.5']);
  });

  test('get_release_notes filters by newer_than', () async {
    final id = seedWatch();
    store.insertReleases(id, [
      Release(watchId: id, version: '1.3.0'),
      Release(watchId: id, version: '1.2.5'),
    ]);
    final r =
        await call('get_release_notes', {'id': id, 'newer_than': '1.2.5'})
            as List;
    expect(r.map((x) => (x as Map)['version']), ['1.3.0']);
  });

  test(
    'get_release_notes accepts an integral double id and limit (M5)',
    () async {
      final id = seedWatch();
      store.insertReleases(id, [
        Release(watchId: id, version: '1.3.0', notesMd: 'newer'),
        Release(watchId: id, version: '1.2.5', notesMd: 'older'),
      ]);
      final r =
          await call('get_release_notes', {'id': id.toDouble(), 'limit': 1.0})
              as List;
      expect(r, hasLength(1));
      expect((r.single as Map)['version'], '1.3.0');
    },
  );

  test(
    'get_release_notes rejects a non-integral limit with a clear error (M5)',
    () async {
      final id = seedWatch();
      await expectLater(
        call('get_release_notes', {'id': id, 'limit': 1.5}),
        throwsArgumentError,
      );
    },
  );

  test('get_release_notes rejects an out-of-range limit with a clear error '
      'naming the parameter, rather than silently returning an empty list '
      'or throwing a raw RangeError', () async {
    final id = seedWatch();
    store.insertReleases(id, [Release(watchId: id, version: '1.3.0')]);
    await expectLater(
      call('get_release_notes', {'id': id, 'limit': 0}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('limit'),
        ),
      ),
    );
    await expectLater(
      call('get_release_notes', {'id': id, 'limit': -1}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('limit'),
        ),
      ),
    );
  });

  test('the anyOf id-or-name requirement is enforced for every tool that '
      'advertises it (I2)', () async {
    const toolsRequiringWatchIdentity = [
      'get_watch',
      'get_release_notes',
      'remove_watch',
      'mark_read',
      'snooze',
    ];
    for (final name in toolsRequiringWatchIdentity) {
      final args = name == 'snooze'
          ? {'until': '2030-01-01T00:00:00Z'}
          : <String, Object?>{};
      await expectLater(
        call(name, args),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('id'), contains('name')),
          ),
        ),
        reason: name,
      );
    }
  });

  test('get_watch resolves by id when both id and name are supplied and '
      'agree exactly', () async {
    final id = seedWatch(name: 'http');
    final r = await call('get_watch', {'id': id, 'name': 'http'}) as Map;
    expect(r['id'], id);
  });

  test(
    'get_watch accepts id plus a differently-spelled name that '
    'canonicalizes to the same watch (crates.io folds `_` and `-` together)',
    () async {
      final added =
          await call('add_watch', {'kind': 'crates', 'name': 'serde-json'})
              as Map;
      final id = added['id'] as int;
      final r =
          await call('get_watch', {'id': id, 'name': 'serde_json'}) as Map;
      expect(r['id'], id);
    },
  );

  test('a watch is reachable by its own id and name even when another '
      'registry watches the same package name', () async {
    // Regression: the cross-check used to resolve `name` globally, and the
    // resolver answers with the first matching WatchKind in enum order. So
    // with `http` watched on both pub and npm it always answered "pub", and
    // the npm watch's own id paired with its own correct name was rejected as
    // referring to different watches. This is a multi-registry tracker —
    // `http`, `path`, `uuid`, `crypto` and `requests` collide across
    // ecosystems routinely — so every id-taking tool was unusable for them.
    final pubId = store.upsertWatch(WatchKind.pub, 'http');
    final npmId = store.upsertWatch(WatchKind.npm, 'http');
    expect(pubId, isNot(npmId));

    expect(
      (await call('get_watch', {'id': npmId, 'name': 'http'}) as Map)['id'],
      npmId,
    );
    expect(
      (await call('get_watch', {'id': pubId, 'name': 'http'}) as Map)['id'],
      pubId,
    );
  });

  test('get_watch rejects id and name that resolve to different watches, '
      'naming both rather than silently preferring id', () async {
    final id = seedWatch(name: 'http');
    seedWatch(name: 'provider');
    await expectLater(
      call('get_watch', {'id': id, 'name': 'provider'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('$id'), contains('provider')),
        ),
      ),
    );
  });

  test('remove_watch rejects id and name that resolve to different watches '
      'and removes nothing', () async {
    final id = seedWatch(name: 'http');
    final otherId = seedWatch(name: 'provider');
    await expectLater(
      call('remove_watch', {'id': id, 'name': 'provider'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('$id'), contains('provider')),
        ),
      ),
    );
    expect(store.watchById(id), isNotNull);
    expect(store.watchById(otherId), isNotNull);
  });

  test('mark_read rejects id and name that resolve to different watches and '
      'leaves releases unread', () async {
    final id = seedWatch(name: 'http');
    seedWatch(name: 'provider');
    store.insertReleases(id, [Release(watchId: id, version: '1.3.0')]);
    await expectLater(
      call('mark_read', {'id': id, 'name': 'provider'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('$id'), contains('provider')),
        ),
      ),
    );
    expect(store.releasesFor(id).where((r) => !r.read), hasLength(1));
  });

  test('list_watches attributes each row\'s counts to that watch, not the '
      'next one in the list (regression: batched countsFor key/index '
      'mixup)', () async {
    // Three watches with distinct, non-equal usage/unread counts, plus
    // one watch with zero of both alongside the non-zero ones. Equal
    // counts across rows would make a next-watch misattribution
    // invisible, so every pair here differs.
    final aId = store.upsertWatch(WatchKind.pub, 'aaa_pkg');
    for (final p in ['/a1', '/a2', '/a3']) {
      store.replaceUsagesForProject(p, 'pubspec.lock', [
        Usage(
          watchId: aId,
          projectPath: p,
          manifestFile: 'pubspec.lock',
          pinnedVersion: '1.0.0',
          isResolved: true,
          isDevDep: false,
        ),
      ]);
    }
    store.insertReleases(aId, [
      Release(watchId: aId, version: '1.1.0'),
      Release(watchId: aId, version: '1.2.0'),
    ]);

    final bId = store.upsertWatch(WatchKind.pub, 'bbb_pkg');
    store.replaceUsagesForProject('/b1', 'pubspec.lock', [
      Usage(
        watchId: bId,
        projectPath: '/b1',
        manifestFile: 'pubspec.lock',
        pinnedVersion: '2.0.0',
        isResolved: true,
        isDevDep: false,
      ),
    ]);
    store.insertReleases(bId, [
      Release(watchId: bId, version: '2.1.0'),
      Release(watchId: bId, version: '2.2.0'),
      Release(watchId: bId, version: '2.3.0'),
      Release(watchId: bId, version: '2.4.0'),
    ]);

    // Zero usages, zero unread — exercises the `?? 0` absent-key path
    // rather than a populated-but-small count.
    final cId = store.upsertWatch(WatchKind.pub, 'ccc_pkg');

    Map<String, Object?> rowNamed(List rows, String name) =>
        rows.cast<Map<String, Object?>>().firstWhere((r) => r['name'] == name);

    final listed = await call('list_watches') as List;
    expect(listed, hasLength(3));
    final a = rowNamed(listed, 'aaa_pkg');
    expect(a['usage_count'], 3);
    expect(a['unread_count'], 2);
    final b = rowNamed(listed, 'bbb_pkg');
    expect(b['usage_count'], 1);
    expect(b['unread_count'], 4);
    final c = rowNamed(listed, 'ccc_pkg');
    expect(c['id'], cId);
    expect(c['usage_count'], 0);
    expect(c['unread_count'], 0);

    final searched = await call('search_watches', {'query': '_pkg'}) as List;
    expect(searched, hasLength(3));
    final aS = rowNamed(searched, 'aaa_pkg');
    expect(aS['usage_count'], 3);
    expect(aS['unread_count'], 2);
    final bS = rowNamed(searched, 'bbb_pkg');
    expect(bS['usage_count'], 1);
    expect(bS['unread_count'], 4);
    final cS = rowNamed(searched, 'ccc_pkg');
    expect(cS['usage_count'], 0);
    expect(cS['unread_count'], 0);
  });

  test('search_watches matches a substring', () async {
    seedWatch(name: 'shared_preferences');
    expect(await call('search_watches', {'query': 'prefer'}), hasLength(1));
    expect(await call('search_watches', {'query': 'zzz'}), isEmpty);
  });

  test('add_watch creates a watch and returns its id', () async {
    final r =
        await call('add_watch', {'kind': 'crates', 'name': 'serde_json'})
            as Map;
    expect(r['id'], isA<int>());
    expect(store.watches().single.displayName, 'serde_json');
  });

  test('add_watch is idempotent through canonicalization', () async {
    final a =
        await call('add_watch', {'kind': 'crates', 'name': 'serde_json'})
            as Map;
    final b =
        await call('add_watch', {'kind': 'crates', 'name': 'serde-json'})
            as Map;
    expect(b['id'], a['id']);
    expect(store.watches(), hasLength(1));
  });

  test('add_watch rejects an unknown kind', () async {
    await expectLater(
      call('add_watch', {'kind': 'maven', 'name': 'x'}),
      throwsArgumentError,
    );
  });

  test('add_watch refuses the rss kind, which has its own tool', () async {
    await expectLater(
      call('add_watch', {'kind': 'rss', 'name': 'https://x/f'}),
      throwsArgumentError,
    );
  });

  test('add_watch accepts an owner/repo slug for kind=github', () async {
    final r =
        await call('add_watch', {'kind': 'github', 'name': 'flutter/flutter'})
            as Map;
    expect(r['id'], isA<int>());
  });

  test('add_watch accepts a github.com URL for kind=github', () async {
    final r =
        await call('add_watch', {
              'kind': 'github',
              'name': 'https://github.com/a/b',
            })
            as Map;
    expect(r['id'], isA<int>());
  });

  test(
    'add_watch rejects a kind=github name that resolves to a non-github host',
    () async {
      await expectLater(
        call('add_watch', {'kind': 'github', 'name': 'https://gitlab.com/a/b'}),
        throwsArgumentError,
      );
    },
  );

  test(
    'add_watch rejects a kind=github name with no owner/repo shape',
    () async {
      await expectLater(
        call('add_watch', {'kind': 'github', 'name': 'justowner'}),
        throwsArgumentError,
      );
    },
  );

  test('add_rss_watch requires an http url', () async {
    final r =
        await call('add_rss_watch', {'url': 'https://example.com/f.xml'})
            as Map;
    expect(store.watchById(r['id'] as int)!.kind, WatchKind.rss);
    await expectLater(
      call('add_rss_watch', {'url': 'ftp://example.com/f.xml'}),
      throwsArgumentError,
    );
    await expectLater(
      call('add_rss_watch', {'url': 'not a url'}),
      throwsArgumentError,
    );
  });

  test('remove_watch deletes it', () async {
    final id = seedWatch();
    await call('remove_watch', {'id': id});
    expect(store.watches(), isEmpty);
  });

  test('mark_read marks all or one version', () async {
    final id = seedWatch();
    store.insertReleases(id, [
      Release(watchId: id, version: '1.3.0'),
      Release(watchId: id, version: '1.4.0'),
    ]);
    await call('mark_read', {'id': id, 'version': '1.3.0'});
    expect(store.releasesFor(id).where((r) => !r.read).map((r) => r.version), [
      '1.4.0',
    ]);
    await call('mark_read', {'id': id});
    expect(store.releasesFor(id).where((r) => !r.read), isEmpty);
  });

  test('mark_read accepts an integral double id (M5)', () async {
    final id = seedWatch();
    store.insertReleases(id, [Release(watchId: id, version: '1.3.0')]);
    await call('mark_read', {'id': id.toDouble()});
    expect(store.releasesFor(id).where((r) => !r.read), isEmpty);
  });

  test('mark_read rejects a non-integral id with a clear error (M5)', () async {
    final id = seedWatch();
    await expectLater(call('mark_read', {'id': id + 0.5}), throwsArgumentError);
  });

  test('snooze accepts an iso timestamp and rejects junk', () async {
    final id = seedWatch();
    await call('snooze', {'id': id, 'until': '2030-01-01T00:00:00Z'});
    expect(store.watchById(id)!.isSnoozed, isTrue);
    await expectLater(
      call('snooze', {'id': id, 'until': 'next tuesday'}),
      throwsArgumentError,
    );
  });

  test('refresh_now refreshes everything or one watch', () async {
    final id = seedWatch();
    final all = await call('refresh_now') as Map;
    expect(all['refreshed'], 1);
    expect(refreshCalls, [null]);
    await call('refresh_now', {'id': id});
    expect(refreshCalls, [id]);
  });

  test('refresh_now surfaces stale_marking_failed for both values', () async {
    // A normal refresh: the injected callback's default report has
    // staleMarkingFailed: false.
    final normalTools = buildTools(
      store,
      refresh: (watchId) async =>
          const RefreshReport(refreshed: 1, failed: 0, newReleases: 0),
    );
    final normal =
        await normalTools
                .firstWhere((t) => t.name == 'refresh_now')
                .handler(const {})
            as Map;
    expect(normal['stale_marking_failed'], false);

    // A rate-limited refresh where the best-effort stale-marking write
    // itself failed — constructed directly, no real database failure
    // needed.
    final failedTools = buildTools(
      store,
      refresh: (watchId) async => const RefreshReport(
        refreshed: 1,
        failed: 0,
        newReleases: 0,
        rateLimited: true,
        staleMarkingFailed: true,
      ),
    );
    final failed =
        await failedTools
                .firstWhere((t) => t.name == 'refresh_now')
                .handler(const {})
            as Map;
    expect(failed['stale_marking_failed'], true);
    expect(failed['rate_limited'], true);
  });

  test('refresh_now accepts an integral double id (M5)', () async {
    final id = seedWatch();
    await call('refresh_now', {'id': id.toDouble()});
    expect(refreshCalls, [id]);
  });

  test(
    'refresh_now rejects a non-integral id with a clear error (M5)',
    () async {
      await expectLater(call('refresh_now', {'id': 1.5}), throwsArgumentError);
    },
  );

  test('no tool result exposes a token field', () async {
    final id = seedWatch();
    store.insertReleases(id, [Release(watchId: id, version: '1.3.0')]);
    final encoded = [
      (await call('list_watches')).toString(),
      (await call('get_watch', {'id': id})).toString(),
      (await call('get_release_notes', {'id': id})).toString(),
    ].join();
    expect(encoded.toLowerCase(), isNot(contains('token')));
    expect(encoded.toLowerCase(), isNot(contains('bearer')));
  });
}

// Rejection arms an agent can actually hit by sending a wrong-typed or
// missing argument. Each must name the parameter, because the message is the
// only thing the calling agent can act on.
void validationRejectionTests() {
  test('a wrong-typed string parameter is rejected by name, not as a raw '
      'TypeError', () async {
    final id = seedWatch(name: 'http');
    // Every one of these is declared `"type": "string"` in the schema, so a
    // number is a client bug the server should describe rather than crash on.
    final cases = <String, Map<String, Object?>>{
      'list_watches': {'filter': 1},
      'get_release_notes': {'id': id, 'newer_than': 2},
      'mark_read': {'id': id, 'version': 3},
    };
    for (final entry in cases.entries) {
      await expectLater(
        call(entry.key, entry.value),
        throwsA(isA<ArgumentError>()),
        reason: entry.key,
      );
    }
  });

  test('an unknown kind is rejected by name', () async {
    await expectLater(
      call('list_watches', {'kind': 'maven'}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'message',
          contains('maven'),
        ),
      ),
    );
    await expectLater(
      call('add_watch', {'kind': 'maven', 'name': 'x'}),
      throwsA(isA<ArgumentError>()),
    );
    // A non-String kind takes a different arm from an unrecognised name, and
    // must still name the parameter rather than surface a cast failure.
    await expectLater(
      call('add_watch', {'kind': 1, 'name': 'x'}),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('search_watches requires a query', () async {
    await expectLater(
      call('search_watches', const {}),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('add_watch requires a name', () async {
    await expectLater(
      call('add_watch', {'kind': 'pub'}),
      throwsA(isA<ArgumentError>()),
    );
  });
}
