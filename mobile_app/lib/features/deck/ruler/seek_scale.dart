// Doc 36 (ruler slider, 2026-10-17): velocity-sensing time-frame model.
//
// The deck's bottom ruler is a speed-sensing scrubber: swipe direction
// gives the sign, swipe SPEED picks the time frame applied per 24 px
// notch — slow = 1 s (frame-precise), then 5 s, 10 s, 30 s, 1 min,
// 2 min, and a full-speed flick = 5 min per notch, capped at ±5 min of
// travel per gesture.  Pure Dart (no Flutter imports) so it unit-tests
// cold and stays reusable.

/// One notch of ruler travel, in physical pixels (tick spacing).
const double kRulerNotchPx = 24;

/// Maximum travel of a single gesture, milliseconds, both directions
/// ("the maximum is 5 minutes" — user spec, 2026-10-17).
const double kRulerBudgetMs = 300000;

/// Seconds of end-velocity projected after release — "flick to travel".
const double kRulerFlickProjectionS = 0.12;

/// Velocity (px/s) below which gestures stay in the finest frame.
const double kRulerFineFloorPxPerSec = 150;

/// One time frame: label, the px/s speed that ENTERS it, the media
/// milliseconds each 24 px notch applies, and how many notches apart
/// labelled ticks sit (so labels always read round numbers).
class RulerTier {
  const RulerTier({
    required this.label,
    required this.enterPxPerSec,
    required this.msPerNotch,
    required this.labelEvery,
  });

  final String label;
  final double enterPxPerSec;
  final double msPerNotch;
  final int labelEvery;

  /// Media milliseconds represented by one physical pixel.
  double get msPerPx => msPerNotch / kRulerNotchPx;

  /// Media milliseconds between labelled major ticks.
  int get labelMs => (msPerNotch * labelEvery).round();

  @override
  String toString() => 'RulerTier($label @ ${enterPxPerSec}px/s)';
}

/// The full ladder, slowest → fastest.  Entry speeds are deliberately
/// thumb-friendly: casual drags stay ≤10 s/notch; only real flicks
/// unlock the 5-minute frame.
const List<RulerTier> kRulerTiers = <RulerTier>[
  RulerTier(
    label: '1 s',
    enterPxPerSec: 0,
    msPerNotch: 1000,
    labelEvery: 5,
  ),
  RulerTier(
    label: '5 s',
    enterPxPerSec: kRulerFineFloorPxPerSec,
    msPerNotch: 5000,
    labelEvery: 2,
  ),
  RulerTier(
    label: '10 s',
    enterPxPerSec: 400,
    msPerNotch: 10000,
    labelEvery: 2,
  ),
  RulerTier(
    label: '30 s',
    enterPxPerSec: 800,
    msPerNotch: 30000,
    labelEvery: 1,
  ),
  RulerTier(
    label: '1 m',
    enterPxPerSec: 1500,
    msPerNotch: 60000,
    labelEvery: 1,
  ),
  RulerTier(
    label: '2 m',
    enterPxPerSec: 2500,
    msPerNotch: 120000,
    labelEvery: 1,
  ),
  RulerTier(
    label: '5 m',
    enterPxPerSec: 4000,
    msPerNotch: 300000,
    labelEvery: 1,
  ),
];

/// Stateful velocity → tier mapper with hysteresis: tiers switch UP the
/// moment the speed qualifies, but switch DOWN only after the speed falls
/// to 65 % of the current tier's entry — boundary jitter can never flap
/// the frame mid-swipe.
class SeekTierResolver {
  SeekTierResolver([this._index = 0]);

  /// Fraction of a tier's entry speed required to fall back below it.
  static const double kDownMargin = 0.65;

  int _index = 0;

  int get index => _index;
  RulerTier get tier => kRulerTiers[_index];

  /// Resolves [velocityPxPerSec] (sign ignored) to the active tier.
  RulerTier resolve(double velocityPxPerSec) {
    final double v = velocityPxPerSec.abs();
    int candidate = 0;
    for (int i = 0; i < kRulerTiers.length; i++) {
      if (v >= kRulerTiers[i].enterPxPerSec) {
        candidate = i;
      } else {
        break;
      }
    }
    if (candidate > _index) {
      _index = candidate; // instant climb — flicks must feel immediate
    } else if (candidate < _index &&
        v < kRulerTiers[_index].enterPxPerSec * kDownMargin) {
      _index = candidate;
    }
    return tier;
  }

  void reset() => _index = 0;
}

/// Caps one event's millisecond contribution so the whole gesture stays
/// inside ±[kRulerBudgetMs].  [spentMs] is the travel already applied in
/// this gesture; the returned delta never pushes the total past the cap.
double clampGestureMs(double deltaMs, double spentMs) {
  final double remaining = kRulerBudgetMs - spentMs.abs();
  if (remaining <= 0) {
    return 0;
  }
  if (deltaMs.abs() <= remaining) {
    return deltaMs;
  }
  return deltaMs.isNegative ? -remaining : remaining;
}

/// Chip label for travel from the gesture anchor: `0`, `+18 s`, `−2:34`.
/// Uses U+2212 MINUS for typography.
String formatDeltaLabel(int deltaMs) {
  final String sign = deltaMs < 0 ? '\u2212' : '+';
  final int abs = deltaMs.abs();
  if (abs < 1000) {
    return '0';
  }
  if (abs < 60000) {
    return '$sign${(abs / 1000).round()} s';
  }
  final int minutes = abs ~/ 60000;
  final int seconds = (abs % 60000) ~/ 1000;
  return '$sign$minutes:${seconds.toString().padLeft(2, '0')}';
}
