// Doc 35: 120 Hz multi-touch virtual trackpad surface.
//
// A full-screen gesture engine emitting *relative* input to the PC through
// Doc 30's `UdpSender` (types 0x01 move / 0x02 scroll / 0x03 button) — the
// primary bedroom mouse. A single raw `Listener` drives the whole state
// machine (no gesture arenas): velocity-EMA amplified moves, tap-to-click,
// double-tap-and-hold drag lock, two-finger right-click, two-finger inertia
// scroll in wheel ticks (Doc 06), each cue delegated to Doc 42 through the
// [HapticHooks] seam (no-op default; real engine wired at the composition
// root). Middle-click is never emitted (reserved). The sender's coalescer is
// the 120 Hz packet budget — this widget emits at touch-sampling rate.

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/storage/connection_cache.dart';
import '../../core/theme/oled_theme.dart';
import '../../network/udp_sender.dart';

// ---------------------------------------------------------------------------
// Tunable gesture constants (Doc 35 §3 table — ergonomics defaults).
// ---------------------------------------------------------------------------

/// Press shorter than this is a tap candidate.
const Duration kTapMaxDuration = Duration(milliseconds: 180);

/// Movement above this (px) disqualifies a tap.
const double kTapSlopPx = 10;

/// Second tap must start within this window of the previous tap.
const Duration kDoubleTapWindowMs = Duration(milliseconds: 300);

/// Hold the second tap this long (without slop travel) to engage drag lock.
const Duration kDoubleTapHoldMs = Duration(milliseconds: 250);

/// Max both-down time for a two-finger tap to count as right-click.
const Duration kTwoFingerTapMaxMs = Duration(milliseconds: 250);

/// Max gap between 1st and 2nd finger down for two-finger fusion.
const Duration kTwoFingerStartWindowMs = Duration(milliseconds: 80);

/// Min distance (px) between the two fused pointers.
const double kTwoFingerFusionPx = 30;

/// Travel in two-finger mode before scroll engages.
const double kScrollStartPx = 8;

/// Smallest wheel-tick delta that produces a scroll packet.
const int kScrollMinDelta = 1;

/// Inertia floor (px/ms) — below it, coasting stops.
const double kInertiaMinVelocity = 0.05;

/// Velocity multiplier per 16 ms inertia tick.
const double kInertiaFriction = 0.94;

/// EMA velocity clamp (px/ms).
const double kMaxVelocity = 6.0;

// Implementation constants (single constants, tunable — Doc 35 §10).

/// EMA blend factor for per-event speed (Doc 35 §4 algo 2).
const double kVelocityEmaAlpha = 0.4;

/// Velocity resets after motion stops this long.
const Duration kVelocityResetMs = Duration(milliseconds: 150);

/// Finger px per wheel tick at `scrollMultiplier == 1` (Doc 35 §5: 1 tick ≈
/// one notch; Doc 06 expands each tick to 120 WHEEL_DELTA units).
const double kScrollPxPerTick = 16.0;

/// Inertia frame period — `v · 16 ms` px per tick (Doc 35 §4 algo 10).
const double kInertiaFrameMs = 16.0;

// ---------------------------------------------------------------------------
// Public contract types.
// ---------------------------------------------------------------------------

/// Gesture phases of the trackpad surface (Doc 35 §3 state machine).
enum TrackpadPhase {
  /// No gesture in flight.
  idle,

  /// First finger down, waiting for tap vs. move disambiguation.
  tapPending,

  /// Second tap candidate waiting for quick-up (double-click) or hold
  /// (drag lock).
  doubleTapPending,

  /// Single-finger cursor movement.
  moving,

  /// Left button held — double-tap-and-hold engaged; move = drag.
  dragLock,

  /// Fused two-finger scroll stream.
  twoFingerScroll,

  /// Fused pair down, deciding right-click vs. scroll.
  twoFingerTapPending,

  /// Post-lift coasting: decaying wheel ticks from the last flick.
  inertiaScroll,
}

/// Pure velocity/scroll math — unit-testable without widgets (Doc 35 §3).
@immutable
class VelocityModel {
  /// Builds the curve from a [TrackpadProfile] snapshot (Docs 34/35).
  const VelocityModel.fromProfile(this.profile);

  /// Source fields: sensitivity, accelerationGain/threshold, multiplier.
  final TrackpadProfile profile;

