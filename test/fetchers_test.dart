import 'dart:io';

import 'package:deptracker/fetchers/fetchers.dart';
import 'package:deptracker/models.dart';
import 'package:deptracker/net.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// I8: fetchWatch had zero test references anywhere in the suite, despite
// _fromRegistry being ~45 lines of non-trivial join logic — the registry is
// authoritative about which versions exist, GitHub is the only source of
// notes, and the two must be merged rather than one overriding the other.

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

const _pubBody =
    '{"name":"http","latest":{"version":"1.2.2"},"versions":['
    '{"version":"1.2.1","published":"2024-05-01T10:00:00.000Z",'
    '"pubspec":{"repository":"https://github.com/dart-lang/http"}},'
    '{"version":"1.2.2","published":"2024-06-01T10:00:00.000Z",'
    '"pubspec":{"repository":"https://github.com/dart-lang/http"}}'
    ']}';

Watch pubWatch({String? repoUrl}) => Watch(
  id: 1,
  kind: WatchKind.pub,
  name: 'http',
  displayName: 'http',
  repoUrl: repoUrl,
);

void main() {
  dispatchTests();

  test(
    'notes attach to the matching version across a v-prefix mismatch',
    () async {
      final net = Net(
        client: MockClient((req) async {
          if (req.url.host == 'pub.dev') {
            return http.Response(_pubBody, 200);
          }
          if (req.url.path.endsWith('/releases.atom')) {
            return http.Response(fixture('releases.atom'), 200);
          }
          throw StateError('unexpected request: ${req.url}');
        }),
      );

      final outcome = await fetchWatch(net, pubWatch());
      final r = outcome.releases.firstWhere((r) => r.version == '1.2.2');
      // The registry writes "1.2.2"; the GitHub feed's entry is tagged
      // "v1.2.2" — _key()'s leading-v strip is what lets these join.
      expect(r.notesMd, contains('Fixed a redirect bug.'));
    },
  );

  test('a version with no matching github entry keeps its version and gets '
      'null notes', () async {
    final net = Net(
      client: MockClient((req) async {
        if (req.url.host == 'pub.dev') {
          return http.Response(_pubBody, 200);
        }
        if (req.url.path.endsWith('.atom')) {
          // No entries at all, from either releases.atom or its
          // tags.atom fallback: every registry version must still
          // survive.
          return http.Response(
            '<feed xmlns="http://www.w3.org/2005/Atom"></feed>',
            200,
          );
        }
        throw StateError('unexpected request: ${req.url}');
      }),
    );

    final outcome = await fetchWatch(net, pubWatch());
    expect(outcome.releases.map((r) => r.version), ['1.2.1', '1.2.2']);
    expect(outcome.releases.every((r) => r.notesMd == null), isTrue);
  });

  test(
    'a 404 from the github half costs the notes but not the version list',
    () async {
      final net = Net(
        client: MockClient((req) async {
          if (req.url.host == 'pub.dev') {
            return http.Response(_pubBody, 200);
          }
          if (req.url.host == 'github.com') {
            return http.Response('not found', 404);
          }
          throw StateError('unexpected request: ${req.url}');
        }),
      );

      final outcome = await fetchWatch(net, pubWatch());
      expect(outcome.releases.map((r) => r.version), ['1.2.1', '1.2.2']);
      expect(outcome.releases.every((r) => r.notesMd == null), isTrue);
    },
  );

  test('a rate-limited github half rethrows rather than being swallowed', () {
    final net = Net(
      client: MockClient((req) async {
        if (req.url.host == 'pub.dev') {
          return http.Response(_pubBody, 200);
        }
        if (req.url.host == 'github.com') {
          return http.Response('rate limited', 429);
        }
        throw StateError('unexpected request: ${req.url}');
      }),
    );

    expect(
      () => fetchWatch(net, pubWatch()),
      throwsA(isA<NetException>().having((e) => e.isRateLimit, 'rate', true)),
    );
  });

  test('repoUrl is null when the registry tells us nothing new', () async {
    final net = Net(
      client: MockClient((req) async {
        if (req.url.host == 'pub.dev') return http.Response(_pubBody, 200);
        if (req.url.path.endsWith('.atom')) {
          return http.Response(
            '<feed xmlns="http://www.w3.org/2005/Atom"></feed>',
            200,
          );
        }
        throw StateError('unexpected request: ${req.url}');
      }),
    );

    final outcome = await fetchWatch(
      net,
      pubWatch(repoUrl: 'https://github.com/dart-lang/http'),
    );
    expect(outcome.repoUrl, isNull);
  });

  test(
    'repoUrl is set when the registry reveals it for the first time',
    () async {
      final net = Net(
        client: MockClient((req) async {
          if (req.url.host == 'pub.dev') return http.Response(_pubBody, 200);
          if (req.url.path.endsWith('.atom')) {
            return http.Response(
              '<feed xmlns="http://www.w3.org/2005/Atom"></feed>',
              200,
            );
          }
          throw StateError('unexpected request: ${req.url}');
        }),
      );

      final outcome = await fetchWatch(net, pubWatch());
      expect(outcome.repoUrl, 'https://github.com/dart-lang/http');
    },
  );
}

