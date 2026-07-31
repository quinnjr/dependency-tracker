import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/manifests.dart';
import 'package:deptracker/models.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

ParsedDep dep(List<ParsedDep> deps, String name) =>
    deps.firstWhere((d) => d.name == name);

void main() {
  test('pubspec.lock yields resolved versions including transitives', () {
    final deps = parseManifest('pubspec.lock', fixture('pubspec.lock'));
    expect(dep(deps, 'http').version, '1.2.2');
    expect(dep(deps, 'http').isResolved, isTrue);
    expect(dep(deps, 'http').kind, WatchKind.pub);
    expect(dep(deps, 'meta').version, '1.15.0');
    expect(dep(deps, 'flutter_lints').isDevDep, isTrue);
  });

  test('pubspec.lock skips non-hosted sources', () {
    final deps = parseManifest('pubspec.lock', fixture('pubspec.lock'));
    expect(deps.map((d) => d.name), isNot(contains('my_local_thing')));
  });

  test('pubspec.yaml yields unresolved ranges and skips sdk deps', () {
    final deps = parseManifest('pubspec.yaml', fixture('pubspec.yaml'));
    expect(dep(deps, 'http').version, '^1.2.0');
    expect(dep(deps, 'http').isResolved, isFalse);
    expect(dep(deps, 'provider').version, '6.1.2');
    expect(dep(deps, 'flutter_lints').isDevDep, isTrue);
    expect(deps.map((d) => d.name), isNot(contains('flutter')));
    expect(deps.map((d) => d.name), isNot(contains('flutter_test')));
  });

  test('package.json separates dev deps and ignores peers', () {
    final deps = parseManifest('package.json', fixture('package.json'));
    expect(dep(deps, 'left-pad').version, '^1.3.0');
    expect(dep(deps, 'left-pad').kind, WatchKind.npm);
    expect(dep(deps, '@scope/pkg').version, '2.0.1');
    expect(dep(deps, 'typescript').isDevDep, isTrue);
    expect(deps.map((d) => d.name), isNot(contains('react')));
  });

  test('package.json treats a bare version as an exact pin, not a range', () {
    // node-semver: a bare "2.0.1" means "must match version exactly" — the
    // implicit-caret behavior only applies to what `npm install` writes when
    // the user omits an operator, not to how an already-bare string reads.
    final deps = parseManifest('package.json', fixture('package.json'));
    expect(dep(deps, '@scope/pkg').isResolved, isTrue);
    expect(dep(deps, 'left-pad').isResolved, isFalse);
    expect(dep(deps, 'typescript').isResolved, isFalse);
  });

  test('pubspec.yaml bare pin resolves a version combining prerelease and '
      'build metadata', () {
    // Full semver permits a prerelease AND build metadata together
    // ("1.2.3-beta+001"); the old _isExactVersion regex only permitted one
    // [-+] group and would wrongly demote this to unresolved — the same
    // class of mistake C1 made for PyPI.
    final deps = parseManifest(
      'pubspec.yaml',
      'dependencies:\n  http: 1.2.3-beta+001\n',
    );
    expect(dep(deps, 'http').isResolved, isTrue);
    expect(dep(deps, 'http').version, '1.2.3-beta+001');
  });

  test('pubspec.yaml range operators stay unresolved after the '
      'isWellFormedVersion gate', () {
    final deps = parseManifest(
      'pubspec.yaml',
      'dependencies:\n  a: ^1.2.0\n  b: ">=1.0.0 <2.0.0"\n',
    );
    expect(dep(deps, 'a').isResolved, isFalse);
    expect(dep(deps, 'b').isResolved, isFalse);
  });

  test('package.json skips file: and workspace: protocol dependencies', () {
    final deps = parseManifest('package.json', fixture('package.json'));
    expect(deps.map((d) => d.name), isNot(contains('local-thing')));
    expect(deps.map((d) => d.name), isNot(contains('shared-lib')));
  });

  test('package.json bare pin resolves a version combining prerelease and '
      'build metadata', () {
    // Same class of mistake as the pubspec.yaml case above: full semver
    // allows a prerelease and build metadata together, which the old
    // _isExactVersion regex's single-suffix-group pattern rejected.
    final deps = parseManifest(
      'package.json',
      '{"dependencies": {"foo": "1.2.3-beta+001"}}',
    );
    expect(dep(deps, 'foo').isResolved, isTrue);
    expect(dep(deps, 'foo').version, '1.2.3-beta+001');
  });

  test('package.json range operators stay unresolved after the '
      'isWellFormedVersion gate', () {
    final deps = parseManifest(
      'package.json',
      '{"dependencies": {"a": "^1.2.0", "b": ">=1.0.0 <2.0.0"}}',
    );
    expect(dep(deps, 'a').isResolved, isFalse);
    expect(dep(deps, 'b').isResolved, isFalse);
  });

  test('package-lock.json resolves every entry, including a nested transitive '
      'dependency (I6)', () {
    // Without a lockfile parser, `outdated` is structurally dead for npm:
    // package.json alone yields only ranges, and a range is never
    // compared. This is the seam that made outdated an empty list no
    // matter how far behind an npm project was.
    final deps = parseManifest(
      'package-lock.json',
      fixture('package-lock.json'),
    );
    expect(dep(deps, 'left-pad').version, '1.3.0');
    expect(dep(deps, 'left-pad').isResolved, isTrue);
    expect(dep(deps, '@scope/pkg').version, '2.0.1');
    expect(dep(deps, 'typescript').isDevDep, isTrue);
    // "bar" only appears nested under node_modules/foo/node_modules/bar —
    // a transitive dependency, not one the project itself declares.
    expect(dep(deps, 'bar').version, '1.5.0');
    expect(dep(deps, 'bar').isResolved, isTrue);
  });

  test('package-lock.json does not yield an entry for the project root', () {
    final deps = parseManifest(
      'package-lock.json',
      fixture('package-lock.json'),
    );
    expect(deps.map((d) => d.name), isNot(contains('example')));
  });

  test('pnpm-lock.yaml resolves every entry, including a transitive '
      'dependency (I6)', () {
    final deps = parseManifest('pnpm-lock.yaml', fixture('pnpm-lock.yaml'));
    expect(dep(deps, 'left-pad').version, '1.3.0');
    expect(dep(deps, 'left-pad').isResolved, isTrue);
    expect(dep(deps, '@scope/pkg').version, '2.0.1');
    expect(dep(deps, 'typescript').isDevDep, isTrue);
    // "bar" is only ever a transitive dependency of "foo" in this fixture.
    expect(dep(deps, 'bar').version, '1.5.0');
  });

  test('Cargo.toml handles both string and table dependency forms', () {
    final deps = parseManifest('Cargo.toml', fixture('Cargo.toml'));
    expect(dep(deps, 'serde').version, '1.0.210');
    expect(dep(deps, 'serde_json').version, '1.0.128');
    expect(dep(deps, 'tokio').version, '1.40');
    expect(dep(deps, 'criterion').isDevDep, isTrue);
    expect(dep(deps, 'serde').kind, WatchKind.crates);
  });

  test('Cargo.toml skips path dependencies', () {
    final deps = parseManifest('Cargo.toml', fixture('Cargo.toml'));
    expect(deps.map((d) => d.name), isNot(contains('local_thing')));
  });

  test('Cargo.toml treats bare and partial versions as caret ranges', () {
    // Cargo Book: "Leaving off the caret is a simplified equivalent syntax
    // to using caret requirements" — a bare "1.0.210" or "1.40" is a range,
    // not a pin. Only an explicit "=1.2.3" is exact.
    final deps = parseManifest('Cargo.toml', fixture('Cargo.toml'));
    expect(dep(deps, 'serde').isResolved, isFalse);
    expect(dep(deps, 'tokio').isResolved, isFalse);
    expect(dep(deps, 'exact_dep').version, '1.2.3');
    expect(dep(deps, 'exact_dep').isResolved, isTrue);
  });

  test('Cargo.toml = pin resolves a version combining prerelease and build '
      'metadata', () {
    // Full semver permits a prerelease AND build metadata together
    // ("1.2.3-alpha.1+build"); the old _isExactVersion regex only
    // permitted one [-+] group and would wrongly demote this to
    // unresolved — the same class of mistake C1 made for PyPI.
    final deps = parseManifest(
      'Cargo.toml',
      '[dependencies]\nfoo = "=1.2.3-alpha.1+build"\n',
    );
    expect(dep(deps, 'foo').isResolved, isTrue);
    expect(dep(deps, 'foo').version, '1.2.3-alpha.1+build');
  });

  test('Cargo.lock yields resolved versions', () {
    final deps = parseManifest('Cargo.lock', fixture('Cargo.lock'));
    expect(dep(deps, 'serde').version, '1.0.213');
    expect(dep(deps, 'serde').isResolved, isTrue);
  });

  test('go.mod yields resolved versions and marks indirect as dev', () {
    final deps = parseManifest('go.mod', fixture('go.mod'));
    expect(dep(deps, 'github.com/BurntSushi/toml').version, 'v1.4.0');
    expect(dep(deps, 'github.com/BurntSushi/toml').isResolved, isTrue);
    expect(dep(deps, 'golang.org/x/net').version, 'v0.30.0');
    expect(dep(deps, 'github.com/stretchr/testify').isDevDep, isTrue);
  });

  test('go.mod does not treat the module line as a dependency', () {
    final deps = parseManifest('go.mod', fixture('go.mod'));
    expect(deps.map((d) => d.name), isNot(contains('github.com/me/example')));
  });

  test('pyproject.toml splits name from specifier', () {
    final deps = parseManifest('pyproject.toml', fixture('pyproject.toml'));
    expect(dep(deps, 'requests').version, '>=2.32.0');
    expect(dep(deps, 'requests').isResolved, isFalse);
    expect(dep(deps, 'Zope.Interface').version, '7.1.1');
    expect(dep(deps, 'Zope.Interface').isResolved, isTrue);
    expect(dep(deps, 'pytest').isDevDep, isTrue);
    expect(dep(deps, 'requests').kind, WatchKind.pypi);
  });

  test('pyproject.toml stores an == pin as a bare version, not with the '
      'operator attached', () {
    // C1: compareVersions cannot parse a leading `==`, and a malformed
    // parse sorts below every clean release — so a stored "==7.1.1" makes
    // an up-to-date pin read as permanently outdated.
    final deps = parseManifest('pyproject.toml', fixture('pyproject.toml'));
    expect(dep(deps, 'Zope.Interface').version, isNot(contains('=')));
  });

  test('pyproject.toml === (arbitrary equality) is a resolved pin', () {
    final deps = parseManifest(
      'pyproject.toml',
      '[project]\ndependencies = ["widget===1.2.3+local"]\n',
    );
    expect(dep(deps, 'widget').version, '1.2.3+local');
    expect(dep(deps, 'widget').isResolved, isTrue);
  });

  test('pyproject.toml == wildcard is a range, not a pin', () {
    final deps = parseManifest(
      'pyproject.toml',
      '[project]\ndependencies = ["widget==1.2.*"]\n',
    );
    expect(dep(deps, 'widget').version, '==1.2.*');
    expect(dep(deps, 'widget').isResolved, isFalse);
  });

  test('pyproject.toml == pins parse for post/rc/beta/dev spellings, not just '
      'hyphenated ones', () {
    // Regression: _pep440Pin used to gate on a stricter regex than
    // versions.dart's own parser, so PEP 440's own pin spellings
    // (post-release, rc, beta, dev) were wrongly demoted to
    // "unresolved" — permanently un-comparable, never reported outdated.
    for (final spec in ['1.2.3.post1', '1.0rc1', '2.0b3', '1.0.dev1']) {
      final deps = parseManifest(
        'pyproject.toml',
        '[project]\ndependencies = ["widget==$spec"]\n',
      );
      expect(
        dep(deps, 'widget').isResolved,
        isTrue,
        reason: 'spec ==$spec should resolve',
      );
      expect(dep(deps, 'widget').version, spec);
    }
  });

  test(
    'pyproject.toml only treats the dev extras group as a dev dependency',
    () {
      // PEP 621 optional-dependencies groups are arbitrary named extras
      // ("docs", "test", "speedups", ...); only a group literally named "dev"
      // should be classified as a dev dependency.
      final deps = parseManifest('pyproject.toml', fixture('pyproject.toml'));
      expect(dep(deps, 'sphinx').isDevDep, isFalse);
    },
  );

  test('requirements.txt skips comments, blanks, and -r includes', () {
    final deps = parseManifest('requirements.txt', fixture('requirements.txt'));
    expect(
      deps.map((d) => d.name),
      containsAll(['requests', 'ruamel.yaml', 'flask__cors']),
    );
    expect(deps.length, 3);
    expect(dep(deps, 'requests').version, '2.32.3');
  });

  test('an exact pin in requirements.txt counts as resolved', () {
    final deps = parseManifest('requirements.txt', fixture('requirements.txt'));
    expect(dep(deps, 'requests').isResolved, isTrue);
    expect(dep(deps, 'ruamel.yaml').isResolved, isFalse);
  });

  test('requirements.txt == wildcard is a range, not a pin', () {
    final deps = parseManifest('requirements.txt', 'requests==2.31.*\n');
    expect(dep(deps, 'requests').version, '==2.31.*');
    expect(dep(deps, 'requests').isResolved, isFalse);
  });

  test('unknown filenames throw rather than returning empty', () {
    expect(
      () => parseManifest('Gemfile', 'source :rubygems'),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('malformed content throws FormatException', () {
    expect(
      () => parseManifest('package.json', 'not json at all'),
      throwsA(isA<FormatException>()),
    );
  });
}
