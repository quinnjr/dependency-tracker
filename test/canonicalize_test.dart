import 'package:deptracker/canonicalize.dart';
import 'package:deptracker/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pypi follows PEP 503', () {
    expect(
      canonicalize(WatchKind.pypi, 'Flask-SQLAlchemy'),
      'flask-sqlalchemy',
    );
    expect(canonicalize(WatchKind.pypi, 'zope.interface'), 'zope-interface');
    expect(canonicalize(WatchKind.pypi, 'a__b'), 'a-b');
    expect(canonicalize(WatchKind.pypi, 'a-_.b'), 'a-b');
  });

  test('npm lowercases but preserves scope', () {
    expect(canonicalize(WatchKind.npm, '@Scope/Pkg'), '@scope/pkg');
    expect(canonicalize(WatchKind.npm, 'Left-Pad'), 'left-pad');
  });

  test('crates treats dash and underscore as the same identity', () {
    expect(
      canonicalize(WatchKind.crates, 'serde_json'),
      canonicalize(WatchKind.crates, 'serde-json'),
    );
    expect(canonicalize(WatchKind.crates, 'Serde_JSON'), 'serde-json');
  });

  test('go preserves case and trims a trailing slash', () {
    expect(canonicalize(WatchKind.go, 'GitHub.com/x/y'), 'GitHub.com/x/y');
    expect(canonicalize(WatchKind.go, 'github.com/x/y/'), 'github.com/x/y');
  });

  test('go does not collapse a major-version suffix into its base module', () {
    expect(
      canonicalize(WatchKind.go, 'example.com/mod'),
      isNot(canonicalize(WatchKind.go, 'example.com/mod/v3')),
    );
  });

  test('goProxyPath escapes uppercase letters for proxy.golang.org', () {
    expect(
      goProxyPath('github.com/BurntSushi/toml'),
      'github.com/!burnt!sushi/toml',
    );
    expect(goProxyPath('golang.org/x/net'), 'golang.org/x/net');
  });

  test('pub lowercases', () {
    expect(canonicalize(WatchKind.pub, 'Http'), 'http');
  });

  test('github canonicalizes to lowercase owner/repo', () {
    expect(
      canonicalize(WatchKind.github, 'https://github.com/Dart-Lang/Http'),
      'dart-lang/http',
    );
    expect(
      canonicalize(WatchKind.github, 'Dart-Lang/Http.git'),
      'dart-lang/http',
    );
  });

  test('github accepts bare owner/repo shorthand with no scheme', () {
    expect(canonicalize(WatchKind.github, 'Dart-Lang/Http'), 'dart-lang/http');
  });

  test('github falls back to the lowercased raw string for a single '
      'segment', () {
    expect(canonicalize(WatchKind.github, 'justowner'), 'justowner');
  });

  test('github is case-insensitive about the github.com host '
      '(regression: old parser treated a mixed-case host as the owner, '
      'dropping the real repo name)', () {
    expect(canonicalize(WatchKind.github, 'https://GitHub.com/A/B'), 'a/b');
  });

  test('github keeps distinct non-github repos distinct '
      '(regression: old parser collapsed every non-github URL to '
      'host/owner, merging unrelated repos)', () {
    final b = canonicalize(WatchKind.github, 'https://gitlab.com/a/b');
    final c = canonicalize(WatchKind.github, 'https://gitlab.com/a/c');
    expect(b, isNot(c));
  });

  test('github canonicalizes an empty string to itself', () {
    expect(canonicalize(WatchKind.github, ''), '');
  });

  test('github handles the ssh shorthand form', () {
    expect(
      canonicalize(WatchKind.github, 'git@github.com:Owner/Repo.git'),
      'owner/repo',
    );
  });

  test('github strips a /tree/... suffix', () {
    expect(
      canonicalize(WatchKind.github, 'https://github.com/a/b/tree/main/pkg'),
      'a/b',
    );
  });

  test('rss keys on the exact URL', () {
    expect(
      canonicalize(WatchKind.rss, 'https://Example.com/Feed.xml'),
      'https://example.com/Feed.xml',
    );
  });

  test('canonicalize is idempotent for every kind', () {
    for (final kind in WatchKind.values) {
      final once = canonicalize(kind, 'Some_Example.Name/v2');
      expect(canonicalize(kind, once), once, reason: 'kind=$kind');
    }
  });
}
