import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mcp_sse_server/mcp_sse_server.dart' as mcp;

import '../paths.dart';
import '../redact.dart';

/// Single endpoint for the Streamable HTTP transport.
const String mcpPath = '/mcp';

/// How long a session may sit idle before it is dropped.
///
/// `package:mcp_sse_server`'s own `McpHttpServer` expires idle sessions; this
/// server cannot use it (see [McpTransport]), so the timeout is reimplemented
/// here. Without it an agent that exits without sending DELETE would leak its
/// session — and with it the tool closures over the [Store] — until app exit.
const Duration mcpSessionIdleTimeout = Duration(minutes: 30);

/// Sessions allowed at once, past which new ones are refused.
///
/// A local agent needs one. The cap exists so a client looping on `initialize`
/// cannot exhaust memory; it is not a security control, since reaching this
/// code already requires the bearer token.
const int mcpMaxSessions = 8;

const int _invalidRequest = -32600;

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

/// One MCP session: a server instance and the transport feeding it.
class _Session {
  _Session(this.server, this.transport);

  final mcp.McpServer server;
  final mcp.SseTransport transport;
  Timer? idle;

  Future<void> close() async {
    idle?.cancel();
    idle = null;
    await server.close();
    await transport.close();
  }
}

/// The authenticating front door for the MCP server.
///
/// `package:mcp_sse_server` owns the protocol and the SSE framing, but its
/// `McpHttpServer` binds its own socket and has no authorization hook — its
/// docs are explicit that Origin checking is "rebinding control, never
/// authorization". Since any page in any browser can POST to loopback, the
/// bearer token is the only thing actually gating this server, so the socket
/// and the auth check stay here and the package is driven through the
/// [mcp.SseTransport] it exposes for exactly this purpose.
class McpTransport {
  McpTransport({
    required mcp.McpServer Function() onSession,
    required String bearerToken,
    this.requestedPort = 0,
    this.idleTimeout = mcpSessionIdleTimeout,
  }) : // Fields are private so nothing outside this file can read the token
       // back out; that makes an initializing formal (which would require a
       // public `bearerToken` field) unavailable here.
       // ignore: prefer_initializing_formals
       _onSession = onSession,
       // ignore: prefer_initializing_formals
       _bearerToken = bearerToken;

  final mcp.McpServer Function() _onSession;
  final String _bearerToken;
  final int requestedPort;
  final Duration idleTimeout;

  HttpServer? _http;
  final Map<String, _Session> _sessions = {};
  final Random _rng = Random.secure();

  int? get port => _http?.port;

  /// Live session ids. Exposed for tests and the settings pane; the ids are
  /// not secrets on their own, since every request still needs the token.
  Iterable<String> get sessionIds => List.unmodifiable(_sessions.keys);

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

    // SSE keep-alives are the transport's job now: mcp.SseTransport sends a
    // heartbeat on its own schedule, so the timer that used to live here would
    // only duplicate it.
    return server.port;
  }

  Future<void> stop() async {
    for (final session in _sessions.values.toList()) {
      try {
        await session.close();
      } catch (_) {
        // Client already gone; closing the socket below covers it.
      }
    }
    _sessions.clear();
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
          await _handleDelete(request, response);
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

  /// Parsing, framing, and dispatch all belong to the package; what this
  /// method owns is deciding which session a request belongs to, and creating
  /// one when a client says `initialize`.
  Future<void> _handlePost(HttpRequest request, HttpResponse response) async {
    // The same ceiling SseTransport applies to the bodies it reads itself, so
    // a request is not accepted here only to be rejected one layer down.
    final message = await mcp.readJsonRpcPost(
      request,
      maxBytes: mcp.SseTransport.defaultMaxRequestBytes,
    );
    // A null message means readJsonRpcPost already answered — malformed JSON,
    // an oversized body, a read timeout. Writing again would corrupt it.
    if (message == null) return;

    final existing = _session(request);
    if (existing != null) {
      _touch(existing);
      await existing.transport.handlePost(request, message: message);
      return;
    }

    if (request.headers.value(mcp.sessionIdHeader) != null) {
      // A named session we do not have: expired, or from a previous run of the
      // app. Saying so lets the client start a new one instead of retrying.
      await _rpcError(
        response,
        HttpStatus.notFound,
        message,
        'unknown or expired session; send initialize to start a new one',
      );
      return;
    }

    final isInitialize =
        message is mcp.JsonRpcRequest &&
        message.method == mcp.McpMethods.initialize;
    if (!isInitialize) {
      await _rpcError(
        response,
        HttpStatus.badRequest,
        message,
        'no session; send initialize first',
      );
      return;
    }

    if (_sessions.length >= mcpMaxSessions) {
      await _rpcError(
        response,
        HttpStatus.serviceUnavailable,
        message,
        'too many concurrent MCP sessions',
      );
      return;
    }

    final session = await _openSession();
    await session.transport.handlePost(request, message: message);
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

    final session = _session(request);
    if (session == null) {
      await _plain(
        response,
        HttpStatus.notFound,
        'unknown or expired session; send initialize first',
      );
      return;
    }

    // The stream outlives this call, so the idle timer is stamped on open and
    // then again by whatever requests follow.
    _touch(session);
    await session.transport.handleGet(request);
  }

  Future<void> _handleDelete(HttpRequest request, HttpResponse response) async {
    final id = request.headers.value(mcp.sessionIdHeader);
    final session = id == null ? null : _sessions.remove(id);
    // Idempotent: deleting an already-gone session is a success, so a client
    // that retries its shutdown does not have to special-case the second try.
    await session?.close();
    response.statusCode = HttpStatus.noContent;
    await response.close();
  }

  _Session? _session(HttpRequest request) {
    final id = request.headers.value(mcp.sessionIdHeader);
    return id == null ? null : _sessions[id];
  }

  Future<_Session> _openSession() async {
    // 18 bytes from a CSPRNG: the id is a bearer of session state, and a
    // guessable one would let one authenticated client hijack another's.
    final id = base64Url.encode(
      List<int>.generate(18, (_) => _rng.nextInt(256)),
    );
    final transport = mcp.SseTransport(sessionId: id);
    final server = _onSession();
    await server.connect(transport);

    final session = _Session(server, transport);
    _sessions[id] = session;
    _touch(session);

    // The client may vanish without a DELETE; when the transport notices, drop
    // the session rather than leaving it to the idle timer.
    unawaited(
      transport.done.then((_) => _drop(id)).catchError((_) => _drop(id)),
    );
    return session;
  }

  void _touch(_Session session) {
    session.idle?.cancel();
    session.idle = Timer(idleTimeout, () {
      final id = _sessions.entries
          .where((e) => identical(e.value, session))
          .map((e) => e.key)
          .firstOrNull;
      if (id != null) _drop(id);
    });
  }

  void _drop(String id) {
    final session = _sessions.remove(id);
    unawaited(session?.close().catchError((_) {}));
  }

  /// Answers a request with a JSON-RPC error carrying the caller's own id, so
  /// a client correlating replies is not left waiting on a request it can no
  /// longer match.
  Future<void> _rpcError(
    HttpResponse response,
    int status,
    mcp.JsonRpcMessage message,
    String detail,
  ) async {
    await _json(response, status, {
      'jsonrpc': '2.0',
      'id': message is mcp.JsonRpcRequest ? message.id : null,
      'error': {'code': _invalidRequest, 'message': redact(detail)},
    });
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
