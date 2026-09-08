import 'package:flutter/material.dart';

/// ShadowChat theme. Placeholder palette — a real visual identity comes later
/// (see docs/OPEN-QUESTIONS.md #11). A high-contrast variant is wired for the
/// accessibility requirement.
class AppTheme {
  static const _seed = Color(0xFF5B4B8A); // muted violet

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData highContrast(Brightness b) {
    final t = _base(b);
    return t.copyWith(
      colorScheme:
          (b == Brightness.dark
                  ? const ColorScheme.highContrastDark()
                  : const ColorScheme.highContrastLight())
              .copyWith(primary: _seed),
    );
  }

  static ThemeData _base(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: brightness,
      ),
    );
  }
}
