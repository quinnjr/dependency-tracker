import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';

class WatchList extends StatelessWidget {
  const WatchList({
    super.key,
    required this.store,
    required this.filter,
    required this.selectedId,
    required this.onSelect,
  });

  final Store store;
  final WatchFilter filter;
  final int? selectedId;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final watches = store.watches(filter: filter);
    if (watches.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No watches yet. Add a scan root in settings, or add one by hand.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    // One batched query pair for the whole build, rather than two per row:
    // with N watches this is the difference between 2 queries and 2N.
    final counts = store.countsFor(watches.map((w) => w.id!));

    return ListView.builder(
      itemCount: watches.length,
      itemBuilder: (context, i) {
        final w = watches[i];
        final unread = counts.unread[w.id] ?? 0;
        final usages = counts.usages[w.id] ?? 0;

        return ListTile(
          selected: w.id == selectedId,
          onTap: () => onSelect(w.id!),
          leading: _KindChip(kind: w.kind),
          title: Text(w.displayName),
          subtitle: Text(
            usages == 0
                ? 'not used by any scanned project'
                : 'used in $usages ${usages == 1 ? 'project' : 'projects'}',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (w.lastError != null)
                Tooltip(
                  message: w.lastError!,
                  child: const Icon(Icons.warning_amber_rounded, size: 18),
                ),
              if (w.isSnoozed)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.snooze, size: 18),
                ),
              if (unread > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Badge(
                    key: const Key('unread-badge'),
                    label: Text('$unread'),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final WatchKind kind;

  @override
  Widget build(BuildContext context) {
    // Short labels keep the list scannable; the full kind is in the detail pane.
    const labels = {
      WatchKind.pub: 'pub',
      WatchKind.npm: 'npm',
      WatchKind.crates: 'crate',
      WatchKind.pypi: 'pypi',
      WatchKind.go: 'go',
      WatchKind.github: 'gh',
      WatchKind.rss: 'rss',
    };
    return SizedBox(
      width: 44,
      child: Text(labels[kind]!, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