  /// Applies sensitivity + velocity acceleration to a raw pointer delta (px).
  ///
  /// Linear zone `|v| <= threshold` → gain = sensitivity; beyond it, gain
  /// grows linearly toward `sensitivity × accelerationGain` at
  /// [kMaxVelocity], where it is exactly bounded.
  double amplify(double deltaPx, double velocityPxMs) {
    double velocity = velocityPxMs < 0 ? -velocityPxMs : velocityPxMs;
    if (velocity > kMaxVelocity) {
      velocity = kMaxVelocity;
    }
    final double threshold = profile.accelerationThreshold;
    if (threshold >= kMaxVelocity || velocity <= threshold) {
      return deltaPx * profile.sensitivity;
    }
    final double t = (velocity - threshold) / (kMaxVelocity - threshold);
    final double gain =
        profile.sensitivity *
        (1.0 + t * (profile.accelerationGain - 1.0));
    return deltaPx * gain;
  }

  /// Converts accumulated finger travel (px) into wheel ticks for arg1/arg2
  /// of a scroll packet (scales by `scrollMultiplier`, truncates toward zero
  /// so sub-tick drift never produces a packet — Doc 35 `kScrollMinDelta`).
  int scrollUnits(double deltaPx) {
    final double ticks =
        deltaPx * profile.scrollMultiplier / kScrollPxPerTick;
    return ticks.truncate(); // toward zero: sub-tick drift never emits
  }

  /// True while inertia should keep emitting (|velocity| above floor).
  bool inertiaActive(double velocityPxMs) {
    final double abs = velocityPxMs < 0 ? -velocityPxMs : velocityPxMs;
    return abs >= kInertiaMinVelocity;
  }

  /// Per-frame friction: v' = v × [kInertiaFriction] per 16 ms tick.
  double decay(double velocityPxMs) => velocityPxMs * kInertiaFriction;
}

/// Lightweight haptic seam owned by this file (Doc 35 §3); backed by Doc
/// 42's `HapticEngine` at the composition root — tests inject spies.
class HapticHooks {
  const HapticHooks({
    this.tapClick = _silent,
    this.dragStart = _silent,
    this.dragEnd = _silent,
    this.rightClick = _silent,
    this.scrollTick,
  });

  /// Real hooks onto the Doc 42 engine (tap/drag/right-click/scroll ticks
  /// map to its tick-class patterns per Doc 35 §10).
  factory HapticHooks.fromEngine(HapticEngine engine) => HapticHooks(
    tapClick: () => engine.play(HapticPattern.microTick),
    dragStart: () => engine.play(HapticPattern.heavyThud),
    dragEnd: () => engine.play(HapticPattern.microTick),
    rightClick: () => engine.play(HapticPattern.minuteTick),
    scrollTick: (double intensity) => engine.play(HapticPattern.scrubPulse),
  );

  /// Light tick on tap-to-click.
  final void Function() tapClick;

  /// Firm tick on drag lock engage.
  final void Function() dragStart;

  /// Tick when drag lock releases.
  final void Function() dragEnd;

  /// Two-finger right-click tick.
  final void Function() rightClick;

  /// Per scroll burst direction edge, intensity 0–1 (nullable → silent).
  final void Function(double intensity)? scrollTick;

  static void _silent() {}
}

/// Multi-touch virtual trackpad surface (120 Hz packet budget) — Doc 35.
class VirtualTrackpad extends StatefulWidget {
  const VirtualTrackpad({
    super.key,
    required this.sender,
    this.profile,
    this.haptics,
  });

  /// Injected transport (Doc 30) — sole outbound dependency.
  final UdpSender sender;

  /// null ⇒ `ConnectionCache.trackpadProfile` (or its defaults).
  final TrackpadProfile? profile;

  /// Injected Doc 42 seam; null ⇒ silent.
  final HapticHooks? haptics;

  @override
  State<VirtualTrackpad> createState() => _VirtualTrackpadState();
}

// ---------------------------------------------------------------------------
// Engine internals.
// ---------------------------------------------------------------------------

/// Reused per-pointer slot (fixed pool — no per-event allocation).
class _FingerSlot {
  int pointer = -1; // -1 == free
  double x = 0;
  double y = 0;
  double travel = 0;
  Duration downTime = Duration.zero;
}

