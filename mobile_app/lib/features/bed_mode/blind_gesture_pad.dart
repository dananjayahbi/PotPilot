// Doc 41: eyes-free full-screen gesture canvas for bed-mode control.
//
// Four mutually-exclusive gesture domains are decided once per touch
// session (§4.2): single tap -> frozen `CMD_POTPLAYER PLAY_PAUSE`,
// horizontal swipe/hold -> Doc 30 UDP `0x04` stream + frozen WS
// `SEEK {position_ms}` commit (the Doc 38 dual-channel pattern), two-finger
// vertical slide -> throttled `SET_VOLUME`, right-edge vertical slide ->
// throttled `SET_BRIGHTNESS` through the shared Doc 40 builder. Every
// domain carries a distinct Doc 42 haptic signature (minute ticks while
// scrubbing, 5 % volume ticks, 10 % brightness detents, refusal/wall
// double-ticks) so state is felt, not seen. A transient OSD (with staleness
// `?` and disconnect `!` prefixes) keeps eyes-open users informed without
// permanent chrome; the pad itself holds no sockets — all dispatch goes
// through [GestureCommandSink] and all haptics through Doc 42.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/theme/oled_theme.dart';
import '../../features/display/monitor_power_sheet.dart';
import '../../network/telemetry_provider.dart';
import '../../network/udp_sender.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';

/// Right-edge brightness zone width in dp; pointer-down inside it claims the
/// brightness domain (§4.2 priority 1). The pad marks it with a faint 1 dp
/// border for discoverability (§4.1).
const double kEdgeZoneWidth = 28;

/// Decision slop in dp: a session decides its mode only when net travel from
/// touch-down passes this (strictly greater — "past 12 dp", §4.2).
const double kGestureSlop = 12;

/// Single-pointer horizontal dominance for the scrub lock:
/// `|dx| > |dy| * 1.2` (§4.2 priority 3).
const double kScrubAxisRatio = 1.2;

/// Tap window: down -> up within this many ms and drift <= [kGestureSlop]
/// locks `tapPlayPause` (§4.2 priority 4).
const int kTapMaxMs = 250;

/// OSD auto-hide after the last gesture event (§4.1).
const Duration kOsdHideDelay = Duration(milliseconds: 1200);

/// WS `SET_VOLUME` throttle window — at most one packet per window, latest
/// value wins, trailing send on lift (§4.5).
const Duration kVolumeThrottle = Duration(milliseconds: 100);

/// UDP `0x04` stream throttle: >= 16 ms apart AND integer-second change
/// only (~60 Hz cap — same throttle as Doc 38, §4.3).
const int kUdpScrubMinIntervalMs = 16;

/// One `volumeTick` per 5 % crossed (§4.5).
const int kVolumeTickStepPct = 5;

/// One `microTick` brightness detent per 10 % crossed (§4.6).
const int kBrightnessTickStepPct = 10;

/// Media milliseconds per minute boundary; every 5th boundary is a
/// 5-minute mark -> `heavyThud` instead of `minuteTick` (§4.4).
const int kMinuteMediaMs = 60000;

/// Commit overshoot guard: scrub targets clamp to
/// `[0, duration − kCommitOvershootGuardMs]` (§4.3).
const int kCommitOvershootGuardMs = 500;

/// Doc 33 staleness clock: older frames prefix the OSD with `?` (§5).
const int kBedStaleAfterMs = 1000;

/// [GestureSession.startBrightness] sentinel: DDC/CI unsupported (wire
/// `brightness: null`) or unknown with no Doc 34 cache fallback — the edge
/// gesture refuses with a `doubleTick` instead of sending doomed
/// `SET_BRIGHTNESS` calls (§7).
const int kBrightnessUnknown = -1;

/// The four mutually-exclusive gesture domains decided at gesture start
/// (§4.2). [GestureMode.none] is the inert, command-swallowing outcome.
enum GestureMode {
  none,
  tapPlayPause,
  horizontalScrub,
  twoFingerVolume,
  edgeBrightness,
}

/// Immutable per-gesture-session bookkeeping (start state + accumulators).
///
/// Created by the pad's session factory the moment a domain decides:
/// [startPositionMs] is frozen at that instant (stale-safe, `null` = stale),
/// [startBrightness] is the telemetry value, the Doc 34-style display-cache
/// fallback, or [kBrightnessUnknown] (§6/§7).
@immutable
class GestureSession {
  const GestureSession({
    required this.mode,
    required this.startX,
    required this.startY,
    required this.startPositionMs,
    required this.startVolume,
    required this.startBrightness,
  });

