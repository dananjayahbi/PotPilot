// Doc 36 (ruler slider, 2026-10-17): the deck's bottom scrub ruler —
// a zone-friendly, speed-sensing scrubber replacing the tiny top track.
//
// Interaction model (user spec):
//   * slow swipe   → 1 s per notch (frame-precise skipping)
//   * faster swipe → 5 s, 10 s, 30 s, 1 min, 2 min …
//   * full flick   → 5 min per notch, capped at ±5 min per gesture
//   * tap          → fine jump (± a few seconds) at the tapped zone
// All travel flows through the shared [ScrubController] (scaled mode via
// `updateDragByMs`), so throttled UDP preview streaming, the WS
// `SEEK {position_ms}` commit, settle convergence and minute haptics are
// exactly the ones the old track used.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/haptics/haptic_engine.dart';
import '../../../core/theme/oled_theme.dart';
import '../../hud/scrub_speed_hud.dart';
import 'ruler_painter.dart';
import 'seek_scale.dart';

/// EMA weight of the newest pointer sample in the velocity estimate.
const double kRulerVelocityAlpha = 0.4;

/// The ruler slider.  The whole widget is the gesture zone (its generous
/// height is the "precision" the generic top track lacked).
class RulerSeekSlider extends ConsumerStatefulWidget {
  const RulerSeekSlider({super.key, required this.enabled});

  /// False while WS is down or PotPlayer is closed (deck gate).
  final bool enabled;

  @override
  ConsumerState<RulerSeekSlider> createState() => _RulerSeekSliderState();
}

class _RulerSeekSliderState extends ConsumerState<RulerSeekSlider> {
  final SeekTierResolver _resolver = SeekTierResolver();
  final GlobalKey _trackKey = GlobalKey();

  double _velocityEma = 0;
  int _lastEventAtMs = 0;
  double _spentMs = 0;
  int _anchorMs = 0;
  int _lastNotchIndex = 0;
  bool _gestureActive = false;

  ScrubController get _controller => ref.read(scrubControllerProvider);

  bool get _mediaReady => _controller.preview.durationMs > 0;

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  // -- gesture lifecycle -----------------------------------------------------

  void _begin(double width) {
    if (!widget.enabled || !_mediaReady) {
      return;
    }
    _controller.beginDrag(width);
    if (!_controller.dragging) {
      return; // settle in flight or media vanished — refused by the engine
    }
    _resolver.reset();
    _spentMs = 0;
    _velocityEma = 0;
    _lastEventAtMs = _nowMs();
    _anchorMs = _controller.preview.positionMs;
    _lastNotchIndex = _anchorMs ~/ _resolver.tier.msPerNotch.toInt();
    _gestureActive = true;
  }

  void _applyDelta(double dx, {double? velocityPxPerSec}) {
    if (!_gestureActive || !_controller.dragging) {
      return;
    }
    final int now = _nowMs();
    final double dt =
        ((now - _lastEventAtMs).clamp(8, 120) / 1000.0).toDouble();
    _lastEventAtMs = now;
    if (velocityPxPerSec == null && dt > 0) {
      final double instantaneous = dx / dt;
      _velocityEma = kRulerVelocityAlpha * instantaneous +
          (1 - kRulerVelocityAlpha) * _velocityEma;
    }
    final double speed =
        velocityPxPerSec ?? _velocityEma;
    final RulerTier tier = _resolver.resolve(speed);
    final double contribution =
        clampGestureMs(dx * tier.msPerPx, _spentMs);
    if (contribution == 0) {
      return;
    }
    _spentMs += contribution;
    _controller.updateDragByMs(contribution);
    _feedback(tier);
  }

  /// Notch-crossing ticks + tier-change double tick (minute ticks come
  /// from the shared controller itself).
  void _feedback(RulerTier tier) {
    final int notch = _controller.preview.positionMs ~/
        tier.msPerNotch.toInt();
    if (notch != _lastNotchIndex) {
      _lastNotchIndex = notch;
      unawaitedHaptic(HapticPattern.microTick);
    }
  }

  void _tierChanged(RulerTier previous, RulerTier next) {
    if (previous != next) {
      unawaitedHaptic(HapticPattern.doubleTick);
    }
  }

  void _end(double endVelocityPxPerSec) {
    if (!_gestureActive) {
      return;
    }
    _gestureActive = false;
    if (_controller.dragging) {
      final RulerTier tier = _resolver.resolve(endVelocityPxPerSec);
      final double projection = clampGestureMs(
        endVelocityPxPerSec * tier.msPerPx * kRulerFlickProjectionS,
        _spentMs,
      );
      if (projection.abs() >= 1) {
        _spentMs += projection;
        _controller.updateDragByMs(projection);
      }
      _controller.endDrag();
    }
  }

  void _cancel() {
    _gestureActive = false;
    if (_controller.dragging) {
      _controller.cancelDrag();
    }
  }

