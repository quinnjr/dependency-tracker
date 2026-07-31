import '../canonicalize.dart';
import '../models.dart';
import '../net.dart';
import 'feed.dart';
import 'github.dart';
import 'registry.dart';

class FetchOutcome {
  const FetchOutcome({required this.releases, this.repoUrl});

  final List<Release> releases;

  /// Newly discovered repository URL, or null if nothing new was learned.
  final String? repoUrl;
}

/// Strips a leading `v` so `v1.2.0` and `1.2.0` are recognized as the same
/// release when merging registry versions with GitHub notes.
String _key(String version) =>
    version.startsWith('v') ? version.substring(1) : version;

/// Dispatches a single watch to the fetcher for its kind, and normalizes the
/// result into one shape: the release list plus any newly-learned repo URL.
///
/// No test of its own — it is a dispatch switch, covered by the refresh
/// orchestrator's tests and each fetcher's own tests.
Future<FetchOutcome> fetchWatch(Net net, Watch watch, {String? token}) async {
  switch (watch.kind) {
    case WatchKind.rss:
      return _fromFeedWatch(net, watch);
    case WatchKind.github:
      // displayName is the original user-entered string, which may be a full
      // URL rather than the bare `owner/repo` slug the fetcher and feed URLs
      // require.
      final slug = githubSlug(watch.displayName) ?? watch.displayName;
      return FetchOutcome(
        releases: await fetchGithubReleases(
          net,
          slug: slug,
          watchId: watch.id!,
          token: token,
        ),
        repoUrl: 'https://github.com/$slug',
      );
    case WatchKind.pub:
    case WatchKind.npm:
    case WatchKind.crates:
    case WatchKind.pypi:
    case WatchKind.go:
      return _fromRegistry(net, watch, token: token);
  }
}

Future<FetchOutcome> _fromFeedWatch(Net net, Watch watch) async {
  final entries = await fetchFeed(net, Uri.parse(watch.displayName));
  return FetchOutcome(
    releases: entries
        .map(
          (e) => Release(
            watchId: watch.id!,
            // A blog post has no version, so the entry identity is the
            // version: it is what makes the row unique and stable.
            version: e.title.isEmpty ? e.id : e.title,
            publishedAt: e.published,
            notesMd: e.content == null ? null : htmlToPlain(e.content!),
            url: e.url,
          ),
        )
        .toList(),
  );
}

Future<FetchOutcome> _fromRegistry(
  Net net,
  Watch watch, {
  String? token,
}) async {
  final registry = await fetchRegistry(net, watch);
  final repoUrl = registry.repoUrl ?? watch.repoUrl;

  // The registry is authoritative about which versions exist and when they
  // shipped; GitHub is the only source of notes. Merge rather than choosing.
  final notes = <String, Release>{};
  final slug = githubSlug(repoUrl);
  if (slug != null) {
    try {
      final fromGithub = await fetchGithubReleases(
        net,
        slug: slug,
        watchId: watch.id!,
        token: token,
      );
      for (final r in fromGithub) {
        notes[_key(r.version)] = r;
      }
    } on NetException catch (e) {
      // A missing or renamed repo must not cost us the version list, which is
      // the more important half of the answer. A rate limit is temporary and
      // must be surfaced rather than swallowed as "no notes".
      if (e.isRateLimit) rethrow;
    }
  }

  final releases = registry.versions.map((v) {
    final match = notes[_key(v.version)];
    return Release(
      watchId: watch.id!,
      version: v.version,
      publishedAt: v.publishedAt ?? match?.publishedAt,
      notesMd: match?.notesMd,
      url: match?.url,
    );
  }).toList();

  return FetchOutcome(
    releases: releases,
    repoUrl: registry.repoUrl == watch.repoUrl ? null : registry.repoUrl,
  );
}
