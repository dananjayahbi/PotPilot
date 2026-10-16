import 'package:flutter/material.dart';

/// Pure-black OLED palette + dim crimson/amber night-vision accents.
///
/// Exact hex values frozen in Doc 29 - the single source of truth for the
/// app. Screens must not invent new hex values; luminance ceiling is
/// [onAccent] (no token above it, never pure white).
abstract final class AppColors {
  /// Scaffold / sheet / nav-status-bar background - true black, AMOLED
  /// pixel-off.
  static const Color background = Color(0xFF000000);

  /// Cards, deck panels - imperceptible lift.
  static const Color surface = Color(0xFF0A0A0B);

  /// Modals, HUD chips, inputs - subtle elevation via color, not shadow.
  static const Color surfaceHigh = Color(0xFF141416);

  /// 1-pt hairline borders/dividers - visible only up close.
  static const Color outline = Color(0xFF2A2A2E);

  /// Primary accent: record, errors, destructive actions - dim, preserves
  /// dark adaptation.
  static const Color crimson = Color(0xFFB23A48);

  /// Pressed / disabled primary accent - barely-lit.
  static const Color crimsonDim = Color(0xFF6B2029);

  /// Secondary accent: active status, playback, scrubber - dim warm beacon.
  static const Color amber = Color(0xFFC8922F);

  /// Idle/connected badge fill - off-state glow.
  static const Color amberDim = Color(0xFF6E5016);

  /// Main copy - warm off-white, never pure white (no glare).
  static const Color textPrimary = Color(0xFFD6CEC9);

  /// Supporting copy.
  static const Color textSecondary = Color(0xFF9C938E);

  /// Hints, timestamps - decorative use only.
  static const Color textTertiary = Color(0xFF6A625E);

  /// Label on crimson/amber fills.
  static const Color onAccent = Color(0xFFF3EFEA);

  /// 60% black modal backdrop overlay.
  static const Color scrim = Color(0x99000000);
}

/// Zero-glare typography tokens (system font in v1; Roboto on Android).
///
/// Sizes are `font-size / line-height`, weights per Doc 29. All glyph
/// colors draw from [AppColors] text tokens - no pure-white text.
abstract final class AppTypography {
  /// Display copy: 28 / 1.2, w500.
  static const TextStyle display = TextStyle(
    fontSize: 28,
    height: 1.2,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  /// Screen titles: 20 / 1.3, w600.
  static const TextStyle title = TextStyle(
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  /// Main body copy: 16 / 1.5, w400.
  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  /// Secondary body copy: 14 / 1.5, w400.
  static const TextStyle bodySmall = TextStyle(
    fontSize: 14,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );

  /// Chip/label text: 12 / 1.4, w500, letterSpacing 0.6 - consumers
  /// render labels uppercased (TextStyle itself cannot force case).
  static const TextStyle label = TextStyle(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.6,
    color: AppColors.textSecondary,
  );

  /// Media timecodes: 24 / 1.1, w500, tabular figures via mono fallback.
  static const TextStyle timecode = TextStyle(
    fontSize: 24,
    height: 1.1,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    fontFamilyFallback: <String>['Roboto Mono', 'monospace'],
  );
}

/// Shared UI motion durations (also usable by the haptic engine, Doc 42).
abstract final class AppMotion {
  /// Micro-transitions: taps, presses, state flips.
  static const Duration fast = Duration(milliseconds: 120);

  /// Standard transitions: sheets, HUD, tab-adjacent moves.
  static const Duration normal = Duration(milliseconds: 200);
}

/// All 15 Material text slots mapped onto the six typography tokens so no
/// default (near-)white Material glyph color can leak into the UI.
const TextTheme _appTextTheme = TextTheme(
  displayLarge: AppTypography.display,
  displayMedium: AppTypography.display,
  displaySmall: AppTypography.title,
  headlineLarge: AppTypography.title,
  headlineMedium: AppTypography.display,
  headlineSmall: AppTypography.title,
  titleLarge: AppTypography.title,
  titleMedium: AppTypography.title,
  titleSmall: AppTypography.bodySmall,
  bodyLarge: AppTypography.body,
  bodyMedium: AppTypography.body,
  bodySmall: AppTypography.bodySmall,
  labelLarge: AppTypography.label,
  labelMedium: AppTypography.label,
  labelSmall: AppTypography.label,
);

/// Builds the complete dark-only Material 3 theme for the PotPilot remote.
///
/// Zero-glare rules: elevation 0 everywhere, surfaces differentiated by
/// 1-pt [AppColors.outline] hairlines instead of shadows, black system
/// bars (chrome styled from `main()` via SystemChrome).
ThemeData buildOledTheme() {
  const ColorScheme colorScheme = ColorScheme.dark(
    primary: AppColors.crimson,
    onPrimary: AppColors.onAccent,
    primaryContainer: AppColors.crimsonDim,
    onPrimaryContainer: AppColors.onAccent,
    secondary: AppColors.amber,
    onSecondary: AppColors.onAccent,
    secondaryContainer: AppColors.amberDim,
    onSecondaryContainer: AppColors.onAccent,
    tertiary: AppColors.amber,
    onTertiary: AppColors.onAccent,
    tertiaryContainer: AppColors.amberDim,
    onTertiaryContainer: AppColors.onAccent,
    error: AppColors.crimson,
    onError: AppColors.onAccent,
    errorContainer: AppColors.crimsonDim,
    onErrorContainer: AppColors.onAccent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceDim: AppColors.background,
    surfaceBright: AppColors.surfaceHigh,
    surfaceContainerLowest: AppColors.background,
    surfaceContainerLow: AppColors.surface,
    surfaceContainer: AppColors.surface,
    surfaceContainerHigh: AppColors.surfaceHigh,
    surfaceContainerHighest: AppColors.surfaceHigh,
    outline: AppColors.outline,
    outlineVariant: AppColors.outline,
    shadow: AppColors.background,
    scrim: AppColors.scrim,
    inverseSurface: AppColors.textPrimary,
    onInverseSurface: AppColors.background,
    inversePrimary: AppColors.crimsonDim,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    textTheme: _appTextTheme,
    primaryTextTheme: _appTextTheme,
    dividerTheme: const DividerThemeData(
      color: AppColors.outline,
      thickness: 1,
      space: 1,
    ),
    // Cards float over true black via hairline, not shadow.
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: AppColors.outline, width: 1),
      ),
    ),
    // Sheets legible on pure black: lift by color + amber drag handle.
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: AppColors.amber,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: AppColors.outline, width: 1),
      ),
    ),
    // Scrub/volume sliders read as a warm beacon.
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.amber,
      thumbColor: AppColors.amber,
      overlayColor: AppColors.amberDim,
      inactiveTrackColor: AppColors.amberDim,
      trackHeight: 4,
    ),
    // No default M3 surface-tint leaks.
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surfaceHigh,
      elevation: 0,
      titleTextStyle: AppTypography.title,
      contentTextStyle: AppTypography.body,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: AppColors.outline, width: 1),
      ),
    ),
    // Error/action affordance without glare.
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: AppTypography.bodySmall,
      actionTextColor: AppColors.crimson,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
        side: BorderSide(color: AppColors.outline, width: 1),
      ),
    ),
    // Primary action (Play/Pause in the deck).
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppColors.crimson,
      foregroundColor: AppColors.onAccent,
      elevation: 0,
    ),
    // Nav bar renders on true black per the token table.
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.background,
      indicatorColor: AppColors.surfaceHigh,
      elevation: 0,
    ),
  );
}
