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
