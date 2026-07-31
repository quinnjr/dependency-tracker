import 'package:deptracker/canonicalize.dart';
import 'package:deptracker/fetchers/registry.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Watch w(WatchKind kind, String displayName) => Watch(
  id: 1,
  kind: kind,
  name: displayName.toLowerCase(),
  displayName: displayName,
);

Net netReturning(String body, {void Function(Uri)? spy}) => Net(
  client: MockClient((req) async {
    spy?.call(req.url);
    return http.Response(body, 200);
  }),
);

void main() {
  group('url construction', () {
    test('escapes an npm scope', () {
      expect(
        registryUrl(WatchKind.npm, '@scope/pkg').toString(),
        'https://registry.npmjs.org/@scope%2Fpkg',
      );
    });
    test('bang-escapes uppercase in a go module path', () {
      expect(
        registryUrl(WatchKind.go, 'github.com/BurntSushi/toml').toString(),
        'https://proxy.golang.org/github.com/!burnt!sushi/toml/@v/list',
      );
    });
    test('uses the display name verbatim for crates.io', () {
      expect(
        registryUrl(WatchKind.crates, 'serde_json').toString(),
        'https://crates.io/api/v1/crates/serde_json',
      );
    });
    test('rejects non-registry kinds', () {
      expect(
        () => registryUrl(WatchKind.rss, 'https://x/feed'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('pub.dev', () {
    const body = '''
{
  "name": "http",
  "latest": {"version": "1.2.2"},
  "versions": [
    {"version": "1.2.1", "published": "2024-05-01T10:00:00.000Z",
     "pubspec": {"repository": "https://github.com/dart-lang/http"}},
    {"version": "1.2.2", "published": "2024-06-01T10:00:00.000Z",
     "pubspec": {"repository": "https://github.com/dart-lang/http"}}
  ]
}''';
    test('reads versions newest-last and the repository url', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.pub, 'http'),
      );
      expect(r.versions.map((v) => v.version), ['1.2.1', '1.2.2']);
      expect(r.versions.last.publishedAt, DateTime.utc(2024, 6, 1, 10));
      expect(r.repoUrl, 'https://github.com/dart-lang/http');
    });

    test('sorts out-of-order versions oldest-first by publishedAt', () async {
      const outOfOrderBody = '''
{
  "name": "http",
  "latest": {"version": "1.2.2"},
  "versions": [
    {"version": "1.2.2", "published": "2024-06-01T10:00:00.000Z"},
    {"version": "1.2.1", "published": "2024-05-01T10:00:00.000Z"}
  ]
}''';
      final r = await fetchRegistry(
        netReturning(outOfOrderBody),
        w(WatchKind.pub, 'http'),
      );
      expect(r.versions.map((v) => v.version), ['1.2.1', '1.2.2']);
      expect(r.versions.last.version, '1.2.2');
      expect(r.versions.last.publishedAt, DateTime.utc(2024, 6, 1, 10));
    });

    test('breaks a publishedAt tie by version order', () async {
      const tiedBody = '''
{
  "name": "http",
  "latest": {"version": "1.2.2"},
  "versions": [
    {"version": "1.2.2", "published": "2024-06-01T10:00:00.000Z"},
    {"version": "1.2.10", "published": "2024-06-01T10:00:00.000Z"},
    {"version": "1.2.1", "published": "2024-06-01T10:00:00.000Z"}
  ]
}''';
      final r = await fetchRegistry(
        netReturning(tiedBody),
        w(WatchKind.pub, 'http'),
      );
      expect(r.versions.map((v) => v.version), ['1.2.1', '1.2.2', '1.2.10']);
      expect(r.versions.last.version, '1.2.10');
    });

    test(
      'orders deterministically by version when publishedAt is missing',
      () async {
        const noTimestampBody = '''
{
  "name": "http",
  "latest": {"version": "1.2.2"},
  "versions": [
    {"version": "1.2.2"},
    {"version": "1.2.10"},
    {"version": "1.2.1"}
  ]
}''';
        final r = await fetchRegistry(
          netReturning(noTimestampBody),
          w(WatchKind.pub, 'http'),
        );
        expect(r.versions.map((v) => v.version), ['1.2.1', '1.2.2', '1.2.10']);
        expect(r.versions.every((v) => v.publishedAt == null), isTrue);
      },
    );
  });

  group('npm', () {
    const body = '''
{
  "name": "left-pad",
  "dist-tags": {"latest": "1.3.0"},
  "versions": {"1.2.0": {}, "1.3.0": {}},
  "time": {
    "created": "2014-01-01T00:00:00.000Z",
    "1.2.0": "2015-01-01T00:00:00.000Z",
    "1.3.0": "2016-01-01T00:00:00.000Z"
  },
  "repository": {"type": "git", "url": "git+https://github.com/stevemao/left-pad.git"}
}''';
    test('reads versions, timestamps, and normalizes the git url', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.npm, 'left-pad'),
      );
      expect(r.versions.map((v) => v.version), ['1.2.0', '1.3.0']);
      expect(r.versions.first.publishedAt, DateTime.utc(2015, 1, 1));
      expect(r.repoUrl, 'https://github.com/stevemao/left-pad');
    });
    test('ignores the non-version keys in the time map', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.npm, 'left-pad'),
      );
      expect(r.versions.map((v) => v.version), isNot(contains('created')));
    });
    test('sorts out-of-order versions oldest-first by publishedAt', () async {
      const outOfOrderBody = '''
{
  "name": "left-pad",
  "dist-tags": {"latest": "1.3.0"},
  "versions": {"1.3.0": {}, "1.2.0": {}},
  "time": {
    "created": "2014-01-01T00:00:00.000Z",
    "1.2.0": "2015-01-01T00:00:00.000Z",
    "1.3.0": "2016-01-01T00:00:00.000Z"
  }
}''';
      final r = await fetchRegistry(
        netReturning(outOfOrderBody),
        w(WatchKind.npm, 'left-pad'),
      );
      expect(r.versions.map((v) => v.version), ['1.2.0', '1.3.0']);
      expect(r.versions.last.version, '1.3.0');
    });
  });

  group('crates.io', () {
    const body = '''
{
  "crate": {"name": "serde", "max_version": "1.0.213",
            "repository": "https://github.com/serde-rs/serde"},
  "versions": [
    {"num": "1.0.213", "created_at": "2024-10-01T00:00:00+00:00", "yanked": false},
    {"num": "1.0.212", "created_at": "2024-09-01T00:00:00+00:00", "yanked": false},
    {"num": "1.0.211", "created_at": "2024-08-01T00:00:00+00:00", "yanked": true}
  ]
}''';
    test('reads versions and repository', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.crates, 'serde'),
      );
      expect(r.repoUrl, 'https://github.com/serde-rs/serde');
      expect(r.versions.map((v) => v.version), contains('1.0.213'));
    });
    test('drops yanked versions', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.crates, 'serde'),
      );
      expect(r.versions.map((v) => v.version), isNot(contains('1.0.211')));
    });
    test('sorts versions oldest-first by publishedAt', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.crates, 'serde'),
      );
      expect(r.versions.map((v) => v.version), ['1.0.212', '1.0.213']);
      expect(r.versions.last.version, '1.0.213');
    });
  });

  group('pypi', () {
    const body = '''
{
  "info": {
    "version": "2.32.3",
    "home_page": "",
    "project_urls": {"Source": "https://github.com/psf/requests"}
  },
  "releases": {
    "2.32.2": [{"upload_time_iso_8601": "2024-05-01T00:00:00.000000Z"}],
    "2.32.3": [{"upload_time_iso_8601": "2024-06-01T00:00:00.000000Z"}],
    "2.32.4": []
  }
}''';
    test('reads releases and the source url from project_urls', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.pypi, 'requests'),
      );
      expect(r.repoUrl, 'https://github.com/psf/requests');
      expect(
        r.versions.map((v) => v.version),
        containsAll(['2.32.2', '2.32.3']),
      );
      expect(
        r.versions.firstWhere((v) => v.version == '2.32.3').publishedAt,
        DateTime.utc(2024, 6, 1),
      );
    });
    test('skips releases with no files, which are withdrawn', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.pypi, 'requests'),
      );
      expect(r.versions.map((v) => v.version), isNot(contains('2.32.4')));
    });
    test('sorts releases oldest-first by publishedAt', () async {
      final r = await fetchRegistry(
        netReturning(body),
        w(WatchKind.pypi, 'requests'),
      );
      expect(r.versions.map((v) => v.version), ['2.32.2', '2.32.3']);
      expect(r.versions.last.version, '2.32.3');
    });
  });

  group('go proxy', () {
    test('parses the newline-delimited version list', () async {
      final net = netReturning('v0.30.0\nv0.29.0\n\n');
      final r = await fetchRegistry(net, w(WatchKind.go, 'golang.org/x/net'));
      expect(r.versions.map((v) => v.version), ['v0.29.0', 'v0.30.0']);
      expect(r.versions.first.publishedAt, isNull);
    });

    test(
      'orders by version, not by string, so the last entry is newest (I3)',
      () async {
        // v1.9.0 and v1.10.0 are a case where string order and version order
        // DISAGREE ("v1.10.0" < "v1.9.0" lexicographically), unlike the
        // fixture above (v0.29.0/v0.30.0), which cannot distinguish a plain
        // string sort from compareVersions. RegistryResult.versions is
        // documented as oldest-first so the caller can treat the last entry
        // as newest; this is the guard for that contract.
        final net = netReturning('v1.9.0\nv1.10.0\n');
        final r = await fetchRegistry(net, w(WatchKind.go, 'golang.org/x/net'));
        expect(r.versions.map((v) => v.version), ['v1.9.0', 'v1.10.0']);
        expect(r.versions.last.version, 'v1.10.0');
      },
    );

    test('derives a github repo url from the module path', () async {
      final net = netReturning('v1.4.0\n');
      final r = await fetchRegistry(
        net,
        w(WatchKind.go, 'github.com/BurntSushi/toml'),
      );
      expect(r.repoUrl, 'https://github.com/BurntSushi/toml');
    });

    test('leaves repoUrl null for a non-github module', () async {
      final net = netReturning('v0.30.0\n');
      final r = await fetchRegistry(net, w(WatchKind.go, 'golang.org/x/net'));
      expect(r.repoUrl, isNull);
    });

    test('an empty version list is not an error', () async {
      final r = await fetchRegistry(
        netReturning('\n'),
        w(WatchKind.go, 'example.com/x'),
      );
      expect(r.versions, isEmpty);
    });
  });

  group('githubSlug', () {
    test('accepts the common url shapes', () {
      expect(githubSlug('https://github.com/dart-lang/http'), 'dart-lang/http');
      expect(githubSlug('git+https://github.com/a/b.git'), 'a/b');
      expect(githubSlug('git://github.com/a/b.git'), 'a/b');
      expect(githubSlug('https://github.com/a/b/tree/main/pkg'), 'a/b');
      expect(githubSlug('git@github.com:a/b.git'), 'a/b');
    });
    test('rejects non-github and malformed urls', () {
      expect(githubSlug('https://gitlab.com/a/b'), isNull);
      expect(githubSlug('https://github.com/onlyowner'), isNull);
      expect(githubSlug(null), isNull);
      expect(githubSlug('not a url'), isNull);
    });
  });

  test('malformed registry json throws FormatException', () async {
    await expectLater(
      fetchRegistry(
        netReturning('<html>down</html>'),
        w(WatchKind.pub, 'http'),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('a 404 propagates as NetException', () async {
    final net = Net(client: MockClient((_) async => http.Response('', 404)));
    await expectLater(
      fetchRegistry(net, w(WatchKind.pub, 'nope')),
      throwsA(isA<NetException>().having((e) => e.status, 'status', 404)),
    );
  });
}
