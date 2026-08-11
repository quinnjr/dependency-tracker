import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:deptracker/ui/theme.dart';

void main() {
  test('both brightnesses carry their own token set', () {
    final light = buildTheme(Brightness.light).extension<DriftTokens>()!;
    final dark = buildTheme(Brightness.dark).extension<DriftTokens>()!;
    expect(light, same(DriftTokens.light));
    expect(dark, same(DriftTokens.dark));
    expect(dark.paper.computeLuminance(), lessThan(0.1));
    expect(light.paper.computeLuminance(), greaterThan(0.6));
  });

  test('the semantic pair stays distinguishable on both grounds', () {
    // The two colours that carry meaning have to survive the theme switch: a
    // dark theme built by inverting the light one leaves "current" nearly
    // invisible and "behind" muddy, which would silently drop the only signal
    // in the window.
    for (final t in [DriftTokens.light, DriftTokens.dark]) {
      final ground = t.paper.computeLuminance();
      for (final c in [t.behind, t.behindMark, t.current]) {
        expect(
          (c.computeLuminance() - ground).abs(),
          greaterThan(0.1),
          reason: 'a semantic colour must not sink into the ground',
        );
      }
      expect(t.behind, isNot(t.current));
    }
  });

  test('copyWith replaces only what it is given', () {
    final t = DriftTokens.light.copyWith(behind: const Color(0xFF112233));
    expect(t.behind, const Color(0xFF112233));
    expect(t.paper, DriftTokens.light.paper);
    expect(t.ink, DriftTokens.light.ink);
    expect(t.slate, DriftTokens.light.slate);
    expect(t.rule, DriftTokens.light.rule);
    expect(t.behindMark, DriftTokens.light.behindMark);
    expect(t.current, DriftTokens.light.current);
  });

  test('copyWith with no arguments is a faithful copy', () {
    final t = DriftTokens.light.copyWith();
    expect(t.paper, DriftTokens.light.paper);
    expect(t.behind, DriftTokens.light.behind);
    expect(t.current, DriftTokens.light.current);
  });

  test('lerp crosses from one token set to the other', () {
    // Flutter calls this when a theme change animates; a lerp that dropped a
    // field would flash the wrong colour mid-transition.
    final mid = DriftTokens.light.lerp(DriftTokens.dark, 0.5);
    expect(
      mid.paper,
      Color.lerp(DriftTokens.light.paper, DriftTokens.dark.paper, 0.5),
    );
    expect(
      mid.ink,
      Color.lerp(DriftTokens.light.ink, DriftTokens.dark.ink, 0.5),
    );
    expect(
      mid.slate,
      Color.lerp(DriftTokens.light.slate, DriftTokens.dark.slate, 0.5),
    );
    expect(
      mid.rule,
      Color.lerp(DriftTokens.light.rule, DriftTokens.dark.rule, 0.5),
    );
    expect(
      mid.behindMark,
      Color.lerp(
        DriftTokens.light.behindMark,
        DriftTokens.dark.behindMark,
        0.5,
      ),
    );
    expect(
      mid.current,
      Color.lerp(DriftTokens.light.current, DriftTokens.dark.current, 0.5),
    );

    expect(
      DriftTokens.light.lerp(DriftTokens.dark, 0).paper,
      DriftTokens.light.paper,
    );
    expect(
      DriftTokens.light.lerp(DriftTokens.dark, 1).paper,
      DriftTokens.dark.paper,
    );
  });

  test('lerp against a null other keeps this set', () {
    expect(DriftTokens.light.lerp(null, 0.5), same(DriftTokens.light));
  });

  testWidgets('tokensOf falls back to the light set outside a themed app', (
    tester,
  ) async {
    // Most widget tests mount a bare MaterialApp with no extension registered.
    // Throwing there would make every one of them a theme-setup exercise.
    late DriftTokens seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(),
        home: Builder(
          builder: (context) {
            seen = tokensOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(DriftTokens.light));
  });

  testWidgets('tokensOf reads the registered set when there is one', (
    tester,
  ) async {
    late DriftTokens seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Builder(
          builder: (context) {
            seen = tokensOf(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(seen, same(DriftTokens.dark));
  });

  test('version and path type is tabular, so columns of digits line up', () {
    final s = monoStyle(color: const Color(0xFF000000));
    expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
    expect(s.fontFamily, 'monospace');
    expect(s.fontFamilyFallback, isNotEmpty);
  });

  test('eyebrow tracking scales with its size', () {
    expect(
      eyebrowStyle(color: const Color(0xFF000000), size: 10).letterSpacing,
      closeTo(0.9, 1e-9),
    );
    expect(
      eyebrowStyle(color: const Color(0xFF000000), size: 20).letterSpacing,
      closeTo(1.8, 1e-9),
    );
  });

  test('nothing in the theme is rounded and nothing splashes', () {
    // Both are deliberate: this is a status instrument, not a phone app. A
    // stray default radius or ripple would read as an oversight next to the
    // hairline vocabulary everything else uses.
    final theme = buildTheme(Brightness.light);
    expect(theme.splashFactory, NoSplash.splashFactory);
    for (final shape in [
      theme.textButtonTheme.style?.shape?.resolve({}),
      theme.outlinedButtonTheme.style?.shape?.resolve({}),
      theme.filledButtonTheme.style?.shape?.resolve({}),
      theme.snackBarTheme.shape,
      theme.dialogTheme.shape,
    ]) {
      expect((shape as RoundedRectangleBorder).borderRadius, BorderRadius.zero);
    }
  });
}
