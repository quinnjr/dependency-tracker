import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api_keys.dart';
import '../bootstrap/app_resources.dart';
import '../models.dart';
import '../notify.dart';
import '../refresh.dart';
import '../store.dart';

/// The browser's half of the sync protocol: keeps an in-memory mirror
/// [Store] hydrated from `GET /api/snapshot`, and turns UI mutations into
/// REST calls whose response snapshot is applied back — so the server stays
/// authoritative and the widgets keep their synchronous reads.
///
/// Session handling: the access JWT lives in this object (page memory
/// only); a 401 triggers exactly one `auth/refresh` (the HttpOnly cookie
/// rides along automatically in a browser) and a retry before giving up to
/// the login screen.
class SyncClient implements AuthController {
  SyncClient(this.base, this.mirror, {http.Client? client})
    : _http = client ?? http.Client();

  final Uri base;
  final Store mirror;
  final http.Client _http;

  /// The last failed round trip, for the shell's banner. Null when clear.
  final ValueCell<String?> syncError = ValueCell(null);

  String? _jwt;
  String? _username;
  String? _role;
  bool _zeroUsers = false;
  bool _registrationOpen = true;

  @override
  final StoreListenable changes = StoreListenable();

  @override
  bool get authenticated => _jwt != null;
  @override
  String? get username => _username;
  @override
  String? get role => _role;
  @override
  bool get zeroUsers => _zeroUsers;
  @override
  bool get registrationOpen => _registrationOpen;

  // --- session -----------------------------------------------------------------

  /// Loads `/api/status` and, when the cookie allows it, silently resumes
  /// the previous session — a revisit within the refresh window is one
  /// round trip, not a password prompt.
  Future<void> initialize() async {
    await refreshStatus();
    final r = await _http.post(base.resolve('api/auth/refresh'));
    if (r.statusCode == 200) {
      _adoptSession(jsonDecode(r.body) as Map);
      await hydrate();
    }
    changes.notifyListeners();
  }

  Future<void> refreshStatus() async {
    final r = await _http.get(base.resolve('api/status'));
    if (r.statusCode == 200) {
      final status = jsonDecode(r.body) as Map;
      _zeroUsers = status['users'] == 0;
      _registrationOpen = status['registrationOpen'] == true;
    }
  }

  Future<bool> githubTokenSet() async {
    final r = await _http.get(base.resolve('api/status'));
    return r.statusCode == 200 &&
        (jsonDecode(r.body) as Map)['githubTokenSet'] == true;
  }

  @override
  Future<String?> login(String username, String password) =>
      _credentialCall('api/auth/login', username, password);

  @override
  Future<String?> register(String username, String password) =>
      _credentialCall('api/auth/register', username, password);

