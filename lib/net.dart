import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

import 'redact.dart';

/// crates.io rejects requests without a descriptive User-Agent, and every
/// other registry prefers one.
const String userAgent =
    'dependency-tracker/0.1 (+https://github.com/local/dependency-tracker)';

/// A persistent store for ETag-conditional GET caching.
///
/// `Store` (`lib/store.dart`) implements this with its `http_cache` table, so
/// a launch-time refresh survives an app restart instead of re-fetching
/// everything. [Net] does not require one: without a cache, it falls back to
/// a private in-memory map so callers (and tests) need no database.
abstract interface class EtagCache {
  String? etagFor(String url);
  String? cachedBody(String url);
  void putCache(String url, String? etag, String body);
}

class NetResponse {
  const NetResponse({
    required this.status,
    required this.body,
    this.notModified = false,
  });

  final int status;
  final String body;

  /// True when the server answered 304 and [body] came from the cache.
  final bool notModified;
}

class NetException implements Exception {
  NetException(String message, {this.status, this.isRateLimit = false})
    : message = redact(message);

  /// Always redacted at construction, so there is no path that formats an
  /// unredacted message.
  final String message;
  final int? status;
  final bool isRateLimit;

  @override
  String toString() => 'NetException($status): $message';
}

class _MemoryEtagCache implements EtagCache {
  final Map<String, String> _etags = {};
  final Map<String, String> _bodies = {};

  @override
  String? etagFor(String url) => _etags[url];

  @override
  String? cachedBody(String url) => _bodies[url];

  @override
  void putCache(String url, String? etag, String body) {
    if (etag != null) _etags[url] = etag;
    _bodies[url] = body;
  }
}

class Net {
  Net({
    http.Client? client,
    this.concurrency = 8,
    EtagCache? cache,
    this.requestTimeout = defaultRequestTimeout,
  }) : _client = client ?? http.Client(),
       _cache = cache ?? _MemoryEtagCache();

  /// Ceiling on a single registry request.
  ///
  /// Generous rather than tight: a cold pub.dev or a large Atom feed on a slow
  /// link is normal, and turning that into a spurious per-watch error would be
  /// worse than waiting. It exists to bound a hang, not to enforce latency.
  static const Duration defaultRequestTimeout = Duration(seconds: 30);

  final Duration requestTimeout;

  final http.Client _client;
  final int concurrency;
  final EtagCache _cache;

  var _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<void> _acquire() {
    if (_active < concurrency) {
      _active++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }

  Future<NetResponse> get(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    await _acquire();
    try {
      final key = url.toString();
      final cachedEtag = _cache.etagFor(key);
      final sent = {
        'User-Agent': userAgent,
        ...headers,
        if (cachedEtag != null) 'If-None-Match': cachedEtag,
      };

      final http.Response response;
      try {
        // A registry that accepts the connection and then never answers —
        // captive portal, half-open NAT mapping, wedged proxy — would
        // otherwise park this worker forever. That is worse than a slow
        // refresh: refreshAll awaits every worker, so one dead socket means
        // the whole refresh never returns, the rate-limit stop never takes
        // effect, and the UI's in-progress state never clears. Landing it in
        // the per-watch catch instead records the failure on that watch and
        // lets the rest finish.
        response = await _client
            .get(url, headers: sent)
            .timeout(
              requestTimeout,
              onTimeout: () => throw NetException(
                '${url.host}: no response within '
                '${requestTimeout.inSeconds}s',
              ),
            );
      } on http.ClientException catch (e) {
        throw NetException('${url.host}: ${e.message}');
      } on Exception catch (e) {
        throw NetException('${url.host}: $e');
      }

      if (response.statusCode == 304) {
        final cachedBody = _cache.cachedBody(key);
        if (cachedBody != null) {
          return NetResponse(status: 304, body: cachedBody, notModified: true);
        }
        // A 304 with no matching cache entry is a protocol violation: we
        // never sent (or no longer hold) an If-None-Match this server could
        // legitimately be answering against. Treating it as a normal
        // response would return an empty body indistinguishable from a real
        // empty payload, and if this response also carries an etag, letting
        // it fall through to the cache write below would persist that empty
        // body — every later conditional request would then replay '' as
        // though it were the real payload (e.g. a package's version list
        // silently becoming empty).
        throw NetException(
          '${url.host} returned 304 with no matching cache entry',
          status: 304,
        );
      }

      if (response.statusCode >= 400) {
        final remaining = response.headers['x-ratelimit-remaining'];
        throw NetException(
          '${url.host} returned ${response.statusCode}: ${response.body}',
          status: response.statusCode,
          isRateLimit: response.statusCode == 429 || remaining == '0',
        );
      }

      // Never persist a response fetched with credentials: http_cache.body is
      // an unconstrained value store, and caching an authenticated response
      // would leak private data to disk outside the keyring.
      final etag = response.headers['etag'];
      final hasAuth = sent.keys.any((k) => k.toLowerCase() == 'authorization');
      // Defensive: an empty body must never become a cache entry under any
      // circumstances, since a later 304 replaying it would be
      // indistinguishable from a real, empty payload. On this path
      // (statusCode < 400, i.e. normally 200) a genuinely empty body from a
      // well-behaved server is not expected, but nothing prevents a
      // misbehaving one from sending it, so the guard costs nothing to keep.
      if (etag != null && !hasAuth && response.body.isNotEmpty) {
        _cache.putCache(key, etag, response.body);
      }
      return NetResponse(status: response.statusCode, body: response.body);
    } finally {
      _release();
    }
  }

  void close() => _client.close();
}
