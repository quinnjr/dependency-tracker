import 'fetchers/fetchers.dart';
import 'models.dart';
import 'net.dart';
import 'redact.dart';
import 'store.dart';
import 'versions.dart';

class RefreshReport {
  const RefreshReport({
    required this.refreshed,
    required this.failed,
    required this.newReleases,
    this.rateLimited = false,
    this.staleMarkingFailed = false,
  });

  final int refreshed;
  final int failed;
  final int newReleases;

  /// True when a rate limit stopped this refresh before every watch was
  /// attempted. The remaining, unattempted watches are left stale (their
  /// last_error explains why) rather than counted as failed.
  final bool rateLimited;

  /// True when [rateLimited] is true but the best-effort write marking the
  /// untouched watches stale itself failed (locked database, disk full,
  /// closed store). The counts above are still accurate — they were
  /// computed before this write was attempted — but the untouched watches
  /// were not marked stale, so they will look "never refreshed" rather than
  /// "hit a rate limit" until a later refresh reaches them.
  final bool staleMarkingFailed;
}

/// Recorded on a watch a rate-limited refresh never got to, so the UI and
/// an agent can tell "not yet retried" apart from "this one failed".
const String rateLimitStaleMessage =
    'refresh stopped after a rate limit; not yet retried';

/// The newest version any project actually has pinned, ignoring ranges.
///
/// This is the baseline for the first fetch: releases at or below it are
/// already in use and are not news.
String? highestResolvedUsage(Store store, int watchId) => newestVersion(
  store
      .usagesFor(watchId)
      .where((u) => u.isResolved)
      .map((u) => u.pinnedVersion),
);

/// Marks releases at or below [baseline] as read.
///
/// Without this, adding a watch for a ten-year-old package presents two
/// hundred historical releases as unread news. With no baseline at all — a
/// manual watch with no local usage — everything existing is treated as
/// already seen, so the watch only reports what happens next.
List<Release> applyFirstFetchBaseline(
  List<Release> releases,
  String? baseline,
) => releases
    .map(
      (r) => Release(
        watchId: r.watchId,
        version: r.version,
        publishedAt: r.publishedAt,
        notesMd: r.notesMd,
        url: r.url,
        read: baseline == null || compareVersions(r.version, baseline) <= 0,
      ),
    )
    .toList();

/// Fetches every watch (or just [onlyWatchId]) and reconciles the result into
/// the store. Failures are per-watch: a dead registry, a renamed repo, or a
/// malformed payload records into `watch.last_error` and refresh continues to
/// the next watch, so one bad watch never aborts a refresh of three hundred.
Future<RefreshReport> refreshAll(
  Store store,
  Net net, {
  String? token,
  int? onlyWatchId,
  void Function(int done, int total)? onProgress,
}) async {
  final targets = onlyWatchId == null
      ? store.watches()
      : [store.watchById(onlyWatchId)].whereType<Watch>().toList();

  var refreshed = 0;
  var failed = 0;
  var newReleases = 0;
  var done = 0;

  for (var i = 0; i < targets.length; i++) {
    final watch = targets[i];
    try {
      final outcome = await fetchWatch(net, watch, token: token);

      final isFirstFetch = watch.lastSeenVersion == null;
      final releases = isFirstFetch
          ? applyFirstFetchBaseline(
              outcome.releases,
              highestResolvedUsage(store, watch.id!),
            )
          : outcome.releases;

      newReleases += store.insertReleases(watch.id!, releases);

      store.setWatchMeta(
        watch.id!,
        repoUrl: outcome.repoUrl,
        lastSeenVersion: newestVersion(releases.map((r) => r.version)),
        lastCheckedAt: DateTime.now().toUtc(),
        clearError: true,
      );
      refreshed++;
    } catch (e) {
      // Every failure mode is per-watch: a dead registry, a renamed repo, or a
      // malformed payload must not abort a refresh of three hundred packages.
      // redact() is belt-and-braces here — NetException already redacts, but a
      // FormatException from a registry payload does not.
      store.setWatchMeta(
        watch.id!,
        lastError: redact(e.toString()),
        lastCheckedAt: DateTime.now().toUtc(),
      );
      failed++;

      if (e is NetException && e.isRateLimit) {
        // A rate limit is a property of the host, not of one watch: issuing
        // ~300 more requests at full concurrency, each rejected, is the
        // "retrying in a loop" the spec forbids and is exactly the pattern a
        // secondary rate limiter responds to by extending the block. Stop
        // here rather than continuing to the next watch, and leave every
        // watch this refresh never got to marked stale (not "failed" — it
        // was never attempted) so a later refresh knows to retry it.
        done++;
        onProgress?.call(done, targets.length);

        // Best-effort bookkeeping: the report above is the contract with the
        // caller, and it is already fully computed by this point. If this
        // batched write throws — locked database, disk full, closed store —
        // that must not cost the caller the report; it only means the
        // untouched watches will look "never refreshed" rather than "hit a
        // rate limit" until a later refresh reaches them. Anything other
        // than a realistic database-write failure (a programming error, say)
        // still propagates.
        var staleMarkingFailed = false;
        try {
          store.markUnattemptedStale(
            targets.skip(i + 1).map((w) => w.id!),
            rateLimitStaleMessage,
          );
        } on Exception catch (_) {
          staleMarkingFailed = true;
        } on StateError catch (_) {
          // StateError, not Error broadly: a closed database (Store.close()
          // then a write) throws StateError from sqlite3, which is a
          // realistic best-effort-write failure this catch exists for.
          // TypeError/ArgumentError are programming errors and must keep
          // propagating rather than being swallowed as "stale marking
          // failed".
          staleMarkingFailed = true;
        }
        return RefreshReport(
          refreshed: refreshed,
          failed: failed,
          newReleases: newReleases,
          rateLimited: true,
          staleMarkingFailed: staleMarkingFailed,
        );
      }
    }
    done++;
    onProgress?.call(done, targets.length);
  }

  return RefreshReport(
    refreshed: refreshed,
    failed: failed,
    newReleases: newReleases,
  );
}
