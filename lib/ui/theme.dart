import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// The window's design tokens.
///
/// These are the same values the project page at `docs/index.html` uses, and
/// deliberately so: it is one product, so it gets one identity rather than a
/// homepage that looks nothing like the thing it advertises.
///
/// The ground is a cool green-grey rather than white or cream — a neutral with
/// a slight bias toward the "current" green, so it reads as chosen. There is no
/// decorative accent hue anywhere in the app: the only saturated colors are
/// [behind] and [current], which carry meaning. That constraint is the point.
/// Anything eye-catching in this window is something the user needs to act on.
@immutable
class DriftTokens extends ThemeExtension<DriftTokens> {
  const DriftTokens({
    required this.paper,
    required this.ink,
    required this.slate,
    required this.rule,
    required this.behind,
    required this.behindMark,
    required this.current,
  });

  /// Page ground.
  final Color paper;

  /// Primary text.
  final Color ink;

  /// Secondary text: labels, paths, anything supporting.
  final Color slate;

  /// Hairlines. Every division in this app is a 1px rule, not a card edge.
  final Color rule;

  /// "Your repos are behind" — text weight.
  final Color behind;

  /// "Your repos are behind" — marks and fills, which need more chroma than
  /// text does to read at 6px.
  final Color behindMark;

  /// "Your repos are on the newest release."
  final Color current;

  /// Light theme. The values a designer would name if asked for "paper you
  /// could read a dependency audit off of."
  static const light = DriftTokens(
    paper: Color(0xFFE7ECE8),
    ink: Color(0xFF101614),
    slate: Color(0xFF55655E),
    rule: Color(0xFFBFCBC4),
    behind: Color(0xFF8A6510),
    behindMark: Color(0xFFB4881A),
    current: Color(0xFF2C5A48),
  );

  /// Dark theme. Not an inversion: the semantic pair is re-picked so both
  /// colors still carry their meaning against a dark ground, where the light
  /// theme's ochre goes muddy and its green goes invisible.
  static const dark = DriftTokens(
    paper: Color(0xFF0D1211),
    ink: Color(0xFFDCE4E0),
    slate: Color(0xFF8B9A94),
    rule: Color(0xFF263030),
    behind: Color(0xFFD9A72E),
    behindMark: Color(0xFFD9A72E),
    current: Color(0xFF6FB394),
  );

  @override
  DriftTokens copyWith({
    Color? paper,
    Color? ink,
    Color? slate,
    Color? rule,
    Color? behind,
    Color? behindMark,
    Color? current,
  }) => DriftTokens(
    paper: paper ?? this.paper,
    ink: ink ?? this.ink,
    slate: slate ?? this.slate,
    rule: rule ?? this.rule,
    behind: behind ?? this.behind,
    behindMark: behindMark ?? this.behindMark,
    current: current ?? this.current,
  );

  @override
  DriftTokens lerp(DriftTokens? other, double t) {
    if (other == null) return this;
    return DriftTokens(
      paper: Color.lerp(paper, other.paper, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      slate: Color.lerp(slate, other.slate, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      behind: Color.lerp(behind, other.behind, t)!,
      behindMark: Color.lerp(behindMark, other.behindMark, t)!,
      current: Color.lerp(current, other.current, t)!,
    );
  }
}

/// Reads the tokens for the current theme.
///
/// Falls back to [DriftTokens.light] rather than throwing, so a widget lifted
/// into a bare `MaterialApp` — which is exactly what most of the widget tests
/// do — still renders instead of crashing on a null extension.
DriftTokens tokensOf(BuildContext context) =>
    Theme.of(context).extension<DriftTokens>() ?? DriftTokens.light;

/// The monospace stack used for every version string, filesystem path, port
/// and token in the app.
///
/// No font is bundled. A committed face would cost a few hundred KB across
/// three desktop bundles and a Flatpak for a personality this app does not
/// keep in its display type — it keeps it in how the data is set. What matters
/// here is that the digits are tabular so a column of versions aligns, and
/// every platform's default mono already gives that.
const _monoFallback = <String>[
  'SF Mono',
  'Menlo',
  'Consolas',
  'Cascadia Mono',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'monospace',
];

/// Versions, paths, ports, tokens: anything the user might compare
/// character-by-character against something else on screen.
TextStyle monoStyle({
  required Color color,
  double size = 13,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: _monoFallback,
  fontSize: size,
  fontWeight: weight,
  color: color,
  height: 1.35,
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Section headers and the ecosystem mark. Uppercase and tracked wide, so it
/// reads as structure rather than as something to read.
TextStyle eyebrowStyle({required Color color, double size = 11}) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.09 * size,
  color: color,
);

/// Builds the app theme for one brightness.
///
/// Two deliberate departures from Material's defaults, both in service of this
/// being an instrument you glance at rather than an app you swipe:
///
/// Nothing is rounded. Material 3 wants 12–28px radii; a table of versions
/// wants square edges and hairlines, and radius on a data row is decoration
/// that costs legibility at the row's left edge.
///
/// Nothing splashes. Tap feedback is removed but hover and keyboard focus are
/// kept and strengthened — the goal is a still window, not an unresponsive
/// one, and dropping the focus highlight along with the ripple would trade a
/// design preference for an accessibility regression.
ThemeData buildTheme(Brightness brightness) {
  final t = brightness == Brightness.dark
      ? DriftTokens.dark
      : DriftTokens.light;

  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.current,
        brightness: brightness,
      ).copyWith(
        surface: t.paper,
        onSurface: t.ink,
        outline: t.rule,
        outlineVariant: t.rule,
        error: t.behind,
      );

  const square = RoundedRectangleBorder(borderRadius: BorderRadius.zero);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: t.paper,
    canvasColor: t.paper,
    dividerColor: t.rule,
    splashFactory: NoSplash.splashFactory,
    highlightColor: t.rule.withValues(alpha: 0.45),
    hoverColor: t.rule.withValues(alpha: 0.30),
    focusColor: t.rule.withValues(alpha: 0.55),
    extensions: [t],
    dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
    textTheme: Typography.material2021(
      platform: defaultTargetPlatform,
      colorScheme: scheme,
    ).black.apply(bodyColor: t.ink, displayColor: t.ink),
    iconTheme: IconThemeData(color: t.slate, size: 18),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: t.ink, borderRadius: BorderRadius.zero),
      textStyle: TextStyle(fontSize: 12, color: t.paper),
      waitDuration: const Duration(milliseconds: 400),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.ink,
        shape: square,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        side: BorderSide(color: t.rule),
        shape: square,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        minimumSize: const Size(0, 34),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.ink,
        foregroundColor: t.paper,
        shape: square,
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        minimumSize: const Size(0, 34),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: brightness == Brightness.dark
          ? t.rule.withValues(alpha: 0.35)
          : Colors.white.withValues(alpha: 0.55),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: t.rule),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: t.rule),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: t.ink, width: 1.5),
      ),
      labelStyle: TextStyle(color: t.slate, fontSize: 13),
      hintStyle: TextStyle(color: t.slate, fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.ink,
      contentTextStyle: TextStyle(color: t.paper, fontSize: 13),
      shape: square,
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: t.rule),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.slate),
  );
}