  Future<String?> _credentialCall(
    String path,
    String username,
    String password,
  ) async {
    final r = await _http.post(
      base.resolve(path),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (r.statusCode != 200) {
      final body = _tryJson(r.body);
      return '${body?['error'] ?? 'sign-in failed (${r.statusCode})'}';
    }
    _adoptSession(jsonDecode(r.body) as Map);
    _username = username.trim().toLowerCase();
    await hydrate();
    await refreshStatus();
    changes.notifyListeners();
    return null;
  }

  @override
  Future<void> logout() async {
    await _http.post(base.resolve('api/auth/logout'));
    _jwt = null;
    _username = null;
    _role = null;
    await refreshStatus();
    changes.notifyListeners();
  }

  @override
  Future<void> setRegistrationOpen(bool open) async {
    await _send('PUT', 'api/auth/registration', body: {'enabled': open});
    _registrationOpen = open;
    changes.notifyListeners();
  }

  void _adoptSession(Map<dynamic, dynamic> body) {
    _jwt = body['accessToken'] as String?;
    _role = body['role'] as String?;
    // The server does not echo the username back; _credentialCall records
    // what the form submitted. A cookie-resumed session has no form, so the
    // account section may show no name until the next explicit login.
  }

  // --- data --------------------------------------------------------------------

  Future<void> hydrate() async {
    final body = await _send('GET', 'api/snapshot');
    final snapshot = body?['snapshot'];
    if (snapshot is Map) {
      mirror.importSnapshot(snapshot.cast<String, Object?>());
    }
  }

  Future<RefreshReport> refresh(int? watchId) async {
    final body = await _send(
      'POST',
      'api/refresh',
      body: {if (watchId != null) 'watchId': watchId},
      orThrow: true,
    );
    _applySnapshot(body);
    final report = (body!['report'] as Map).cast<String, Object?>();
    return RefreshReport(
      refreshed: report['refreshed'] as int? ?? 0,
      failed: report['failed'] as int? ?? 0,
      newReleases: report['newReleases'] as int? ?? 0,
      rateLimited: report['rateLimited'] as bool? ?? false,
      staleMarkingFailed: report['staleMarkingFailed'] as bool? ?? false,
    );
  }

  Future<ScanResult> scan() async {
    final body = await _send('POST', 'api/scan', orThrow: true);
    _applySnapshot(body);
    final result = (body!['result'] as Map).cast<String, Object?>();
    return ScanResult(
      projectsScanned: result['projectsScanned'] as int? ?? 0,
      depsFound: result['depsFound'] as int? ?? 0,
      errors: (result['errors'] as List? ?? const []).cast<String>(),
    );
  }

  /// The [StoreMutations] wiring: fire the REST call, apply the returned
  /// snapshot; failures land in [syncError] instead of throwing into a
  /// void-returning widget callback.
  StoreMutations get mutations => StoreMutations(
    markRead: (id, {version}) => _mutate(
      'POST',
      'api/watches/$id/read',
      body: {if (version != null) 'version': version},
    ),
    snooze: (id, until) => _mutate(
      'POST',
      'api/watches/$id/snooze',
      body: {'until': until.toUtc().toIso8601String()},
    ),
    addScanRoot: (path) =>
        _mutate('POST', 'api/scan-roots', body: {'path': path}),
    removeScanRoot: (path) =>
        _mutate('DELETE', 'api/scan-roots', body: {'path': path}),
  );

  McpKeyOps get mcpKeys => McpKeyOps(
    list: () async {
      final body = await _send('GET', 'api/mcp-keys', orThrow: true);
      return [
        for (final k in (body!['keys'] as List).cast<Map>())
          ApiKeyInfo(
            id: k['id'] as int,
            name: k['name'] as String,
            createdAt: DateTime.parse(k['createdAt'] as String),
            lastUsedAt: k['lastUsedAt'] == null
                ? null
                : DateTime.parse(k['lastUsedAt'] as String),
          ),
      ];
    },
    create: (name) async {
      final body = await _send(
        'POST',
        'api/mcp-keys',
        body: {'name': name},
        orThrow: true,
      );
      return MintedKey(
        id: body!['id'] as int,
        name: body['name'] as String,
        key: body['key'] as String,
      );
    },
    revoke: (id) async => _send('DELETE', 'api/mcp-keys/$id', orThrow: true),
  );

  Future<void> putGithubToken(String? token) async {
    await _send(
      'PUT',
      'api/secrets/github-token',
      body: {'token': token},
      orThrow: true,
    );
  }

  void _mutate(String method, String path, {Object? body}) {
    _send(method, path, body: body).then((response) {
      _applySnapshot(response);
    });
  }

  void _applySnapshot(Map<String, Object?>? body) {
    final snapshot = body?['snapshot'];
    if (snapshot is Map) {
      mirror.importSnapshot(snapshot.cast<String, Object?>());
    }
  }

  /// One request with the standing JWT; on a 401, one silent refresh and
  /// one retry. Returns the decoded JSON body (empty map for 204), or null
  /// after recording the failure in [syncError] — unless [orThrow], for
  /// callers (refresh, scan) whose UI already renders errors itself.
  Future<Map<String, Object?>?> _send(
    String method,
    String path, {
    Object? body,
    bool orThrow = false,
    bool retried = false,
  }) async {
    final request = http.Request(method, base.resolve(path));
    request.headers['content-type'] = 'application/json';
    if (_jwt != null) request.headers['authorization'] = 'Bearer $_jwt';
    if (body != null) request.body = jsonEncode(body);
    final r = await http.Response.fromStream(await _http.send(request));

    if (r.statusCode == 401 && !retried) {
      final refreshed = await _http.post(base.resolve('api/auth/refresh'));
      if (refreshed.statusCode == 200) {
        _adoptSession(jsonDecode(refreshed.body) as Map);
        return _send(method, path, body: body, orThrow: orThrow, retried: true);
      }
      // The session is genuinely over; the gate widget listens for this.
      _jwt = null;
      changes.notifyListeners();
    }

    if (r.statusCode >= 200 && r.statusCode < 300) {
      syncError.value = null;
      if (r.body.isEmpty) return const {};
      final decoded = _tryJson(r.body);
      return decoded?.cast<String, Object?>() ?? const {};
    }

    final message =
        '${_tryJson(r.body)?['error'] ?? 'request failed'} (${r.statusCode})';
    if (orThrow) throw Exception(message);
    syncError.value = message;
    return null;
  }

  Map<dynamic, dynamic>? _tryJson(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
