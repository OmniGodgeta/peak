import 'package:flutter/material.dart';

/// Peak's visual identity, drawn from the app mark: a lit summit against deep
/// space. Dark-first — the light theme is a faithful inversion, not the primary
/// look. A high-contrast variant is wired for the accessibility requirement.
class AppTheme {
  // ── Brand palette (sampled from the mark) ─────────────────────────────────
  static const summitGlow = Color(0xFF27AEF2); // electric blue — primary accent
  static const summitDeep = Color(0xFF0563DE); // saturated core blue
  static const ice = Color(0xFFCFE6F2); // near-white blue, headline text
  static const space = Color(0xFF010B22); // deep space navy — canvas

  static ThemeData dark() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: summitDeep,
          brightness: Brightness.dark,
        ).copyWith(
          primary: summitGlow,
          onPrimary: space,
          surface: space,
          onSurface: ice,
          surfaceContainerLowest: const Color(0xFF03081A),
          surfaceContainerLow: const Color(0xFF071026),
          surfaceContainer: const Color(0xFF0A1430),
          surfaceContainerHigh: const Color(0xFF111D3E),
          surfaceContainerHighest: const Color(0xFF17264A),
          outline: const Color(0xFF23407A),
        );
    return _build(scheme);
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: summitDeep,
      brightness: Brightness.light,
      primary: summitDeep,
    );
    return _build(scheme);
  }

  static ThemeData highContrast(Brightness b) {
    final base = b == Brightness.dark ? dark() : light();
    return base.copyWith(
      colorScheme:
          (b == Brightness.dark
                  ? const ColorScheme.highContrastDark()
                  : const ColorScheme.highContrastLight())
              .copyWith(
                primary: b == Brightness.dark ? summitGlow : summitDeep,
              ),
    );
  }

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // NB: don't force a full-width minimumSize here — it breaks FilledButtons
          // used in tight spaces like AppBar actions. Screens that want a
          // full-width button size it themselves.
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        filled: true,
      ),
    );
  }
}
