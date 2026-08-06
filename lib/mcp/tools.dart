import '../canonicalize.dart';
import '../models.dart';
import '../refresh.dart';
import '../store.dart';

/// Documented once, quoted by every tool that takes `id`/`name`. Five
/// hand-maintained copies would drift, and a tool's description is the only
/// thing a consuming agent ever sees — so a drifted copy is a behavioural lie.
const String _idOrNameNote =
    'Accepts id, name, or both; if both are given they must identify the same '
    'watch or the call fails.';

class ToolDef {
  const ToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final Future<Object?> Function(Map<String, Object?> args) handler;
}

WatchFilter? _filterByName(String name) {
  for (final f in WatchFilter.values) {
    if (f.name == name) return f;
  }
  return null;
}

WatchKind? _kindByName(String name) {
  for (final k in WatchKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

/// Coerces a JSON-decoded numeric argument into an `int`.
///
/// A JSON number like `2` or `2.0` is equally valid input for an
/// integer-typed schema field, but `jsonDecode` hands back a Dart `double`
/// for any literal with a decimal point — including a whole one. Casting
/// that straight to `int?` throws a raw `_TypeError`, which is not a
/// message an MCP client can act on. Accept an integral double as the
/// integer it represents; reject anything else (a non-integral double, or
/// a value of the wrong type) with an `ArgumentError` naming the
/// parameter, which the protocol layer already turns into a clear
/// `isError` result. Returns null only when [v] itself is null, so
/// optional parameters keep their "absent" meaning.
int? _coerceOptionalInt(Object? v, String paramName) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw ArgumentError.value(v, paramName, 'must be an integer');
}

/// [_coerceOptionalInt] plus the `minimum: 1` the schemas already advertise.
/// Two copies of the coerce-then-range pair had drifted apart on where they
/// ran relative to the query they bound.
int? _coerceOptionalPositiveInt(Object? v, String paramName) {
  final n = _coerceOptionalInt(v, paramName);
  if (n != null && n < 1) {
    throw ArgumentError.value(n, paramName, 'must be at least 1');
  }
  return n;
}

/// The string counterpart. Without it a wrong-typed `name`/`version`/
/// `newer_than` reached the client as a raw Dart `_TypeError` naming an
/// internal type — which, per [_coerceOptionalInt]'s own reasoning, is not a
/// message an MCP client can act on.
String? _coerceOptionalString(Object? v, String paramName) {
  if (v == null) return null;
  if (v is String) return v;
  throw ArgumentError.value(v, paramName, 'must be a string');
}

/// Resolves [name] to a watch id, the same way add_watch does, rather than
/// rolling a second definition of package identity here: canonicalize()
/// already knows each kind's equivalence rule (PyPI folds `-_.` together,
/// Go does not fold case at all), so trying it is what lets add_watch and
/// get_watch agree on every spelling — and, just as importantly, refuse to
/// agree on a Go module path differing only in case.
int _resolveWatchByName(Store store, String name) {
  for (final k in WatchKind.values) {
    final w = store.watchByIdentity(k, canonicalize(k, name));
    if (w != null) return w.id!;
  }
  // Exact fallback for a spelling no kind's canonicalize() recognises as
  // equivalent to anything stored. Case-sensitive: a case-insensitive
  // fallback would reintroduce the Go over-match canonicalize() exists to
  // prevent.
  for (final w in store.watches()) {
    if (w.displayName == name) return w.id!;
  }
  throw ArgumentError.value(name, 'name', 'no such watch');
}

int _requireWatchId(Store store, Map<String, Object?> args) {
  final id = _coerceOptionalInt(args['id'], 'id');
  final name = args['name'];
  final hasName = name is String;

  if (id != null) {
    if (store.watchById(id) == null) {
      throw ArgumentError.value(id, 'id', 'no such watch');
    }
    // A caller passing both id and name only is safe to honour if the two
    // actually agree — an agent that drifted (a correct id alongside a
    // stale or wrong name) must be told its inputs disagree rather than
    // have the mismatch silently swallowed by preferring id, which is
    // exactly the hazard this check exists to catch. Only resolve name
    // when it is actually supplied, so the single-parameter path costs no
    // extra query.
    if (hasName) {
      // Ask whether `name` is a valid spelling of *this* watch, not what the
      // name resolves to globally. _resolveWatchByName answers with the first
      // matching WatchKind in enum order, so on a cross-registry collision —
      // `http` on both pub and npm, and this is a multi-registry tracker where
      // `path`, `uuid`, `crypto` and `requests` collide routinely — it always
      // answers "pub". A caller passing the npm watch's own id alongside its
      // own correct name would then be told the two disagree.
      //
      // Comparing against the id'd watch keeps the Go case-sensitivity
      // guarantee: neither canonicalize(go, ...) nor the displayName
      // comparison folds case.
      final watch = store.watchById(id)!;
      final agrees =
          canonicalize(watch.kind, name) == watch.name ||
          watch.displayName == name;
      if (!agrees) {
        throw ArgumentError(
          'id ($id) and name ("$name") refer to different watches',
        );
      }
    }
    return id;
  }
  if (hasName) {
    return _resolveWatchByName(store, name);
  }
  throw ArgumentError('one of `id` or `name` is required');
}

/// [counts], if given, must come from a [Store.countsFor] call covering
/// [w]'s id — used by callers mapping many watches at once so the tool
/// call costs O(1) queries rather than O(n). Field names (`usage_count`,
/// `unread_count`) are part of the MCP tool contract agents consume and
/// must not change shape here.
///
/// Omitting [counts] is only correct for a single-watch call site such as
/// `get_watch`, where it falls back to issuing its own one-off
/// [Store.countsFor] query. **Any caller rendering more than one watch
/// must supply [counts]** — use [_watchJsonList], which already batches
/// the query for exactly that case. Writing a loop that calls
/// `_watchJson(store, w)` per watch (copying the `get_watch` pattern
/// instead of using `_watchJsonList`) silently reintroduces the O(n)
/// per-watch query this batching was added to remove, and nothing will
/// fail to flag it — it costs one extra query per watch, not a wrong
/// answer.
Map<String, Object?> _watchJson(Store store, Watch w, {WatchCounts? counts}) {
  final resolved = counts ?? store.countsFor([w.id!]);
  return {
    'id': w.id,
    'kind': w.kind.name,
    'name': w.displayName,
    'repo_url': w.repoUrl,
    'latest_known': w.lastSeenVersion,
    'usage_count': resolved.usages[w.id] ?? 0,
    'unread_count': resolved.unread[w.id] ?? 0,
    'snoozed_until': w.snoozedUntil?.toIso8601String(),
    'last_checked_at': w.lastCheckedAt?.toIso8601String(),
    // Already redacted at the point it was stored.
    'last_error': w.lastError,
  };
}

/// One-query-pair projection over [watches], for tool handlers that map an
/// entire result list through [_watchJson] instead of one watch at a time.
List<Map<String, Object?>> _watchJsonList(Store store, List<Watch> watches) {
  final counts = store.countsFor(watches.map((w) => w.id!));
  return watches.map((w) => _watchJson(store, w, counts: counts)).toList();
}

Map<String, Object?> _releaseJson(Release r) => {
  'version': r.version,
  'published_at': r.publishedAt?.toIso8601String(),
  'url': r.url,
  'read': r.read,
  'notes': r.notesMd,
};

List<ToolDef> buildTools(
  Store store, {
  required Future<RefreshReport> Function(int? watchId) refresh,
}) {
  return [
    ToolDef(
      name: 'list_watches',
      description:
          'List watched packages and feeds. filter: all (default), unread '
          '(has a release nobody has looked at), or outdated (some project '
          'pins a version below the newest release). Snoozed watches are '
          'excluded unless filter is all.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'filter': {
            'type': 'string',
            'enum': ['all', 'unread', 'outdated'],
          },
          'kind': {
            'type': 'string',
            'enum': ['pub', 'npm', 'crates', 'pypi', 'go', 'github', 'rss'],
          },
          'limit': {'type': 'integer', 'minimum': 1},
        },
      },
      handler: (args) async {
        final filterName =
            _coerceOptionalString(args['filter'], 'filter') ?? 'all';
        final filter = _filterByName(filterName);
        if (filter == null) {
          throw ArgumentError.value(filterName, 'filter', 'unknown filter');
        }
        final kindName = _coerceOptionalString(args['kind'], 'kind');
        WatchKind? kind;
        if (kindName != null) {
          kind = _kindByName(kindName);
          if (kind == null) {
            throw ArgumentError.value(kindName, 'kind', 'unknown kind');
          }
        }
        final limit = _coerceOptionalPositiveInt(args['limit'], 'limit');
        return _watchJsonList(
          store,
          store.watches(filter: filter, kind: kind, limit: limit),
        );
      },
    ),

    ToolDef(
      name: 'get_watch',
      description:
          'Get one watch with every project that uses it and the version each '
          'one pins. This is the cross-repo view: a package used in five '
          'repos is one watch with five usages. $_idOrNameNote',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
        },
        'anyOf': [
          {
            'required': ['id'],
          },
          {
            'required': ['name'],
          },
        ],
      },
      handler: (args) async {
        final id = _requireWatchId(store, args);
        final w = store.watchById(id)!;
        return {
          ..._watchJson(store, w),
          'usages': store
              .usagesFor(id)
              .map(
                (u) => {
                  'project_path': u.projectPath,
                  'manifest_file': u.manifestFile,
                  'pinned_version': u.pinnedVersion,
                  'is_resolved': u.isResolved,
                  'is_dev_dep': u.isDevDep,
                },
              )
              .toList(),
        };
      },
    ),

    ToolDef(
      name: 'get_release_notes',
      description:
          'Release notes for a watch, newest first. Pass newer_than to get '
          'only what shipped after a version you already know about. '
          '$_idOrNameNote',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
          'newer_than': {'type': 'string'},
          'limit': {'type': 'integer', 'minimum': 1},
        },
        'anyOf': [
          {
            'required': ['id'],
          },
          {
            'required': ['name'],
          },
        ],
      },
      handler: (args) async {
        final id = _requireWatchId(store, args);
        // Validated before the query rather than after it: rejecting a call
        // only once its rows have been read wastes the read and was the odd
        // one out against list_watches.
        final limit = _coerceOptionalPositiveInt(args['limit'], 'limit');
        var releases = store.releasesFor(
          id,
          newerThan: _coerceOptionalString(args['newer_than'], 'newer_than'),
        );
        if (limit != null && releases.length > limit) {
          releases = releases.sublist(0, limit);
        }
        return releases.map(_releaseJson).toList();
      },
    ),

    ToolDef(
      name: 'search_watches',
      description:
          'Find watches whose name or repository URL contains a '
          'substring, case-insensitively.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'minLength': 1},
        },
        'required': ['query'],
      },
      handler: (args) async {
        final query = args['query'];
        if (query is! String || query.isEmpty) {
          throw ArgumentError('`query` is required');
        }
        return _watchJsonList(store, store.searchWatches(query));
      },
    ),

    ToolDef(
      name: 'add_watch',
      description:
          'Watch a package from a registry. Idempotent: adding a name that '
          'canonicalizes to an existing watch returns that watch. For '
          'kind=github, name must be an owner/repo slug or a github.com URL. '
          'Use add_rss_watch for feeds.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'enum': ['pub', 'npm', 'crates', 'pypi', 'go', 'github'],
          },
          'name': {
            'type': 'string',
            'minLength': 1,
            'description':
                'Package name, Go module path, or owner/repo (or a '
                'github.com URL) for kind=github.',
          },
        },
        'required': ['kind', 'name'],
      },
      handler: (args) async {
        final kindName = args['kind'];
        final name = args['name'];
        if (name is! String || name.trim().isEmpty) {
          throw ArgumentError('`name` is required');
        }
        if (kindName is! String) {
          throw ArgumentError.value(kindName, 'kind', 'unknown kind');
        }
        final kind = _kindByName(kindName);
        if (kind == null) {
          throw ArgumentError.value(kindName, 'kind', 'unknown kind');
        }
        if (kind == WatchKind.rss) {
          throw ArgumentError.value(
            kindName,
            'kind',
            'use add_rss_watch for feeds',
          );
        }
        final trimmed = name.trim();
        // canonicalize() always returns a string, even for garbage input —
        // it is not the layer that rejects bad names. A kind=github watch
        // whose name resolves to no owner/repo would otherwise be stored and
        // then be permanently unpollable, so validate here with the same
        // githubSlug() the fetcher and canonicalize() rely on.
        if (kind == WatchKind.github && githubSlug(trimmed) == null) {
          throw ArgumentError.value(
            trimmed,
            'name',
            'must be an owner/repo slug or a github.com URL',
          );
        }
        return {'id': store.upsertWatch(kind, trimmed)};
      },
    ),

    ToolDef(
      name: 'add_rss_watch',
      description:
          'Watch an RSS or Atom feed that is not a package — a '
          'release blog, an announcements feed, a CVE feed.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'minLength': 1,
            'description':
                'The http(s) URL of the RSS or Atom feed, e.g. '
                'https://github.com/owner/repo/releases.atom. Other '
                'schemes (ftp, etc.) are rejected.',
          },
        },
        'required': ['url'],
      },
      handler: (args) async {
        final raw = args['url'];
        if (raw is! String) throw ArgumentError('`url` is required');
        final url = Uri.tryParse(raw.trim());
        if (url == null ||
            !url.hasAuthority ||
            (url.scheme != 'http' && url.scheme != 'https')) {
          throw ArgumentError.value(raw, 'url', 'must be an http(s) url');
        }
        return {'id': store.upsertWatch(WatchKind.rss, url.toString())};
      },
    ),

    ToolDef(
      name: 'remove_watch',
      description:
          'Stop watching something. Its releases and usage records go '
          'with it; a rescan recreates the watch if a project still uses it. '
          '$_idOrNameNote',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
        },
        'anyOf': [
          {
            'required': ['id'],
          },
          {
            'required': ['name'],
          },
        ],
      },
      handler: (args) async {
        final id = _requireWatchId(store, args);
        store.removeWatch(id);
        return {'removed': id};
      },
    ),

    ToolDef(
      name: 'mark_read',
      description:
          'Mark a watch triaged. With no version, marks every release '
          'read; with a version, only that one. $_idOrNameNote',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
          'version': {'type': 'string'},
        },
        'anyOf': [
          {
            'required': ['id'],
          },
          {
            'required': ['name'],
          },
        ],
      },
      handler: (args) async {
        final id = _requireWatchId(store, args);
        store.markRead(
          id,
          version: _coerceOptionalString(args['version'], 'version'),
        );
        return {'marked': id};
      },
    ),

    ToolDef(
      name: 'snooze',
      description:
          'Hide a watch from the unread and outdated filters until an '
          'ISO 8601 timestamp. $_idOrNameNote',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'name': {'type': 'string'},
          'until': {
            'type': 'string',
            'description': 'ISO 8601, e.g. 2026-09-01T00:00:00Z',
          },
        },
        'required': ['until'],
        'anyOf': [
          {
            'required': ['id'],
          },
          {
            'required': ['name'],
          },
        ],
      },
      handler: (args) async {
        final id = _requireWatchId(store, args);
        final raw = args['until'];
        final until = raw is String ? DateTime.tryParse(raw) : null;
        if (until == null) {
          throw ArgumentError.value(raw, 'until', 'not an ISO 8601 timestamp');
        }
        store.snooze(id, until.toUtc());
        return {'snoozed_until': until.toUtc().toIso8601String()};
      },
    ),

    ToolDef(
      name: 'refresh_now',
      description:
          'Fetch fresh versions and notes immediately. With an id, '
          'refreshes one watch; otherwise all of them. The open app window '
          'updates as this runs. If rate_limited is true, watches this run '
          'did not reach are normally marked stale so a later refresh '
          'retries them first. That marking is all-or-nothing: either '
          'every watch this run did not reach gets flagged, or none do. '
          'If stale_marking_failed is also true, none of them were '
          'flagged, so treat every unreached watch as un-prioritised — '
          'it will look like it was never refreshed rather than '
          'rate-limited, and a subsequent refresh will not know to '
          'prioritise it.',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
        },
      },
      handler: (args) async {
        final id = _coerceOptionalInt(args['id'], 'id');
        final report = await refresh(id);
        return {
          'refreshed': report.refreshed,
          'failed': report.failed,
          'new_releases': report.newReleases,
          'rate_limited': report.rateLimited,
          'stale_marking_failed': report.staleMarkingFailed,
        };
      },
    ),
  ];
}