// fetchWatch's dispatch arms. Its doc comment said it needed no test of its
// own because the orchestrator and the individual fetchers cover it — but the
// rss and github arms are not pure dispatch: each builds a Release list, and
// the rss arm decides what a feed entry's "version" even is. Nothing exercised
// them.

Watch _watch(WatchKind kind, String displayName) =>
    Watch(id: 7, kind: kind, name: displayName, displayName: displayName);

Net _netReturning(String body, {String contentType = 'application/json'}) =>
    Net(
      client: MockClient(
        (_) async =>
            http.Response(body, 200, headers: {'content-type': contentType}),
      ),
    );

void dispatchTests() {
  test('an rss watch turns feed entries into releases', () async {
    const atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>tag:example.com,2024:1</id>
    <title>Release 2.0.0</title>
    <link href="https://example.com/2"/>
    <updated>2024-06-01T10:00:00Z</updated>
    <content type="html">&lt;p&gt;Notes &lt;b&gt;here&lt;/b&gt;&lt;/p&gt;</content>
  </entry>
</feed>''';

    final out = await fetchWatch(
      _netReturning(atom, contentType: 'application/atom+xml'),
      _watch(WatchKind.rss, 'https://example.com/feed.atom'),
    );

    // A feed watch learns no repository, so it must not invent one.
    expect(out.repoUrl, isNull);
    final release = out.releases.single;
    expect(release.watchId, 7);
    expect(release.version, 'Release 2.0.0');
    expect(release.url, 'https://example.com/2');
    expect(release.publishedAt, DateTime.utc(2024, 6, 1, 10));
    // Content is stored as plain text, not the raw HTML the feed carried.
    expect(release.notesMd, 'Notes here');
  });

  test(
    'an rss entry with no title falls back to its id as the version',
    () async {
      // The version column is what makes a release row unique, so an untitled
      // entry still needs a stable one or every refresh re-inserts it.
      const atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>tag:example.com,2024:only-id</id>
    <title></title>
    <updated>2024-06-01T10:00:00Z</updated>
  </entry>
</feed>''';

      final out = await fetchWatch(
        _netReturning(atom, contentType: 'application/atom+xml'),
        _watch(WatchKind.rss, 'https://example.com/feed.atom'),
      );
      expect(out.releases.single.version, 'tag:example.com,2024:only-id');
      expect(out.releases.single.notesMd, isNull);
    },
  );

  test('a github watch resolves a url display name down to its slug', () async {
    // displayName is whatever the user typed, which may be a full URL, while
    // the fetcher and the repoUrl both need the bare owner/repo. With no
    // token the fetcher reads the public releases.atom feed, so the mock has
    // to answer on that URL specifically — proving the slug reached it.
    const atom = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>tag:github.com,2024:Repository/1/v1.0.0</id>
    <title>v1.0.0</title>
    <link href="https://github.com/dart-lang/http/releases/tag/v1.0.0"/>
    <updated>2024-06-01T10:00:00Z</updated>
  </entry>
</feed>""";

    final asked = <String>[];
    final net = Net(
      client: MockClient((req) async {
        asked.add(req.url.toString());
        return http.Response(
          atom,
          200,
          headers: {'content-type': 'application/atom+xml'},
        );
      }),
    );

    final out = await fetchWatch(
      net,
      _watch(WatchKind.github, 'https://github.com/dart-lang/http'),
    );

    expect(out.repoUrl, 'https://github.com/dart-lang/http');
    expect(out.releases.single.watchId, 7);
    expect(
      asked.single,
      'https://github.com/dart-lang/http/releases.atom',
      reason: 'the full URL must be reduced to owner/repo before fetching',
    );
  });

  test('a go watch goes through the registry path', () async {
    // go is grouped with the registry kinds in the switch; this pins that it
    // is not silently falling into the feed arm.
    final asked = <String>[];
    final net = Net(
      client: MockClient((req) async {
        asked.add(req.url.toString());
        if (req.url.path.endsWith('/@v/list')) {
          return http.Response('v1.1.0\nv1.2.0\n', 200);
        }
        if (req.url.path.contains('.info')) {
          return http.Response(
            '{"Version":"v1.2.0","Time":"2024-06-01T10:00:00Z"}',
            200,
          );
        }
        return http.Response('', 404);
      }),
    );

    final out = await fetchWatch(
      net,
      _watch(WatchKind.go, 'github.com/pkg/errors'),
    );

    expect(out.releases, isNotEmpty);
    expect(
      asked.first,
      contains('proxy.golang.org'),
      reason: 'a go watch must query the module proxy, not a feed',
    );
  });
}
