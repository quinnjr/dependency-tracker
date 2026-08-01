import 'dart:convert';

import '../canonicalize.dart';
import '../models.dart';
import '../net.dart';
import '../versions.dart';

class VersionInfo {
  const VersionInfo(this.version, this.publishedAt);
  final String version;
  final DateTime? publishedAt;
}

class RegistryResult {
  const RegistryResult({required this.versions, this.repoUrl});

  /// Oldest first, so the caller can treat the last entry as newest.
  final List<VersionInfo> versions;
  final String? repoUrl;
}

Uri registryUrl(WatchKind kind, String displayName) {
  switch (kind) {
    case WatchKind.pub:
      return Uri.parse('https://pub.dev/api/packages/$displayName');
    case WatchKind.npm:
      // A scoped name's slash must stay encoded or the registry 404s.
      return Uri.parse(
        'https://registry.npmjs.org/${displayName.replaceAll('/', '%2F')}',
      );
    case WatchKind.crates:
      return Uri.parse('https://crates.io/api/v1/crates/$displayName');
    case WatchKind.pypi:
      return Uri.parse('https://pypi.org/pypi/$displayName/json');
    case WatchKind.go:
      return Uri.parse(
        'https://proxy.golang.org/${goProxyPath(displayName)}/@v/list',
      );
    case WatchKind.github:
    case WatchKind.rss:
      throw ArgumentError.value(kind, 'kind', 'not a package registry');
  }
}

/// Reads the version list and best-effort repository URL for [watch] from
/// its registry. Uses `watch.displayName`, never `watch.name`: canonical
/// names are deliberately lossy (crates.io's `serde_json` canonicalizes to
/// `serde-json`, which 404s), so the wire form must be the original string.
Future<RegistryResult> fetchRegistry(Net net, Watch watch) async {
  final url = registryUrl(watch.kind, watch.displayName);
  final response = await net.get(url);

  switch (watch.kind) {
    case WatchKind.pub:
      return _pub(response.body);
    case WatchKind.npm:
      return _npm(response.body);
    case WatchKind.crates:
      return _crates(response.body);
    case WatchKind.pypi:
      return _pypi(response.body);
    case WatchKind.go:
      return _go(response.body, watch.displayName);
    case WatchKind.github:
    case WatchKind.rss:
      throw ArgumentError.value(watch.kind, 'kind', 'not a package registry');
  }
}

Map<String, dynamic> _json(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw const FormatException('expected a JSON object');
  return Map<String, dynamic>.from(decoded);
}

DateTime? _parseTime(Object? v) {
  if (v is! String || v.isEmpty) return null;
  return DateTime.tryParse(v)?.toUtc();
}

/// Fallback timestamp for entries with no parseable `publishedAt`, so a
/// missing timestamp sorts as "oldest" rather than throwing or comparing
/// arbitrarily against a present one.
final DateTime _publishedAtFallback = DateTime.utc(1970);

/// Sorts [versions] oldest-first by `publishedAt`, breaking ties (including
/// entries that share the [_publishedAtFallback] fallback) by `compareVersions` so the
/// order is fully deterministic and `.last` is always the genuinely newest.
///
/// `compareVersions` sorts a malformed version string strictly below any
/// version it parsed cleanly, independent of either version's numbers. So
/// when a tie is broken between a malformed entry (e.g. a registry tag like
/// `"nightly"`) and a well-formed one, the malformed entry always loses —
/// even against a low clean version like `"0.0.1"` — because a string that
/// isn't a real version can never be the "genuinely newest" one. This is the
/// intended guarantee, not an accidental side effect of the tiebreak.
void _sortByPublishedAt(List<VersionInfo> versions) {
  versions.sort((a, b) {
    final timeCmp = (a.publishedAt ?? _publishedAtFallback).compareTo(
      b.publishedAt ?? _publishedAtFallback,
    );
    if (timeCmp != 0) return timeCmp;
    return compareVersions(a.version, b.version);
  });
}