  /// Domain this session locked into (never [GestureMode.none]).
  final GestureMode mode;

  /// Touch-down position (local dp) — the scrub/volume/brightness anchor.
  final double startX;
  final double startY;

  /// Playback position ms frozen at session start; `null` when telemetry was
  /// stale (scrub refuses, §7).
  final int? startPositionMs;

  /// PotPlayer mixer 0–100 frozen at session start (volume base, §4.5).
  final int startVolume;

  /// Monitor brightness 0–100 frozen at session start, or
  /// [kBrightnessUnknown] (brightness base, §4.6/§7).
  final int startBrightness;
}

/// Recognizer state machine: feeds raw pointer events, emits commands +
/// haptic cues. Pure bookkeeping — transports live in [GestureCommandSink],
/// the OSD/chrome lives in [BlindGesturePad].
///
/// The pad owns pointer counting and calls [reset] once **all** pointers
/// lifted (the mode is locked until then, §4.2); [feed] itself cancels the
/// session when [canvasSize] changes (rotation/resize, §7).
class GestureRecognizer {
  GestureRecognizer({
    required GestureSession Function(PointerDownEvent down, GestureMode mode)
    startSession,
    required int Function() durationMs,
    Future<void> Function(HapticPattern pattern)? playHaptic,
    this.sensitivity = 1.0,
  }) : _startSession = startSession,
       _durationMs = durationMs,
       _playHaptic = playHaptic ?? _silentHaptic;

  static Future<void> _silentHaptic(HapticPattern pattern) async {}

  final GestureSession Function(PointerDownEvent down, GestureMode mode)
  _startSession;
  final int Function() _durationMs;
  final Future<void> Function(HapticPattern) _playHaptic;

  /// Media-seconds per dp multiplier (default 1 dp ≈ 1 s; the Doc 34
  /// sensitivity curve multiplies it, §4.3). Mutable so a settings change
  /// applies without rebuilding the recognizer mid-session.
  double sensitivity;

  bool _active = false; // a touch session owns the state machine
  bool _decided = false; // mode locked (or ruled inert) this session
  GestureMode _mode = GestureMode.none;
  GestureSession? _session;
  bool _refused = false; // locked domain refuses to dispatch (§7)
  bool _sawMulti = false; // any second pointer joined -> veto the tap
  PointerDownEvent? _downEvent;
  int? _primaryPointer;
  Offset _downPos = Offset.zero;
  Size? _canvasSize;

  // Scrub accumulators.
  int? _scrubTargetMs;
  int _firedCrossed = 0; // high-water minute boundaries (§4.4)

  // Volume accumulators.
  int? _volumePercent;
  int? _volumeTickStep;
  bool _volumeWallInside = true;

  // Brightness accumulators.
  int? _brightnessPercent;
  int? _brightnessTickStep;
  bool _brightnessWallInside = true;

  /// Active domain once decided; [GestureMode.none] until thresholds met
  /// (§4.2). Stays put until [reset] — mid-gesture events cannot switch it.
  GestureMode get mode => _mode;

  /// True when the locked domain refuses to dispatch (stale scrub base,
  /// zero-duration media, unsupported brightness — §7).
  bool get refused => _refused;

  /// The active session's frozen start state; `null` while deciding, after
  /// an inert decision, or after [reset].
  GestureSession? get session => _session;

  /// Clamped scrub preview target in ms (start + Σ delta, `[0, duration −
  /// 500]`); `null` outside an un-refused scrub (§4.3).
  int? get scrubTargetMs {
    if (_mode != GestureMode.horizontalScrub || _refused) {
      return null;
    }
    return _scrubTargetMs;
  }

  /// Accumulated scrub preview `+MM:SS` / `−MM:SS` while scrubbing.
  String? get scrubPreview {
    final GestureSession? session = _session;
    final int? target = _scrubTargetMs;
    final int? start = session?.startPositionMs;
    if (_mode != GestureMode.horizontalScrub || _refused) {
      return null;
    }
    if (session == null || start == null || target == null) {
      return null;
    }
    return _formatSignedMs(target - start);
  }

  /// Current volume preview 0–100 while the volume domain is active.
  int? get volumePercent =>
      _mode == GestureMode.twoFingerVolume && !_refused
      ? _volumePercent
      : null;

  /// Current brightness preview 0–100 while the brightness domain is active
  /// (`null` when refused).
  int? get brightnessPercent =>
      _mode == GestureMode.edgeBrightness && !_refused
      ? _brightnessPercent
      : null;

