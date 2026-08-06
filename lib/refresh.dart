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
  ///
  /// The watch that itself hit the limit is also excluded from [failed] — it
  /// got no data, so counting it as a failure would blame the package for the
  /// host's throttling. It keeps its own 429 error rather than the generic
  /// stale message, since it is the only record of which host stopped the run.
  /// So on a rate-limited run `refreshed + failed` does not account for every
  /// watch that was attempted.
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
///
/// Watches are pulled off a shared queue by [concurrency] workers (default 8,
/// matching [Net]'s own semaphore cap) rather than awaited one at a time.
/// Dispatching every watch as an independent future and leaning on `Net`'s
/// semaphore to throttle would give the same throughput but destroy the
/// rate-limit short-circuit below: once a future is created its request is
/// already queued inside `Net` and cannot be un-issued. A worker pool can
/// simply stop pulling new work instead.
///
/// No locking guards `refreshed`/`failed`/`newReleases`/the queue index:
/// Dart is single-threaded per isolate, so an `await` is the only place
/// another worker gets to run, and every `Store` call here is a synchronous
/// sqlite3 FFI call (see `lib/store.dart`, `package:sqlite3/sqlite3.dart`) —
/// nothing preempts mid-statement. Claiming the next queue index is a plain
/// read-then-increment with no `await` in between, so two workers can never
/// claim the same index, and the `+=`/`++` counters are commutative, so their
/// final totals do not depend on which worker's `await` resolves first.
Future<RefreshReport> refreshAll(
  Store store,
  Net net, {
  String? token,
  int? onlyWatchId,
  void Function(int done, int total)? onProgress,
  int concurrency = 8,
}) async {
  if (concurrency < 1) {
    // Zero would build zero workers, so Future.wait([]) returns at once and
    // the report reads refreshed: 0, failed: 0 — indistinguishable from "all
    // up to date" while nothing was fetched. Rejecting matches how the MCP
    // layer treats a limit below 1 rather than degrading quietly.
    throw ArgumentError.value(concurrency, 'concurrency', 'must be at least 1');
  }

  final targets = onlyWatchId == null
      ? store.watches()
      : [store.watchById(onlyWatchId)].whereType<Watch>().toList();

  var refreshed = 0;
  var failed = 0;
  var newReleases = 0;
  var done = 0;
  var nextIndex = 0;

  // Set on a rate-limit exception from any worker. Workers finish the watch
  // they are already on (an in-flight request cannot be un-issued) but take
  // no further work off the queue once this is true.
  var stopped = false;

  // Every watch that itself raised the rate limit. It got no data — it
  // belongs with the retry set (see below), not with `failed`.
  final rateLimitedIds = <int>{};

  Future<void> processOne(Watch watch) async {
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
      final isRateLimit = e is NetException && e.isRateLimit;

      // Best-effort, for the same reason markUnattemptedStale is: the report
      // is the contract with the caller, and by this point the watches that
      // already succeeded are committed. Letting a failed bookkeeping write
      // escape here would propagate out of Future.wait and throw away the
      // totals for every one of them.
      try {
        store.setWatchMeta(
          watch.id!,
          lastError: redact(e.toString()),
          // A rate-limited watch is grouped with the ones never dequeued, so
          // stamping it as checked would make it claim a freshness it does
          // not have. setWatchMeta leaves a null lastCheckedAt untouched.
          lastCheckedAt: isRateLimit ? null : DateTime.now().toUtc(),
        );
      } catch (_) {
        // The watch keeps its previous error; the counts below still stand.
      }

      if (isRateLimit) {
        // A rate limit is a property of the host, not of one watch: issuing
        // ~300 more requests at full concurrency, each rejected, is the
        // "retrying in a loop" the spec forbids and is exactly the pattern a
        // secondary rate limiter responds to by extending the block. This
        // watch got no data, so — like every watch never dequeued — it is
        // left for a later refresh to retry rather than counted as failed.
        stopped = true;
        rateLimitedIds.add(watch.id!);
      } else {
        failed++;
      }
    }
    done++;
    onProgress?.call(done, targets.length);
  }

  Future<void> worker() async {
    while (!stopped) {
      if (nextIndex >= targets.length) return;
      final watch = targets[nextIndex];
      nextIndex++;
      await processOne(watch);
    }
  }

  final workerCount = concurrency < targets.length
      ? concurrency
      : targets.length;
  await Future.wait(List.generate(workerCount, (_) => worker()));

  if (stopped) {
    // Unattempted = every watch never dequeued: indices from nextIndex on,
    // frozen once every worker observed `stopped` and returned.
    //
    // The watches that themselves hit the limit are deliberately NOT included,
    // even though they also got no data. markUnattemptedStale overwrites
    // last_error, and theirs is the only record of which host rate-limited
    // this run and with what status — replacing it with "not yet retried"
    // would destroy the one diagnostic worth having, and would claim they were
    // never attempted when they were.
    final unattemptedIds = <int>{
      for (var i = nextIndex; i < targets.length; i++) targets[i].id!,
    };

    // Best-effort bookkeeping: the report below is the contract with the
    // caller, and it is already fully computed by this point. If this
    // batched write throws — locked database, disk full, closed store —
    // that must not cost the caller the report; it only means the untouched
    // watches will look "never refreshed" rather than "hit a rate limit"
    // until a later refresh reaches them. Anything other than a realistic
    // database-write failure (a programming error, say) still propagates.
    var staleMarkingFailed = false;
    try {
      store.markUnattemptedStale(unattemptedIds, rateLimitStaleMessage);
    } on Exception catch (_) {
      staleMarkingFailed = true;
    } on StateError catch (_) {
      // StateError, not Error broadly: a closed database (Store.close()
      // then a write) throws StateError from sqlite3, which is a
      // realistic best-effort-write failure this catch exists for.
      // TypeError/ArgumentError are programming errors and must keep
      // propagating rather than being swallowed as "stale marking failed".
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

  return RefreshReport(
    refreshed: refreshed,
    failed: failed,
    newReleases: newReleases,
  );
}
