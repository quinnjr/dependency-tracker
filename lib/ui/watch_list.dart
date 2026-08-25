import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import 'theme.dart';

class WatchList extends StatelessWidget {
  const WatchList({
    super.key,
    required this.store,
    required this.watches,
    required this.filter,
    required this.selectedId,
    required this.onSelect,
  });

  final Store store;

  /// The rows to draw. Supplied rather than queried so the count in the
  /// masthead and the rows underneath it cannot come from two different reads
  /// of the database.
  final List<Watch> watches;

  final WatchFilter filter;
  final int? selectedId;
  final ValueChanged<int> onSelect;

  static const _empty = {
    WatchFilter.all:
        'No watches yet. Add a folder to scan in settings, or ask an agent to '
        'add one over MCP.',
    WatchFilter.unread: 'Nothing new. Every release you watch has been read.',
    WatchFilter.outdated:
        'Nothing behind. Every project is on the newest release of what it '
        'depends on.',
  };

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    if (watches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            _empty[filter]!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: t.slate, height: 1.5),
          ),
        ),
      );
    }

    // Three batched queries for the whole build, rather than three per row:
    // with N watches this is the difference between 3 queries and 3N.
    final ids = watches.map((w) => w.id!);
    final counts = store.countsFor(ids);
    final drift = store.driftFor(ids);

    return ListView.builder(
      itemCount: watches.length,
      itemBuilder: (context, i) {
        final w = watches[i];
        return _WatchRow(
          watch: w,
          unread: counts.unread[w.id] ?? 0,
          usages: counts.usages[w.id] ?? 0,
          drift: drift[w.id],
          selected: w.id == selectedId,
          onTap: () => onSelect(w.id!),
        );
      },
    );
  }
}

class _WatchRow extends StatelessWidget {
  const _WatchRow({
    required this.watch,
    required this.unread,
    required this.usages,
    required this.drift,
    required this.selected,
    required this.onTap,
  });

  final Watch watch;
  final int unread;
  final int usages;
  final Drift? drift;
  final bool selected;
  final VoidCallback onTap;

  /// Short and uppercase: the ecosystem is a column you scan down, not a word
  /// you read. The full kind is spelled out in the detail pane.
  static const _kinds = {
    WatchKind.pub: 'pub',
    WatchKind.npm: 'npm',
    WatchKind.crates: 'crate',
    WatchKind.pypi: 'pypi',
    WatchKind.go: 'go',
    WatchKind.github: 'gh',
    WatchKind.rss: 'rss',
  };

  /// What the row says underneath the package name: how many of your projects
  /// use it, and which versions they hold it at. The version spread is the
  /// whole reason this app dedupes across projects, so it belongs on the row
  /// rather than only in the detail pane.
  String _summary() {
    if (usages == 0) return 'not used by any scanned project';
    final projects = '$usages ${usages == 1 ? 'project' : 'projects'}';
    final d = drift;
    // A null drift is not "no resolved pin" — driftFor omits a watch that
    // has no fetched release yet, so this is a scanned-but-never-refreshed
    // watch whose pins are simply unknown to us, distinct from a watch
    // whose pins really are all ranges (pinnedProjects == 0).
    if (d == null) return '$projects · no releases fetched yet';
    if (d.pinnedProjects == 0) return '$projects · pinned by range only';
    return d.isSplit
        ? '$projects · ${d.lowestPin} → ${d.highestPin}'
        : '$projects · ${d.lowestPin}';
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final d = drift;
    final behind = d?.behindBy ?? 0;

    return InkWell(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? t.rule.withValues(alpha: 0.45) : null,
          border: Border(
            bottom: BorderSide(color: t.rule.withValues(alpha: 0.6)),
            // Selection is a solid rail on the left edge, which is where the
            // eye already is when scanning a list of names.
            left: BorderSide(
              color: selected ? t.ink : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    _kinds[watch.kind]!.toUpperCase(),
                    style: eyebrowStyle(color: t.slate, size: 10),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            watch.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: t.ink,
                              // Unread news thickens the name, so the row
                              // reads as needing attention before any number
                              // on it has been parsed.
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (watch.lastError != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 5),
                            child: Tooltip(
                              message: watch.lastError!,
                              child: Icon(
                                Icons.warning_amber_rounded,
                                size: 15,
                                color: t.behind,
                              ),
                            ),
                          ),
                        if (watch.isSnoozed)
                          Padding(
                            padding: const EdgeInsets.only(left: 5),
                            child: Tooltip(
                              message: 'Snoozed — hidden from Unread',
                              child: Icon(
                                Icons.snooze,
                                size: 15,
                                color: t.slate,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _summary(),
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(color: t.slate, size: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (behind > 0)
                    Text(
                      '$behind BEHIND',
                      style: eyebrowStyle(color: t.behind, size: 10),
                    )
                  else if (d != null && d.isCurrent)
                    Text(
                      'CURRENT',
                      style: eyebrowStyle(color: t.current, size: 10),
                    ),
                  if (unread > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: _UnreadCount(count: unread),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The unread-release count.
///
/// Outlined rather than filled. Filled, it was the highest-contrast object in
/// the window and pulled the eye away from the ochre that actually means work
/// — the one colour this app spends on emphasis. Unreadness is already carried
/// by the row name's weight, so the count only has to be legible, not loud.
class _UnreadCount extends StatelessWidget {
  const _UnreadCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return Container(
      key: const Key('unread-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: t.rule)),
      child: Text(
        '$count',
        style: monoStyle(color: t.slate, size: 11, weight: FontWeight.w600),
      ),
    );
  }
}