  /// Feeds one raw pointer event; returns the current OSD text (or null).
  ///
  /// [canvasSize] changes cancel an in-flight session without committing
  /// (rotation/resize, §7). [twoFinger] reports ≥ 2 active pointers so the
  /// second-pointer-down and two-finger-vertical rules can fire (§4.2).
  String? feed(
    PointerEvent e, {
    required Size canvasSize,
    required bool twoFinger,
  }) {
    if (_canvasSize != null && canvasSize != _canvasSize) {
      if (_active) {
        reset(); // rotation/resize mid-session: no phantom commit (§7)
      }
      _canvasSize = canvasSize;
      return null;
    }
    _canvasSize = canvasSize;

    if (e is PointerDownEvent) {
      return _onDown(e, twoFinger);
    }
    if (e is PointerMoveEvent) {
      return _onMove(e, twoFinger);
    }
    if (e is PointerUpEvent) {
      return _onUp(e);
    }
    if (e is PointerCancelEvent) {
      reset(); // system took the gesture: abort without committing
      return null;
    }
    return null;
  }

  /// Clears the session (no commit) and re-arms the recognizer — called by
  /// the pad after **all** pointers lifted, on cancellation (pointer cancel,
  /// rotation, app background, Doc 44 OFFHOOK hook).
  void reset() {
    _active = false;
    _decided = false;
    _mode = GestureMode.none;
    _session = null;
    _refused = false;
    _sawMulti = false;
    _downEvent = null;
    _primaryPointer = null;
    _downPos = Offset.zero;
    _scrubTargetMs = null;
    _firedCrossed = 0;
    _volumePercent = null;
    _volumeTickStep = null;
    _volumeWallInside = true;
    _brightnessPercent = null;
    _brightnessTickStep = null;
    _brightnessWallInside = true;
  }

  // -- pointer pipeline -----------------------------------------------------

  String? _onDown(PointerDownEvent e, bool twoFinger) {
    if (_active) {
      // Extra pointer mid-session: ignored until all lift (third-finger
      // case, §7) — but record multi-touch so it can never read as a tap.
      if (twoFinger) {
        _sawMulti = true;
      }
      return null;
    }
    reset(); // defensive: stale accumulators from a cancelled session
    _active = true;
    _downEvent = e;
    _primaryPointer = e.pointer;
    _downPos = e.localPosition;
    final double width = (_canvasSize ?? Size.zero).width;
    if (e.localPosition.dx >= width - kEdgeZoneWidth) {
      // Priority 1 (§4.2): the edge zone decides at touch-down — "any
      // direction" — so a quick tap there never fires PLAY_PAUSE and a
      // brightness refusal can happen immediately (§7).
      _decide(GestureMode.edgeBrightness);
    }
    return null;
  }

  String? _onMove(PointerMoveEvent e, bool twoFinger) {
    if (!_active || e.pointer != _primaryPointer) {
      return null; // extra pointers never drive the session
    }
    final double dx = e.localPosition.dx - _downPos.dx;
    final double dy = e.localPosition.dy - _downPos.dy;

    if (!_decided) {
      final double dist = sqrt(dx * dx + dy * dy);
      if (dist <= kGestureSlop) {
        return null; // decision point is *past* 12 dp (§4.2)
      }
      if (twoFinger) {
        _decide(
          dy.abs() > dx.abs() ? GestureMode.twoFingerVolume : GestureMode.none,
        );
      } else {
        _decide(
          dx.abs() > dy.abs() * kScrubAxisRatio
              ? GestureMode.horizontalScrub
              : GestureMode.none,
        );
      }
      if (_mode == GestureMode.none) {
        return null; // inert, swallow (incl. single-finger vertical)
      }
      // Lock and accumulate this very move — no dead zone after the slop.
    }
    return _applyMove(dx, dy);
  }

  String? _onUp(PointerUpEvent e) {
    if (!_active || e.pointer != _primaryPointer) {
      return null; // non-primary lift; the pad finalizes on the last lift
    }
    if (!_decided) {
      final double dx = e.localPosition.dx - _downPos.dx;
      final double dy = e.localPosition.dy - _downPos.dy;
      final double drift = sqrt(dx * dx + dy * dy);
      final PointerDownEvent? down = _downEvent;
      final int elapsedMs = (e.timeStamp - (down?.timeStamp ?? Duration.zero))
          .inMilliseconds;
      if (!_sawMulti && elapsedMs <= kTapMaxMs && drift <= kGestureSlop) {
        _decide(GestureMode.tapPlayPause);
      } else {
        _decide(GestureMode.none);
      }
      return null;
    }
    // Decided: fold the lift position in so the trailing dispatch uses the
    // finger's final delta, then report the final preview.
    final double dx = e.localPosition.dx - _downPos.dx;
    final double dy = e.localPosition.dy - _downPos.dy;
    return _applyMove(dx, dy);
  }

