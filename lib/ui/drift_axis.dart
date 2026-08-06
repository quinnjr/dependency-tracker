import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../versions.dart';
import 'theme.dart';

/// The version axis: every release the registry has published, as ticks in
/// order, with your own projects' pins marked on it.
///
/// This is the one thing in the window that is not a list. Everything a
/// dependency tool usually says in prose — "3 versions behind", "used at two
/// different versions" — is here as distance instead: the coloured run from
/// your stalest pin to the right-hand end *is* the drift, and marks sitting
/// apart from each other *are* a split across projects.
///
/// Ticks are placed by rank, not by version arithmetic. There is no meaningful
/// metric on version numbers — the distance from 1.9.0 to 2.0.0 is not a
/// number — so the axis measures the only thing that is real: how many
/// releases came between.
class DriftAxis extends StatelessWidget {
  const DriftAxis({
    super.key,
    required this.releaseVersions,
    required this.resolvedPins,
    this.unresolvedPinCount = 0,
  });

  /// Every fetched release, in any order.
  final List<String> releaseVersions;

  /// One entry per project that pins a specific version. Duplicates are
  /// expected and meaningful: three projects on one version is three entries.
  final List<String> resolvedPins;

  /// Projects whose pin is a range rather than a version. They cannot be placed
  /// on the axis without inventing a position, so they are counted and named
  /// in the legend instead.
  final int unresolvedPinCount;

