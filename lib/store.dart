import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';

import 'canonicalize.dart';
import 'db/db_open_io.dart' if (dart.library.js_interop) 'db/db_open_web.dart';
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

/// Where one watch's own projects sit relative to the registry, as
/// [Store.driftFor] projects it.
///
/// This is the number the whole app exists to show: not "a new version exists"
/// but "your projects are this far from it".
class Drift {
  const Drift({
    required this.pinnedProjects,
    required this.lowestPin,
    required this.highestPin,
    required this.newestRelease,
    required this.behindBy,
  });

  /// Usages with a resolved pin. Zero when every usage is an unresolved range,
  /// in which case [lowestPin] and [highestPin] are both null and [behindBy]
  /// is zero — nothing is known to be behind, because nothing is known.
  final int pinnedProjects;

  /// Oldest and newest version this package is pinned at across all projects.
  /// Equal when every project agrees; both null when no pin is resolved.
  final String? lowestPin;
  final String? highestPin;

  /// Newest version the registry has published. Never null: a [Drift] only
  /// exists for a watch with at least one fetched release.
  final String newestRelease;

  /// Releases strictly newer than [lowestPin].
  final int behindBy;

  /// True when every project is on the newest published release.
  bool get isCurrent => pinnedProjects > 0 && behindBy == 0;

  /// True when projects disagree about which version to use — worth surfacing
  /// separately from being behind, because it is a different job to fix.
  bool get isSplit =>
      lowestPin != null && highestPin != null && lowestPin != highestPin;
}

/// The only mutable state in the app. Both the UI and the MCP server hold a
/// reference to one instance, which is why an agent calling `add_watch` shows up
/// in the open window with no extra plumbing.
///
/// Mutators of UI-visible state (`watch`, `usage`, `release`, `scan_root`)
/// notify at most once per call: exactly once when state actually changed,
/// and zero times on an explicit batch opt-out (`upsertWatch(notify: false)`)
/// or a call with nothing to do (`markUnattemptedStale` with an empty id
/// list). Every such mutator routes through [_deferOrNotify], so inside a
/// [runInTransaction] batch the notification is deferred to a single one
/// fired after `COMMIT` — and never fired for a batch that rolls back.
/// `meta` and `http_cache` are internal bookkeeping the UI never renders and
/// are exempt from the rule entirely — see the "meta and http cache" section
/// below for the specifics.
class Store extends ChangeNotifier implements EtagCache {
  Store._(this._db);

  final CommonDatabase _db;
  bool _closed = false;
  bool _inTransaction = false;
  bool _pendingNotify = false;

  // Prepared once per Store and reused, because the scanner calls
  // [upsertWatch] once per parsed dependency inside its per-manifest
  // transaction — re-preparing two fixed SQL strings per dependency is the
  // per-row overhead [insertReleases] and [replaceUsagesForProject] already
  // avoid with their prepare-once/execute-many statements.
  CommonPreparedStatement? _upsertWatchInsert;
  CommonPreparedStatement? _upsertWatchSelect;

  static Store open(String file) {
    final store = Store._(openDatabaseFile(file));
    store._migrate();
    return store;
  }

  static Store openInMemory() {
    final store = Store._(openDatabaseInMemory());
    store._migrate();
    return store;
  }