  /// Locks [mode] once per session (no-op after the first decision) and
  /// creates the frozen [GestureSession]; refusal-critical domains cue
  /// `doubleTick` right here (§7).
  void _decide(GestureMode mode) {
    if (_decided) {
      return;
    }
    _decided = true;
    _mode = mode;
    if (mode == GestureMode.none || _downEvent == null) {
      return;
    }
    _session = _startSession(_downEvent!, mode);
    if (mode == GestureMode.tapPlayPause) {
      unawaited(_playHaptic(HapticPattern.heavyThud)); // tap confirmation
    } else if (mode == GestureMode.horizontalScrub) {
      if (_session!.startPositionMs == null || _durationMs() <= 0) {
        // Stale base / zero-duration: a blind commit to an unknown position
        // is worse than refusing (§7).
        _refused = true;
        unawaited(_playHaptic(HapticPattern.doubleTick));
      } else {
        _scrubTargetMs = _clampScrub(_session!.startPositionMs!);
        _firedCrossed = 0;
      }
    } else if (mode == GestureMode.twoFingerVolume) {
      _volumePercent = _session!.startVolume;
      _volumeTickStep = _volumePercent! ~/ kVolumeTickStepPct;
      _volumeWallInside = true;
    } else if (mode == GestureMode.edgeBrightness) {
      final int base = _session!.startBrightness;
      if (base == kBrightnessUnknown || base < 0) {
        _refused = true; // DDC/CI unsupported or unknown (§7)
        unawaited(_playHaptic(HapticPattern.doubleTick));
      } else {
        _brightnessPercent = base;
        _brightnessTickStep = base ~/ kBrightnessTickStepPct;
        _brightnessWallInside = true;
      }
    }
  }

  /// Applies the net delta of the current mode and returns the OSD text.
  String? _applyMove(double dx, double dy) {
    if (_mode == GestureMode.horizontalScrub) {
      if (_refused) {
        return null;
      }
      _updateScrub(dx);
      return scrubPreview;
    }
    if (_mode == GestureMode.twoFingerVolume) {
      _updateVolume(dy);
      final int? percent = _volumePercent;
      return percent == null ? null : 'Vol $percent%';
    }
    if (_mode == GestureMode.edgeBrightness) {
      if (_refused) {
        return null;
      }
      _updateBrightness(dy);
      final int? percent = _brightnessPercent;
      return percent == null ? null : 'Bright $percent%';
    }
    return null;
  }

  // -- scrub math (§4.3/§4.4) ----------------------------------------------

  void _updateScrub(double dx) {
    final GestureSession session = _session!;
    final int start = session.startPositionMs!;
    final int raw = start + (dx * 1000 * sensitivity).round();
    _scrubTargetMs = _clampScrub(raw);
    _tickMinuteBoundary(_scrubTargetMs! - start);
  }

  /// `ms` clamped to `[0, duration − kCommitOvershootGuardMs]`.
  int _clampScrub(int ms) {
    final int duration = _durationMs();
    final int hi = duration > kCommitOvershootGuardMs
        ? duration - kCommitOvershootGuardMs
        : 0;
    if (ms < 0) {
      return 0;
    }
    return ms > hi ? hi : ms;
  }

  /// One cue per newly crossed 60 s media boundary; the 5th boundary is a
  /// 5-minute mark -> `heavyThud`. Direction changes never un-fire a tick
  /// (high-water mark tracks absolute media distance from the start, §4.4).
  void _tickMinuteBoundary(int deltaMs) {
    final int crossed = deltaMs.abs() ~/ kMinuteMediaMs;
    while (_firedCrossed < crossed) {
      _firedCrossed += 1;
      unawaited(
        _playHaptic(
          _firedCrossed % 5 == 0
              ? HapticPattern.heavyThud
              : HapticPattern.minuteTick,
        ),
      );
    }
  }

  // -- volume / brightness previews (§4.5/§4.6) -----------------------------

