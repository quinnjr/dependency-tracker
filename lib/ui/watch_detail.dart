import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../versions.dart';
import 'drift_axis.dart';
import 'theme.dart';

class WatchDetail extends StatelessWidget {
  const WatchDetail({super.key, required this.store, required this.watchId});

  final Store store;
  final int? watchId;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final id = watchId;
    if (id == null) {
      return _Placeholder(
        text: 'Pick a package to see its drift and where it is used.',
      );
    }
    final watch = store.watchById(id);
    if (watch == null) {
      return _Placeholder(text: 'That watch no longer exists.');
    }

    final usages = store.usagesFor(id);
    final releases = store.releasesFor(id);
    final resolvedPins = [
      for (final u in usages)
        if (u.isResolved) u.pinnedVersion,
    ];
    final newestPin = newestVersion(resolvedPins);

    return _Measure(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _Header(store: store, watch: watch),

          if (watch.lastError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
              decoration: BoxDecoration(
                color: t.behindMark.withValues(alpha: 0.14),
                border: Border(left: BorderSide(color: t.behindMark, width: 3)),
              ),
              child: Text(
                'Last refresh failed: ${watch.lastError}',
                style: TextStyle(fontSize: 12.5, color: t.behind, height: 1.4),
              ),
            ),

          // The drift axis first, because it answers the question the user opened
          // the row to ask. Everything below it is the detail behind that answer.
          //
          // Dropped entirely when nothing has been fetched: with no releases
          // there is no axis to draw, and a section header over the words
          // "nothing yet" is a heading that earns its own space back in nothing.
          // The Releases section below already says it once.
          if (releases.isNotEmpty)
            _Section(
              label: 'Drift',
              child: DriftAxis(
                releaseVersions: [for (final r in releases) r.version],
                resolvedPins: resolvedPins,
                unresolvedPinCount: usages.length - resolvedPins.length,
              ),
            ),

          _Section(
            label: 'Used in',
            child: usages.isEmpty
                ? Text(
                    'No scanned project depends on this.',
                    style: TextStyle(fontSize: 13, color: t.slate),
                  )
                : Column(
                    children: [for (final u in usages) _UsageRow(usage: u)],
                  ),
          ),

          _Section(
            label: 'Releases',
            child: releases.isEmpty
                ? Text(
                    'Nothing fetched yet.',
                    style: TextStyle(fontSize: 13, color: t.slate),
                  )
                : Column(
                    children: [
                      for (final r in releases)
                        _ReleaseRow(
                          release: r,
                          // A release newer than the newest version any project
                          // holds is one nobody has taken yet. That is a
                          // different thing from unread, which only records
                          // whether it has been looked at.
                          aheadOfEveryProject:
                              newestPin != null &&
                              compareVersions(r.version, newestPin) > 0,
                          onRead: () =>
                              store.markRead(watchId!, version: r.version),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }
}

/// Caps how wide the detail pane's content runs and pins it to the leading
/// edge.
///
/// Release notes set across a 900px pane are unreadable, and a usage table
/// stretched that far puts a project path and its version at opposite ends of
/// the screen with nothing between them. Left-aligned rather than centred so
/// the pane's content stays in line with the list beside it.
class _Measure extends StatelessWidget {
  const _Measure({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: child,
    ),
  );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: t.slate),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store, required this.watch});

  final Store store;
  final Watch watch;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final id = watch.id!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 14, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  watch.displayName,
                  style: monoStyle(
                    color: t.ink,
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => store.markRead(id),
                child: const Text('Mark all read'),
              ),
              TextButton(
                onPressed: () => store.snooze(
                  id,
                  DateTime.now().toUtc().add(const Duration(days: 30)),
                ),
                child: const Text('Snooze 30d'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                watch.kind.name.toUpperCase(),
                style: eyebrowStyle(color: t.slate, size: 10),
              ),
              if (watch.repoUrl != null) ...[
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    watch.repoUrl!,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: t.slate, size: 11.5),
                  ),
                ),
              ],
              if (watch.isSnoozed) ...[
                const SizedBox(width: 10),
                Text(
                  'SNOOZED UNTIL '
                  '${watch.snoozedUntil!.toIso8601String().substring(0, 10)}',
                  style: eyebrowStyle(color: t.slate, size: 10),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A titled band. The eyebrow above a hairline is the only structural device in
/// the pane — there are no cards, because a card around a row of version
/// numbers adds an edge to look at without adding anything to read.
class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: eyebrowStyle(color: t.slate)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.usage});

  final Usage usage;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Tooltip(
              message: usage.projectPath,
              child: Text(
                usage.projectPath,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(color: t.ink, size: 12.5),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              usage.manifestFile,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: t.slate, size: 12.5),
            ),
          ),
          if (usage.isDevDep) ...[
            const SizedBox(width: 8),
            Text('DEV', style: eyebrowStyle(color: t.slate, size: 9)),
          ],
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                // A range is marked as a range rather than dressed up as a
                // resolved version: the spec forbids presenting one as though
                // it were a pin, and a separate marker is harder to misread at
                // a glance than a parenthetical.
                //
                // The marker sits to the left of the version, not the right, so
                // every version in the column still ends at the same x and the
                // tabular figures actually line up — which is the entire reason
                // this column is set in mono.
                if (!usage.isResolved) ...[
                  Text('RANGE', style: eyebrowStyle(color: t.slate, size: 9)),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    usage.pinnedVersion,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: usage.isResolved ? t.ink : t.slate,
                      size: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.aheadOfEveryProject,
    required this.onRead,
  });

  final Release release;
  final bool aheadOfEveryProject;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.fromLTRB(11, 9, 0, 9),
      decoration: BoxDecoration(
        // The rail marks releases no project has taken yet — the ones that
        // represent outstanding work, as opposed to merely unread ones.
        border: Border(
          left: BorderSide(
            color: aheadOfEveryProject ? t.behindMark : t.rule,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                release.version,
                style: monoStyle(
                  color: t.ink,
                  size: 13.5,
                  weight: release.read ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
              if (release.publishedAt != null) ...[
                const SizedBox(width: 12),
                Text(
                  release.publishedAt!.toIso8601String().substring(0, 10),
                  style: monoStyle(color: t.slate, size: 12),
                ),
              ],
              const Spacer(),
              if (!release.read)
                TextButton(onPressed: onRead, child: const Text('Read')),
            ],
          ),
          if (release.notesMd != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 16),
              child: SelectableText(
                release.notesMd!,
                style: TextStyle(fontSize: 12.5, color: t.slate, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
