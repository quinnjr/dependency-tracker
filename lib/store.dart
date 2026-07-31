import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import 'canonicalize.dart';
import 'models.dart';
import 'net.dart';
import 'versions.dart';

const _schemaVersion = 1;

/// Narrows [Store.watches] to a subset the UI or an agent cares about.
enum WatchFilter { all, unread, outdated }

/// Batched result of [Store.countsFor]: unread release count and usage
/// count per watch id. An id with no entry in a map has a count of zero
/// for that map.
class WatchCounts {
  const WatchCounts({required this.unread, required this.usages});

  final Map<int, int> unread;
  final Map<int, int> usages;
}

/// The only mutable state in the app. Both the UI and the MCP server hold a
/// reference to one instance, which is why an agent calling `add_watch` shows up
/// in the open window with no extra plumbing.
class Store extends ChangeNotifier implements EtagCache {
  Store._(this._db);

  final Database _db;
  bool _closed = false;

  static Store open(String file) {
    final db = sqlite3.open(file);
    final store = Store._(db);
    store._migrate();
    return store;
  }

  static Store openInMemory() {
    final store = Store._(sqlite3.openInMemory());
    store._migrate();
    return store;
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  void _migrate() {
    // ON DELETE CASCADE is inert unless foreign keys are switched on per
    // connection, which SQLite leaves off by default.
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS watch (
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        display_name TEXT NOT NULL,
        repo_url TEXT,
        last_seen_version TEXT,
        last_checked_at INTEGER,
        last_error TEXT,
        snoozed_until INTEGER,
        UNIQUE(kind, name)
      );
      CREATE TABLE IF NOT EXISTS usage (
        watch_id INTEGER NOT NULL REFERENCES watch(id) ON DELETE CASCADE,
        project_path TEXT NOT NULL,
        manifest_file TEXT NOT NULL,
        pinned_version TEXT NOT NULL,
        is_resolved INTEGER NOT NULL,
        is_dev_dep INTEGER NOT NULL,
        UNIQUE(watch_id, project_path, manifest_file)
      );
      CREATE TABLE IF NOT EXISTS scan_root (
        path TEXT PRIMARY KEY
      );
      CREATE TABLE IF NOT EXISTS release (
        id INTEGER PRIMARY KEY,
        watch_id INTEGER NOT NULL REFERENCES watch(id) ON DELETE CASCADE,
        version TEXT NOT NULL,
        published_at INTEGER,
        notes_md TEXT,
        url TEXT,
        read INTEGER NOT NULL DEFAULT 0,
        UNIQUE(watch_id, version)
      );
      CREATE TABLE IF NOT EXISTS http_cache (
        url TEXT PRIMARY KEY,
        etag TEXT,
        body TEXT NOT NULL,
        fetched_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS usage_by_project ON usage(project_path);
      CREATE INDEX IF NOT EXISTS release_by_watch ON release(watch_id);
    ''');
    metaSet('schema_version', '$_schemaVersion');
  }

  static int _epoch(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;

  /// Splits [items] into chunks of at most [size] elements, preserving
  /// order. Exists because every batched query below binds one placeholder
  /// per id in an `IN (...)` clause, and SQLite's `SQLITE_LIMIT_VARIABLE_NUMBER`
  /// caps the number of bound parameters a single statement may use — 999 on
  /// older builds. 500 leaves headroom for a caller (like
  /// [markUnattemptedStale]) that binds one extra parameter alongside the id
  /// list.
  static Iterable<List<T>> _chunks<T>(List<T> items, [int size = 500]) sync* {
    for (var i = 0; i < items.length; i += size) {
      yield items.sublist(i, i + size > items.length ? items.length : i + size);
    }
  }

  // --- watches ---------------------------------------------------------------

  /// [notify] defaults to true for the common case (one call, one visible
  /// change). A caller upserting many watches in a batch — the scanner
  /// reconciling one manifest's worth of dependencies is the only one today
  /// — passes false and relies on its own single notifyListeners() (here,
  /// replaceUsagesForProject's) to represent the whole batch as one change,
  /// rather than firing one notification per dependency.
  int upsertWatch(WatchKind kind, String displayName, {bool notify = true}) {
    final name = canonicalize(kind, displayName);
    _db.execute(
      'INSERT INTO watch (kind, name, display_name) VALUES (?, ?, ?) '
      'ON CONFLICT(kind, name) DO NOTHING',
      [kind.name, name, displayName],
    );
    final row = _db.select('SELECT id FROM watch WHERE kind = ? AND name = ?', [
      kind.name,
      name,
    ]).first;
    if (notify) notifyListeners();
    return row['id'] as int;
  }

  Watch? watchById(int id) {
    final rows = _db.select('SELECT * FROM watch WHERE id = ?', [id]);
    return rows.isEmpty ? null : Watch.fromRow(rows.first);
  }

  Watch? watchByIdentity(WatchKind kind, String canonicalName) {
    final rows = _db.select('SELECT * FROM watch WHERE kind = ? AND name = ?', [
      kind.name,
      canonicalName,
    ]);
    return rows.isEmpty ? null : Watch.fromRow(rows.first);
  }

  /// Lists watches, narrowed by [filter] and optionally by [kind], ordered by
  /// `display_name`, and capped at [limit] entries after filtering.
  ///
  /// `unread` and `outdated` both exclude currently-snoozed watches; `all`
  /// does not. A snooze whose timestamp has already passed no longer hides
  /// anything. Version comparison for `outdated` uses [compareVersions] in
  /// Dart rather than in SQL, because SQLite's text ordering would sort
  /// `1.10.0` below `1.9.0`.
  List<Watch> watches({
    WatchFilter filter = WatchFilter.all,
    WatchKind? kind,
    int? limit,
  }) {
    final sql = StringBuffer('SELECT * FROM watch');
    final params = <Object?>[];
    if (kind != null) {
      sql.write(' WHERE kind = ?');
      params.add(kind.name);
    }
    sql.write(' ORDER BY display_name');
    var result = _db.select(sql.toString(), params).map(Watch.fromRow).toList();

    switch (filter) {
      case WatchFilter.all:
        break;
      case WatchFilter.unread:
        final candidates = result.where((w) => !w.isSnoozed).toList();
        final unreadIds = _watchIdsWithUnreadRelease(
          candidates.map((w) => w.id!),
        );
        result = candidates.where((w) => unreadIds.contains(w.id)).toList();
      case WatchFilter.outdated:
        final candidates = result.where((w) => !w.isSnoozed).toList();
        final outdatedIds = _outdatedWatchIds(candidates.map((w) => w.id!));
        result = candidates.where((w) => outdatedIds.contains(w.id)).toList();
    }

    if (limit != null) result = result.take(limit).toList();
    return result;
  }

  /// Grouped-by-`watch_id` equivalent of asking, one watch at a time,
  /// "does this watch have an unread release?" Returns the subset of [ids]
  /// that do, in one query rather than one per candidate.
  Set<int> _watchIdsWithUnreadRelease(Iterable<int> ids) {
    final idList = ids.toList();
    if (idList.isEmpty) return {};
    final result = <int>{};
    for (final chunk in _chunks(idList)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      result.addAll(
        _db
            .select(
              'SELECT DISTINCT watch_id FROM release '
              'WHERE read = 0 AND watch_id IN ($placeholders)',
              chunk,
            )
            .map((r) => r['watch_id'] as int),
      );
    }
    return result;
  }

  /// Grouped-by-`watch_id` equivalent of asking, one watch at a time,
  /// "is this watch outdated?" Returns the subset of [ids] that are, in two
  /// queries (usages, releases) rather than up to three per candidate.
  ///
  /// Version comparison still happens in Dart via [compareVersions], never
  /// in SQL — SQLite's text ordering would sort `1.10.0` below `1.9.0` — and
  /// unresolved usages are still excluded, exactly as the per-watch version
  /// did.
  Set<int> _outdatedWatchIds(Iterable<int> ids) {
    final idList = ids.toList();
    if (idList.isEmpty) return {};

    final usagesByWatch = <int, List<String>>{};
    final releasesByWatch = <int, List<String>>{};
    for (final chunk in _chunks(idList)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');

      for (final r in _db.select(
        'SELECT watch_id, pinned_version FROM usage '
        'WHERE is_resolved = 1 AND watch_id IN ($placeholders)',
        chunk,
      )) {
        usagesByWatch
            .putIfAbsent(r['watch_id'] as int, () => [])
            .add(r['pinned_version'] as String);
      }

      for (final r in _db.select(
        'SELECT watch_id, version FROM release WHERE watch_id IN ($placeholders)',
        chunk,
      )) {
        releasesByWatch
            .putIfAbsent(r['watch_id'] as int, () => [])
            .add(r['version'] as String);
      }
    }
    if (usagesByWatch.isEmpty) return {};

    final outdated = <int>{};
    usagesByWatch.forEach((watchId, pins) {
      final versions = releasesByWatch[watchId];
      if (versions == null || versions.isEmpty) return;
      String? newest;
      for (final v in versions) {
        if (newest == null || compareVersions(v, newest) > 0) newest = v;
      }
      if (pins.any((p) => compareVersions(p, newest!) < 0)) {
        outdated.add(watchId);
      }
    });
    return outdated;
  }

  /// Case-insensitive substring match over `display_name` and `repo_url`.
  List<Watch> searchWatches(String query) {
    final needle = '%${query.toLowerCase()}%';
    return _db
        .select(
          'SELECT * FROM watch WHERE LOWER(display_name) LIKE ? '
          'OR LOWER(repo_url) LIKE ? ORDER BY display_name',
          [needle, needle],
        )
        .map(Watch.fromRow)
        .toList();
  }

  void removeWatch(int id) {
    _db.execute('DELETE FROM watch WHERE id = ?', [id]);
    notifyListeners();
  }

  /// Un-snoozing is `snooze(id, DateTime.now())` — there is no separate
  /// clear operation, since a snooze in the past is inert to [watches].
  void snooze(int watchId, DateTime until) {
    _db.execute('UPDATE watch SET snoozed_until = ? WHERE id = ?', [
      _epoch(until),
      watchId,
    ]);
    notifyListeners();
  }

  /// Updates only the fields actually passed. `clearError: true` sets
  /// `last_error` back to NULL; passing neither `lastError` nor `clearError`
  /// leaves it untouched. `lastCheckedAt` is caller-supplied rather than
  /// stamped internally, so a refresh orchestrator controls its own clock.
  void setWatchMeta(
    int id, {
    String? repoUrl,
    String? lastSeenVersion,
    String? lastError,
    DateTime? lastCheckedAt,
    bool clearError = false,
  }) {
    final sets = <String>[];
    final params = <Object?>[];
    if (repoUrl != null) {
      sets.add('repo_url = ?');
      params.add(repoUrl);
    }
    if (lastSeenVersion != null) {
      sets.add('last_seen_version = ?');
      params.add(lastSeenVersion);
    }
    if (lastError != null) {
      sets.add('last_error = ?');
      params.add(lastError);
    } else if (clearError) {
      sets.add('last_error = NULL');
    }
    if (lastCheckedAt != null) {
      sets.add('last_checked_at = ?');
      params.add(_epoch(lastCheckedAt));
    }

    if (sets.isNotEmpty) {
      params.add(id);
      _db.execute('UPDATE watch SET ${sets.join(', ')} WHERE id = ?', params);
    }
    notifyListeners();
  }

  /// Batched equivalent of calling [setWatchMeta] with only `lastError` for
  /// every id in [watchIds]: one `UPDATE ... WHERE id IN (...)` per chunk of
  /// ids instead of one `UPDATE` per watch. Exists for a rate-limited
  /// refresh, which needs to stamp the same message on every watch it never
  /// got to *this run* — "stale" here means "not attempted", not "attempted
  /// and failed", even though both land in the same `last_error` column.
  ///
  /// Deliberately does not route through [setWatchMeta]: that method builds a
  /// dynamic column list for a single id, where this always touches exactly
  /// one column (`last_error`) across a batched `IN (...)` of ids — different
  /// enough query shapes that sharing one code path would only obscure both.
  ///
  /// All chunks run inside a single transaction, so the call is atomic: a
  /// failure partway through leaves no chunk committed rather than leaving
  /// an arbitrary prefix of [watchIds] durably marked while the rest are
  /// not — see [replaceUsagesForProject] for the same BEGIN/COMMIT/ROLLBACK
  /// shape.
  ///
  /// Notifies exactly once for the whole batch, no matter how many chunks
  /// the id list is split into internally, unlike the per-watch loop this
  /// replaced, which notified once per watch. That means a rate-limited
  /// refresh now produces a single UI rebuild instead of one per skipped
  /// watch — not a violation of the one-call-one-notify rule, but a real
  /// change in rebuild cadence worth knowing about. It does not notify at
  /// all if the transaction rolls back, since no state changed.
  void markUnattemptedStale(Iterable<int> watchIds, String message) {
    final ids = watchIds.toList();
    if (ids.isEmpty) return;
    _db.execute('BEGIN');
    try {
      // Each chunk binds `message` plus the chunk's own ids, so the chunk
      // size must leave room for that extra placeholder; 500 ids + 1
      // message is comfortably under SQLite's 999-parameter ceiling.
      for (final chunk in _chunks(ids)) {
        final placeholders = List.filled(chunk.length, '?').join(', ');
        _db.execute(
          'UPDATE watch SET last_error = ? WHERE id IN ($placeholders)',
          [message, ...chunk],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  // --- releases ----------------------------------------------------------------

  /// Idempotent per `(watch_id, version)`: an already-stored version is left
  /// untouched, including its `read` flag, which is why this uses
  /// `INSERT OR IGNORE` rather than the plain INSERT `replaceUsagesForProject`
  /// needs — here the ignore-on-conflict behaviour is the intended semantics.
  ///
  /// Returns the number of rows actually inserted (i.e. genuinely new
  /// versions), reading it off SQLite's own per-statement change count
  /// rather than diffing a before/after `SELECT COUNT(*)`, so a caller
  /// wanting "how many were new" never has to re-query for it.
  int insertReleases(int watchId, List<Release> releases) {
    final stmt = _db.prepare(
      'INSERT OR IGNORE INTO release (watch_id, version, published_at, '
      'notes_md, url, read) VALUES (?, ?, ?, ?, ?, ?)',
    );
    var inserted = 0;
    try {
      for (final r in releases) {
        stmt.execute([
          watchId,
          r.version,
          r.publishedAt == null ? null : _epoch(r.publishedAt!),
          r.notesMd,
          r.url,
          r.read ? 1 : 0,
        ]);
        inserted += _db.updatedRows;
      }
    } finally {
      stmt.dispose();
    }
    notifyListeners();
    return inserted;
  }

  /// Newest version first. [newerThan], if given, filters to versions
  /// strictly greater. Ordering and filtering both use [compareVersions]
  /// rather than SQL, for the same reason `watches(filter: outdated)` does.
  List<Release> releasesFor(int watchId, {String? newerThan}) {
    var releases =
        _db
            .select('SELECT * FROM release WHERE watch_id = ?', [watchId])
            .map(Release.fromRow)
            .toList()
          ..sort((a, b) => compareVersions(b.version, a.version));
    if (newerThan != null) {
      releases = releases
          .where((r) => compareVersions(r.version, newerThan) > 0)
          .toList();
    }
    return releases;
  }

  /// With no [version], marks every release for the watch read; with one,
  /// only that release.
  void markRead(int watchId, {String? version}) {
    if (version == null) {
      _db.execute('UPDATE release SET read = 1 WHERE watch_id = ?', [watchId]);
    } else {
      _db.execute(
        'UPDATE release SET read = 1 WHERE watch_id = ? AND version = ?',
        [watchId, version],
      );
    }
    notifyListeners();
  }

  // --- usages ----------------------------------------------------------------

  List<Usage> usagesFor(int watchId) => _db
      .select('SELECT * FROM usage WHERE watch_id = ? ORDER BY project_path', [
        watchId,
      ])
      .map(Usage.fromRow)
      .toList();

  /// Batched projection of the two counts every watch-list row needs:
  /// unread release count and usage count, keyed by watch id. Both maps
  /// use `GROUP BY watch_id` rather than one query per watch, so listing
  /// N watches costs two queries total instead of 2N. A watch id absent
  /// from either map has a count of zero for that map — callers should
  /// read with `?? 0` rather than assume every id in [watchIds] appears.
  WatchCounts countsFor(Iterable<int> watchIds) {
    final ids = watchIds.toSet().toList();
    if (ids.isEmpty) return const WatchCounts(unread: {}, usages: {});

    final unread = <int, int>{};
    final usages = <int, int>{};
    for (final chunk in _chunks(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');

      for (final r in _db.select(
        'SELECT watch_id, COUNT(*) AS c FROM release '
        'WHERE read = 0 AND watch_id IN ($placeholders) GROUP BY watch_id',
        chunk,
      )) {
        unread[r['watch_id'] as int] = r['c'] as int;
      }

      for (final r in _db.select(
        'SELECT watch_id, COUNT(*) AS c FROM usage '
        'WHERE watch_id IN ($placeholders) GROUP BY watch_id',
        chunk,
      )) {
        usages[r['watch_id'] as int] = r['c'] as int;
      }
    }

    return WatchCounts(unread: unread, usages: usages);
  }

  /// A rescan is authoritative for the manifest it scanned: dependencies that
  /// disappeared from that manifest must disappear from the usage table, so
  /// this deletes and reinserts rather than upserting. The delete keys on
  /// both `project_path` and `manifest_file` — a scanner reconciles one
  /// manifest at a time, and a directory holding both `pubspec.lock` and
  /// `package.json` must not lose one manifest's usages when the other is
  /// written.
  void replaceUsagesForProject(
    String projectPath,
    String manifestFile,
    List<Usage> usages,
  ) {
    _db.execute('BEGIN');
    PreparedStatement? stmt;
    try {
      _db.execute(
        'DELETE FROM usage WHERE project_path = ? AND manifest_file = ?',
        [projectPath, manifestFile],
      );
      stmt = _db.prepare(
        'INSERT INTO usage (watch_id, project_path, manifest_file, '
        'pinned_version, is_resolved, is_dev_dep) VALUES (?, ?, ?, ?, ?, ?)',
      );
      for (final u in usages) {
        stmt.execute([
          u.watchId,
          u.projectPath,
          u.manifestFile,
          u.pinnedVersion,
          u.isResolved ? 1 : 0,
          u.isDevDep ? 1 : 0,
        ]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      stmt?.dispose();
    }
    notifyListeners();
  }

  /// Every distinct `project_path` in `usage`, ordered.
  List<String> knownProjects() => _db
      .select('SELECT DISTINCT project_path FROM usage ORDER BY project_path')
      .map((r) => r['project_path'] as String)
      .toList();

  // --- scan roots --------------------------------------------------------------

  List<String> scanRoots() => _db
      .select('SELECT path FROM scan_root ORDER BY path')
      .map((r) => r['path'] as String)
      .toList();

  void addScanRoot(String path) {
    _db.execute('INSERT OR IGNORE INTO scan_root (path) VALUES (?)', [path]);
    notifyListeners();
  }

  void removeScanRoot(String path) {
    _db.execute('DELETE FROM scan_root WHERE path = ?', [path]);
    notifyListeners();
  }

  // --- meta and http cache -----------------------------------------------------

  String? metaGet(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void metaSet(String key, String value) {
    _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
    notifyListeners();
  }

  @override
  String? etagFor(String url) {
    final rows = _db.select('SELECT etag FROM http_cache WHERE url = ?', [url]);
    return rows.isEmpty ? null : rows.first['etag'] as String?;
  }

  @override
  String? cachedBody(String url) {
    final rows = _db.select('SELECT body FROM http_cache WHERE url = ?', [url]);
    return rows.isEmpty ? null : rows.first['body'] as String;
  }

  @override
  void putCache(String url, String? etag, String body) => _db.execute(
    'INSERT OR REPLACE INTO http_cache (url, etag, body, fetched_at) '
    'VALUES (?, ?, ?, ?)',
    [url, etag, body, _epoch(DateTime.now())],
  );
}
