import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Material 3 theme built from a single spice-toned seed so light and dark
/// stay in step, plus the small overrides the app actually needs.
class AppTheme {
  const AppTheme._();

  /// Transparent system bars with icons that contrast against [brightness].
  ///
  /// Android 15 draws every app edge-to-edge whether it asks to or not, so the
  /// only question left is whether the bars look deliberate. Contrast
  /// enforcement is switched off because the scrim Android paints behind the
  /// bars to "help" is exactly the grey band edge-to-edge is meant to remove.
  static SystemUiOverlayStyle systemBarsFor(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final icons = isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      // iOS reads the *background* brightness here, not the icon brightness.
      statusBarBrightness: brightness,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
      systemStatusBarContrastEnforced: false,
    );
  }

  /// Turmeric/saffron — reads as "Indian food" without being a literal chilli
  /// red, which at large fills looks like an error state.
  static const seed = Color(0xFFE07A21);

  static const macroProtein = Color(0xFF3F7D58);
  static const macroCarbs = Color(0xFFD98324);
  static const macroFat = Color(0xFF8B5CF6);
  static const water = Color(0xFF2D9CDB);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      fontFamilyFallback: const ['NotoSansDevanagari'],
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        // AppBar publishes its own AnnotatedRegion, so without this every
        // screen with an app bar would override the root overlay style and
        // repaint the bars opaque.
        systemOverlayStyle: systemBarsFor(brightness),
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color:
            isDark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 3,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        backgroundColor: scheme.surfaceContainer,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
    );
  }

  /// Veg / non-veg dot colours, matching the Indian FSSAI packaging marks.
  static Color dietColor(String diet) => switch (diet) {
        'nonveg' => const Color(0xFFB3261E),
        'egg' => const Color(0xFFB98600),
        _ => const Color(0xFF2E7D32),
      };
}

/// Spacing scale — using named constants keeps padding consistent across 20+
/// screens far better than sprinkling magic numbers.
class Gap {
  const Gap._();

  static const xs = SizedBox(height: 4, width: 4);
  static const s = SizedBox(height: 8, width: 8);
  static const m = SizedBox(height: 16, width: 16);
  static const l = SizedBox(height: 24, width: 24);
  static const xl = SizedBox(height: 32, width: 32);
}
