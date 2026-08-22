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

/// Lives here rather than in scanner.dart so the web build — which renders
/// scan UI copy but compiles the dart:io scanner out — can name the type
/// without dragging dart:io in.
class ScanResult {
  const ScanResult({
    required this.projectsScanned,
    required this.depsFound,
    required this.errors,
  });

  final int projectsScanned;
  final int depsFound;
  final List<String> errors;

  /// Wire form shared by the server and the web client, defined once here so
  /// the two ends cannot drift.
  Map<String, Object?> toJson() => {
    'projectsScanned': projectsScanned,
    'depsFound': depsFound,
    'errors': errors,
  };

  factory ScanResult.fromJson(Map<String, Object?> json) => ScanResult(
    projectsScanned: json['projectsScanned'] as int? ?? 0,
    depsFound: json['depsFound'] as int? ?? 0,
    errors: (json['errors'] as List? ?? const []).cast<String>(),
  );
}

/// A named MCP API key as the UI may see it: metadata only, never the hash
/// (and the key itself exists nowhere after minting).
class ApiKeyInfo {
  const ApiKeyInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastUsedAt,
  });

  final int id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  /// Wire form (metadata only — the hash never leaves the store), defined
  /// once here so the server's list endpoint and the client's parser agree.
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'lastUsedAt': lastUsedAt?.toIso8601String(),
  };

  factory ApiKeyInfo.fromJson(Map<String, Object?> json) => ApiKeyInfo(
    id: json['id'] as int,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastUsedAt: json['lastUsedAt'] == null
        ? null
        : DateTime.parse(json['lastUsedAt'] as String),
  );
}