  @override
  Widget build(BuildContext context) {
    final t = tokensOf(context);
    final ordered = [...releaseVersions]..sort(compareVersions);
    if (ordered.isEmpty) return const SizedBox.shrink();

    final rank = <String, int>{
      for (var i = 0; i < ordered.length; i++) ordered[i]: i,
    };

    // A pin naming a version the registry no longer lists (yanked, or a
    // private mirror) has no rank, so it cannot be plotted. Say so rather
    // than dropping it silently.
    final plotted = <int>[];
    var offAxis = 0;
    for (final p in resolvedPins) {
      final i = rank[p];
      if (i == null) {
        offAxis++;
      } else {
        plotted.add(i);
      }
    }

    final stalest = plotted.isEmpty
        ? null
        : plotted.reduce((a, b) => a < b ? a : b);
    final behindBy = stalest == null ? 0 : ordered.length - 1 - stalest;

    return Semantics(
      label: _semanticSummary(ordered, plotted, behindBy, offAxis),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ordered.first, style: monoStyle(color: t.slate, size: 12)),
              const Spacer(),
              Text(
                ordered.last,
                style: monoStyle(
                  color: t.ink,
                  size: 12,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 18,
            child: CustomPaint(
              painter: _AxisPainter(
                tickCount: ordered.length,
                pinRanks: plotted,
                stalestRank: stalest,
                rule: t.rule,
                drift: t.behindMark,
                mark: t.ink,
                current: t.current,
              ),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _legend(ordered, plotted, behindBy, offAxis),
            style: TextStyle(
              fontSize: 12,
              color: behindBy > 0 ? t.behind : t.slate,
            ),
          ),
        ],
      ),
    );
  }

  String _plural(int n, String one, String many) => '$n ${n == 1 ? one : many}';

  /// The prose the axis is standing in for. Read out to a screen reader, and
  /// the reason [Semantics] excludes the painted children: a ruler with no
  /// labels is noise, not information.
  String _semanticSummary(
    List<String> ordered,
    List<int> plotted,
    int behindBy,
    int offAxis,
  ) {
    final parts = <String>[
      '${_plural(ordered.length, 'release', 'releases')} known, '
          'newest ${ordered.last}',
    ];
    if (plotted.isEmpty) {
      parts.add('no project pins a specific version');
    } else {
      final low = ordered[plotted.reduce((a, b) => a < b ? a : b)];
      final high = ordered[plotted.reduce((a, b) => a > b ? a : b)];
      parts.add(
        low == high
            ? '${_plural(plotted.length, 'project', 'projects')} pinned at $low'
            : '${_plural(plotted.length, 'project', 'projects')} pinned between '
                  '$low and $high',
      );
      parts.add(
        behindBy == 0
            ? 'on the newest release'
            : '${_plural(behindBy, 'release', 'releases')} behind the stalest '
                  'pin',
      );
    }
    if (offAxis > 0) {
      parts.add('${_plural(offAxis, 'pin', 'pins')} not among known releases');
    }
    if (unresolvedPinCount > 0) {
      parts.add(
        '${_plural(unresolvedPinCount, 'project', 'projects')} '
        '${unresolvedPinCount == 1 ? 'uses' : 'use'} a range',
      );
    }
    return '${parts.join('. ')}.';
  }

  String _legend(
    List<String> ordered,
    List<int> plotted,
    int behindBy,
    int offAxis,
  ) {
    final parts = <String>[];
    if (plotted.isEmpty) {
      parts.add('no pinned version in your projects');
    } else {
      parts.add('${_plural(plotted.length, 'project', 'projects')} pinned');
      final low = ordered[plotted.reduce((a, b) => a < b ? a : b)];
      parts.add(
        behindBy == 0
            ? 'on the newest release'
            : 'stalest $low, ${_plural(behindBy, 'release', 'releases')} behind',
      );
    }
    if (offAxis > 0) {
      parts.add('${_plural(offAxis, 'pin', 'pins')} off-axis');
    }
    if (unresolvedPinCount > 0) {
      parts.add('${_plural(unresolvedPinCount, 'range', 'ranges')} unplotted');
    }
    return parts.join(' · ');
  }
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({
    required this.tickCount,
    required this.pinRanks,
    required this.stalestRank,
    required this.rule,
    required this.drift,
    required this.mark,
    required this.current,
  });

  final int tickCount;
  final List<int> pinRanks;
  final int? stalestRank;
  final Color rule;
  final Color drift;
  final Color mark;
  final Color current;

  /// Inset so the end marks sit fully inside the widget rather than half
  /// clipped by its edges.
  static const _inset = 5.0;

  double _x(int rank, double width) {
    final span = width - _inset * 2;
    if (tickCount == 1) return _inset + span / 2;
    return _inset + span * (rank / (tickCount - 1));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final left = _x(0, size.width);
    final right = _x(tickCount - 1, size.width);

    final baseline = Paint()
      ..color = rule
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(Offset(left, y), Offset(right, y), baseline);

    // The drift, as distance: the run from the stalest pin to the newest
    // release, thickened and coloured. When every repo is current there is no
    // run to draw and the axis stays entirely neutral — the absence of colour
    // is the "nothing to do here" signal.
    final stalest = stalestRank;
    if (stalest != null && stalest < tickCount - 1) {
      canvas.drawLine(
        Offset(_x(stalest, size.width), y),
        Offset(right, y),
        Paint()
          ..color = drift
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.butt,
      );
    }

    final tick = Paint()
      ..color = rule
      ..strokeWidth = 1;
    for (var i = 0; i < tickCount; i++) {
      final x = _x(i, size.width);
      canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), tick);
    }

    // The newest release always gets a stop, so the right end of the axis
    // reads as an end rather than as a line that ran out of room.
    canvas.drawLine(
      Offset(right, y - 7),
      Offset(right, y + 7),
      Paint()
        ..color = mark
        ..strokeWidth = 1.5,
    );

    // One mark per distinct pinned version, sized by how many projects share
    // it, so a package six projects agree on reads heavier than one only a
    // single project uses.
    final byRank = <int, int>{};
    for (final r in pinRanks) {
      byRank[r] = (byRank[r] ?? 0) + 1;
    }
    byRank.forEach((rank, count) {
      final onNewest = rank == tickCount - 1;
      canvas.drawCircle(
        Offset(_x(rank, size.width), y),
        // Grows with the count but flattens fast: 1 project 3.5px, 6 or more 6px.
        3.5 + (count - 1).clamp(0, 5) * 0.5,
        Paint()..color = onNewest ? current : mark,
      );
    });
  }

  @override
  bool shouldRepaint(_AxisPainter old) =>
      old.tickCount != tickCount ||
      old.stalestRank != stalestRank ||
      !listEquals(old.pinRanks, pinRanks) ||
      old.rule != rule ||
      old.drift != drift ||
      old.mark != mark ||
      old.current != current;
}