  void _updateVolume(double dy) {
    final GestureSession session = _session!;
    final double raw = session.startVolume - dy * 0.5;
    final bool wallFired = _checkWall(raw, isVolume: true);
    _volumePercent = raw < 0 ? 0 : (raw > 100 ? 100 : raw.round());
    final int step = _volumePercent! ~/ kVolumeTickStepPct;
    if (step != _volumeTickStep) {
      _volumeTickStep = step;
      if (!wallFired) {
        // A wall doubleTick already landed in this 30 ms coalesce window.
        unawaited(_playHaptic(HapticPattern.volumeTick));
      }
    }
  }

  void _updateBrightness(double dy) {
    final GestureSession session = _session!;
    final double raw = session.startBrightness - dy * 0.5;
    final bool wallFired = _checkWall(raw, isVolume: false);
    _brightnessPercent = raw < 0 ? 0 : (raw > 100 ? 100 : raw.round());
    final int step = _brightnessPercent! ~/ kBrightnessTickStepPct;
    if (step != _brightnessTickStep) {
      _brightnessTickStep = step;
      if (!wallFired) {
        unawaited(_playHaptic(HapticPattern.microTick));
      }
    }
  }

  /// At a bound: one `doubleTick` confirms the wall on the inside→outside
  /// crossing and further travel sends no clamped no-op packets (§7).
  bool _checkWall(double raw, {required bool isVolume}) {
    final bool outside = raw < 0 || raw > 100;
    if (outside) {
      final bool inside = isVolume ? _volumeWallInside : _brightnessWallInside;
      if (!inside) {
        return false;
      }
      if (isVolume) {
        _volumeWallInside = false;
      } else {
        _brightnessWallInside = false;
      }
      unawaited(_playHaptic(HapticPattern.doubleTick));
      return true;
    }
    if (isVolume) {
      _volumeWallInside = true;
    } else {
      _brightnessWallInside = true;
    }
    return false;
  }

  static String _formatSignedMs(int ms) {
    final String sign = ms < 0 ? '\u2212' : '+';
    final int totalSeconds = ms.abs() ~/ 1000;
    final String mm = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final String ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$sign$mm:$ss';
  }
}

/// Commit/apply layer: converts gestures into Doc 30/31 dispatches.
///
/// Owns the three throttle windows (UDP ≥16 ms + integer-second change,
/// `SET_VOLUME` 100 ms, `SET_BRIGHTNESS` 200 ms — latest value wins with a
/// trailing flush) and the Doc 31 connected gate: WS commands are dropped
/// when the socket is down, never queued (§7).
class GestureCommandSink {
  GestureCommandSink({
    WsClient? ws,
    UdpSender? udp,
    int Function()? nowMs,
    int Function()? durationMs,
  }) : _ws = ws ?? WsClient.instance,
       _udp = udp ?? UdpSender.instance,
       _nowMs = nowMs ?? _systemNowMs,
       _durationMs = durationMs;

  static int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

  final WsClient _ws;
  final UdpSender _udp;
  final int Function() _nowMs;
  final int Function()? _durationMs;

  int? _lastScrubSecond;
  int? _lastScrubAtMs;
  int? _pendingVolume;
  int? _lastVolumeSent;
  Timer? _volumeTimer;
  int? _pendingBrightness;
  int? _lastBrightnessSent;
  Timer? _brightnessTimer;

  /// Doc 31 connected gate — every WS dispatch below respects it.
  bool get wsConnected => _ws.state == WsConnectionState.connected;

  /// Streams throttled UDP `0x04` `sendScrub(targetSeconds)` while
  /// scrubbing: floored seconds, ≥16 ms apart, integer-second change only
  /// (the first packet of a drag always goes out, §4.3).
  void streamScrub(int targetSeconds) {
    if (targetSeconds == _lastScrubSecond) {
      return; // throttle (b): integer-second change only
    }
    final int now = _nowMs();
    if (_lastScrubAtMs != null &&
        now - _lastScrubAtMs! < kUdpScrubMinIntervalMs) {
      return; // throttle (a): ≥16 ms spacing (~60 Hz cap)
    }
    _lastScrubSecond = targetSeconds;
    _lastScrubAtMs = now;
    _udp.sendScrub(targetSeconds);
  }

