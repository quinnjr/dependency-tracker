import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show SqliteException;

import '../api_keys.dart';
import '../mcp/transport.dart';
import '../models.dart';
import '../redact.dart';
import '../refresh.dart';
import '../secrets.dart';
import '../store.dart';
import 'auth.dart';

/// Name of the refresh-token cookie. Scoped to the auth endpoints only, so
/// it never rides along on data requests where nothing reads it.
const String refreshCookieName = 'dt_refresh';

const int _maxBodyBytes = 1024 * 1024;

/// The gateway: one listener serving the REST API under `/api`, the MCP
/// transport at [mcpPath], and the built Flutter frontend for everything
/// else.
///
/// Unlike the desktop [McpTransport], this binds any-IPv4 by default — a
/// gateway exists to be reached over the network; keeping it loopback-only
/// is the reverse proxy operator's choice via [bindAddress].
class AppServer {
  AppServer({
    required this.store,
    required this.auth,
    required this.secrets,
    required Future<RefreshReport> Function(int? watchId) refresh,
    required Future<ScanResult> Function() scan,
    required this.mcp,
    required this.webRoot,
    this.requestedPort = 0,
    InternetAddress? bindAddress,
    // ignore: prefer_initializing_formals
  }) : _refresh = refresh,
       // ignore: prefer_initializing_formals
       _scan = scan,
       bind = bindAddress ?? InternetAddress.anyIPv4;

  final Store store;
  final Auth auth;
  final Secrets secrets;
  final Future<RefreshReport> Function(int? watchId) _refresh;
  final Future<ScanResult> Function() _scan;
  final McpTransport mcp;
  final String webRoot;
  final int requestedPort;
  final InternetAddress bind;

  HttpServer? _http;

  int? get port => _http?.port;

  Future<int> start() async {
    final server = await HttpServer.bind(bind, requestedPort);
    _http = server;
    server.listen(_handle, onError: (_) {});
    return server.port;
  }

