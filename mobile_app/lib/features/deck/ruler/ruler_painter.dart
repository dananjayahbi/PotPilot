// Doc 36 (ruler slider): the ruler's CustomPainter — media-time ticks
// that scroll under a fixed amber centre pointer, round-number major
// labels; edge fading is applied by the host via ShaderMask.
//
// Geometry: a tick at media time `t` paints at
//   x = centre + (t - targetMs) / msPerPx,
// so dragging slides the whole tape while the pointer stays put — the
// classic number-ruler feel of the reference design (2026-10-17).

import 'package:flutter/material.dart';

import '../../../core/theme/oled_theme.dart';
import 'seek_scale.dart';

/// Paints one ruler band.  Plain value inputs keep the painter trivially
/// inspectable; hit maths reuses [tickXOf].
class RulerPainter extends CustomPainter {
  const RulerPainter({
    required this.targetMs,
    required this.durationMs,
    required this.tier,
    this.enabled = true,
  });

  /// Media milliseconds the centre pointer sits on (the drag target).
  final int targetMs;

  /// Media total; ticks never paint beyond it.
  final int durationMs;

  /// Active velocity tier (tick spacing + label cadence).
  final RulerTier tier;

  final bool enabled;

  /// Horizontal centre of the band (pointer position).
  static const double centreFraction = 0.5;

  static const double minorTickHeight = 10;
  static const double majorTickHeight = 18;
  static const double bandHeight = 56;

  /// Absolute x of media time [ms] for a band of [width].
  static double tickXOf(int ms, double width, int targetMs, double msPerPx) =>
      width * centreFraction + (ms - targetMs) / msPerPx;

  @override
  void paint(Canvas canvas, Size size) {
    final double centre = size.width * centreFraction;
    final double msPerPx = tier.msPerPx;
    final Color major = enabled
        ? AppColors.textSecondary
        : AppColors.textTertiary;
    final Color label = enabled
        ? AppColors.textSecondary
        : AppColors.textTertiary;

    // Visible media range, half a band each side.
    final double msLeft = targetMs - centre * msPerPx;
    final double msRight = targetMs + centre * msPerPx;
    final int tickMs = tier.msPerNotch.toInt();
    int kMin = (msLeft / tickMs).floor();
    if (kMin < 0) {
      kMin = 0;
    }
    final int kMax = (msRight / tickMs).ceil();

    final TextPainter textPainter = TextPainter(
      textDirection: TextDirection.ltr,
    );

    for (int k = kMin; k <= kMax; k++) {
      final int mediaMs = k * tickMs;
      if (durationMs > 0 && mediaMs > durationMs) {
        break;
      }
      final double x = tickXOf(mediaMs, size.width, targetMs, msPerPx);
      if (x < -40 || x > size.width + 40) {
        continue;
      }
      final bool isMajor = k % tier.labelEvery == 0;
      final double height = isMajor ? majorTickHeight : minorTickHeight;
      final Paint paint = Paint()
        ..color = isMajor ? major : AppColors.outline
        ..strokeWidth = isMajor ? 1.6 : 1.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, size.height - height),
        Offset(x, size.height - 2),
        paint,
      );
      if (isMajor) {
        textPainter.text = TextSpan(
          text: formatTickLabel(mediaMs),
          style: AppTypography.label.copyWith(
            fontSize: 10,
            height: 1.0,
            color: label,
          ),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x - textPainter.width / 2, 2));
      }
    }

    // Fixed centre pointer: amber needle with a foot dot — "you are here".
    final Color pointerColor = enabled ? AppColors.amber : AppColors.textTertiary;
    final Paint pointer = Paint()
      ..color = pointerColor
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(centre, 6),
      Offset(centre, size.height - 1),
      pointer,
    );
    canvas.drawCircle(
      Offset(centre, size.height - 1),
      2.5,
      Paint()..color = pointerColor,
    );
  }

  /// `m:ss` under an hour, `h:mm:ss` beyond — compact tape labels.
  static String formatTickLabel(int ms) {
    final int total = ms ~/ 1000;
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  bool shouldRepaint(RulerPainter old) =>
      old.targetMs != targetMs ||
      old.durationMs != durationMs ||
      old.tier != tier ||
      old.enabled != enabled;
}
