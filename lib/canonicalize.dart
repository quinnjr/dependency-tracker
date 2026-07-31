import 'models.dart';

/// Per-ecosystem package identity. Two strings that canonicalize to the same
/// value are the same package and must share one `watch` row.
///
/// Never send the result to a registry — use `Watch.displayName` for that.
/// crates.io in particular treats `-` and `_` as distinct characters even
/// though it forbids both spellings coexisting.
String canonicalize(WatchKind kind, String name) {
  final trimmed = name.trim();
  return switch (kind) {
    WatchKind.pypi => trimmed.toLowerCase().replaceAll(RegExp(r'[-_.]+'), '-'),
    WatchKind.npm => trimmed.toLowerCase(),
    WatchKind.crates => trimmed.toLowerCase().replaceAll('_', '-'),
    WatchKind.pub => trimmed.toLowerCase(),
    WatchKind.go => _goModule(trimmed),
    WatchKind.github => (githubSlug(trimmed) ?? trimmed).toLowerCase(),
    WatchKind.rss => _rssKey(trimmed),
  };
}

/// Go module paths are case-sensitive. `example.com/mod` and
/// `example.com/mod/v3` are distinct modules — the `/vN` major-version
/// suffix is part of Go's semantic-import-versioning scheme, and a build can
/// require both simultaneously at different versions. Collapsing them into
/// one watch means registry polling (which uses `Watch.displayName`) ends up
/// comparing one project's pinned version against a different module's
/// release list, whichever spelling happened to win the upsert.
String _goModule(String s) =>
    s.endsWith('/') ? s.substring(0, s.length - 1) : s;

/// Extracts `owner/repo` from any of the URL shapes registries and manifests
/// use for a GitHub repository, or `null` if [url] is absent, is a URL on a
/// host other than github.com, or does not carry both an owner and a repo
/// segment. Handles `git+` prefixes, `git@github.com:owner/repo.git`,
/// `git://`, `ssh://git@`, `.git` suffixes, `/tree/...` or `/blob/...` paths,
/// and bare `owner/repo` shorthand with no host at all.
///
/// Case is preserved — callers that want a case-insensitive identity (see
/// `canonicalize`'s `WatchKind.github` arm) must lowercase the result
/// themselves.
String? githubSlug(String? url) {
  if (url == null) return null;
  var v = url.trim();
  if (v.isEmpty) return null;
  v = v.replaceFirst(RegExp(r'^git\+'), '');
  v = v.replaceFirst(RegExp(r'^(https?://|git://|ssh://git@|git@)'), '');

  // A host prefix looks like "some.domain[:/]"; a bare "owner/repo" shorthand
  // never has a dot in its first segment. Reject any URL whose host isn't
  // github.com rather than silently treating e.g. gitlab.com as if it were.
  final hostMatch = RegExp(
    r'^([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})[:/]',
  ).firstMatch(v);
  if (hostMatch != null) {
    final host = hostMatch.group(1)!.toLowerCase();
    if (host != 'github.com' && host != 'www.github.com') return null;
    v = v.substring(hostMatch.end);
  }

  v = v.replaceFirst(RegExp(r'\.git$'), '');
  v = v.replaceFirst(RegExp(r'/(tree|blob)/.*$'), '');
  final parts = v.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;
  return '${parts[0]}/${parts[1]}';
}

/// Escapes a Go module path for `proxy.golang.org`, which requires uppercase
/// letters be written as `!` + the lowercase letter so that case-insensitive
/// filesystems cannot collide two distinct modules.
String goProxyPath(String module) =>
    module.replaceAllMapped(RegExp('[A-Z]'), (m) => '!${m[0]!.toLowerCase()}');

/// Feeds are identified by URL. Host is case-insensitive; the path is not.
String _rssKey(String s) {
  final uri = Uri.tryParse(s);
  if (uri == null || uri.host.isEmpty) return s;
  return uri.replace(host: uri.host.toLowerCase()).toString();
}