  void unawaitedHaptic(HapticPattern pattern) {
    unawaited(ref.read(hapticEngineProvider).play(pattern));
  }

  // -- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.enabled && _mediaReady;
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? _) {
        final ScrubPreview preview = _controller.preview;
        final int targetMs = preview.positionMs;
        final RulerTier tier = _resolver.tier;
        final int deltaMs = _gestureActive ? targetMs - _anchorMs : 0;

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Semantics(
            label: 'Seek ruler',
            value: formatTimecode(targetMs),
            child: GestureDetector(
              key: const Key('ruler_track'),
              behavior: HitTestBehavior.opaque,
              onTapUp: enabled ? _onTapUp : null,
              onPanStart: enabled
                  ? (DragStartDetails details) => _begin(_trackWidth())
                  : null,
              onPanUpdate: enabled
                  ? (DragUpdateDetails details) {
                      final RulerTier before = _resolver.tier;
                      _applyDelta(details.delta.dx);
                      _tierChanged(before, _resolver.tier);
                    }
                  : null,
              onPanEnd: enabled
                  ? (DragEndDetails details) => _end(
                        details.velocity.pixelsPerSecond.dx,
                      )
                  : null,
              onPanCancel: enabled ? _cancel : null,
              child: Column(
                key: _trackKey,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _Bubble(targetMs: targetMs, enabled: enabled),
                  const SizedBox(height: 2),
                  ShaderMask(
                    shaderCallback: (Rect rect) => const LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: <Color>[
                        Color(0x00000000),
                        Color(0xFF000000),
                        Color(0xFF000000),
                        Color(0x00000000),
                      ],
                      stops: <double>[0.0, 0.12, 0.88, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: SizedBox(
                      height: RulerPainter.bandHeight,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: RulerPainter(
                          targetMs: targetMs,
                          durationMs: preview.durationMs,
                          tier: tier,
                          enabled: enabled,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      _TierChip(
                        label: tier.label,
                        hot: kRulerTiers.indexOf(tier) >= 3,
                        enabled: enabled,
                      ),
                      const SizedBox(width: 8),
                      _DeltaChip(
                        label: formatDeltaLabel(deltaMs),
                        active: _gestureActive && deltaMs != 0,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'swipe slow = fine \u00b7 flick = \u00b15 min',
                    key: const Key('ruler_hint'),
                    style: AppTypography.label.copyWith(
                      fontSize: 10,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Size of the gesture surface (the Column inside the padding) — must
  /// match [TapUpDetails.localPosition]'s coordinate space, which the
  /// state's own context (padding ancestor) does not.
  Size? _trackSize() => _trackKey.currentContext?.size;

  double _trackWidth() => _trackSize()?.width ?? 0;

  /// Tap-to-jump: the tapped zone becomes a fine (1 s/notch) seek.
  void _onTapUp(TapUpDetails details) {
    final Size? size = _trackSize();
    if (size == null || size.width <= 0) {
      return;
    }
    _begin(size.width);
    if (!_gestureActive) {
      return;
    }
    final double dx =
        details.localPosition.dx - size.width * RulerPainter.centreFraction;
    _applyDelta(dx, velocityPxPerSec: 0); // tap = finest tier, no EMA
    _end(0);
  }
}

/// Dark pill bubble riding above the centre pointer (reference design).
class _Bubble extends StatelessWidget {
  const _Bubble({required this.targetMs, required this.enabled});

  final int targetMs;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.outline),
      ),
      child: Text(
        formatTimecode(targetMs),
        key: const Key('ruler_time'),
        style: AppTypography.timecode.copyWith(
          fontSize: 20,
          color: enabled ? AppColors.amber : AppColors.textTertiary,
        ),
      ),
    );
  }
}

/// `1 s` … `5 m` frame pill; heats up (amber → crimson) at fast tiers.
class _TierChip extends StatelessWidget {
  const _TierChip({
    required this.label,
    required this.hot,
    required this.enabled,
  });

  final String label;
  final bool hot;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color fg = !enabled
        ? AppColors.textTertiary
        : (hot ? AppColors.crimson : AppColors.amber);
    return Container(
      key: const Key('ruler_tier'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.outline),
      ),
      child: Text(
        label,
        style: AppTypography.label.copyWith(fontSize: 11, color: fg),
      ),
    );
  }
}

/// Travel-from-anchor chip (`+18 s`, `−2:34`), amber while dragging.
class _DeltaChip extends StatelessWidget {
  const _DeltaChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('ruler_delta'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: active ? AppColors.amberDim : AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? AppColors.amber : AppColors.outline,
        ),
      ),
      child: Text(
        label,
        style: AppTypography.label.copyWith(
          fontSize: 11,
          color: active ? AppColors.amber : AppColors.textTertiary,
        ),
      ),
    );
  }
}