  /// Sends the final WS `SEEK {"position_ms": targetMs}` on finger lift —
  /// the frozen Doc 03 commit with millisecond precision, clamped to
  /// `[0, duration − 500]` (§4.3). Dropped (fire semantics) when WS is down.
  void commitScrub(GestureSession s, int targetMs) {
    // A completed drag re-arms the stream throttle so the next drag's first
    // packet is never delayed by the previous gesture's window.
    _lastScrubSecond = null;
    _lastScrubAtMs = null;
    if (!wsConnected) {
      return; // Doc 31 fire semantics: dropped, never queued (§7)
    }
    int target = targetMs;
    final int duration = _durationMs?.call() ?? 0;
    if (duration > 0) {
      final int hi = duration > kCommitOvershootGuardMs
          ? duration - kCommitOvershootGuardMs
          : 0;
      if (target < 0) {
        target = 0;
      } else if (target > hi) {
        target = hi;
      }
    }
    unawaited(
      _ws.send(typeCmdPotplayer, Action.seek, <String, dynamic>{
        'position_ms': target,
      }),
    );
  }

  /// Queues the throttled `CMD_POTPLAYER SET_VOLUME {"percent": …}` —
  /// window-style: latest value wins, one trailing packet on lift (§4.5).
  void setVolume(int percent) {
    _pendingVolume = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    _volumeTimer ??= Timer(kVolumeThrottle, _flushVolume);
  }

  void _flushVolume() {
    _volumeTimer = null;
    final int? value = _pendingVolume;
    _pendingVolume = null;
    if (value == null || value == _lastVolumeSent || !wsConnected) {
      return; // no clamped no-op packets; WS down -> dropped (§7)
    }
    _lastVolumeSent = value;
    unawaited(
      _ws.send(typeCmdPotplayer, Action.setVolume, <String, dynamic>{
        'percent': value,
      }),
    );
  }

  /// Queues the throttled `CMD_SYSTEM SET_BRIGHTNESS {"percent": …}` through
  /// the shared Doc 40 [SystemCommandBuilder] (byte-identical envelopes) —
  /// window-style: ≥200 ms cadence + trailing send on lift (§4.6).
  void setBrightness(int percent) {
    _pendingBrightness = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    _brightnessTimer ??= Timer(kBrightnessThrottle, _flushBrightness);
  }

  void _flushBrightness() {
    _brightnessTimer = null;
    final int? value = _pendingBrightness;
    _pendingBrightness = null;
    if (value == null || value == _lastBrightnessSent || !wsConnected) {
      return;
    }
    _lastBrightnessSent = value;
    final Map<String, Object?> envelope = SystemCommandBuilder.brightness(
      value,
    );
    unawaited(
      _ws.send(
        envelope['type']! as String,
        envelope['action']! as String,
        Map<String, dynamic>.from(envelope['payload']! as Map),
      ),
    );
  }

  /// Sends `CMD_POTPLAYER PLAY_PAUSE {}` (dropped when WS is down).
  void togglePlayPause() {
    if (!wsConnected) {
      return;
    }
    unawaited(
      _ws.send(typeCmdPotplayer, Action.playPause, const <String, dynamic>{}),
    );
  }

  /// Cancels in-flight throttle timers (composition-root teardown).
  void dispose() {
    _volumeTimer?.cancel();
    _volumeTimer = null;
    _brightnessTimer?.cancel();
    _brightnessTimer = null;
  }
}

/// Pad transport seam (Doc 30/31 dispatches + Doc 40 builder): tests
/// override this with a sink wired to fake WS/UDP clients.
final Provider<GestureCommandSink> gestureCommandSinkProvider =
    Provider<GestureCommandSink>((Ref ref) {
      final GestureCommandSink sink = GestureCommandSink(
        durationMs: () => ref.read(telemetryProvider).durationMs,
      );
      ref.onDispose(sink.dispose);
      return sink;
    });

/// Full-screen eyes-free gesture surface; hosts the recognizer + minimal
/// OSD layer. Mounted as a full-screen tab by Session 3 wiring; sensitivity
/// defaults to 1 dp ≈ 1 media-second (§4.3).
class BlindGesturePad extends ConsumerStatefulWidget {
  const BlindGesturePad({super.key, this.sensitivity = 1.0});

  /// Media-seconds per dp multiplier (Doc 34 curve multiplies it).
  final double sensitivity;

  @override
  BlindGesturePadState createState() => BlindGesturePadState();
}

