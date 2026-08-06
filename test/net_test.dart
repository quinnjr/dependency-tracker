import 'package:deptracker/net.dart';
import 'package:deptracker/redact.dart';
import 'package:deptracker/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  timeoutAndLifecycleTests();
  setUp(clearSecrets);

  test('returns the body on 200', () async {
    final net = Net(
      client: MockClient((_) async => http.Response('hello', 200)),
    );
    expect((await net.get(Uri.parse('https://example.com'))).body, 'hello');
  });

  test('sends a User-Agent, which crates.io requires', () async {
    String? seen;
    final net = Net(
      client: MockClient((req) async {
        seen = req.headers['user-agent'];
        return http.Response('{}', 200);
      }),
    );
    await net.get(Uri.parse('https://crates.io/api/v1/crates/serde'));
    expect(seen, isNotNull);
    expect(seen, contains('dependency-tracker'));
  });

  test('replays the cached body on a 304', () async {
    var calls = 0;
    final net = Net(
      client: MockClient((req) async {
        calls++;
        if (req.headers.containsKey('If-None-Match')) {
          expect(req.headers['If-None-Match'], '"v1"');
          return http.Response('', 304);
        }
        return http.Response('first', 200, headers: {'etag': '"v1"'});
      }),
    );
    final url = Uri.parse('https://example.com/a');
    expect((await net.get(url)).body, 'first');
    final second = await net.get(url);
    expect(second.body, 'first');
    expect(second.notModified, isTrue);
    expect(calls, 2);
  });

  test(
    'a stray 304 with no matching cache entry is a NetException, not data',
    () async {
      final store = Store.openInMemory();
      addTearDown(store.close);
      final net = Net(
        cache: store,
        client: MockClient((_) async => http.Response('', 304)),
      );
      final url = Uri.parse('https://example.com/stray');
      await expectLater(
        net.get(url),
        throwsA(isA<NetException>().having((e) => e.status, 'status', 304)),
      );
      expect(store.cachedBody(url.toString()), isNull);
    },
  );

  test(
    'a stray 304 carrying an etag still never caches an empty body',
    () async {
      final store = Store.openInMemory();
      addTearDown(store.close);
      final net = Net(
        cache: store,
        client: MockClient(
          (_) async => http.Response('', 304, headers: {'etag': '"stray"'}),
        ),
      );
      final url = Uri.parse('https://example.com/stray-with-etag');
      await expectLater(net.get(url), throwsA(isA<NetException>()));
      expect(store.cachedBody(url.toString()), isNull);
      expect(store.etagFor(url.toString()), isNull);
    },
  );

  test('caches per url, not globally', () async {
    final net = Net(
      client: MockClient((req) async {
        return http.Response(req.url.path, 200, headers: {'etag': '"e"'});
      }),
    );
    expect((await net.get(Uri.parse('https://example.com/a'))).body, '/a');
    expect((await net.get(Uri.parse('https://example.com/b'))).body, '/b');
  });

  test('throws NetException with a redacted message on 5xx', () async {
    registerSecret('ghp_abcdefghijklmnop');
    final net = Net(
      client: MockClient(
        (_) async => http.Response('token ghp_abcdefghijklmnop is bad', 500),
      ),
    );
    await expectLater(
      net.get(Uri.parse('https://example.com')),
      throwsA(
        isA<NetException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('«redacted»'), isNot(contains('ghp_'))),
        ),
      ),
    );
  });

  test('surfaces 404 as a NetException carrying the status', () async {
    final net = Net(client: MockClient((_) async => http.Response('', 404)));
    await expectLater(
      net.get(Uri.parse('https://example.com')),
      throwsA(isA<NetException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('reports rate limiting distinctly so refresh can back off', () async {
    final net = Net(
      client: MockClient(
        (_) async => http.Response(
          'rate limit exceeded',
          403,
          headers: {'x-ratelimit-remaining': '0'},
        ),
      ),
    );
    await expectLater(
      net.get(Uri.parse('https://api.github.com/x')),
      throwsA(
        isA<NetException>().having((e) => e.isRateLimit, 'isRateLimit', isTrue),
      ),
    );
  });

  test('never runs more than `concurrency` requests at once', () async {
    var inFlight = 0;
    var peak = 0;
    final net = Net(
      concurrency: 3,
      client: MockClient((_) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return http.Response('ok', 200);
      }),
    );
    await Future.wait(
      List.generate(12, (i) => net.get(Uri.parse('https://example.com/$i'))),
    );
    expect(peak, lessThanOrEqualTo(3));
  });

  test('a failing request releases its concurrency slot', () async {
    final net = Net(
      concurrency: 1,
      client: MockClient(
        (req) async => http.Response('', req.url.path == '/bad' ? 500 : 200),
      ),
    );
    await expectLater(
      net.get(Uri.parse('https://example.com/bad')),
      throwsA(isA<NetException>()),
    );
    expect((await net.get(Uri.parse('https://example.com/ok'))).status, 200);
  });

  test('wraps a transport failure as a redacted NetException', () async {
    registerSecret('ghp_abcdefghijklmnop');
    final net = Net(
      client: MockClient((_) async {
        throw http.ClientException('connect failed for ghp_abcdefghijklmnop');
      }),
    );
    await expectLater(
      net.get(Uri.parse('https://example.com')),
      throwsA(
        isA<NetException>().having(
          (e) => e.toString(),
          'message',
          isNot(contains('ghp_')),
        ),
      ),
    );
  });

  test('a real Store satisfies EtagCache and round-trips through it', () async {
    final store = Store.openInMemory();
    addTearDown(store.close);
    var calls = 0;
    final net = Net(
      cache: store,
      client: MockClient((req) async {
        calls++;
        if (req.headers.containsKey('If-None-Match')) {
          return http.Response('', 304);
        }
        return http.Response('body-1', 200, headers: {'etag': '"s1"'});
      }),
    );
    final url = Uri.parse('https://example.com/store-backed');
    final first = await net.get(url);
    expect(first.body, 'body-1');
    expect(store.etagFor(url.toString()), '"s1"');
    expect(store.cachedBody(url.toString()), 'body-1');

    final second = await net.get(url);
    expect(second.body, 'body-1');
    expect(second.notModified, isTrue);
    expect(calls, 2);
  });

  test(
    'never caches a response fetched with an Authorization header',
    () async {
      var sawConditionalRequest = false;
      final net = Net(
        client: MockClient((req) async {
          if (req.headers.containsKey('If-None-Match')) {
            sawConditionalRequest = true;
          }
          return http.Response(
            'secret payload',
            200,
            headers: {'etag': '"auth-etag"'},
          );
        }),
      );
      final url = Uri.parse('https://example.com/private');
      await net.get(url, headers: {'Authorization': 'Bearer token12345678'});
      // A second request through the same Net would send If-None-Match if the
      // first response had been cached. It must not have been, since the first
      // request carried an Authorization header.
      await net.get(url, headers: {'Authorization': 'Bearer token12345678'});
      expect(sawConditionalRequest, isFalse);
    },
  );
}

// The bound on a single request, the generic-exception arm, and close().
void timeoutAndLifecycleTests() {
  test('a request that never answers fails the watch instead of hanging the '
      'refresh', () async {
    // refreshAll awaits every worker, so one socket that accepts and then
    // goes quiet would otherwise park a worker forever, defeat the
    // rate-limit stop, and leave the UI's in-progress state stuck.
    final net = Net(
      requestTimeout: const Duration(milliseconds: 50),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return http.Response('never gets here', 200);
      }),
    );

    await expectLater(
      net.get(Uri.parse('https://example.com/slow')),
      throwsA(
        isA<NetException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('example.com'), contains('no response')),
        ),
      ),
    );
  });

  test(
    'a non-client exception is wrapped as a NetException naming the host',
    () async {
      // Anything the http stack can throw has to arrive at the per-watch catch
      // as a NetException, or the message stored on the watch names a Dart
      // internal instead of the registry that failed.
      final net = Net(
        client: MockClient(
          (_) async => throw const FormatException('bad chunk'),
        ),
      );

      await expectLater(
        net.get(Uri.parse('https://registry.example.com/x')),
        throwsA(
          isA<NetException>().having(
            (e) => e.toString(),
            'message',
            contains('registry.example.com'),
          ),
        ),
      );
    },
  );

  test('close releases the underlying client', () async {
    // main.dart closes Net on exit; a client left open holds its sockets.
    var closed = false;
    final net = Net(client: _ClosableMock(() => closed = true));
    net.close();
    expect(closed, isTrue);
  });

  test('the default constructor builds its own client', () {
    // The `?? http.Client()` arm: production never passes one in.
    final net = Net();
    addTearDown(net.close);
    expect(net.concurrency, 8);
    expect(net.requestTimeout, Net.defaultRequestTimeout);
  });
}

/// A client that records close(), which MockClient does not expose.
class _ClosableMock extends http.BaseClient {
  _ClosableMock(this.onClose);

  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);

  @override
  void close() => onClose();
}
