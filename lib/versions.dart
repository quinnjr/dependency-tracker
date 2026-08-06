/// Version ordering across the three dialects this app sees: semver from
/// pub/npm/crates, Go's `v`-prefixed module tags (including pseudo-versions
/// built from a commit timestamp and hash), and PEP 440 from PyPI.
///
/// Each version parses structurally into four components: a numeric
/// `release` list, an optional semver-style `pre` identifier list, and PEP
/// 440's `post` and `dev` release numbers. Precedence within an equal
/// release follows PEP 440: dev < pre < release < post. A version that
/// could not be fully consumed by parsing is marked `malformed` and always
/// sorts below one that parsed cleanly, so a caller never reads a degraded
/// parse as "confirmed equal" to real input.
///
/// Deliberately lenient: registries occasionally publish strings that are
/// not versions at all (`nightly`, `latest`). Those never throw; they parse
/// to a malformed, empty release and compare equal to each other, but below
/// anything that parsed cleanly, because one weird tag must not fail a whole
/// refresh.
int compareVersions(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);

  if (pa.malformed != pb.malformed) {
    // A clean parse always outranks a malformed one.
    return pa.malformed ? -1 : 1;
  }

  final releaseCmp = _compareReleaseLists(pa.release, pb.release);
  if (releaseCmp != 0) return releaseCmp;

  final ra = _rank(pa);
  final rb = _rank(pb);
  if (ra != rb) return ra < rb ? -1 : 1;

  switch (ra) {
    case 0: // dev-only release
      return (pa.dev ?? 0).compareTo(pb.dev ?? 0);
    case 1: // prerelease
      final m = pa.pre.length > pb.pre.length ? pa.pre.length : pb.pre.length;
      for (var i = 0; i < m; i++) {
        if (i >= pa.pre.length) return -1; // fewer identifiers sorts lower
        if (i >= pb.pre.length) return 1;
        final c = _comparePreIdentifier(pa.pre[i], pb.pre[i]);
        if (c != 0) return c;
      }
      return _compareDevTiebreak(pa.dev, pb.dev);
    case 3: // post-release
      if (pa.post != pb.post) return (pa.post ?? 0).compareTo(pb.post ?? 0);
      return _compareDevTiebreak(pa.dev, pb.dev);
    default: // rank 2: plain final release
      return 0;
  }
}

/// When two versions are otherwise tied within a rank, one carrying a dev
/// suffix (e.g. `1.0a1.dev1`) is lower than the equivalent without it.
int _compareDevTiebreak(int? devA, int? devB) {
  if ((devA != null) != (devB != null)) return devA != null ? -1 : 1;
  if (devA != null && devB != null) return devA.compareTo(devB);
  return 0;
}

/// Numeric identifiers compare numerically and sort below alphanumeric ones,
/// per semver. `alpha.9` therefore precedes `alpha.10`.
int _comparePreIdentifier(String a, String b) {
  final na = int.tryParse(a);
  final nb = int.tryParse(b);
  if (na != null && nb != null) return na.compareTo(nb);
  if (na != null) return -1;
  if (nb != null) return 1;
  return a.compareTo(b);
}

int _compareReleaseLists(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Precedence rank within an equal release: dev < pre < release < post.
int _rank(_Parsed p) {
  if (p.dev != null && p.pre.isEmpty && p.post == null) return 0;
  if (p.pre.isNotEmpty) return 1;
  if (p.post != null) return 3;
  return 2;
}

/// True when [s] parses to a clean (non-malformed) version under the same
/// structural parser [compareVersions] uses. Callers that need to gate on
/// "is this a real, comparable version" — rather than compare two of them —
/// should use this instead of inventing a second, stricter regex: a pin
/// gate that is pickier than the comparator it feeds produces a version
/// that is stored but can never be compared, which is worse than storing
/// nothing.
bool isWellFormedVersion(String s) => !_parse(s).malformed;

String? newestVersion(Iterable<String> versions) {
  String? best;
  for (final v in versions) {
    if (best == null || compareVersions(v, best) > 0) best = v;
  }
  return best;
}

class _Parsed {
  const _Parsed({
    required this.malformed,
    required this.release,
    required this.pre, // empty means "no prerelease"
    this.post,
    this.dev,
  });

  final bool malformed;
  final List<int> release;
  final List<String> pre;
  final int? post;
  final int? dev;
}

final _releaseRegex = RegExp(r'^\d+(?:\.\d+)*');

// Longer alternatives are listed before the shorter ones they share a
// prefix with (`alpha` before `a`, `preview` before `pre`) — regex
// alternation takes the first alternative that matches, not the longest,
// so ordering here controls correctness.
final _preSuffixRegex = RegExp(
  r'^[-_.]?(preview|alpha|beta|rc|pre|a|b|c)[-_.]?(\d+)?',
  caseSensitive: false,
);
final _postSuffixRegex = RegExp(
  r'^[-_.]?(post|rev|r)[-_.]?(\d+)?',
  caseSensitive: false,
);
final _devSuffixRegex = RegExp(
  r'^[-_.]?(dev)[-_.]?(\d+)?',
  caseSensitive: false,
);

_Parsed _parse(String raw) {
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final plusIndex = s.indexOf('+');
  if (plusIndex != -1) s = s.substring(0, plusIndex); // build metadata

  var malformed = false;
  final release = <int>[];
  var remainder = s;

  final releaseMatch = _releaseRegex.matchAsPrefix(s);
  if (releaseMatch == null) {
    malformed = true;
  } else {
    for (final seg in releaseMatch.group(0)!.split('.')) {
      release.add(int.parse(seg));
    }
    remainder = s.substring(releaseMatch.end);
  }

  var pre = const <String>[];
  int? post;
  int? dev;

  if (remainder.startsWith('-')) {
    // Semver prerelease path, and how Go pseudo-versions
    // (`v0.0.0-20260101120000-4f9a2c1e8b3d`) stay intact as opaque
    // identifiers instead of being shredded by PEP 440 suffix parsing.
    pre = remainder
        .substring(1)
        .split(RegExp(r'[-.]'))
        .where((p) => p.isNotEmpty)
        .toList();
  } else if (remainder.isNotEmpty) {
    final preMatch = _preSuffixRegex.matchAsPrefix(remainder);
    if (preMatch != null) {
      final token = preMatch.group(1)!.toLowerCase();
      final num = preMatch.group(2) ?? '0';
      pre = [token, num];
      remainder = remainder.substring(preMatch.end);
    }

    final postMatch = _postSuffixRegex.matchAsPrefix(remainder);
    if (postMatch != null) {
      post = int.parse(postMatch.group(2) ?? '0');
      remainder = remainder.substring(postMatch.end);
    }

    final devMatch = _devSuffixRegex.matchAsPrefix(remainder);
    if (devMatch != null) {
      dev = int.parse(devMatch.group(2) ?? '0');
      remainder = remainder.substring(devMatch.end);
    }

    if (remainder.isNotEmpty) malformed = true;
  }

  return _Parsed(
    malformed: malformed,
    release: release,
    pre: pre,
    post: post,
    dev: dev,
  );
}
