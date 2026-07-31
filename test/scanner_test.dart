import 'dart:io';

import 'package:deptracker/models.dart';
import 'package:deptracker/scanner.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Directory tmp;

Store _store() => Store.openInMemory();

void write(String relative, String content) {
  final f = File(p.join(tmp.path, relative));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('scanner_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('finds a project and records its usages', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
''');
    final s = _store();
    final r = await scanDirectory(s, tmp.path);
    expect(r.projectsScanned, 1);
    final watch = s.watches().single;
    expect(watch.displayName, 'http');
    expect(s.usagesFor(watch.id!).single.pinnedVersion, '^1.2.0');
  });

  test('prefers the lockfile when both are present', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
''');
    write('app/pubspec.lock', '''
packages:
  http:
    dependency: "direct main"
    description:
      name: http
      url: "https://pub.dev"
    source: hosted
    version: "1.2.2"
''');
    final s = _store();
    await scanDirectory(s, tmp.path);
    final u = s.usagesFor(s.watches().single.id!).single;
    expect(u.pinnedVersion, '1.2.2');
    expect(u.isResolved, isTrue);
    expect(u.manifestFile, 'pubspec.lock');
  });

  test('prefers Cargo.lock over Cargo.toml when both are present', () async {
    write('app/Cargo.toml', '''
[package]
name = "app"

[dependencies]
serde = "1.0"
''');
    write('app/Cargo.lock', '''
[[package]]
name = "serde"
version = "1.0.210"
''');
    final s = _store();
    await scanDirectory(s, tmp.path);
    final u = s.usagesFor(s.watches().single.id!).single;
    expect(u.pinnedVersion, '1.0.210');
    expect(u.isResolved, isTrue);
    expect(u.manifestFile, 'Cargo.lock');
  });

  test('prefers package-lock.json over package.json when both are present '
      '(I6)', () async {
    write('app/package.json', '''
{"dependencies":{"left-pad":"^1.3.0"}}
''');
    write('app/package-lock.json', '''
{
  "packages": {
    "": {"name": "app", "version": "1.0.0"},
    "node_modules/left-pad": {"version": "1.3.0"}
  }
}
''');
    final s = _store();
    await scanDirectory(s, tmp.path);
    final u = s.usagesFor(s.watches().single.id!).single;
    expect(u.pinnedVersion, '1.3.0');
    expect(u.isResolved, isTrue);
    expect(u.manifestFile, 'package-lock.json');
  });

  test(
    'prefers pnpm-lock.yaml over package.json when both are present (I6)',
    () async {
      write('app/package.json', '''
{"dependencies":{"left-pad":"^1.3.0"}}
''');
      write('app/pnpm-lock.yaml', '''
packages:
  /left-pad@1.3.0:
    resolution: {integrity: sha512-fake==}
''');
      final s = _store();
      await scanDirectory(s, tmp.path);
      final u = s.usagesFor(s.watches().single.id!).single;
      expect(u.pinnedVersion, '1.3.0');
      expect(u.isResolved, isTrue);
      expect(u.manifestFile, 'pnpm-lock.yaml');
    },
  );

  test('an npm package pinned via package-lock.json at the newest release is '
      'not outdated, unlike a bare package.json range (I6)', () async {
    // Seam regression: without a lockfile parser, package.json alone
    // yields only ranges, which the outdated filter never acts on — so
    // outdated was structurally dead for every npm project regardless of
    // how far behind it was.
    write('app/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
    write('app/package-lock.json', '''
{
  "packages": {
    "": {"name": "app", "version": "1.0.0"},
    "node_modules/left-pad": {"version": "1.3.0"}
  }
}
''');
    final s = _store();
    await scanDirectory(s, tmp.path);
    final watch = s.watches().single;
    s.insertReleases(watch.id!, [
      Release(watchId: watch.id!, version: '1.3.0'),
    ]);
    expect(s.watches(filter: WatchFilter.outdated), isEmpty);
  });

  test('dedupes one package across sibling projects', () async {
    for (final name in ['a', 'b', 'c']) {
      write('$name/pubspec.yaml', '''
name: $name
dependencies:
  http: ^1.2.0
''');
    }
    final s = _store();
    final r = await scanDirectory(s, tmp.path);
    expect(r.projectsScanned, 3);
    expect(s.watches().length, 1);
    expect(s.usagesFor(s.watches().single.id!).length, 3);
  });

  test('tracks two ecosystems in one project directory', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
''');
    write('app/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
    final s = _store();
    await scanDirectory(s, tmp.path);
    expect(s.watches().map((w) => w.kind).toSet(), {
      WatchKind.pub,
      WatchKind.npm,
    });
  });

  test('skips noise directories', () async {
    write(
      'app/node_modules/dep/package.json',
      '{"dependencies":{"nope":"^1.0.0"}}',
    );
    write('app/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
    final s = _store();
    await scanDirectory(s, tmp.path);
    expect(s.watches().map((w) => w.displayName), ['left-pad']);
  });

  test(
    'a bare venv directory does not mint watches for its bundled packages',
    () async {
      // A virtualenv's site-packages tree is full of installed packages that
      // ship their own pyproject.toml. Walking into it would produce watches
      // for the user's *transitive* dependencies as if the project itself
      // declared them directly — the same failure mode node_modules is
      // skipped for, just for the pypi ecosystem.
      write('app/pyproject.toml', '''
[project]
name = "app"
dependencies = ["requests==2.31.0"]
''');
      write('app/venv/lib/site-packages/somepkg/pyproject.toml', '''
[project]
name = "somepkg"
dependencies = ["phantom==9.9.9"]
''');
      final s = _store();
      // maxDepth large enough that the phantom file would be reachable were
      // venv/ not skipped by name.
      await scanDirectory(s, tmp.path, maxDepth: 8);
      expect(s.watches().map((w) => w.displayName), ['requests']);
    },
  );

  test('respects maxDepth', () async {
    write('a/b/c/d/pubspec.yaml', '''
name: deep
dependencies:
  http: ^1.2.0
''');
    final s = _store();
    final r = await scanDirectory(s, tmp.path, maxDepth: 2);
    expect(r.projectsScanned, 0);
    expect(s.watches(), isEmpty);
  });

  test('respects maxDepth exactly at the boundary', () async {
    // tmp.path itself is depth 1, so 'a' is depth 2 and 'a/b' is depth 3.
    // With maxDepth: 2, the depth-2 manifest must be found and the depth-3
    // one must not — a boundary this tight catches an off-by-one that a
    // wider gap (as in 'respects maxDepth' above) would miss.
    write('a/pubspec.yaml', '''
name: shallow
dependencies:
  http: ^1.2.0
''');
    write('a/b/pubspec.yaml', '''
name: deep
dependencies:
  provider: ^6.1.0
''');
    final s = _store();
    final r = await scanDirectory(s, tmp.path, maxDepth: 2);
    expect(r.projectsScanned, 1);
    expect(s.watches().map((w) => w.displayName), ['http']);
  });

  test(
    'rescanning after a version bump updates rather than duplicates',
    () async {
      write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
''');
      final s = _store();
      await scanDirectory(s, tmp.path);
      write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.3.0
''');
      await scanDirectory(s, tmp.path);
      final u = s.usagesFor(s.watches().single.id!);
      expect(u.length, 1);
      expect(u.single.pinnedVersion, '^1.3.0');
    },
  );

  test('a dependency removed from a manifest loses its usage', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
  provider: ^6.1.0
''');
    final s = _store();
    await scanDirectory(s, tmp.path);
    expect(s.watches().length, 2);
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
''');
    await scanDirectory(s, tmp.path);
    final provider = s.watches().firstWhere((w) => w.displayName == 'provider');
    expect(s.usagesFor(provider.id!), isEmpty);
  });

  test(
    'a malformed manifest is reported but does not abort the scan',
    () async {
      write('bad/package.json', 'not json');
      write('good/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
      final s = _store();
      final r = await scanDirectory(s, tmp.path);
      expect(r.errors, hasLength(1));
      expect(r.errors.single, contains('package.json'));
      expect(s.watches().map((w) => w.displayName), ['left-pad']);
    },
  );

  test(
    'an unreadable directory is reported but does not abort the scan',
    () async {
      write('good/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
      final secret = Directory(p.join(tmp.path, 'secret'))
        ..createSync(recursive: true);
      final chmod = Process.runSync('chmod', ['000', secret.path]);
      expect(chmod.exitCode, 0, reason: 'chmod must succeed to run this test');
      try {
        final s = _store();
        final r = await scanDirectory(s, tmp.path);
        expect(r.errors, hasLength(1));
        expect(r.errors.single, contains('secret'));
        expect(s.watches().map((w) => w.displayName), ['left-pad']);
      } finally {
        // Restore permissions so tearDown's recursive delete can list it.
        Process.runSync('chmod', ['755', secret.path]);
      }
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );

  test('scanRoots walks every configured root', () async {
    write('one/pubspec.yaml', 'name: one\ndependencies:\n  http: ^1.2.0\n');
    write('two/package.json', '{"dependencies":{"left-pad":"^1.3.0"}}');
    final s = _store();
    s.addScanRoot(p.join(tmp.path, 'one'));
    s.addScanRoot(p.join(tmp.path, 'two'));
    final r = await scanRoots(s);
    expect(r.projectsScanned, 2);
    expect(s.watches().length, 2);
  });

  test('a manifest with several dependencies notifies once, not once per '
      'dependency (M4)', () async {
    write('app/pubspec.yaml', '''