class _VirtualTrackpadState extends State<VirtualTrackpad>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Two slots: a third finger is ignored outright (fusion needs ≤2, and
  /// palm contacts must not corrupt gesture state — Doc 35 §7).
  final List<_FingerSlot> _slots = <_FingerSlot>[
    _FingerSlot(),
    _FingerSlot(),
  ];

  TrackpadPhase _phase = TrackpadPhase.idle;
  VelocityModel _model = const VelocityModel.fromProfile(
    TrackpadProfile.defaults,
  );

  // Velocity state.
  double _velocity = 0; // scalar EMA (px/ms) for move amplification
  double _scrollVelY = 0; // signed EMA (wheel px/ms) for inertia
  Duration? _lastMotionStamp;

  // Tap / double-tap / drag-lock state.
  bool _tapCandidate = false;
  Duration? _lastTapUpStamp;
  Timer? _dragLockTimer;

  // Two-finger scroll state.
  double _scrollAccY = 0; // wheel px (finger-up positive)
  double _scrollAccX = 0;
  double _twoFingerTravel = 0; // path length since fusion (px)
  Duration? _fusionStamp;
  Duration? _lastScrollEmitStamp;
  int _lastScrollSign = 0;

  // Inertia state.
  double _inertiaVel = 0;
  Ticker? _inertiaTicker;

  HapticHooks get _hooks => widget.haptics ?? const HapticHooks();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _model = VelocityModel.fromProfile(_resolveProfile());
  }

  @override
  void didUpdateWidget(VirtualTrackpad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _model = VelocityModel.fromProfile(_resolveProfile());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dragLockTimer?.cancel();
    _inertiaTicker?.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _abortGesture(); // background mid-gesture: no stuck button (§7)
    }
  }

  /// Explicit profile, else cache (hot: re-read every gesture so settings
  /// changes apply on the *next* touch — Doc 35 §7), else defaults.
  TrackpadProfile _resolveProfile() {
    final TrackpadProfile? explicit = widget.profile;
    if (explicit != null) {
      return explicit;
    }
    final ConnectionCache cache = ConnectionCache.instance;
    if (cache.isReady) {
      return cache.trackpadProfile;
    }
    return TrackpadProfile.defaults;
  }

  // -- pointer pipeline -----------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: const ColoredBox(color: AppColors.background),
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _stopInertia(discardVelocity: true); // new touch cancels inertia (§4.10)
    final _FingerSlot? slot = _acquire(event);
    if (slot == null) {
      return; // third finger ignored
    }
    _model = VelocityModel.fromProfile(_resolveProfile());
    _velocity = 0;
    _scrollVelY = 0;
    _lastMotionStamp = event.timeStamp;

    if (_activeCount() == 1) {
      final Duration? lastUp = _lastTapUpStamp;
      final bool withinWindow =
          _tapCandidate &&
          lastUp != null &&
          event.timeStamp - lastUp >= Duration.zero &&
          event.timeStamp - lastUp <= kDoubleTapWindowMs;
      _tapCandidate = false; // consumed; re-armed by a successful tap-up
      if (withinWindow) {
        _phase = TrackpadPhase.doubleTapPending;
        _dragLockTimer = Timer(kDoubleTapHoldMs, _engageDragLock);
      } else {
        _phase = TrackpadPhase.tapPending;
      }
      return;
    }

    // Two fingers — fusion only from idle/tapPending (Doc 35 §7 rule).
    if (_phase == TrackpadPhase.tapPending || _phase == TrackpadPhase.idle) {
      if (!_tryFuse(event)) {
        _release(event.pointer); // too late/far — ignore this finger
      }
    } else {
      _release(event.pointer); // drag lock keeps priority (§7)
    }
  }

  bool _tryFuse(PointerDownEvent event) {
    final _FingerSlot first = _otherSlot(event.pointer);
    final Duration gap = event.timeStamp - first.downTime;
    final double distance = (event.position - Offset(first.x, first.y)).distance;
    if (gap < Duration.zero ||
        gap > kTwoFingerStartWindowMs ||
        distance > kTwoFingerFusionPx) {
      return false;
    }
    _phase = TrackpadPhase.twoFingerTapPending;
    _fusionStamp = event.timeStamp;
    _scrollAccY = 0;
    _scrollAccX = 0;
    _twoFingerTravel = 0;
    _lastScrollSign = 0;
    _lastScrollEmitStamp = null;
    _dragLockTimer?.cancel();
    _dragLockTimer = null;
    return true;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final _FingerSlot? slot = _find(event.pointer);
    if (slot == null) {
      return;
    }
    final double dx = event.delta.dx;
    final double dy = event.delta.dy;
    if (dx == 0 && dy == 0) {
      return;
    }
    slot.x = event.position.dx;
    slot.y = event.position.dy;
    slot.travel += event.delta.distance;
    _updateVelocity(event, dx, dy);

    switch (_phase) {
      case TrackpadPhase.tapPending:
        if (slot.travel > kTapSlopPx) {
          _phase = TrackpadPhase.moving;
          _sendMove(dx, dy);
        }
      case TrackpadPhase.doubleTapPending:
        if (slot.travel > kTapSlopPx) {
          _dragLockTimer?.cancel();
          _dragLockTimer = null;
          _phase = TrackpadPhase.moving;
          _sendMove(dx, dy);
        }
      case TrackpadPhase.moving:
      case TrackpadPhase.dragLock:
        _sendMove(dx, dy);
      case TrackpadPhase.twoFingerTapPending:
        if (_activeCount() < 2) {
          // Staggered lift: remaining finger pans as a plain move; travel
          // still disqualifies the pending right-click (Doc 35 §7).
          _twoFingerTravel += dx.abs() + dy.abs();
          _sendMove(dx, dy);
        } else {
          _accumulateScroll(dx, dy);
          if (_twoFingerTravel >= kScrollStartPx) {
            _phase = TrackpadPhase.twoFingerScroll;
            _maybeEmitScroll(event.timeStamp);
          }
        }
      case TrackpadPhase.twoFingerScroll:
        if (_activeCount() < 2) {
          // One finger left after a staggered lift → plain cursor move, no
          // phantom scroll (Doc 35 §7).
          _sendMove(dx, dy);
        } else {
          _accumulateScroll(dx, dy);
          _maybeEmitScroll(event.timeStamp);
        }
      case TrackpadPhase.idle:
      case TrackpadPhase.inertiaScroll:
        break;
    }
  }

  void _updateVelocity(PointerMoveEvent event, double dx, double dy) {
    final Duration? last = _lastMotionStamp;
    final double dtMs = last == null
        ? 0
        : (event.timeStamp - last).inMicroseconds / 1000.0;
    _lastMotionStamp = event.timeStamp;
    if (dtMs <= 0) {
      return; // same-timestamp batch — skip EMA, keep movement flowing
    }
    if (last != null && event.timeStamp - last > kVelocityResetMs) {
      _velocity = 0; // motion stopped >150 ms ago — fresh start (§4.2)
      _scrollVelY = 0;
    }
    final double speed = event.delta.distance / dtMs;
    _velocity += kVelocityEmaAlpha * (speed - _velocity);
    if (_velocity > kMaxVelocity) {
      _velocity = kMaxVelocity;
    }
    if (_phase == TrackpadPhase.twoFingerTapPending ||
        _phase == TrackpadPhase.twoFingerScroll) {
      // Signed wheel-space EMA (finger-up → positive wheel, inertia keeps
      // the flick's direction — Doc 35 §4 algo 10).
      _scrollVelY += kVelocityEmaAlpha * (-dy / dtMs - _scrollVelY);
      if (_scrollVelY > kMaxVelocity) {
        _scrollVelY = kMaxVelocity;
      } else if (_scrollVelY < -kMaxVelocity) {
        _scrollVelY = -kMaxVelocity;
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final _FingerSlot? slot = _find(event.pointer);
    if (slot == null) {
      return;
    }
    final int remaining = _activeCount() - 1;
    switch (_phase) {
      case TrackpadPhase.tapPending:
        _resolveTap(slot, event.timeStamp);
        _release(event.pointer);
        _phase = TrackpadPhase.idle;
      case TrackpadPhase.doubleTapPending:
        _dragLockTimer?.cancel();
        _dragLockTimer = null;
        // Quick second release = double-click; first tap already clicked.
        widget.sender.sendButton(MouseButton.left, ButtonAction.click);
        _hooks.tapClick();
        _release(event.pointer);
        _phase = TrackpadPhase.idle;
      case TrackpadPhase.dragLock:
        _release(event.pointer);
        if (remaining == 0) {
          widget.sender.sendButton(MouseButton.left, ButtonAction.up);
          _hooks.dragEnd();
          _phase = TrackpadPhase.idle;
        }
      case TrackpadPhase.moving:
        _release(event.pointer);
        if (remaining == 0) {
          _phase = TrackpadPhase.idle;
        }
      case TrackpadPhase.twoFingerTapPending:
        _release(event.pointer);
        if (remaining == 0) {
          _resolveTwoFingerTap(event.timeStamp);
          _phase = TrackpadPhase.idle;
        }
      // Staggered lift: keep scroll context — the remaining finger pans as
      // a plain move; the final up resolves lift/inertia (§7 / §4.10).
      case TrackpadPhase.twoFingerScroll:
        _release(event.pointer);
        if (remaining == 0) {
          _resolveScrollLift(event.timeStamp);
        }
      case TrackpadPhase.idle:
        _release(event.pointer);
      case TrackpadPhase.inertiaScroll:
        _release(event.pointer);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _abortGesture(); // notification shade / call / rotation (§4.12)
  }

  // -- gesture resolution ---------------------------------------------------

  void _resolveTap(_FingerSlot slot, Duration upStamp) {
    final Duration held = upStamp - slot.downTime;
    if (held >= Duration.zero &&
        held <= kTapMaxDuration &&
        slot.travel <= kTapSlopPx) {
      widget.sender.sendButton(MouseButton.left, ButtonAction.click);
      _hooks.tapClick();
      _lastTapUpStamp = upStamp;
      _tapCandidate = true;
    } else {
      // Deliberate press-and-hold reaches the PC as a hold (§4.5).
      widget.sender.sendButton(MouseButton.left, ButtonAction.down);
      widget.sender.sendButton(MouseButton.left, ButtonAction.up);
      _tapCandidate = false;
    }
  }

  void _engageDragLock() {
    _dragLockTimer = null;
    if (_phase != TrackpadPhase.doubleTapPending) {
      return;
    }
    final _FingerSlot? slot = _firstActiveSlot();
    if (slot == null || slot.travel > kTapSlopPx) {
      return;
    }
    widget.sender.sendButton(MouseButton.left, ButtonAction.down);
    _hooks.dragStart();
    _phase = TrackpadPhase.dragLock; // tap semantics suppressed (§4.6)
  }

  void _resolveTwoFingerTap(Duration upStamp) {
    final Duration? fusion = _fusionStamp;
    final double travel = _twoFingerTravel;
    _resetScrollState();
    if (fusion == null) {
      return;
    }
    if (upStamp - fusion >= Duration.zero &&
        upStamp - fusion <= kTwoFingerTapMaxMs &&
        travel <= kTapSlopPx) {
      widget.sender.sendButton(MouseButton.right, ButtonAction.click);
      _hooks.rightClick();
    }
    // Above the window / past slop: scroll-then-tap noise → no click (§7).
  }

  void _resolveScrollLift(Duration upStamp) {
    final Duration? last = _lastMotionStamp;
    final bool recent =
        last != null &&
        upStamp - last >= Duration.zero &&
        upStamp - last <= kVelocityResetMs;
    if (recent && _model.inertiaActive(_scrollVelY)) {
      _inertiaVel = _scrollVelY;
      _phase = TrackpadPhase.inertiaScroll;
      _inertiaTicker ??= createTicker(_onInertiaTick);
      _inertiaTicker!.start();
      return;
    }
    _phase = TrackpadPhase.idle;
    _resetScrollState();
  }

  // -- cursor / scroll emission ---------------------------------------------

  void _sendMove(double dx, double dy) {
    final int outX = _model.amplify(dx, _velocity).round();
    final int outY = _model.amplify(dy, _velocity).round();
    if (outX == 0 && outY == 0) {
      return;
    }
    widget.sender.sendMove(outX, outY);
  }

  void _accumulateScroll(double dx, double dy) {
    _scrollAccY += -dy; // finger up → positive wheel (natural direction)
    _scrollAccX += -dx;
    _twoFingerTravel += dx.abs() + dy.abs();
  }

  /// At most one packet per distinct event timestamp (frame-batch proxy for
  /// "emit at most once per frame" — Doc 35 §4 algo 9).
  void _maybeEmitScroll(Duration stamp) {
    if (stamp == _lastScrollEmitStamp) {
      return;
    }
    _lastScrollEmitStamp = stamp;
    _emitScroll();
  }

  void _emitScroll() {
    final int unitsY = _model.scrollUnits(_scrollAccY);
    final int unitsX = _model.scrollUnits(_scrollAccX);
    if (unitsY.abs() < kScrollMinDelta &&
        unitsX.abs() < kScrollMinDelta) {
      return; // sub-tick drift suppressed (§7)
    }
    if (unitsY != 0) {
      _scrollAccY -=
          unitsY * kScrollPxPerTick / _model.profile.scrollMultiplier;
      _scrollEdge(unitsY);
    }
    if (unitsX != 0) {
      _scrollAccX -=
          unitsX * kScrollPxPerTick / _model.profile.scrollMultiplier;
    }
    widget.sender.sendScroll(unitsY, unitsX);
  }

  /// Haptic scroll tick on direction edges only (Doc 35 §4 algo 10).
  void _scrollEdge(int unitsY) {
    if (unitsY == 0) {
      return;
    }
    final int sign = unitsY > 0 ? 1 : -1;
    if (_lastScrollSign == sign) {
      return;
    }
    _lastScrollSign = sign;
    final void Function(double intensity)? tick = _hooks.scrollTick;
    if (tick != null) {
      double intensity = _scrollVelY.abs() / kMaxVelocity;
      if (intensity > 1) {
        intensity = 1;
      }
      tick(intensity);
    }
  }

  // -- inertia --------------------------------------------------------------

  void _onInertiaTick(Duration elapsed) {
    if (_phase != TrackpadPhase.inertiaScroll) {
      _inertiaTicker?.stop();
      return;
    }
    final double v = _inertiaVel;
    if (!_model.inertiaActive(v)) {
      _stopInertia(discardVelocity: true);
      _resetScrollState();
      _phase = TrackpadPhase.idle;
      return;
    }
    _scrollAccY += v * kInertiaFrameMs; // Δ = v · 16 ms (§4 algo 10)
    _emitScroll();
    _inertiaVel = _model.decay(v);
  }

  void _stopInertia({required bool discardVelocity}) {
    _inertiaTicker?.stop();
    if (discardVelocity) {
      _inertiaVel = 0;
      if (_phase == TrackpadPhase.inertiaScroll) {
        _phase = TrackpadPhase.idle;
      }
    }
  }

  void _abortGesture() {
    _dragLockTimer?.cancel();
    _dragLockTimer = null;
    _stopInertia(discardVelocity: true);
    final bool hadLockedButton = _phase == TrackpadPhase.dragLock;
    _releaseAll();
    if (hadLockedButton) {
      // PC never ends up with a stuck button (Doc 35 §4.12 / §7).
      widget.sender.sendButton(MouseButton.left, ButtonAction.up);
      _hooks.dragEnd();
    }
    _phase = TrackpadPhase.idle;
    _tapCandidate = false;
    _velocity = 0;
    _scrollVelY = 0;
    _lastMotionStamp = null;
    _resetScrollState();
  }

  void _resetScrollState() {
    _scrollAccY = 0;
    _scrollAccX = 0;
    _twoFingerTravel = 0;
    _fusionStamp = null;
    _lastScrollEmitStamp = null;
    _lastScrollSign = 0;
  }

  // -- slot pool (hot path: linear scans over 2 preallocated slots) ---------

  _FingerSlot? _acquire(PointerEvent event) {
    for (final _FingerSlot slot in _slots) {
      if (slot.pointer == event.pointer) {
        return slot;
      }
    }
    for (final _FingerSlot slot in _slots) {
      if (slot.pointer == -1) {
        slot
          ..pointer = event.pointer
          ..x = event.position.dx
          ..y = event.position.dy
          ..travel = 0
          ..downTime = event.timeStamp;
        return slot;
      }
    }
    return null;
  }

  _FingerSlot? _find(int pointer) {
    for (final _FingerSlot slot in _slots) {
      if (slot.pointer == pointer) {
        return slot;
      }
    }
    return null;
  }

  _FingerSlot _otherSlot(int pointer) => _slots[0].pointer == pointer
      ? _slots[1]
      : _slots[0];

  _FingerSlot? _firstActiveSlot() {
    for (final _FingerSlot slot in _slots) {
      if (slot.pointer != -1) {
        return slot;
      }
    }
    return null;
  }

  int _activeCount() {
    int count = 0;
    for (final _FingerSlot slot in _slots) {
      if (slot.pointer != -1) {
        count++;
      }
    }
    return count;
  }

  void _release(int pointer) {
    final _FingerSlot? slot = _find(pointer);
    if (slot != null) {
      slot.pointer = -1;
    }
  }

  void _releaseAll() {
    for (final _FingerSlot slot in _slots) {
      slot.pointer = -1;
      slot.travel = 0;
    }
  }
}