  /// [open]'s awaitable twin, and the only opener the web build can use:
  /// fetching sqlite3.wasm and attaching the IndexedDB VFS are async, so a
  /// synchronous open cannot exist there. On the VM it opens the same
  /// database [open] would.
  static Future<Store> openAsync(String ref) async {
    final store = Store._(await openDatabaseAsync(ref));
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
    _upsertWatchInsert?.dispose();
    _upsertWatchSelect?.dispose();
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
      CREATE TABLE IF NOT EXISTS api_key (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        key_hash TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL,
        last_used_at INTEGER
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
      CREATE TABLE IF NOT EXISTS secret (
        key TEXT PRIMARY KEY,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS user (
        id INTEGER PRIMARY KEY,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS refresh_token (
        hash TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
        expires_at INTEGER NOT NULL
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

  /// Runs [action] inside a single `BEGIN`/`COMMIT` transaction, rolling back
  /// on any exception raised by [action] or by SQLite itself. Exists so a
  /// caller reconciling many rows across several Store calls — [scanDirectory]
  /// upserting every dependency in a manifest and then replacing that
  /// manifest's usages is the only caller today — pays for one fsync-backed
  /// commit instead of one implicit autocommit per call, the same batching
  /// [replaceUsagesForProject] and [markUnattemptedStale] already do on their
  /// own for a single kind of write.
  ///
  /// Reentrant: a call made while a transaction is already open — directly,
  /// or via a Store method such as [replaceUsagesForProject] that wraps its
  /// own writes in one — runs [action] against the already-open transaction
  /// instead of issuing a nested `BEGIN`, which SQLite rejects. Only the
  /// outermost call commits or rolls back; an inner call's exception still
  /// propagates out to it.
  ///
  /// A nested mutator that would otherwise notify immediately (every
  /// UI-visible-state mutator in this file routes through [_deferOrNotify])
  /// instead defers, so a caller batching several such mutators in one
  /// [runInTransaction] still gets exactly one notification, fired only once
  /// the outermost call's `COMMIT` actually succeeds — never for a batch
  /// that rolls back, per the same "no state changed, no notification" rule
  /// [markUnattemptedStale] documents.
  ///
  /// [action] must be synchronous. An async closure would return its Future
  /// before doing any work, letting `COMMIT` race ahead of every write after
  /// the first `await` — so a Future return value is rejected outright
  /// rather than silently committing a half-empty transaction.
  T runInTransaction<T>(T Function() action) {
    if (_inTransaction) return action();
    _db.execute('BEGIN');
    _inTransaction = true;
    final T result;
    try {
      result = action();
      if (result is Future) {
        throw ArgumentError(
          'runInTransaction requires a synchronous action; an async closure '
          'would escape the transaction at its first await',
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      // Reset state before attempting ROLLBACK: if COMMIT itself failed
      // (disk full, I/O error), SQLite may have already rolled the
      // transaction back on its own, making an explicit ROLLBACK throw
      // "no transaction is active" — which must neither mask the original
      // error nor strand _pendingNotify to fire on an unrelated later
      // transaction.
      _pendingNotify = false;
      _inTransaction = false;
      try {
        _db.execute('ROLLBACK');
      } on SqliteException {
        // Already rolled back by SQLite; the rethrow below carries the
        // error that actually caused the failure.
      }
      rethrow;
    }
    // _inTransaction is reset before notifying, so a listener that
    // synchronously calls back into the Store during this notification sees
    // the connection as it really is — back in autocommit mode — instead of
    // taking the reentrant no-BEGIN path against a transaction that no
    // longer exists.
    _inTransaction = false;
    if (_pendingNotify) {
      _pendingNotify = false;
      notifyListeners();
    }
    return result;
  }

  /// Notifies immediately when called outside any transaction (the common
  /// case), or defers to a single notification fired by the outermost
  /// [runInTransaction] call once it commits, when called from within one.
  /// See [runInTransaction] for why this exists.
  void _deferOrNotify() {
    if (_inTransaction) {
      _pendingNotify = true;
    } else {
      notifyListeners();
    }
  }

  // --- watches ---------------------------------------------------------------

  /// [notify] defaults to true for the common case (one call, one visible
  /// change). A caller upserting many watches in a batch — the scanner
  /// reconciling one manifest's worth of dependencies is the only one today
  /// — passes false and relies on its own single notifyListeners() (here,
  /// replaceUsagesForProject's) to represent the whole batch as one change,
  /// rather than firing one notification per dependency.
  ///
  /// `watch` is UI-visible state, so (per-call batching aside) this follows
  /// the same rule as the rest of the file: mutators of state the UI renders
  /// notify exactly once per call. That rule does not extend to every
  /// mutator in this file — see the `meta`/`http_cache` section below for
  /// the two tables it deliberately does not cover.
  ///
  /// Uses `RETURNING id` to fold the insert and the id lookup into one
  /// round trip on the common (no-conflict) path; SQLite has supported
  /// `RETURNING` since 3.35, and `store_test.dart` asserts the linked library
  /// clears that floor on every platform, so the feature is safe to rely on
  /// here. `ON CONFLICT DO NOTHING` means a conflicting insert
  /// returns no row, so the conflict path still needs a fallback `SELECT` to
  /// find the existing row's id — this only removes the second round trip
  /// for genuinely new watches, not for repeats.
  int upsertWatch(WatchKind kind, String displayName, {bool notify = true}) {
    final name = canonicalize(kind, displayName);
    _upsertWatchInsert ??= _db.prepare(
      'INSERT INTO watch (kind, name, display_name) VALUES (?, ?, ?) '
      'ON CONFLICT(kind, name) DO NOTHING RETURNING id',
    );
    final inserted = _upsertWatchInsert!.select([kind.name, name, displayName]);
    final int id;
    if (inserted.isNotEmpty) {
      id = inserted.first['id'] as int;
    } else {
      _upsertWatchSelect ??= _db.prepare(
        'SELECT id FROM watch WHERE kind = ? AND name = ?',
      );
      final existing = _upsertWatchSelect!.select([kind.name, name]);
      if (existing.isEmpty) {
        // Reachable only if the conflicting row vanished between the two
        // statements, or a future unique constraint conflicts where
        // ON CONFLICT(kind, name) does not catch it. `.first` would raise a
        // bare "No element" naming neither the kind nor the name.
        //
        // No test can reach it: both statements are synchronous sqlite3 FFI
        // calls with no await between them, so nothing can delete the row in
        // the gap. Excluded from coverage rather than deleted, because the
        // day a second unique constraint is added it stops being unreachable
        // and starts being the only thing that names the offending watch.
        // coverage:ignore-start
        throw StateError(
          'upsertWatch: insert conflicted but no ${kind.name} row named '
          '"$name" exists',
        );
        // coverage:ignore-end
      }
      id = existing.first['id'] as int;
    }
    if (notify) _deferOrNotify();
    return id;
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
    var result = _baseWatches(kind);

    switch (filter) {
      case WatchFilter.all:
        break;
      case WatchFilter.unread:
        final candidates = _unsnoozed(result);
        final unreadIds = _watchIdsWithUnreadRelease(
          candidates.map((w) => w.id!),
        );
        result = _membersOf(candidates, unreadIds);
      case WatchFilter.outdated:
        final candidates = _unsnoozed(result);
        final outdatedIds = _outdatedWatchIds(candidates.map((w) => w.id!));
        result = _membersOf(candidates, outdatedIds);
    }

    if (limit != null) result = result.take(limit).toList();
    return result;
  }

  /// The base query [watches] and [watchesByFilter] share: every watch,
  /// optionally narrowed to one [kind], ordered by `display_name`. Extracted
  /// so the two functions cannot drift apart on what "the watch list" means.
  List<Watch> _baseWatches(WatchKind? kind) {
    final sql = StringBuffer('SELECT * FROM watch');
    final params = <Object?>[];
    if (kind != null) {
      sql.write(' WHERE kind = ?');
      params.add(kind.name);
    }
    sql.write(' ORDER BY display_name');
    return _db.select(sql.toString(), params).map(Watch.fromRow).toList();
  }

  static List<Watch> _unsnoozed(List<Watch> watches) =>
      watches.where((w) => !w.isSnoozed).toList();

  static List<Watch> _membersOf(List<Watch> candidates, Set<int> ids) =>
      candidates.where((w) => ids.contains(w.id)).toList();

  /// Single-pass equivalent of calling [watches] once per [WatchFilter]:
  /// the base `SELECT * FROM watch` runs once, and `unread`/`outdated`
  /// membership is derived from that same result via the same two batched
  /// `IN`-queries [watches] already uses — instead of each of the three
  /// filters rerunning its own full table scan. Built from the same
  /// [_baseWatches]/[_unsnoozed]/[_membersOf] pieces [watches] uses, so it
  /// returns exactly what three separate `watches(filter: f)` calls would:
  /// same rows, same order, same snoozed-watch exclusion for
  /// `unread`/`outdated` — `store_test.dart` asserts that equivalence
  /// directly. Exists for a caller (the AppShell masthead) that needs all
  /// three filters'-worth of watches simultaneously and would otherwise pay
  /// for the base scan three times per rebuild (the two `IN`-queries only
  /// ever ran once each; the redundancy was in the base scans).
  Map<WatchFilter, List<Watch>> watchesByFilter({WatchKind? kind, int? limit}) {
    final all = _baseWatches(kind);
    final candidates = _unsnoozed(all);
    final candidateIds = candidates.map((w) => w.id!).toList();
    final unreadIds = _watchIdsWithUnreadRelease(candidateIds);
    final outdatedIds = _outdatedWatchIds(candidateIds);

    List<Watch> select(WatchFilter f) {
      // An exhaustive switch, so adding a WatchFilter value refuses to
      // compile here rather than silently leaving the new filter without an
      // entry in the returned map.
      final result = switch (f) {
        WatchFilter.all => all,
        WatchFilter.unread => _membersOf(candidates, unreadIds),
        WatchFilter.outdated => _membersOf(candidates, outdatedIds),
      };
      return limit == null ? result : result.take(limit).toList();
    }

    return {for (final f in WatchFilter.values) f: select(f)};
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
    _deferOrNotify();
  }

  /// Un-snoozing is `snooze(id, DateTime.now())` — there is no separate
  /// clear operation, since a snooze in the past is inert to [watches].
  void snooze(int watchId, DateTime until) {
    _db.execute('UPDATE watch SET snoozed_until = ? WHERE id = ?', [
      _epoch(until),
      watchId,
    ]);
    _deferOrNotify();
  }

  /// Updates only the fields actually passed. `clearError: true` sets
  /// `last_error` back to NULL; passing neither `lastError` nor `clearError`
  /// leaves it untouched. `lastCheckedAt` is caller-supplied rather than
  /// stamped internally, so a refresh orchestrator controls its own clock.
  ///
  /// `watch` is UI-visible state, so this notifies on every call, same as
  /// [upsertWatch] — see the `meta`/`http_cache` section below for the two
  /// tables that are exempt from that rule.
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
    _deferOrNotify();
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
  /// All chunks run inside a single transaction via [runInTransaction], so
  /// the call is atomic: a failure partway through leaves no chunk committed
  /// rather than leaving an arbitrary prefix of [watchIds] durably marked
  /// while the rest are not — and, being reentrant, it also composes with a
  /// caller's own [runInTransaction] batch instead of throwing on a nested
  /// `BEGIN`.
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
    runInTransaction(() {
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
    });
    _deferOrNotify();
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
    _deferOrNotify();
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
    _deferOrNotify();
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

  /// Batched projection of where a watch's own projects sit relative to what
  /// the registry has published, keyed by watch id.
  ///
  /// A watch appears here only if it has at least one fetched release: with
  /// nothing fetched there is no published version to be behind of, and an
  /// entry claiming zero drift would be indistinguishable from one that has
  /// genuinely caught up. Callers must treat an absent id as "not known yet"
  /// rather than as "up to date".
  ///
  /// Costs two queries per chunk regardless of how many watches are asked
  /// about, for the same reason [countsFor] does — the watch list calls both
  /// once per build, not once per row.
  Map<int, Drift> driftFor(Iterable<int> watchIds) {
    final ids = watchIds.toSet().toList();
    if (ids.isEmpty) return const {};

    final pins = <int, List<String>>{};
    final versions = <int, List<String>>{};
    for (final chunk in _chunks(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');

      // Only resolved pins: a range like `^1.2.0` names no single version, so
      // placing it on an axis or measuring drift from it would be an invention.
      for (final r in _db.select(
        'SELECT watch_id, pinned_version FROM usage '
        'WHERE is_resolved = 1 AND watch_id IN ($placeholders)',
        chunk,
      )) {
        pins
            .putIfAbsent(r['watch_id'] as int, () => [])
            .add(r['pinned_version'] as String);
      }

      for (final r in _db.select(
        'SELECT watch_id, version FROM release WHERE watch_id IN ($placeholders)',
        chunk,
      )) {
        versions
            .putIfAbsent(r['watch_id'] as int, () => [])
            .add(r['version'] as String);
      }
    }

    final drift = <int, Drift>{};
    versions.forEach((watchId, released) {
      final newest = newestVersion(released);
      if (newest == null) return;

      final ownPins = pins[watchId] ?? const <String>[];
      String? low;
      String? high;
      for (final p in ownPins) {
        if (low == null || compareVersions(p, low) < 0) low = p;
        if (high == null || compareVersions(p, high) > 0) high = p;
      }

      drift[watchId] = Drift(
        pinnedProjects: ownPins.length,
        lowestPin: low,
        highestPin: high,
        newestRelease: newest,
        // Measured from the *stalest* pin, because that is the repo that
        // actually needs work. Measuring from the newest pin would report zero
        // drift for a package one repo has already upgraded and five have not.
        behindBy: low == null
            ? 0
            : released.where((v) => compareVersions(v, low!) > 0).length,
      );
    });
    return drift;
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
    runInTransaction(() {
      CommonPreparedStatement? stmt;
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
      } finally {
        stmt?.dispose();
      }
    });
    _deferOrNotify();
  }

  /// Every distinct `project_path` in `usage`, ordered.
  List<String> knownProjects() => _db
      .select('SELECT DISTINCT project_path FROM usage ORDER BY project_path')
      .map((r) => r['project_path'] as String)
      .toList();

  // --- api keys ----------------------------------------------------------------
  //
  // Named MCP API keys, stored hash-only (see lib/api_keys.dart for minting
  // and authentication). `api_key` is UI-visible state — the settings pane
  // renders the key list — so insert and revoke follow the notify
  // convention. [touchApiKey] is the deliberate exception: it runs on every
  // authenticated MCP request, and a per-request UI rebuild would be a
  // denial-of-service on the shell.

  int insertApiKey(String name, String keyHash) {
    final rows = _db.select(
      'INSERT INTO api_key (name, key_hash, created_at) VALUES (?, ?, ?) '
      'RETURNING id',
      [name, keyHash, _epoch(DateTime.now())],
    );
    final id = rows.first['id'] as int;
    _deferOrNotify();
    return id;
  }

  List<ApiKeyInfo> apiKeys() => _db
      .select(
        'SELECT id, name, created_at, last_used_at FROM api_key ORDER BY name',
      )
      .map(
        (r) => ApiKeyInfo(
          id: r['id'] as int,
          name: r['name'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (r['created_at'] as int) * 1000,
            isUtc: true,
          ),
          lastUsedAt: r['last_used_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (r['last_used_at'] as int) * 1000,
                  isUtc: true,
                ),
        ),
      )
      .toList();

  void revokeApiKey(int id) {
    _db.execute('DELETE FROM api_key WHERE id = ?', [id]);
    _deferOrNotify();
  }

  int? apiKeyIdForHash(String keyHash) {
    final rows = _db.select('SELECT id FROM api_key WHERE key_hash = ?', [
      keyHash,
    ]);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  void touchApiKey(int id, DateTime at) => _db.execute(
    'UPDATE api_key SET last_used_at = ? WHERE id = ?',
    [_epoch(at), id],
  );

  // --- scan roots --------------------------------------------------------------

  List<String> scanRoots() => _db
      .select('SELECT path FROM scan_root ORDER BY path')
      .map((r) => r['path'] as String)
      .toList();

  void addScanRoot(String path) {
    _db.execute('INSERT OR IGNORE INTO scan_root (path) VALUES (?)', [path]);
    _deferOrNotify();
  }

  void removeScanRoot(String path) {
    _db.execute('DELETE FROM scan_root WHERE path = ?', [path]);
    _deferOrNotify();
  }

  // --- meta and http cache -----------------------------------------------------
  //
  // Unlike `watch`, `usage`, `release`, and `scan_root` above — state the UI
  // actually renders, and whose mutators all notify exactly once per call —
  // `meta` and `http_cache` are internal bookkeeping the UI never reads. Their
  // mutators are exempt from the notify convention: [metaSet] notifies only
  // because it costs nothing to do so (see below), and [putCache] does not
  // notify at all.

  String? metaGet(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// `meta` is internal bookkeeping, not UI-rendered state, so this would be
  /// exempt from the notify convention like [putCache] below. It still
  /// notifies because its only caller today is [_migrate], which runs before
  /// `Store.open`/`openInMemory` return and thus before any listener can have
  /// attached — the notification is a no-op in practice, so removing it
  /// would only churn a passing test for symmetry's sake.
  void metaSet(String key, String value) {
    _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
    notifyListeners();
  }

  // `user` and `refresh_token` are server bookkeeping like `secret` below:
  // the desktop UI never renders accounts, so their mutators do not notify.
  // Passwords arrive here already Argon2id-hashed and refresh tokens
  // already SHA-256-hashed (lib/server/auth.dart) — the Store never sees
  // either in the clear.

  int insertUser(String username, String passwordHash, String role) {
    final rows = _db.select(
      'INSERT INTO user (username, password_hash, role, created_at) '
      'VALUES (?, ?, ?, ?) RETURNING id',
      [username, passwordHash, role, _epoch(DateTime.now())],
    );
    return rows.first['id'] as int;
  }

  ({int id, String passwordHash, String role})? userByName(String username) {
    final rows = _db.select(
      'SELECT id, password_hash, role FROM user WHERE username = ?',
      [username],
    );
    if (rows.isEmpty) return null;
    return (
      id: rows.first['id'] as int,
      passwordHash: rows.first['password_hash'] as String,
      role: rows.first['role'] as String,
    );
  }

  int userCount() =>
      _db.select('SELECT COUNT(*) AS c FROM user').first['c'] as int;

  String? userRoleById(int id) {
    final rows = _db.select('SELECT role FROM user WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.first['role'] as String;
  }

  void setUserPasswordHash(int id, String passwordHash) => _db.execute(
    'UPDATE user SET password_hash = ? WHERE id = ?',
    [passwordHash, id],
  );

  void insertRefreshToken(String hash, int userId, DateTime expires) =>
      _db.execute(
        'INSERT INTO refresh_token (hash, user_id, expires_at) '
        'VALUES (?, ?, ?)',
        [hash, userId, _epoch(expires)],
      );

  ({int userId, DateTime expiresAt})? refreshTokenByHash(String hash) {
    final rows = _db.select(
      'SELECT user_id, expires_at FROM refresh_token WHERE hash = ?',
      [hash],
    );
    if (rows.isEmpty) return null;
    return (
      userId: rows.first['user_id'] as int,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (rows.first['expires_at'] as int) * 1000,
        isUtc: true,
      ),
    );
  }

  void deleteRefreshToken(String hash) =>
      _db.execute('DELETE FROM refresh_token WHERE hash = ?', [hash]);

  // `secret` follows the same exemption as `meta`/`http_cache`: server
  // bookkeeping the UI never renders, so its mutators do not notify. The
  // rows are AES-GCM ciphertext produced by SqliteSecretBackend
  // (lib/server/sqlite_secrets.dart); the Store never sees a plaintext
  // secret, which keeps the "never passed to Store" rule intact.

  void secretPut(String key, List<int> nonce, List<int> ciphertext) =>
      _db.execute(
        'INSERT OR REPLACE INTO secret (key, nonce, ciphertext) '
        'VALUES (?, ?, ?)',
        [key, Uint8List.fromList(nonce), Uint8List.fromList(ciphertext)],
      );

  ({List<int> nonce, List<int> ciphertext})? secretGet(String key) {
    final rows = _db.select(
      'SELECT nonce, ciphertext FROM secret WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return (
      nonce: rows.first['nonce'] as List<int>,
      ciphertext: rows.first['ciphertext'] as List<int>,
    );
  }

  void secretDelete(String key) =>
      _db.execute('DELETE FROM secret WHERE key = ?', [key]);

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

  /// Deliberately does not call `notifyListeners()`: `http_cache` is
  /// internal bookkeeping the UI never renders, not UI-visible state like
  /// `watch` or `release`, and a refresh can write hundreds of cache entries
  /// in quick succession — notifying per entry would trigger a full shell
  /// rebuild on every HTTP fetch instead of once for the refresh as a whole.
  @override
  void putCache(String url, String? etag, String body) => _db.execute(
    'INSERT OR REPLACE INTO http_cache (url, etag, body, fetched_at) '
    'VALUES (?, ?, ?, ?)',
    [url, etag, body, _epoch(DateTime.now())],
  );
}