name: app
dependencies:
  http: ^1.2.0
  provider: ^6.1.0
  path: ^1.9.0
''');
    final s = _store();
    var notified = 0;
    s.addListener(() => notified++);
    await scanDirectory(s, tmp.path);
    expect(notified, 1);
  });

  test('a missing root is an error, not a crash', () async {
    final s = _store();
    s.addScanRoot(p.join(tmp.path, 'does-not-exist'));
    final r = await scanRoots(s);
    expect(r.errors, hasLength(1));
    expect(r.projectsScanned, 0);
  });

  test(
    'a requirements.txt == pin at the newest release is not outdated (C1)',
    () async {
      // Seam regression for C1: manifest-on-disk -> parseManifest ->
      // upsertWatch -> the `outdated` filter. Before the fix, `==2.31.0`
      // was stored with its operator attached, compareVersions treated it
      // as malformed, and a malformed parse always sorts below a clean one
      // — so a pin at the newest release still read as outdated.
      write('app/requirements.txt', 'requests==2.31.0\n');
      final s = _store();
      await scanDirectory(s, tmp.path);
      final watch = s.watches().single;
      s.insertReleases(watch.id!, [
        Release(watchId: watch.id!, version: '2.31.0'),
      ]);
      expect(s.watches(filter: WatchFilter.outdated), isEmpty);
    },
  );
}
