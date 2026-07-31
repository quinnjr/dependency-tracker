import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deptracker/fetchers/feed.dart';
import 'package:deptracker/fetchers/github.dart';
import 'package:deptracker/net.dart';

String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  group('githubFeedUrl', () {
    test('builds the releases and tags feed urls', () {
      expect(
        githubFeedUrl('dart-lang/http').toString(),
        'https://github.com/dart-lang/http/releases.atom',
      );
      expect(
        githubFeedUrl('dart-lang/http', tags: true).toString(),
        'https://github.com/dart-lang/http/tags.atom',
      );
    });
  });

  group('versionFromGithubEntry', () {
    test('prefers the tag in the entry id', () {
      const e = FeedEntry(
        id: 'tag:github.com,2008:Repository/1234/v1.2.2',
        title: 'Some marketing headline',
      );
      expect(versionFromGithubEntry(e), 'v1.2.2');
    });
    test('falls back to the tag in the url', () {
      const e = FeedEntry(
        id: 'urn:opaque',
        title: 'Release day!',
        url: 'https://github.com/a/b/releases/tag/v3.1.0',
      );
      expect(versionFromGithubEntry(e), 'v3.1.0');
    });
    test('falls back to a version-shaped title', () {
      const e = FeedEntry(id: 'urn:opaque', title: '1.2.2');
      expect(versionFromGithubEntry(e), '1.2.2');
    });
    test('extracts a version from a prefixed title', () {
      const e = FeedEntry(id: 'urn:opaque', title: 'Release 2.0.0-rc.1');
      expect(versionFromGithubEntry(e), '2.0.0-rc.1');
    });
    test('returns null when there is no version anywhere', () {
      const e = FeedEntry(id: 'urn:opaque', title: 'Nightly build');
      expect(versionFromGithubEntry(e), isNull);
    });
  });

  group('htmlToPlain', () {
    test('strips tags and unescapes entities', () {
      expect(htmlToPlain('<p>Fixed &amp; shipped</p>'), 'Fixed & shipped');
    });
    test('turns list items into bullets', () {
      expect(htmlToPlain('<ul><li>one</li><li>two</li></ul>'), '- one\n- two');
    });
    test('turns block boundaries into newlines, not run-together text', () {
      expect(htmlToPlain('<p>a</p><p>b</p>'), 'a\n\nb');
    });
    test('drops script and style content entirely', () {
      expect(htmlToPlain('<p>ok</p><script>evil()</script>'), 'ok');
    });
    test('collapses more than two blank lines', () {
      expect(htmlToPlain('<p>a</p><br/><br/><br/><p>b</p>'), 'a\n\nb');
    });
  });

  group('fetchGithubReleases without a token', () {
    test('reads releases.atom and maps entries to releases', () async {
      final net = Net(
        client: MockClient((req) async {
          expect(req.url.path, endsWith('/releases.atom'));
          expect(req.headers.containsKey('Authorization'), isFalse);
          return http.Response(fixture('releases.atom'), 200);
        }),
      );
      final r = await fetchGithubReleases(
        net,
        slug: 'dart-lang/http',
        watchId: 7,
      );
      expect(r.map((x) => x.version), ['v1.2.2', 'v1.2.1']);
      expect(r.first.watchId, 7);
      expect(r.first.notesMd, contains('Fixed a redirect bug.'));
      expect(r.first.url, contains('/releases/tag/v1.2.2'));
      expect(r.first.publishedAt, DateTime.utc(2024, 6, 1, 10));
    });

    test('falls back to tags.atom when there are no releases', () async {
      final requested = <String>[];
      final net = Net(
        client: MockClient((req) async {
          requested.add(req.url.path);
          if (req.url.path.endsWith('/releases.atom')) {
            return http.Response(
              '<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>',
              200,
            );
          }
          return http.Response(fixture('tags.atom'), 200);
        }),
      );
      final r = await fetchGithubReleases(net, slug: 'me/tiny-lib', watchId: 1);
      expect(requested.length, 2);
      expect(r.single.version, 'v0.4.0');
      expect(r.single.notesMd, isNull);
    });

    test('skips entries with no discoverable version', () async {
      const feed = '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><id>urn:x</id><title>Nightly</title></entry>
  <entry><id>tag:github.com,2008:Repository/1/v9.9.9</id><title>x</title></entry>
</feed>''';
      final net = Net(
        client: MockClient((_) async => http.Response(feed, 200)),
      );
      final r = await fetchGithubReleases(net, slug: 'a/b', watchId: 1);
      expect(r.map((x) => x.version), ['v9.9.9']);
    });

    test('a 404 on the repo surfaces as NetException', () async {
      final net = Net(client: MockClient((_) async => http.Response('', 404)));
      await expectLater(
        fetchGithubReleases(net, slug: 'a/gone', watchId: 1),
        throwsA(isA<NetException>().having((e) => e.status, 'status', 404)),
      );
    });
  });

  group('fetchGithubReleases with a token', () {
    const apiBody = '''
[
  {"tag_name": "v2.0.0", "name": "2.0.0",
   "published_at": "2024-08-01T00:00:00Z",
   "html_url": "https://github.com/a/b/releases/tag/v2.0.0",
   "body": "## Breaking\\n\\n- removed `foo`", "draft": false, "prerelease": false},
  {"tag_name": "v1.9.0", "name": "1.9.0",
   "published_at": "2024-07-01T00:00:00Z",
   "html_url": "https://github.com/a/b/releases/tag/v1.9.0",
   "body": "patch", "draft": true, "prerelease": false}
]''';

    test('uses the api and keeps the markdown body verbatim', () async {
      String? auth;
      Uri? seen;
      final net = Net(
        client: MockClient((req) async {
          auth = req.headers['Authorization'];
          seen = req.url;
          return http.Response(apiBody, 200);
        }),
      );
      final r = await fetchGithubReleases(
        net,
        slug: 'a/b',
        watchId: 3,
        token: 'ghp_abcdefghijklmnop',
      );
      expect(auth, 'Bearer ghp_abcdefghijklmnop');
      expect(seen!.host, 'api.github.com');
      expect(seen!.path, '/repos/a/b/releases');
      expect(r.first.notesMd, contains('## Breaking'));
      expect(r.first.notesMd, contains('removed `foo`'));
    });

    test('drops drafts, which are not published versions', () async {
      final net = Net(
        client: MockClient((_) async => http.Response(apiBody, 200)),
      );
      final r = await fetchGithubReleases(
        net,
        slug: 'a/b',
        watchId: 3,
        token: 'ghp_abcdefghijklmnop',
      );
      expect(r.map((x) => x.version), ['v2.0.0']);
    });

    test('keeps a prerelease, which is a real published version', () async {
      const body = '''
[
  {"tag_name": "v3.0.0-beta.1", "name": "3.0.0-beta.1",
   "published_at": "2024-09-01T00:00:00Z",
   "html_url": "https://github.com/a/b/releases/tag/v3.0.0-beta.1",
   "body": "beta notes", "draft": false, "prerelease": true},
  {"tag_name": "v2.9.0", "name": "2.9.0",
   "published_at": "2024-08-15T00:00:00Z",
   "html_url": "https://github.com/a/b/releases/tag/v2.9.0",
   "body": "draft notes", "draft": true, "prerelease": false}
]''';
      final net = Net(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      final r = await fetchGithubReleases(
        net,
        slug: 'a/b',
        watchId: 3,
        token: 'ghp_abcdefghijklmnop',
      );
      expect(r.map((x) => x.version), ['v3.0.0-beta.1']);
    });

    test('falls back to the atom feed when the token is rejected', () async {
      final paths = <String>[];
      final net = Net(
        client: MockClient((req) async {
          paths.add(req.url.host);
          if (req.url.host == 'api.github.com') {
            return http.Response('{"message":"Bad credentials"}', 401);
          }
          return http.Response(fixture('releases.atom'), 200);
        }),
      );
      final r = await fetchGithubReleases(
        net,
        slug: 'dart-lang/http',
        watchId: 1,
        token: 'ghp_expiredtokenvalue',
      );
      expect(paths, ['api.github.com', 'github.com']);
      expect(r.first.version, 'v1.2.2');
    });

    test(
      'does not fall back when rate limited, so the error is visible',
      () async {
        final hosts = <String>[];
        final net = Net(
          client: MockClient((req) async {
            hosts.add(req.url.host);
            return http.Response(
              'rate limit exceeded',
              403,
              headers: {'x-ratelimit-remaining': '0'},
            );
          }),
        );
        await expectLater(
          fetchGithubReleases(
            net,
            slug: 'a/b',
            watchId: 1,
            token: 'ghp_abcdefghijklmnop',
          ),
          throwsA(
            isA<NetException>().having(
              (e) => e.isRateLimit,
              'isRateLimit',
              isTrue,
            ),
          ),
        );
        // A rate limit is temporary and must stay visible, not silently
        // degrade to the feed. Only api.github.com should ever be asked —
        // the previous version of this test used the same MockClient
        // response for every host, so a broken implementation that DID
        // fall back to github.com would hit that same rate-limited
        // response and still satisfy the throwsA assertion above,
        // masking the regression it exists to catch.
        expect(hosts, ['api.github.com']);
      },
    );
  });
}
