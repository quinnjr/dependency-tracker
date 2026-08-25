import 'package:flutter/material.dart';

import '../bootstrap/app_resources.dart';
import '../notify.dart';
import '../refresh.dart';
import '../store.dart';
import 'theme.dart';
import 'watch_detail.dart';
import 'watch_list.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    required this.mutations,
    required this.onRefresh,
    required this.settingsPane,
  });

  final Store store;

  /// Writes the detail pane performs; reads stay on [store].
  final StoreMutations mutations;

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
      // Leads with what was accomplished and appends only the counts that are
      // non-zero, so a clean refresh reads as one short clause instead of
      // "0 failed, 0 new".
      final parts = <String>['${report.refreshed} refreshed'];
      if (report.newReleases > 0) parts.add('${report.newReleases} new');
      if (report.failed > 0) parts.add('${report.failed} failed');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    } catch (_) {
      // The web refresh reaches the server and can fail; a stopped spinner
      // with no word is indistinguishable from success, so say so.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Refresh failed — could not reach the server.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: widget.settingsPane,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);

    // Rebuilding on any store change is what makes an MCP mutation appear in
    // the open window without a refresh button press.
    return NotifierBuilder(
      listenable: widget.store,
      builder: (context) {
        // Every filter's membership is needed anyway — the masthead shows all
        // three counts — so the lists are built once here and the selected one
        // is handed to the list pane. That makes the counts and the rows
        // provably the same query rather than two that could disagree, and
        // watchesByFilter runs the base scan once instead of once per filter.
        final byFilter = widget.store.watchesByFilter();
        final shown = byFilter[_filter]!;

        return Scaffold(
          body: Column(
            children: [
              _Masthead(
                counts: {
                  for (final e in byFilter.entries) e.key: e.value.length,
                },
                selected: _filter,
                onSelect: (f) => setState(() => _filter = f),
                refreshing: _refreshing,
                onRefresh: _refresh,
                onSettings: _openSettings,
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      SizedBox(
                        // Proportional rather than fixed: at a fixed 340 the
                        // list is a quarter of a wide window and the detail
                        // pane becomes a field of empty paper. Clamped at both
                        // ends so a narrow window keeps the list usable and a
                        // very wide one does not turn it into a second pane.
                        width: (box.maxWidth * 0.3).clamp(300.0, 430.0),
                        child: WatchList(
                          store: widget.store,
                          watches: shown,
                          filter: _filter,
                          selectedId: _selected,
                          onSelect: (id) => setState(() => _selected = id),
                        ),
                      ),
                      Container(width: 1, color: t.rule),
                      Expanded(
                        child: WatchDetail(
                          store: widget.store,
                          mutations: widget.mutations,
                          watchId: _selected,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Wordmark, the three counts, and the two window actions.
///
/// The counts are the filter. A dashboard that shows "7 behind" and then makes
/// you find a separate control to see which 7 has spent a row of chrome saying
/// something it could have made actionable instead — so the summary and the
/// navigation are one device, and the number you came to read is the thing you
/// click.
class _Masthead extends StatelessWidget {
  const _Masthead({
    required this.counts,
    required this.selected,
    required this.onSelect,
    required this.refreshing,
    required this.onRefresh,
    required this.onSettings,
  });

  final Map<WatchFilter, int> counts;
  final WatchFilter selected;
  final ValueChanged<WatchFilter> onSelect;
  final bool refreshing;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  static const _labels = {
    WatchFilter.all: 'Watched',
    WatchFilter.unread: 'Unread',
    WatchFilter.outdated: 'Behind',
  };

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.rule)),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 18, right: 8, top: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 14, right: 26),
              child: Text(
                'deptracker',
                style: monoStyle(
                  color: t.ink,
                  size: 14,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            for (final f in WatchFilter.values)
              _CountTab(
                label: _labels[f]!,
                count: counts[f] ?? 0,
                selected: f == selected,
                // Being behind is the only count worth colouring: it is the
                // one that means work. An unread release you have decided to
                // ignore is not a problem, so it stays neutral.
                emphasis: f == WatchFilter.outdated && (counts[f] ?? 0) > 0,
                onTap: () => onSelect(f),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: refreshing ? null : onRefresh,
                    icon: refreshing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: t.slate,
                            ),
                          )
                        : const Icon(Icons.refresh),
                    tooltip: 'Check every watch for new releases',
                  ),
                  IconButton(
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings),
                    tooltip: 'Settings',
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

class _CountTab extends StatelessWidget {
  const _CountTab({
    required this.label,
    required this.count,
    required this.selected,
    required this.emphasis,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final bool emphasis;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final color = emphasis ? t.behind : (selected ? t.ink : t.slate);

    return InkWell(
      onTap: onTap,
      // Selection is a rule under the tab, not a filled pill: the same
      // hairline vocabulary the rest of the window divides things with.
      child: Container(
        padding: const EdgeInsets.only(left: 2, right: 22, bottom: 9),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? t.ink : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: monoStyle(
                color: color,
                size: 21,
                weight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 1),
            Text(label.toUpperCase(), style: eyebrowStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

/// `ListenableBuilder` for a [StoreListenable]: rebuilds [builder] on every
/// notification. Exists because [Store] deliberately does not extend
/// Flutter's `ChangeNotifier` — the server binary runs it on the plain VM
/// where `dart:ui` is unavailable — so this widget is the one bridge from
/// the pure-Dart notifier to the widget tree.
class NotifierBuilder extends StatefulWidget {
  const NotifierBuilder({
    super.key,
    required this.listenable,
    required this.builder,
  });

  final StoreListenable listenable;
  final Widget Function(BuildContext context) builder;

  @override
  State<NotifierBuilder> createState() => _NotifierBuilderState();
}

class _NotifierBuilderState extends State<NotifierBuilder> {
  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(NotifierBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
