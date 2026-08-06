import 'package:flutter/material.dart';

import '../refresh.dart';
import '../store.dart';
import 'watch_detail.dart';
import 'watch_list.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    required this.onRefresh,
    required this.settingsPane,
  });

  final Store store;
  final Future<RefreshReport> Function(int? watchId) onRefresh;
  final Widget settingsPane;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  WatchFilter _filter = WatchFilter.all;
  int? _selected;
  var _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final report = await widget.onRefresh(null);
      if (!mounted) return;
      final failed = report.failed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Refreshed ${report.refreshed}'
            '${failed > 0 ? ', $failed failed' : ''}'
            '${report.newReleases > 0 ? ', ${report.newReleases} new' : ''}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: widget.settingsPane,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilding on any store change is what makes an MCP mutation appear in
    // the open window without a refresh button press.
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Dependency Tracker'),
          actions: [
            IconButton(
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Refresh all',
            ),
            IconButton(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              tooltip: 'Settings',
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  for (final (filter, label) in const [
                    (WatchFilter.all, 'All'),
                    (WatchFilter.unread, 'Unread'),
                    (WatchFilter.outdated, 'Outdated'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(label),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: WatchList(
                      store: widget.store,
                      filter: _filter,
                      selectedId: _selected,
                      onSelect: (id) => setState(() => _selected = id),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: WatchDetail(store: widget.store, watchId: _selected),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