String? _githubUrlFrom(String? raw) {
  final slug = githubSlug(raw);
  return slug == null ? null : 'https://github.com/$slug';
}

RegistryResult _pub(String body) {
  final doc = _json(body);
  final versions = <VersionInfo>[];
  String? repo;
  final list = doc['versions'];
  if (list is List) {
    for (final v in list.whereType<Map>()) {
      final num = v['version'];
      if (num is! String) continue;
      versions.add(VersionInfo(num, _parseTime(v['published'])));
      final pubspec = v['pubspec'];
      if (pubspec is Map) {
        repo ??=
            _githubUrlFrom(pubspec['repository'] as String?) ??
            _githubUrlFrom(pubspec['homepage'] as String?);
      }
    }
  }
  _sortByPublishedAt(versions);
  return RegistryResult(versions: versions, repoUrl: repo);
}

RegistryResult _npm(String body) {
  final doc = _json(body);
  final times = doc['time'];
  final timeMap = times is Map ? times : const {};

  final versions = <VersionInfo>[];
  final all = doc['versions'];
  if (all is Map) {
    for (final key in all.keys.whereType<String>()) {
      versions.add(VersionInfo(key, _parseTime(timeMap[key])));
    }
  }
  _sortByPublishedAt(versions);

  final repository = doc['repository'];
  final raw = repository is Map
      ? repository['url'] as String?
      : repository as String?;
  return RegistryResult(
    versions: versions,
    repoUrl: _githubUrlFrom(raw) ?? _githubUrlFrom(doc['homepage'] as String?),
  );
}

RegistryResult _crates(String body) {
  final doc = _json(body);
  final versions = <VersionInfo>[];
  final list = doc['versions'];
  if (list is List) {
    for (final v in list.whereType<Map>()) {
      // A yanked version must never be offered as an upgrade target.
      if (v['yanked'] == true) continue;
      final num = v['num'];
      if (num is! String) continue;
      versions.add(VersionInfo(num, _parseTime(v['created_at'])));
    }
  }
  _sortByPublishedAt(versions);

  final crate = doc['crate'];
  final repo = crate is Map
      ? _githubUrlFrom(crate['repository'] as String?) ??
            _githubUrlFrom(crate['homepage'] as String?)
      : null;
  return RegistryResult(versions: versions, repoUrl: repo);
}

RegistryResult _pypi(String body) {
  final doc = _json(body);
  final versions = <VersionInfo>[];
  final releases = doc['releases'];
  if (releases is Map) {
    releases.forEach((version, files) {
      // An empty file list means every artifact was removed: not installable.
      if (files is! List || files.isEmpty) return;
      final first = files.first;
      versions.add(
        VersionInfo(
          version as String,
          first is Map ? _parseTime(first['upload_time_iso_8601']) : null,
        ),
      );
    });
  }
  _sortByPublishedAt(versions);

  final info = doc['info'];
  String? repo;
  if (info is Map) {
    final urls = info['project_urls'];
    if (urls is Map) {
      for (final key in ['Source', 'Repository', 'Source Code', 'Homepage']) {
        repo ??= _githubUrlFrom(urls[key] as String?);
      }
    }
    repo ??= _githubUrlFrom(info['home_page'] as String?);
  }
  return RegistryResult(versions: versions, repoUrl: repo);
}

RegistryResult _go(String body, String modulePath) {
  final versions =
      body
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .map((v) => VersionInfo(v, null))
          .toList()
        // The proxy returns no ordering guarantee and no timestamps in
        // @v/list. RegistryResult.versions is documented as oldest-first so
        // callers can treat the last entry as newest; a plain string sort
        // makes that false (e.g. "v1.10.0" sorts before "v1.9.0"), so this
        // must use compareVersions like every other ordering site in the app.
        ..sort((a, b) => compareVersions(a.version, b.version));

  // Most Go modules are hosted at their import path, so the path itself is a
  // more reliable repo hint than anything the proxy returns.
  final repo = _githubUrlFrom('https://$modulePath');
  return RegistryResult(versions: versions, repoUrl: repo);
}
