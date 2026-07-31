import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../paths.dart';
import '../redact.dart';
import 'protocol.dart';

/// Single endpoint for the Streamable HTTP transport.
const String mcpPath = '/mcp';

const int _parseError = -32700;

/// Only loopback origins may talk to this server.
///
/// A page on any website can POST to 127.0.0.1, and DNS rebinding lets an
/// attacker-controlled hostname resolve to loopback — which is why the MCP
/// spec makes Origin validation mandatory for local HTTP servers. A missing
/// Origin is allowed because native clients do not send one; browsers always
/// do.
bool isAllowedOrigin(String? origin) {
  if (origin == null) return true;
  final uri = Uri.tryParse(origin);
  if (uri == null) return false;
  final host = uri.host;
  // Compared exactly: `localhost.evil.com` must not pass a prefix check.
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

/// Compares two strings without leaking their common prefix length through
/// timing. Length differences are unavoidable and not sensitive here.
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var mismatch = 0;
  for (var i = 0; i < a.length; i++) {
    mismatch |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return mismatch == 0;
}

/// Writes the port so clients can find the server. Deliberately never the
/// token: the spec keeps every secret in the host keyring, and the settings
/// pane is the only place to read it.
///
/// The path is [mcpDiscoveryPath] from `lib/paths.dart`, which already knows
/// how the three desktop platforms disagree about where app files belong —
/// `env`/`platform` are threaded through rather than rebuilding that logic
/// here, so tests can point it at a temp directory.
Future<File> writeDiscoveryFile(
  int port, {
  Map<String, String>? env,
  String? platform,
}) async {
  final path = mcpDiscoveryPath(env: env, platform: platform);
  final dir = File(path).parent;
  ensureDir(dir.path);
  final file = File(path);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'port': port, 'url': 'http://127.0.0.1:$port$mcpPath'})}\n',
  );
  return file;
}

class McpTransport {
  McpTransport({
    required McpServer server,
    required String bearerToken,
    this.requestedPort = 0,
  }) : // Fields are private so nothing outside this file can read the token
       // back out; that makes an initializing formal (which would require a
       // public `server`/`bearerToken` field) unavailable here.
       // ignore: prefer_initializing_formals
       _server = server,
       // ignore: prefer_initializing_formals
       _bearerToken = bearerToken;

  final McpServer _server;
  final String _bearerToken;
  final int requestedPort;

  HttpServer? _http;
  final Set<HttpResponse> _streams = {};
  Timer? _keepAlive;

  int? get port => _http?.port;

  Uri get endpoint => Uri.parse('http://127.0.0.1:${port ?? 0}$mcpPath');

  Future<int> start() async {
    // Loopback only. InternetAddress.anyIPv4 would expose the tracker — and
    // through it the ability to mutate the watchlist — to the whole network.
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      requestedPort,
    );
    _http = server;
    server.listen(_handle, onError: (_) {});

    // SSE connections through a proxy or a sleeping laptop die silently
    // without traffic; a comment line every 30s keeps them detectably alive.
    _keepAlive = Timer.periodic(const Duration(seconds: 30), (_) {
      for (final s in _streams.toList()) {
        try {
          s.write(': keep-alive\n\n');
        } catch (_) {
          _streams.remove(s);
        }
      }
    });

    return server.port;
  }

  Future<void> stop() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    for (final s in _streams.toList()) {
      try {
        await s.close();
      } catch (_) {
        // Client already gone.
      }
    }
    _streams.clear();
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!isAllowedOrigin(request.headers.value('origin'))) {
        await _plain(response, HttpStatus.forbidden, 'origin not allowed');
        return;
      }

      // Auth is checked before the path and before any body is read, so an
      // unauthenticated caller cannot reach the protocol layer or learn which
      // paths exist.
      final auth = request.headers.value('authorization') ?? '';
      const prefix = 'Bearer ';
      final presented = auth.startsWith(prefix)
          ? auth.substring(prefix.length)
          : '';
      if (!constantTimeEquals(presented, _bearerToken)) {
        await _plain(response, HttpStatus.unauthorized, 'invalid bearer token');
        return;
      }

      if (request.uri.path != mcpPath) {
        await _plain(response, HttpStatus.notFound, 'not found');
        return;
      }

      switch (request.method) {
        case 'POST':
          await _handlePost(request, response);
        case 'GET':
          await _handleGet(request, response);
        case 'DELETE':
          response.statusCode = HttpStatus.noContent;
          await response.close();
        default:
          await _plain(
            response,
            HttpStatus.methodNotAllowed,
            'method not allowed',
          );
      }
    } catch (e) {
      try {
        await _plain(
          response,
          HttpStatus.internalServerError,
          redact(e.toString()),
        );
      } catch (_) {
        // Response already committed.
      }
    }
  }

  Future<void> _handlePost(HttpRequest request, HttpResponse response) async {
    final body = await utf8.decoder.bind(request).join();

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      await _json(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': _parseError, 'message': 'parse error: ${e.message}'},
      });
      return;
    }

    if (decoded is! Map) {
      // Batching is legal JSON-RPC but not something this server implements;
      // half-handling a batch would silently drop messages.
      await _json(response, HttpStatus.badRequest, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {
          'code': _parseError,
          'message':
              'expected a single JSON-RPC object; batches are not supported',
        },
      });
      return;
    }

    final reply = await _server.handle(Map<String, Object?>.from(decoded));

    if (reply == null) {
      // Notification: accepted, nothing to say.
      response.statusCode = HttpStatus.accepted;
      await response.close();
      return;
    }

    await _json(response, HttpStatus.ok, reply);
  }

  Future<void> _handleGet(HttpRequest request, HttpResponse response) async {
    final accept = request.headers.value('accept') ?? '';
    if (!accept.contains('text/event-stream')) {
      await _plain(
        response,
        HttpStatus.methodNotAllowed,
        'GET requires Accept: text/event-stream',
      );
      return;
    }

    response.statusCode = HttpStatus.ok;
    response.headers
      ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..set('Cache-Control', 'no-cache')
      ..set('Connection', 'keep-alive');
    // Chunked transfer with no Content-Length: the stream stays open.
    response.bufferOutput = false;
    response.write(': connected\n\n');
    _streams.add(response);

    // This server initiates nothing, so the stream carries only keep-alives.
    // It exists because the transport requires the endpoint to accept GET.
    unawaited(response.done.whenComplete(() => _streams.remove(response)));
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _plain(HttpResponse response, int status, String message) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    // redact() rather than interpolating freely: this path formats exception
    // text, and the expected token must never appear in a rejection body.
    response.write(redact(message));
    await response.close();
  }
}
