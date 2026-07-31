import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:deptracker/fetchers/feed.dart';
import 'package:deptracker/net.dart';

String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  group('atom', () {
    test('reads entries newest-first as published', () {
      final e = parseFeed(fixture('releases.atom'));
      expect(e.map((x) => x.title), ['1.2.2', '1.2.1']);
      expect(e.first.published, DateTime.utc(2024, 6, 1, 10));
    });

    test('unescapes html content', () {
      final e = parseFeed(fixture('releases.atom'));
      expect(e.first.content, contains('Fixed a redirect bug.'));
      expect(e.first.content, isNot(contains('&lt;')));
    });

    test('reads the alternate link', () {
      final e = parseFeed(fixture('releases.atom'));
      expect(
        e.first.url,
        'https://github.com/dart-lang/http/releases/tag/v1.2.2',
      );
    });

    test('tolerates an entry with no content, as tag feeds have none', () {
      final e = parseFeed(fixture('tags.atom'));
      expect(e.single.title, 'v0.4.0');
      expect(e.single.content, isNull);
      expect(e.single.published, DateTime.utc(2024, 7, 1));
    });

    test('tolerates an entry with no link at all', () {
      final e = parseFeed(fixture('no-link.atom'));
      expect(e.single.url, isNull);
      expect(e.single.id, 'tag:example.com,2026:2');
    });

    test('prefers an unmarked link over rel="self" when there is no '
        'rel="alternate"', () {
      final e = parseFeed(fixture('multi-link.atom'));
      expect(e.single.url, 'https://example.com/releases/v1.0.0');
    });
  });

  group('rss', () {
    test('reads items with rfc822 dates', () {
      final e = parseFeed(fixture('blog.rss'));
      expect(e.map((x) => x.title), [
        'Flutter 3.44 released',
        'Flutter 3.43 released',
      ]);
      expect(e.first.published, DateTime.utc(2026, 7, 8, 22, 2, 6));
    });

    test('handles a GMT offset', () {
      final e = parseFeed(fixture('blog.rss'));
      expect(e.last.published, DateTime.utc(2026, 6, 3, 9));
    });

    test('uses description as content and link as url', () {
      final e = parseFeed(fixture('blog.rss'));
      expect(e.first.content, contains('Impeller on by default.'));
      expect(e.first.url, 'https://example.com/flutter-3-44');
    });

    test('falls back to the link when there is no guid', () {
      final e = parseFeed(fixture('blog.rss'));
      expect(e.last.id, 'https://example.com/flutter-3-43');
    });

    test('prefers an unqualified link over a namespaced atom:link sibling', () {
      // WordPress-style feeds commonly carry an <atom:link rel="self"/>
      // right alongside the real <link>. A wildcard-namespace match would
      // find the (self-closing, empty) atom:link first and lose the URL.
      final e = parseFeed(fixture('wp-style.rss'));
      expect(e.first.url, 'https://example.com/real');
    });

    test('skips an empty element in favor of a later populated one with the '
        'same name', () {
      final e = parseFeed(fixture('wp-style.rss'));
      expect(e.last.url, 'https://example.com/second');
    });
  });

  group('rdf', () {
    // RSS 1.0 / RDF feeds (e.g. some CVE feeds) put <item> as a sibling of
    // <channel>, not nested inside it. A parser that only looks inside
    // <channel> silently returns no entries for a real, non-empty feed —
    // indistinguishable from "nothing new here".
    test('reads items that are siblings of channel, not nested in it', () {
      final e = parseFeed(fixture('cve.rdf'));
      expect(e.map((x) => x.title), ['CVE-2026-1234', 'CVE-2026-5678']);
      expect(e.first.url, 'https://example.com/cve/CVE-2026-1234');
      expect(e.first.published, DateTime.utc(2026, 7, 15));
      expect(e.last.published, DateTime.utc(2026, 7, 10));
    });
  });

  group('parseFeedDate', () {
    test('accepts iso 8601', () {
      expect(
        parseFeedDate('2024-06-01T10:00:00Z'),
        DateTime.utc(2024, 6, 1, 10),
      );
    });
    test('accepts rfc 822 with a numeric offset', () {
      expect(
        parseFeedDate('Mon, 08 Jul 2026 15:02:06 -0700'),
        DateTime.utc(2026, 7, 8, 22, 2, 6),
      );
    });
    test('accepts named zones it knows', () {
      expect(
        parseFeedDate('Tue, 03 Jun 2026 09:00:00 GMT'),
        DateTime.utc(2026, 6, 3, 9),
      );
      expect(
        parseFeedDate('Tue, 03 Jun 2026 09:00:00 UT'),
        DateTime.utc(2026, 6, 3, 9),
      );
    });
    test('returns null rather than throwing on junk', () {
      expect(parseFeedDate('sometime last tuesday'), isNull);
      expect(parseFeedDate(null), isNull);
      expect(parseFeedDate(''), isNull);
    });
  });

  test('rejects xml that is neither atom nor rss', () {
    expect(
      () => parseFeed('<html><body>nope</body></html>'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed xml', () {
    expect(() => parseFeed('<feed><entry>'), throwsA(isA<FormatException>()));
  });

  test('an empty feed yields no entries rather than throwing', () {
    expect(
      parseFeed(
        '<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>',
      ),
      isEmpty,
    );
  });

  test('fetchFeed parses what the network returns', () async {
    final net = Net(
      client: MockClient((_) async => http.Response(fixture('tags.atom'), 200)),
    );
    final e = await fetchFeed(net, Uri.parse('https://example.com/tags.atom'));
    expect(e.single.title, 'v0.4.0');
  });
}