  Future<void> stop() async {
    await mcp.stop();
    await _http?.close(force: true);
    _http = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      if (path == mcpPath) {
        // The transport owns its whole pipeline, auth included: an MCP API
        // key and a browser JWT are different credentials on purpose.
        await mcp.handleRequest(request);
        return;
      }
      if (path == '/api' || path.startsWith('/api/')) {
        await _api(request, response);
        return;
      }
      await _static(request, response);
    } catch (e) {
      try {
        await _json(response, HttpStatus.internalServerError, {
          'error': redact(e.toString()),
        });
      } catch (_) {
        // Response already committed.
      }
    }
  }

  // --- REST --------------------------------------------------------------------

  Future<void> _api(HttpRequest request, HttpResponse response) async {
    final segments = request.uri.pathSegments; // ['api', ...]
    final route = segments.length > 1 ? segments.sublist(1) : const <String>[];

    if (route.isNotEmpty && route.first == 'auth') {
      await _auth(request, response, route.sublist(1));
      return;
    }

    if (route.length == 1 &&
        route.first == 'status' &&
        request.method == 'GET') {
      await _json(response, HttpStatus.ok, {
        'users': store.userCount(),
        'registrationOpen': auth.registrationOpen,
        'githubTokenSet': (await secrets.githubToken()) != null,
        'mcpPath': mcpPath,
      });
      return;
    }

    // Everything else under /api requires a live access JWT — including the
    // snapshot: the watchlist is the product, not public metadata.
    final claims = _bearerClaims(request);
    if (claims == null) {
      await _json(response, HttpStatus.unauthorized, {
        'error': 'a valid access token is required',
      });
      return;
    }

    switch ((request.method, route)) {
      case ('GET', ['snapshot']):
        final ifNoneMatch = request.headers.value('if-none-match');
        if (ifNoneMatch != null && ifNoneMatch == '${store.revision()}') {
          response.statusCode = HttpStatus.notModified;
          await response.close();
          return;
        }
        await _json(response, HttpStatus.ok, {
          'snapshot': store.exportSnapshot(),
        });

      case ('POST', ['watches']):
        final body = await _body(request);
        final kindName = body['kind'];
        final name = body['name'];
        final kind = WatchKind.values
            .where((k) => k.name == kindName)
            .firstOrNull;
        if (kind == null || name is! String || name.trim().isEmpty) {
          await _badRequest(response, 'kind and name are required');
          return;
        }
        final id = store.upsertWatch(kind, name.trim());
        await _mutated(response, extra: {'id': id});

      case ('DELETE', ['watches', final idText]):
        final id = _requireWatch(idText);
        if (id == null) {
          await _notFound(response);
          return;
        }
        store.removeWatch(id);
        await _mutated(response);

      case ('POST', ['watches', final idText, 'snooze']):
        final id = _requireWatch(idText);
        if (id == null) {
          await _notFound(response);
          return;
        }
        final until = DateTime.tryParse('${(await _body(request))['until']}');
        if (until == null) {
          await _badRequest(response, 'until must be an ISO-8601 timestamp');
          return;
        }
        store.snooze(id, until);
        await _mutated(response);

      case ('POST', ['watches', final idText, 'read']):
        final id = _requireWatch(idText);
        if (id == null) {
          await _notFound(response);
          return;
        }
        final version = (await _body(request))['version'];
        store.markRead(id, version: version is String ? version : null);
        await _mutated(response);

      case ('POST', ['refresh']):
        final watchId = (await _body(request))['watchId'];
        final report = await _refresh(watchId is int ? watchId : null);
        await _mutated(
          response,
          extra: {
            'report': {
              'refreshed': report.refreshed,
              'failed': report.failed,
              'newReleases': report.newReleases,
              'rateLimited': report.rateLimited,
              'staleMarkingFailed': report.staleMarkingFailed,
            },
          },
        );

      case ('POST', ['scan']):
        if (!_requireAdmin(claims, response)) return;
        final result = await _scan();
        await _mutated(
          response,
          extra: {
            'result': {
              'projectsScanned': result.projectsScanned,
              'depsFound': result.depsFound,
              'errors': result.errors,
            },
          },
        );

      case ('POST', ['scan-roots']):
        // Scan roots are server filesystem paths and scanning walks them —
        // arbitrary-path filesystem access is an admin power, not a
        // member's shared-watchlist power.
        if (!_requireAdmin(claims, response)) return;
        final path = (await _body(request))['path'];
        if (path is! String || path.trim().isEmpty) {
          await _badRequest(response, 'path is required');
          return;
        }
        store.addScanRoot(path.trim());
        await _mutated(response);

      case ('DELETE', ['scan-roots']):
        if (!_requireAdmin(claims, response)) return;
        final path = (await _body(request))['path'];
        if (path is! String) {
          await _badRequest(response, 'path is required');
          return;
        }
        store.removeScanRoot(path);
        await _mutated(response);

      case ('PUT', ['secrets', 'github-token']):
        // The GitHub token is shared org-wide; only an admin replaces it.
        if (!_requireAdmin(claims, response)) return;
        final token = (await _body(request))['token'];
        try {
          await secrets.setGithubToken(token is String ? token : null);
        } on ArgumentError catch (e) {
          await _badRequest(response, e.message.toString());
          return;
        }
        response.statusCode = HttpStatus.noContent;
        await response.close();

      // MCP keys are persistent, server-wide agent credentials; managing
      // them is an admin power.
      case ('GET', ['mcp-keys']):
        if (!_requireAdmin(claims, response)) return;
        await _json(response, HttpStatus.ok, {
          'keys': [
            for (final k in store.apiKeys())
              {
                'id': k.id,
                'name': k.name,
                'createdAt': k.createdAt.toIso8601String(),
                'lastUsedAt': k.lastUsedAt?.toIso8601String(),
              },
          ],
        });

      case ('POST', ['mcp-keys']):
        if (!_requireAdmin(claims, response)) return;
        final name = (await _body(request))['name'];
        if (name is! String || name.trim().isEmpty) {
          await _badRequest(response, 'name is required');
          return;
        }
        final MintedKey minted;
        try {
          minted = mintApiKey(store, name.trim());
        } on SqliteException {
          // A duplicate name violates UNIQUE(api_key.name); answer a clean
          // 409 rather than letting SQL text escape through the 500 path.
          await _json(response, HttpStatus.conflict, {
            'error': 'a key named "${name.trim()}" already exists',
          });
          return;
        }
        // The one time the key crosses the wire; only its hash survives
        // server-side, so this response is the caller's only copy.
        await _json(response, HttpStatus.ok, {
          'id': minted.id,
          'name': minted.name,
          'key': minted.key,
        });

      case ('DELETE', ['mcp-keys', final idText]):
        if (!_requireAdmin(claims, response)) return;
        final id = int.tryParse(idText);
        if (id == null) {
          await _notFound(response);
          return;
        }
        store.revokeApiKey(id);
        response.statusCode = HttpStatus.noContent;
        await response.close();

      default:
        await _notFound(response);
    }
  }

  /// Answers 403 and returns false unless [claims] carries the admin role.
  bool _requireAdmin(Map<String, Object?> claims, HttpResponse response) {
    if (claims['role'] == 'admin') return true;
    _json(response, HttpStatus.forbidden, {'error': 'admin only'});
    return false;
  }

  Future<void> _auth(
    HttpRequest request,
    HttpResponse response,
    List<String> route,
  ) async {
    // DNS-rebinding/CSRF guard for the endpoints the refresh cookie rides
    // on: a browser attaches Origin to cross-site POSTs, and one that does
    // not match the host this server answers as is not our frontend.
    if (!_sameOriginOrAbsent(request)) {
      await _json(response, HttpStatus.forbidden, {
        'error': 'origin not allowed',
      });
      return;
    }
    if (request.method != 'POST' &&
        !(request.method == 'PUT' && route.firstOrNull == 'registration')) {
      await _notFound(response);
      return;
    }

    switch (route) {
      case ['register']:
        final body = await _body(request);
        try {
          final result = await auth.register(
            '${body['username'] ?? ''}',
            '${body['password'] ?? ''}',
          );
          await _session(request, response, result!);
        } on RegistrationClosed {
          await _json(response, HttpStatus.forbidden, {
            'error': 'registration is closed',
          });
        } on UsernameTaken {
          await _json(response, HttpStatus.conflict, {
            'error': 'that username is taken',
          });
        } on ArgumentError catch (e) {
          await _badRequest(response, e.message.toString());
        }

      case ['login']:
        final body = await _body(request);
        final result = await auth.login(
          '${body['username'] ?? ''}',
          '${body['password'] ?? ''}',
        );
        if (result == null) {
          await _json(response, HttpStatus.unauthorized, {
            'error': 'invalid credentials',
          });
          return;
        }
        await _session(request, response, result);

      case ['refresh']:
        final presented = _refreshCookie(request);
        final result = presented == null ? null : auth.refresh(presented);
        if (result == null) {
          await _json(response, HttpStatus.unauthorized, {
            'error': 'refresh token invalid or expired',
          });
          return;
        }
        await _session(request, response, result);

      case ['logout']:
        final presented = _refreshCookie(request);
        if (presented != null) auth.logout(presented);
        response.headers.add('set-cookie', _clearCookie(request));
        response.statusCode = HttpStatus.noContent;
        await response.close();

      case ['registration']:
        final claims = _bearerClaims(request);
        if (claims == null) {
          await _json(response, HttpStatus.unauthorized, {
            'error': 'a valid access token is required',
          });
          return;
        }
        if (claims['role'] != 'admin') {
          await _json(response, HttpStatus.forbidden, {
            'error': 'only an admin may change registration',
          });
          return;
        }
        final enabled = (await _body(request))['enabled'];
        if (enabled is! bool) {
          await _badRequest(response, 'enabled must be a boolean');
          return;
        }
        auth.setRegistrationOpen(enabled, byRole: 'admin');
        response.statusCode = HttpStatus.noContent;
        await response.close();

      default:
        await _notFound(response);
    }
  }

  /// A successful register/login/refresh: access JWT in the body, rotated
  /// refresh token in the cookie.
  Future<void> _session(
    HttpRequest request,
    HttpResponse response,
    AuthResult result,
  ) async {
    response.headers.add(
      'set-cookie',
      '$refreshCookieName=${result.refreshToken}; '
          'Max-Age=${refreshTokenTtl.inSeconds}; Path=/api/auth; HttpOnly; '
          'SameSite=Strict${_secureAttr(request)}',
    );
    await _json(response, HttpStatus.ok, {
      'accessToken': result.accessJwt,
      'userId': result.userId,
      'role': result.role,
    });
  }

  String _clearCookie(HttpRequest request) =>
      '$refreshCookieName=; Max-Age=0; Path=/api/auth; HttpOnly; '
      'SameSite=Strict${_secureAttr(request)}';

  /// `; Secure` whenever the request reached us over TLS — directly, or via
  /// a terminating proxy that set `X-Forwarded-Proto: https`. Kept off for
  /// plain http so a localhost/LAN deployment without TLS still works,
  /// while any real https origin binds the 30-day token to encrypted
  /// transport.
  String _secureAttr(HttpRequest request) {
    final forwarded = request.headers
        .value('x-forwarded-proto')
        ?.split(',')
        .first
        .trim()
        .toLowerCase();
    final https =
        request.requestedUri.scheme == 'https' || forwarded == 'https';
    return https ? '; Secure' : '';
  }

  String? _refreshCookie(HttpRequest request) {
    for (final cookie in request.cookies) {
      if (cookie.name == refreshCookieName && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    }
    return null;
  }

  Map<String, Object?>? _bearerClaims(HttpRequest request) {
    final header = request.headers.value('authorization') ?? '';
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return null;
    return auth.verifyAccess(header.substring(prefix.length));
  }

  bool _sameOriginOrAbsent(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null) return true;
    final uri = Uri.tryParse(origin);
    final host = request.headers.value('host');
    if (uri == null || uri.host.isEmpty || host == null) return false;
    // Rebuild the authority exactly as a browser writes it into the Host
    // header — the port present only when it is not the scheme default —
    // and require a full match. Comparing host alone (the old fallback)
    // would accept a same-hostname, different-port Origin, defeating the
    // port dimension of the guard.
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final originAuthority = (uri.hasPort && uri.port != defaultPort)
        ? '${uri.host}:${uri.port}'
        : uri.host;
    return originAuthority == host;
  }

  int? _requireWatch(String idText) {
    final id = int.tryParse(idText);
    if (id == null || store.watchById(id) == null) return null;
    return id;
  }

  /// Every mutation answers with the fresh snapshot, so the client applies
  /// the server's authoritative state in the same round trip it changed it.
  /// The revision has already advanced inside the Store mutation itself (the
  /// one choke point REST and MCP share), so this only serializes it.
  Future<void> _mutated(
    HttpResponse response, {
    Map<String, Object?> extra = const {},
  }) async {
    await _json(response, HttpStatus.ok, {
      ...extra,
      'snapshot': store.exportSnapshot(),
    });
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) {
        throw ArgumentError('request body too large');
      }
    }
    if (bytes.isEmpty) return const {};
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map ? decoded.cast<String, Object?>() : const {};
  }

  Future<void> _badRequest(HttpResponse response, String message) =>
      _json(response, HttpStatus.badRequest, {'error': redact(message)});

  Future<void> _notFound(HttpResponse response) =>
      _json(response, HttpStatus.notFound, {'error': 'not found'});

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

  // --- static frontend ---------------------------------------------------------

  static const Map<String, String> _contentTypes = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.mjs': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.wasm': 'application/wasm',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
    '.svg': 'image/svg+xml',
    '.otf': 'font/otf',
    '.ttf': 'font/ttf',
    '.map': 'application/json',
  };

  Future<void> _static(HttpRequest request, HttpResponse response) async {
    if (request.method != 'GET') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final webRootAbs = p.absolute(webRoot);
    final rel = request.uri.path == '/'
        ? 'index.html'
        : request.uri.path.substring(1);
    final resolved = p.normalize(p.join(webRootAbs, rel));
    // Traversal guard: whatever `..` games the path plays, the resolved
    // file must still live under the web root.
    if (!p.isWithin(webRootAbs, resolved)) {
      await _notFound(response);
      return;
    }
    var file = File(resolved);
    if (!file.existsSync()) {
      // SPA fallback: unknown extensionless paths are client-side routes
      // and get the app shell; unknown assets stay honest 404s.
      if (p.extension(resolved).isEmpty) {
        file = File(p.join(webRootAbs, 'index.html'));
      }
      if (!file.existsSync()) {
        await _notFound(response);
        return;
      }
    }
    final type = _contentTypes[p.extension(file.path)];
    if (type != null) {
      response.headers.set('content-type', type);
    }
    await response.addStream(file.openRead());
    await response.close();
  }
}
