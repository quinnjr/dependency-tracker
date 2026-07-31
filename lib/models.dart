enum WatchKind { pub, npm, crates, pypi, go, github, rss }

WatchKind watchKindFromName(String s) =>
    WatchKind.values.firstWhere((k) => k.name == s);

class Watch {
  const Watch({
    this.id,
    required this.kind,
    required this.name,
    required this.displayName,
    this.repoUrl,
    this.lastSeenVersion,
    this.lastCheckedAt,
    this.lastError,
    this.snoozedUntil,
  });

  final int? id;
  final WatchKind kind;
  final String name; // canonical identity
  final String displayName; // original string, safe for registry calls
  final String? repoUrl;
  final String? lastSeenVersion;
  final DateTime? lastCheckedAt;
  final String? lastError;
  final DateTime? snoozedUntil;

  /// True while `snoozedUntil` is set and still in the future. `Store`'s
  /// `unread`/`outdated` filters and the UI's snooze icon must agree on this
  /// exact definition, which is why they read `watch.isSnoozed` here rather
  /// than recomputing it.
  bool get isSnoozed =>
      snoozedUntil != null && snoozedUntil!.isAfter(DateTime.now().toUtc());

  static DateTime? _time(Object? v) => v == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((v as int) * 1000, isUtc: true);

  factory Watch.fromRow(Map<String, Object?> r) => Watch(
    id: r['id'] as int,
    kind: watchKindFromName(r['kind'] as String),
    name: r['name'] as String,
    displayName: r['display_name'] as String,
    repoUrl: r['repo_url'] as String?,
    lastSeenVersion: r['last_seen_version'] as String?,
    lastCheckedAt: _time(r['last_checked_at']),
    lastError: r['last_error'] as String?,
    snoozedUntil: _time(r['snoozed_until']),
  );
}

class Usage {
  const Usage({
    required this.watchId,
    required this.projectPath,
    required this.manifestFile,
    required this.pinnedVersion,
    required this.isResolved,
    required this.isDevDep,
  });

  final int watchId;
  final String projectPath;
  final String manifestFile;
  final String pinnedVersion;
  final bool isResolved; // false when the value is a range from a manifest
  final bool isDevDep;

  factory Usage.fromRow(Map<String, Object?> r) => Usage(
    watchId: r['watch_id'] as int,
    projectPath: r['project_path'] as String,
    manifestFile: r['manifest_file'] as String,
    pinnedVersion: r['pinned_version'] as String,
    isResolved: (r['is_resolved'] as int) == 1,
    isDevDep: (r['is_dev_dep'] as int) == 1,
  );
}

class Release {
  const Release({
    this.id,
    required this.watchId,
    required this.version,
    this.publishedAt,
    this.notesMd,
    this.url,
    this.read = false,
  });

  final int? id;
  final int watchId;
  final String version;
  final DateTime? publishedAt;
  final String? notesMd;
  final String? url;
  final bool read;

  factory Release.fromRow(Map<String, Object?> r) => Release(
    id: r['id'] as int,
    watchId: r['watch_id'] as int,
    version: r['version'] as String,
    publishedAt: Watch._time(r['published_at']),
    notesMd: r['notes_md'] as String?,
    url: r['url'] as String?,
    read: (r['read'] as int) == 1,
  );
}

/// A release as a fetcher returns it, before it has a database identity.
/// Registry fetchers fill `version` and usually `publishedAt`; `notesMd` is
/// filled later from GitHub, because almost no registry carries release notes.
class FetchedRelease {
  const FetchedRelease({
    required this.version,
    this.publishedAt,
    this.notesMd,
    this.url,
  });

  final String version;
  final DateTime? publishedAt;
  final String? notesMd;
  final String? url;

  FetchedRelease withNotes(String? notes, String? notesUrl) => FetchedRelease(
    version: version,
    publishedAt: publishedAt,
    notesMd: notes ?? notesMd,
    url: notesUrl ?? url,
  );
}
