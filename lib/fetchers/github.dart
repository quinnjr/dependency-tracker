import 'dart:convert';

import '../models.dart';
import '../net.dart';
import 'feed.dart';

Uri githubFeedUrl(String slug, {bool tags = false}) =>
    Uri.parse('https://github.com/$slug/${tags ? 'tags' : 'releases'}.atom');

Uri _apiReleasesUrl(String slug) =>
    Uri.parse('https://api.github.com/repos/$slug/releases?per_page=30');

final RegExp _versionShaped = RegExp(r'v?\d+(\.\d+)+([-+][0-9A-Za-z.-]+)?');

/// Recovers the tag a feed entry describes.
///
/// A release title is free text — "Release day!" is common — so the tag is read
/// from the structured fields first and the title is only a last resort.
String? versionFromGithubEntry(FeedEntry entry) {
  // GitHub ids look like `tag:github.com,2008:Repository/1234/v1.2.2`.
  final fromId = entry.id.split('/').last;
  if (_versionShaped.matchAsPrefix(fromId) != null &&
      _versionShaped.firstMatch(fromId)?.group(0) == fromId) {
    return fromId;
  }

  final url = entry.url;
  if (url != null) {
    final match = RegExp(r'/releases/tag/([^/?#]+)$').firstMatch(url);
    if (match != null) return match.group(1);
    final tagMatch = RegExp(r'/tree/([^/?#]+)$').firstMatch(url);
    if (tagMatch != null) return tagMatch.group(1);
  }

  return _versionShaped.firstMatch(entry.title)?.group(0);
}

/// Converts a release body's HTML into readable plain text.
///
/// Tag-stripping, not an HTML parser. The token path already returns real
/// Markdown, so this only has to make the tokenless path legible.
String htmlToPlain(String html) {
  var out = html;
  out = out.replaceAll(
    RegExp(
      r'<(script|style)\b[^>]*>.*?</\1>',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );
  out = out.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ');
  // </li> is deliberately excluded here: the opening tag above already
  // inserted the bullet's newline, so a block-boundary newline on the
  // closing tag too would put a blank line between every bullet.
  out = out.replaceAll(
    RegExp(r'</(p|div|ul|ol|h[1-6]|tr|blockquote)>', caseSensitive: false),
    '\n\n',
  );
  out = out.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  out = out.replaceAll(RegExp(r'<[^>]+>'), '');

  out = out
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      // Ampersand last, so &amp;lt; does not become a tag delimiter.
      .replaceAll('&amp;', '&');

  out = out.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return out.trim();
}

Future<List<Release>> fetchGithubReleases(
  Net net, {
  required String slug,
  required int watchId,
  String? token,
}) async {
  if (token != null && token.isNotEmpty) {
    try {
      return await _fromApi(net, slug: slug, watchId: watchId, token: token);
    } on NetException catch (e) {
      // A bad or expired token should degrade to the tokenless path rather than
      // leaving the watch permanently broken. Rate limiting is different: it is
      // temporary and worth surfacing so the user knows to wait.
      if (e.isRateLimit) rethrow;
      if (e.status != 401 && e.status != 403) rethrow;
    }
  }

  final releases = await _fromFeed(net, slug: slug, watchId: watchId);
  if (releases.isNotEmpty) return releases;

  // Plenty of packages tag but never cut a GitHub release.
  return _fromFeed(net, slug: slug, watchId: watchId, tags: true);
}

Future<List<Release>> _fromFeed(
  Net net, {
  required String slug,
  required int watchId,
  bool tags = false,
}) async {
  final entries = await fetchFeed(net, githubFeedUrl(slug, tags: tags));
  final out = <Release>[];
  for (final e in entries) {
    final version = versionFromGithubEntry(e);
    // An entry with no recoverable tag cannot be compared to a pinned version,
    // and a release row keyed on a marketing title would never match.
    if (version == null) continue;
    final content = e.content;
    out.add(
      Release(
        watchId: watchId,
        version: version,
        publishedAt: e.published,
        notesMd: content == null ? null : htmlToPlain(content),
        url: e.url,
      ),
    );
  }
  return out;
}

Future<List<Release>> _fromApi(
  Net net, {
  required String slug,
  required int watchId,
  required String token,
}) async {
  final response = await net.get(
    _apiReleasesUrl(slug),
    headers: {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
  );

  final decoded = jsonDecode(response.body);
  if (decoded is! List) {
    throw const FormatException('expected a JSON array of releases');
  }

  final out = <Release>[];
  for (final r in decoded.whereType<Map>()) {
    // A draft is not published, so it is not a version anyone can depend on.
    if (r['draft'] == true) continue;
    final tag = r['tag_name'];
    if (tag is! String) continue;
    final body = r['body'];
    out.add(
      Release(
        watchId: watchId,
        version: tag,
        publishedAt: DateTime.tryParse(
          r['published_at'] as String? ?? '',
        )?.toUtc(),
        // The API returns Markdown already; converting it would only damage it.
        notesMd: (body is String && body.trim().isNotEmpty) ? body : null,
        url: r['html_url'] as String?,
      ),
    );
  }
  return out;
}