/// Public state so lifecycle hooks (Doc 44 OFFHOOK cancellation) can reach
/// [cancelActiveSession] without a contract change.
class BlindGesturePadState extends ConsumerState<BlindGesturePad>
    with WidgetsBindingObserver {
  late final GestureRecognizer _recognizer;
  late final GestureCommandSink _sink;
  late final HapticEngine _haptics;

  /// Currently-down pointers; the pad re-arms only after a full lift (§4.2).
  final Set<int> _pointers = <int>{};

  Size? _canvasSize;
  String? _osdRaw;
  Timer? _osdTimer;
  bool _pulseActive = false;

  @override
  void initState() {
    super.initState();
    _sink = ref.read(gestureCommandSinkProvider);
    _haptics = ref.read(hapticEngineProvider);
    _recognizer = GestureRecognizer(
      startSession: _sessionFor,
      durationMs: () => ref.read(telemetryProvider).durationMs,
      playHaptic: (HapticPattern pattern) => _haptics.play(pattern),
      sensitivity: widget.sensitivity,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Size size = MediaQuery.sizeOf(context);
    if (_canvasSize != null && size != _canvasSize) {
      cancelActiveSession(); // rotation mid-session: no phantom commit (§7)
    }
    _canvasSize = size;
  }

  @override
  void didUpdateWidget(covariant BlindGesturePad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sensitivity != widget.sensitivity) {
      _recognizer.sensitivity = widget.sensitivity;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      return;
    }
    // Screen off / backgrounded: cancel the session, no timers leak (§7).
    cancelActiveSession();
    _osdTimer?.cancel();
    _osdTimer = null;
    if (mounted && _osdRaw != null) {
      setState(() {
        _osdRaw = null;
      });
    }
  }

  /// Aborts any in-flight gesture without committing and re-arms the pad —
  /// the Doc 44 `OFFHOOK` cancel-listener hook targets this method (§7).
  void cancelActiveSession() {
    _recognizer.reset();
    _pointers.clear();
    _stopScrubPulse();
  }

  @override
  void dispose() {
    _osdTimer?.cancel();
    _osdTimer = null;
    _recognizer.reset();
    _stopScrubPulse();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    final bool stale =
        !telemetry.isConnected || _ageMs(telemetry) > kBedStaleAfterMs;
    String? osd = _osdRaw;
    if (osd != null) {
      // Staleness `?` and mid-gesture disconnect `!` prefixes (§5/§7).
      if (stale) {
        osd = '?$osd';
      }
      if (!_sink.wsConnected) {
        osd = '!$osd';
      }
    }
    final String? text = osd;
    return SizedBox.expand(
      child: Listener(
        key: const Key('blind_gesture_pad'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const ColoredBox(color: AppColors.background),
            // Faint 1 dp border marking the right-edge brightness zone (§4.1).
            const Positioned(
              right: kEdgeZoneWidth,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: AppColors.outline),
            ),
            if (text != null)
              Center(
                child: Text(
                  text,
                  key: const Key('blind_gesture_osd'),
                  style: AppTypography.timecode,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // -- pointer pipeline -----------------------------------------------------

  void _onPointerDown(PointerDownEvent e) {
    _pointers.add(e.pointer);
    _showOsd(_feed(e));
  }

  void _onPointerMove(PointerMoveEvent e) {
    _showOsd(_feed(e));
  }

  void _onPointerUp(PointerUpEvent e) {
    final String? text = _feed(e);
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) {
      _finalizeGesture(); // mode locked until ALL pointers lift (§4.2)
    }
    _showOsd(text);
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _feed(e); // recognizer drops the session without committing (§7)
    _stopScrubPulse();
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) {
      _finalizeGesture();
    }
  }

  String? _feed(PointerEvent e) {
    final String? text = _recognizer.feed(
      e,
      canvasSize: _canvasSize ?? Size.zero,
      twoFinger: _pointers.length >= 2,
    );
    _dispatch(e);
    return text;
  }

  /// Converts the recognizer's post-event state into Doc 30/31 dispatches:
  /// scrub pulse + UDP stream while scrubbing, throttled volume/brightness
  /// previews while those domains move (§4.3/§4.5/§4.6).
  void _dispatch(PointerEvent e) {
    if (_recognizer.mode == GestureMode.horizontalScrub &&
        !_recognizer.refused) {
      if (e is! PointerMoveEvent) {
        return;
      }
      if (!_pulseActive) {
        _pulseActive = true;
        _haptics.startScrubPulse(); // heartbeat for the whole drag (§4.3)
      }
      final int? target = _recognizer.scrubTargetMs;
      if (target != null) {
        _sink.streamScrub(target ~/ 1000);
      }
      return;
    }
    if (e is! PointerMoveEvent) {
      return;
    }
    if (_recognizer.mode == GestureMode.twoFingerVolume) {
      final int? percent = _recognizer.volumePercent;
      if (percent != null) {
        _sink.setVolume(percent);
      }
    } else if (_recognizer.mode == GestureMode.edgeBrightness &&
        !_recognizer.refused) {
      final int? percent = _recognizer.brightnessPercent;
      if (percent != null) {
        _sink.setBrightness(percent);
      }
    }
  }

  /// Lift-time dispatch: tap fires exactly once, scrub commits one frozen
  /// `SEEK`, volume/brightness get their trailing send, then the recognizer
  /// re-arms (§4.2/§4.3/§4.5/§4.6).
  void _finalizeGesture() {
    _stopScrubPulse();
    final GestureMode mode = _recognizer.mode;
    final GestureSession? session = _recognizer.session;
    final bool refused = _recognizer.refused;
    final bool wsDown = !_sink.wsConnected;

    if (mode == GestureMode.tapPlayPause && session != null) {
      _sink.togglePlayPause();
      _showTapGlyph();
    } else if (mode == GestureMode.horizontalScrub &&
        session != null &&
        !refused) {
      final int target =
          _recognizer.scrubTargetMs ?? session.startPositionMs ?? 0;
      _sink.commitScrub(session, target);
      if (wsDown) {
        unawaited(_haptics.play(HapticPattern.doubleTick)); // miss cue (§7)
      }
    } else if (mode == GestureMode.twoFingerVolume) {
      final int? percent = _recognizer.volumePercent;
      if (percent != null) {
        _sink.setVolume(percent); // trailing send guarantees final value
        if (wsDown) {
          unawaited(_haptics.play(HapticPattern.doubleTick));
        }
      }
    } else if (mode == GestureMode.edgeBrightness &&
        !refused &&
        session != null) {
      final int? percent = _recognizer.brightnessPercent;
      if (percent != null) {
        _sink.setBrightness(percent); // trailing send guarantees final value
        if (wsDown) {
          unawaited(_haptics.play(HapticPattern.doubleTick));
        }
      }
    }
    _recognizer.reset();
  }

  // -- OSD layer (§4.1) -----------------------------------------------------

  void _showOsd(String? text) {
    if (text == null || !mounted) {
      return;
    }
    setState(() {
      _osdRaw = text;
    });
    _osdTimer?.cancel();
    _osdTimer = Timer(kOsdHideDelay, () {
      _osdTimer = null;
      if (!mounted) {
        return;
      }
      setState(() {
        _osdRaw = null;
      });
    });
  }

  /// Tap flash: the *resulting* play state (currently playing -> `⏸`).
  void _showTapGlyph() {
    final TelemetryState telemetry = ref.read(telemetryProvider);
    _showOsd(telemetry.isPlaying ? '\u23f9' : '\u25b6');
  }

  void _stopScrubPulse() {
    if (_pulseActive) {
      _pulseActive = false;
      _haptics.stopScrubPulse();
    }
  }

  // -- telemetry coupling (§6/§7) -------------------------------------------

  /// Frozen per-session start state: stale telemetry nulls the scrub base
  /// (refusal path); volume falls back to last-known mixer value; brightness
  /// reads the Doc 03 field, then the Doc 34-style display cache, then
  /// refuses (§7).
  GestureSession _sessionFor(PointerDownEvent down, GestureMode mode) {
    final TelemetryState telemetry = ref.read(telemetryProvider);
    final bool stale =
        !telemetry.isConnected || _ageMs(telemetry) > kBedStaleAfterMs;
    final int brightness;
    if (telemetry.extras.containsKey('brightness')) {
      final Object? raw = telemetry.extras['brightness'];
      // Explicit null = DDC/CI unsupported (Doc 03 §5.6) -> refuse (§7).
      brightness = raw is int ? _clampPercent(raw) : kBrightnessUnknown;
    } else {
      brightness =
          DisplayCache.instance.lastBrightnessPct ?? kBrightnessUnknown;
    }
    return GestureSession(
      mode: mode,
      startX: down.localPosition.dx,
      startY: down.localPosition.dy,
      startPositionMs: stale ? null : telemetry.positionMs,
      startVolume: telemetry.potPlayerVolume,
      startBrightness: brightness,
    );
  }

  static int _ageMs(TelemetryState telemetry) {
    final int age =
        DateTime.now().millisecondsSinceEpoch - telemetry.timestamp * 1000;
    return age < 0 ? 0 : age;
  }

  static int _clampPercent(int value) =>
      value < 0 ? 0 : (value > 100 ? 100 : value);
}
