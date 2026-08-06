import 'package:flutter/material.dart';

import '../store.dart';

class WatchDetail extends StatelessWidget {
  const WatchDetail({super.key, required this.store, required this.watchId});

  final Store store;
  final int? watchId;

  @override
  Widget build(BuildContext context) {
    final id = watchId;
    if (id == null) {
      return const Center(child: Text('Select a watch.'));
    }
    final watch = store.watchById(id);
    if (watch == null) {
      return const Center(child: Text('That watch no longer exists.'));
    }

    final usages = store.usagesFor(id);
    final releases = store.releasesFor(id);
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(watch.displayName, style: theme.textTheme.titleLarge),
            ),
            TextButton(
              onPressed: () => store.markRead(id),
              child: const Text('Mark read'),
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
        Text(
          '${watch.kind.name}${watch.repoUrl == null ? '' : ' · ${watch.repoUrl}'}',
          style: theme.textTheme.bodySmall,
        ),
        if (watch.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last refresh failed: ${watch.lastError}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),

        const SizedBox(height: 20),
        Text('Used in', style: theme.textTheme.titleSmall),
        if (usages.isEmpty)
          const Text('No scanned project depends on this.')
        else
          ...usages.map(
            (u) => ListTile(
              dense: true,
              title: Text(u.projectPath),
              subtitle: Text(u.manifestFile),
              // A range is shown as a range: the spec forbids presenting one
              // as though it were a resolved pin.
              trailing: Text(
                u.isResolved ? u.pinnedVersion : '${u.pinnedVersion} (range)',
              ),
            ),
          ),

        const SizedBox(height: 20),
        Text('Releases', style: theme.textTheme.titleSmall),
        if (releases.isEmpty)
          const Text('Nothing fetched yet.')
        else
          ...releases.map(
            (r) => Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          r.version,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: r.read
                                ? FontWeight.normal
                                : FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        if (r.publishedAt != null)
                          Text(
                            r.publishedAt!.toIso8601String().substring(0, 10),
                            style: theme.textTheme.bodySmall,
                          ),
                        if (!r.read)
                          TextButton(
                            onPressed: () =>
                                store.markRead(id, version: r.version),
                            child: const Text('Read'),
                          ),
                      ],
                    ),
                    if (r.notesMd != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SelectableText(r.notesMd!),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
