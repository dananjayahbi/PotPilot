import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';

/// Theme suite (Doc 29 section 9): frozen hex table, night-vision
/// constraints (no pure white, WCAG contrast, luminance ceiling),
/// buildOledTheme() component slots, and the repo-wide grep for banned
/// near-white literals in mobile_app/lib/.
double _linearize(double channel) {
  return channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color color) {
  return 0.2126 * _linearize(color.r) +
      0.7152 * _linearize(color.g) +
      0.0722 * _linearize(color.b);
}

double _contrastRatio(Color foreground, Color background) {
  final double luminanceA = _relativeLuminance(foreground);
  final double luminanceB = _relativeLuminance(background);
  final double lighter = math.max(luminanceA, luminanceB);
  final double darker = math.min(luminanceA, luminanceB);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  const Map<String, Color> tokens = <String, Color>{
    'background': AppColors.background,
    'surface': AppColors.surface,
    'surfaceHigh': AppColors.surfaceHigh,
    'outline': AppColors.outline,
    'crimson': AppColors.crimson,
    'crimsonDim': AppColors.crimsonDim,
    'amber': AppColors.amber,
    'amberDim': AppColors.amberDim,
    'textPrimary': AppColors.textPrimary,
    'textSecondary': AppColors.textSecondary,
    'textTertiary': AppColors.textTertiary,
    'onAccent': AppColors.onAccent,
    'scrim': AppColors.scrim,
  };

  Directory resolveLib() {
    final Directory direct = Directory('lib');
    if (direct.existsSync()) {
      return direct;
    }
    final Directory nested = Directory('mobile_app/lib');
    if (nested.existsSync()) {
      return nested;
    }
    return fail('lib/ not found from ${Directory.current.path}');
  }

  group('AppColors frozen hex table', () {
    test('matches Doc 29 exactly', () {
      expect(AppColors.background, const Color(0xFF000000));
      expect(AppColors.surface, const Color(0xFF0A0A0B));
      expect(AppColors.surfaceHigh, const Color(0xFF141416));
      expect(AppColors.outline, const Color(0xFF2A2A2E));
      expect(AppColors.crimson, const Color(0xFFB23A48));
      expect(AppColors.crimsonDim, const Color(0xFF6B2029));
      expect(AppColors.amber, const Color(0xFFC8922F));
      expect(AppColors.amberDim, const Color(0xFF6E5016));
      expect(AppColors.textPrimary, const Color(0xFFD6CEC9));
      expect(AppColors.textSecondary, const Color(0xFF9C938E));
      expect(AppColors.textTertiary, const Color(0xFF6A625E));
      expect(AppColors.onAccent, const Color(0xFFF3EFEA));
      expect(AppColors.scrim, const Color(0x99000000));
    });

    test('no token is pure white and none exceeds the luminance ceiling',
        () {
      const Color ceiling = AppColors.onAccent;
      tokens.forEach((String name, Color color) {
        expect(
          color.toARGB32(),
          isNot(0xFFFFFFFF),
          reason: '$name must not be pure white',
        );
        expect(
          color.r <= ceiling.r &&
              color.g <= ceiling.g &&
              color.b <= ceiling.b,
          isTrue,
          reason: '$name exceeds the 0xF3EFEA night-vision ceiling',
        );
      });
    });

    test('text tokens meet WCAG contrast on the black background', () {
      expect(
        _contrastRatio(AppColors.textPrimary, AppColors.background),
        greaterThanOrEqualTo(7.0),
        reason: 'textPrimary must be >= 7:1 on #000000',
      );
      expect(
        _contrastRatio(AppColors.textSecondary, AppColors.background),
        greaterThanOrEqualTo(4.5),
        reason: 'textSecondary must be >= 4.5:1 on #000000',
      );
    });
  });

  group('buildOledTheme', () {
    final ThemeData theme = buildOledTheme();

    test('is dark-only AMOLED with the expected ColorScheme', () {
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(theme.brightness, Brightness.dark);
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.brightness, Brightness.dark);
      expect(theme.colorScheme.primary, AppColors.crimson);
      expect(theme.colorScheme.secondary, AppColors.amber);
      expect(theme.colorScheme.error, AppColors.crimson);
      expect(theme.colorScheme.surface, AppColors.surface);
      expect(theme.colorScheme.outline, AppColors.outline);
    });

    test('wires zero-elevation component slots with token colors', () {
      // Card: surface fill, 1-pt outline hairline, elevation 0.
      expect(theme.cardTheme.elevation, 0);
      expect(theme.cardTheme.color, AppColors.surface);
      final RoundedRectangleBorder cardShape =
          theme.cardTheme.shape! as RoundedRectangleBorder;
      expect(cardShape.side.color, AppColors.outline);
      expect(cardShape.side.width, 1);

      // Bottom sheet: surfaceHigh fill, amber drag handle, elevation 0.
      expect(theme.bottomSheetTheme.backgroundColor, AppColors.surfaceHigh);
      expect(theme.bottomSheetTheme.showDragHandle, isTrue);
      expect(theme.bottomSheetTheme.dragHandleColor, AppColors.amber);
      expect(theme.bottomSheetTheme.elevation, 0);

      // Slider: amber beacon, dim inactive track.
      expect(theme.sliderTheme.activeTrackColor, AppColors.amber);
      expect(theme.sliderTheme.thumbColor, AppColors.amber);
      expect(theme.sliderTheme.inactiveTrackColor, AppColors.amberDim);

      // Dialog: surfaceHigh, no M3 surface tint, textPrimary title.
      expect(theme.dialogTheme.backgroundColor, AppColors.surfaceHigh);
      expect(theme.dialogTheme.elevation, 0);
      expect(theme.dialogTheme.titleTextStyle?.color, AppColors.textPrimary);

      // SnackBar: surfaceHigh + textPrimary, crimson action, elevation 0.
      expect(theme.snackBarTheme.backgroundColor, AppColors.surfaceHigh);
      expect(
        theme.snackBarTheme.contentTextStyle?.color,
        AppColors.textPrimary,
      );
      expect(theme.snackBarTheme.actionTextColor, AppColors.crimson);
      expect(theme.snackBarTheme.elevation, 0);

      // Divider: outline hairline, 1 pt.
      expect(theme.dividerTheme.color, AppColors.outline);
      expect(theme.dividerTheme.thickness, 1);

      // FAB: crimson fill, onAccent icon.
      expect(
        theme.floatingActionButtonTheme.backgroundColor,
        AppColors.crimson,
      );
      expect(
        theme.floatingActionButtonTheme.foregroundColor,
        AppColors.onAccent,
      );

      // Nav bar: true-black background.
      expect(theme.navigationBarTheme.backgroundColor, AppColors.background);
    });

    test('every text slot uses an approved zero-glare ink token', () {
      final Set<Color> allowed = <Color>{
        AppColors.textPrimary,
        AppColors.textSecondary,
        AppColors.textTertiary,
        AppColors.onAccent,
      };
      final TextTheme text = theme.textTheme;
      final List<TextStyle?> styles = <TextStyle?>[
        text.displayLarge,
        text.displayMedium,
        text.displaySmall,
        text.headlineLarge,
        text.headlineMedium,
        text.headlineSmall,
        text.titleLarge,
        text.titleMedium,
        text.titleSmall,
        text.bodyLarge,
        text.bodyMedium,
        text.bodySmall,
        text.labelLarge,
        text.labelMedium,
        text.labelSmall,
      ];
      expect(styles.length, 15);
      for (final TextStyle? style in styles) {
        expect(style, isNotNull);
        expect(
          allowed.contains(style!.color),
          isTrue,
          reason:
              'Text slot color ${style.color} is not a night-vision ink '
              'token',
        );
        expect(
          style.color?.toARGB32(),
          isNot(0xFFFFFFFF),
          reason: 'Text slot must never be pure white',
        );
      }
    });
  });

  test('mobile_app/lib contains no banned near-white literals', () {
    final RegExp banned =
        RegExp(r'Colors\.white|0xFFFFFFFF', caseSensitive: false);
    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity
        in resolveLib().listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      if (banned.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Night-vision rule: no pure-white color usage in lib/',
    );
  });
}
