// Doc 38: live two-way timeline scrubber + speed/volume OSD badges.
//
// Idle: the thumb and `HH:MM:SS / HH:MM:SS` labels track Doc 33 telemetry
// (250 ms cadence). Dragging: the phone becomes the source of truth — the
// telemetry position is discarded, the preview follows the finger 1:1 and
// streams throttled Doc 30 UDP `0x04` SCRUB_SEEK packets (>=16 ms apart and
// only on integer-second change). On lift one frozen Doc 03
// `SEEK {position_ms}` commit carries millisecond precision, then the
// state machine settles back onto telemetry (kSettleWindow / kSettleTimeout).
// Badges are strictly display-only: the speed reset lives on the Doc 36 deck.

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../../network/udp_sender.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';

/// Minimum spacing between UDP `0x04` SCRUB_SEEK preview packets (Doc 38
/// §4.3 throttle (a): ~60 Hz cap around second-boundary oscillation).
const int kScrubSendMinInterval = 16;

/// Settle window: |telemetry - committed target| <= this re-attaches idle.
const int kSettleWindow = 1500;

/// Settle timeout: fall back to Idle trusting the committed target (§4.6).
const int kSettleTimeout = 750;

/// Commit overshoot guard: targets clamp to `[0, duration - guard]` so a
/// right-edge throw never seeks past EOF (PotPlayer stop avoided, §7).
const int kCommitOvershootGuard = 500;

/// Doc 33 staleness clock: older frames dim badges/labels to 45 % and show
/// `--` (§7).
const int kStaleAfter = 1000;

/// Below this a Doc 33 `speed` is "unknown" (wire range is 0.2x-4.0x, so
/// the all-zero initial state means no speed frame was ever accepted).
const double kSpeedUnknownBelow = 0.2;

/// Formats [ms] as a timecode: `HH:MM:SS` at >= 1 h, `MM:SS` below,
/// `--:--:--` when null/negative (Public Contract).
String formatTimecode(int? ms) {
  if (ms == null || ms < 0) {
    return '--:--:--';
  }
  final int totalSeconds = ms ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds ~/ 60) % 60;
  final int seconds = totalSeconds % 60;
  final String mm = minutes.toString().padLeft(2, '0');
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$mm:$ss';
  }
  return '$mm:$ss';
}

/// Formats the fixed right-hand duration label: always `HH:MM:SS` so the
/// row never shifts width between `00:00` and `01:00:00` content (§4
/// visual spec); `0` renders `00:00:00`.
String formatDurationTimecode(int? ms) {
  if (ms == null || ms < 0) {
    return '--:--:--';
  }
  final int totalSeconds = ms ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds ~/ 60) % 60;
  final int seconds = totalSeconds % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

/// Single-decimal speed for OSD/deck badges (`1.4`, never
/// `1.4000000000000001`): integer-tenth rounding first (Doc 36 §4.3).
String formatSpeed(double speed) =>
    ((speed * 10).round() / 10).toStringAsFixed(1);

/// Age of the Doc 33 staleness clock in ms (`timestamp` is unix seconds);
/// never negative (rewound PC clock renders as fresh).
int telemetryAgeMs(TelemetryState state) {
  final int age =
      DateTime.now().millisecondsSinceEpoch - state.timestamp * 1000;
  return age < 0 ? 0 : age;
}

/// Seek-drag phase (Doc 38 §4 state machine).
enum ScrubPhase { idle, dragging, settling }

/// Immutable thumb/label snapshot handed to [ScrubTrack].
@immutable
class ScrubPreview {
  const ScrubPreview({
    required this.positionMs,
    required this.durationMs,
    required this.dragging,
    required this.settling,
  });

  final int positionMs;
  final int durationMs;
  final bool dragging;
  final bool settling;

  @override
  bool operator ==(Object other) {
    return other is ScrubPreview &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.dragging == dragging &&
        other.settling == settling;
  }

  @override
  int get hashCode => Object.hash(positionMs, durationMs, dragging, settling);
}

/// Output seam over the Doc 30 UDP sender + Doc 31 WS commit (mirrors
/// Doc 33's `TelemetrySocket` style so tests never open sockets).
abstract class ScrubTransport {
  const ScrubTransport();

  /// Streams one 8-byte `0x04` SCRUB_SEEK preview (floored seconds; auth
  /// byte + seq are owned by Doc 30's packer).
  void sendScrub(int targetSeconds);

  /// Commits the frozen Doc 03 `SEEK {"position_ms": ...}` envelope.
  void sendSeek(int positionMs);

  /// Doc 31 connection state: false drops the release commit (§7).
  bool get wsConnected;
}

/// Production wiring: `UdpSender.instance` + `WsClient.instance`.
class PotpilotScrubTransport extends ScrubTransport {
  const PotpilotScrubTransport();

  @override
  void sendScrub(int targetSeconds) =>
      UdpSender.instance.sendScrub(targetSeconds);

  @override
  void sendSeek(int positionMs) {
    final WsClient client = WsClient.instance;
    if (client.state != WsConnectionState.connected) {
      return; // WS down at release: last UDP preview stands as best effort
    }
    unawaited(
      client.send(typeCmdPotplayer, Action.seek, <String, dynamic>{
        'position_ms': positionMs,
      }),
    );
  }

  @override
  bool get wsConnected => WsClient.instance.state == WsConnectionState.connected;
}

/// Doc 30/31 sinks the HUD writes to (test seam).
final Provider<ScrubTransport> scrubTransportProvider =
    Provider<ScrubTransport>((Ref ref) => const PotpilotScrubTransport());

/// Seek-drag state machine (Doc 38 §4): owns throttling, the WS commit and
/// telemetry re-attach. Plain [ChangeNotifier] so the hosting HUD rebuilds
/// on every drag/settle tick; provider-owned (tests override the provider).
class ScrubController extends ChangeNotifier {
  ScrubController({
    ScrubTransport? transport,
    Future<void> Function(HapticPattern pattern)? playHaptic,
    int Function()? nowMs,
  })  : _transport = transport ?? const PotpilotScrubTransport(),
        _playHaptic = playHaptic ?? _silentHaptic,
        _nowMs = nowMs ?? _systemNow;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> _silentHaptic(HapticPattern pattern) async {}

  final ScrubTransport _transport;
  final Future<void> Function(HapticPattern) _playHaptic;
  final int Function() _nowMs;

  /// Test seam: overrides one-shot `Timer` creation (fake clock in tests).
  @visibleForTesting
  Timer Function(Duration duration, void Function(Timer timer))? timerFactory;

  /// Notifies the host (e.g. deck) to mute telemetry-driven UI: true on
  /// [beginDrag], false whenever the machine returns to Idle (§3).
  void Function(bool active)? onActiveChanged;

  ScrubPhase _phase = ScrubPhase.idle;
  TelemetryState _lastState = TelemetryState.initial;
  double _trackWidth = 1;
  double _dragAnchorMs = 0;
  double _accumDx = 0;

  /// Display position: drag target while dragging, committed target (or a
  /// newer accepted telemetry frame) while settling.
  int _targetMs = 0;

  /// Target frozen at [endDrag] — settle convergence compares against this.
  int _committedTargetMs = 0;

  int? _lastSentSecond;
  int? _lastSendAtMs;
  int _minuteIndex = 0;
  int _commitFrameTs = 0;
  Timer? _settleTimer;

  ScrubPhase get phase => _phase;
  bool get dragging => _phase == ScrubPhase.dragging;
  bool get settling => _phase == ScrubPhase.settling;

  /// Immutable snapshot for [ScrubTrack]; idle follows telemetry position.
  ScrubPreview get preview => ScrubPreview(
        positionMs:
            _phase == ScrubPhase.idle ? _lastState.positionMs : _targetMs,
        durationMs: _lastState.durationMs,
        dragging: _phase == ScrubPhase.dragging,
        settling: _phase == ScrubPhase.settling,
      );

  /// Accepts a telemetry tick; position is ignored while Dragging, frames
  /// older than the commit are ignored while Settling (§4.4 / §4.6).
  void onTelemetry(TelemetryState state) {
    final TelemetryState previous = _lastState;
    final bool durationChanged = state.durationMs != previous.durationMs;
    _lastState = state;

    if (_phase == ScrubPhase.dragging) {
      if (durationChanged) {
        // Duration re-read each frame: thumb fraction re-clamps on the
        // next updateDrag; repaint now so the rail matches the new total.
        notifyListeners();
      }
      return;
    }

    if (_phase == ScrubPhase.settling) {
      if (state.timestamp <= _commitFrameTs) {
        return; // frame predates the commit — not authoritative yet
      }
      if ((state.positionMs - _committedTargetMs).abs() <= kSettleWindow) {
        _exitToIdle(); // telemetry snapped onto the committed target
        return;
      }
      _targetMs = state.positionMs; // newer but still far: thumb follows
      notifyListeners();
      return;
    }

    if (state.positionMs != previous.positionMs || durationChanged) {
      notifyListeners(); // idle: thumb/labels track the new frame
    }
  }

  /// Begins a drag capturing the current telemetry position as anchor
  /// (§4.2). No-op without media — zero-duration gestures are inert (§7).
  void beginDrag(double trackWidth) {
    if (_phase != ScrubPhase.idle) {
      return;
    }
    final int duration = _lastState.durationMs;
    if (duration <= 0) {
      return;
    }
    _phase = ScrubPhase.dragging;
    _trackWidth = trackWidth <= 0 ? 1 : trackWidth;
    _dragAnchorMs = _clampTarget(_lastState.positionMs, duration).toDouble();
    _accumDx = 0;
    _targetMs = _dragAnchorMs.round();
    _lastSentSecond = null;
    _lastSendAtMs = null;
    _minuteIndex = _targetMs ~/ 60000;
    onActiveChanged?.call(true);
    notifyListeners();
  }

  /// Applies pointer delta -> preview position and streams throttled UDP
  /// `0x04` (§4.3): only when the integer second changed AND >=16 ms since
  /// the previous send; one Doc 42 `minuteTick` per 60 s of media crossed.
  void updateDrag(double dx) {
    if (_phase != ScrubPhase.dragging) {
      return;
    }
    final int duration = _lastState.durationMs;
    if (duration <= 0) {
      return;
    }
    _accumDx += dx;
    // Anchor in ms so a mid-drag duration change re-clamps fraction-style
    // without ever producing an out-of-range target (§7).
    final double raw = _dragAnchorMs + (_accumDx / _trackWidth) * duration;
    final int target = _clampTarget(raw.round(), duration);
    _tickMinuteBoundary(target);
    _targetMs = target;
    _streamThrottled(target);
    notifyListeners();
  }

  /// Commits the final WS `SEEK {"position_ms": targetMs}` (plus one last
  /// UDP bridge packet) and enters Settling (§4.5).
  void endDrag() {
    if (_phase != ScrubPhase.dragging) {
      return;
    }
    final int duration = _lastState.durationMs;
    if (duration <= 0) {
      _exitToIdle(); // media vanished underneath — drop silently
      return;
    }
    final int target = _clampTarget(_targetMs, duration);
    _targetMs = target;
    _transport.sendScrub(target ~/ 1000); // final UDP (state diagram)
    _committedTargetMs = target;
    _commitFrameTs = _lastState.timestamp;
    if (_transport.wsConnected) {
      _transport.sendSeek(target);
    }
    _phase = ScrubPhase.settling;
    _startSettleTimer();
    notifyListeners();
  }

  /// Aborts the drag (rotation / sheet overlay): commit only when the
  /// preview drifted >= 1 full second, otherwise drop to Idle (§4.7).
  void cancelDrag() {
    if (_phase != ScrubPhase.dragging) {
      return;
    }
    final int duration = _lastState.durationMs;
    final int drift = (_targetMs - _dragAnchorMs.round()).abs();
    if (drift >= 1000 && duration > 0 && _transport.wsConnected) {
      _transport.sendSeek(_clampTarget(_targetMs, duration));
    }
    _exitToIdle();
  }

  /// `targetMs` clamped to `[0, duration - kCommitOvershootGuard]`.
  int _clampTarget(int ms, int duration) {
    final int hi =
        duration > kCommitOvershootGuard ? duration - kCommitOvershootGuard : 0;
    if (ms < 0) {
      return 0;
    }
    return ms > hi ? hi : ms;
  }

  void _streamThrottled(int targetMs) {
    final int second = targetMs ~/ 1000;
    if (second == _lastSentSecond) {
      return; // throttle (b): integer-second change only
    }
    final int now = _nowMs();
    final int? last = _lastSendAtMs;
    if (last != null && now - last < kScrubSendMinInterval) {
      return; // throttle (a): >=16 ms spacing (~60 Hz cap)
    }
    _lastSentSecond = second;
    _lastSendAtMs = now;
    _transport.sendScrub(second);
  }

  void _tickMinuteBoundary(int targetMs) {
    final int index = targetMs ~/ 60000;
    if (index == _minuteIndex) {
      return;
    }
    final int step = index > _minuteIndex ? 1 : -1;
    for (int i = _minuteIndex; i != index; i += step) {
      unawaited(_playHaptic(HapticPattern.minuteTick));
    }
    _minuteIndex = index;
  }

  void _startSettleTimer() {
    _settleTimer?.cancel();
    _settleTimer = _timer(
      const Duration(milliseconds: kSettleTimeout),
      (Timer timer) {
        if (_phase == ScrubPhase.settling) {
          debugPrint(
            'ScrubSpeedHud: settle timeout after $kSettleTimeout ms — '
            'trusting committed target $_committedTargetMs',
          );
          _exitToIdle();
        }
      },
    );
  }

  Timer _timer(Duration duration, void Function(Timer timer) callback) {
    final Timer Function(Duration, void Function(Timer))? factory =
        timerFactory;
    if (factory != null) {
      return factory(duration, callback);
    }
    late final Timer timer;
    timer = Timer(duration, () => callback(timer));
    return timer;
  }

  void _exitToIdle() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _phase = ScrubPhase.idle;
    onActiveChanged?.call(false);
    notifyListeners();
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _settleTimer = null;
    super.dispose();
  }
}

/// Provider-owned controller: production wires Doc 42 haptics + the Doc 30/31
/// transport; tests override with fully faked instances (no sockets, fake
/// clock, spy haptics).
final Provider<ScrubController> scrubControllerProvider =
    Provider<ScrubController>((Ref ref) {
  final ScrubController controller = ScrubController(
    transport: ref.watch(scrubTransportProvider),
    playHaptic: (HapticPattern pattern) =>
        ref.read(hapticEngineProvider).play(pattern),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// The draggable timeline track: rail + thumb painted by [_RailPainter],
/// horizontal-drag gestures (vertical hit-slop comes from Flutter's
/// horizontal recognizer, ~16 dp) forwarded to [dragController].
class ScrubTrack extends StatefulWidget {
  const ScrubTrack({
    super.key,
    required this.dragController,
    required this.preview,
  });

  final ScrubController dragController;
  final ScrubPreview preview;

  @override
  State<ScrubTrack> createState() => _ScrubTrackState();
}

class _ScrubTrackState extends State<ScrubTrack> {
  double _trackWidth = 1;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _trackWidth = constraints.maxWidth <= 0 ? 1 : constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (DragStartDetails details) =>
              widget.dragController.beginDrag(_trackWidth),
          onHorizontalDragUpdate: (DragUpdateDetails details) =>
              widget.dragController.updateDrag(details.primaryDelta ?? 0),
          onHorizontalDragEnd: (DragEndDetails details) =>
              widget.dragController.endDrag(),
          onHorizontalDragCancel: () => widget.dragController.cancelDrag(),
          child: SizedBox(
            height: 48, // comfortable gesture band around the 3 dp rail
            child: CustomPaint(
              size: Size.infinite, // fill the LayoutBuilder width
              painter: _RailPainter(widget.preview),
            ),
          ),
        );
      },
    );
  }
}

/// Rail (25 % amber) + elapsed fill (Doc 29 amber accent) + thumb
/// (14 dp, grows to 18 dp while dragging).
class _RailPainter extends CustomPainter {
  const _RailPainter(this.preview);

  final ScrubPreview preview;

  @override
  void paint(Canvas canvas, Size size) {
    final double midY = size.height / 2;
    const double railHeight = 3;
    const Radius radius = Radius.circular(railHeight / 2);
    final RRect track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, midY - railHeight / 2, size.width, railHeight),
      radius,
    );
    canvas.drawRRect(
      track,
      Paint()..color = AppColors.amber.withValues(alpha: 0.25),
    );

    if (preview.durationMs <= 0) {
      return; // zero/unknown duration: empty rail only (§7)
    }
    final double fraction = (preview.positionMs / preview.durationMs)
        .clamp(0.0, 1.0)
        .toDouble();
    if (fraction > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            0,
            midY - railHeight / 2,
            size.width * fraction,
            railHeight,
          ),
          radius,
        ),
        Paint()..color = AppColors.amber,
      );
    }

    final double thumbRadius = preview.dragging ? 9 : 7; // 18 dp / 14 dp
    final double minX = thumbRadius;
    final double maxX = size.width - thumbRadius;
    final double x = maxX <= minX
        ? size.width / 2
        : (size.width * fraction).clamp(minX, maxX);
    canvas.drawCircle(
      Offset(x, midY),
      thumbRadius,
      Paint()..color = AppColors.amber,
    );
  }

  @override
  bool shouldRepaint(_RailPainter oldDelegate) =>
      oldDelegate.preview != preview;
}

/// OSD badge kind (Doc 38 §3): display-only pills, no dispatch.
enum OsdBadgeKind { speed, volume }

/// Read-only OSD pill: speed `1.4x` or volume `42%`; dims + shows `--`
/// when the Doc 33 staleness clock exceeds [kStaleAfter] (speed also when
/// the multiplier was never received).
class OsdBadge extends ConsumerWidget {
  const OsdBadge({super.key, required this.kind});

  final OsdBadgeKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetryState state = ref.watch(telemetryProvider);
    final bool stale = telemetryAgeMs(state) > kStaleAfter;
    final bool unknownSpeed =
        kind == OsdBadgeKind.speed && state.speed < kSpeedUnknownBelow;
    final bool dimmed = stale || unknownSpeed;
    final String label;
    switch (kind) {
      case OsdBadgeKind.speed:
        label = dimmed ? '--' : '${formatSpeed(state.speed)}x';
      case OsdBadgeKind.volume:
        label = stale ? '--' : '${state.potPlayerVolume}%';
    }
    return Opacity(
      opacity: dimmed ? 0.45 : 1.0,
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.outline),
        ),
        child: Text(
          label,
          style: AppTypography.label.copyWith(
            fontSize: 11,
            height: 1.0,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Root HUD widget: ScrubTrack + SpeedBadge + VolumeBadge over a
/// TelemetryNotifier watch (Public Contract).
class ScrubSpeedHud extends ConsumerStatefulWidget {
  const ScrubSpeedHud({super.key, this.onScrubActiveChanged});

  /// Notifies the host (e.g. deck) to mute telemetry-driven UI while the
  /// scrub machine is off-Idle.
  final ValueChanged<bool>? onScrubActiveChanged;

  @override
  ConsumerState<ScrubSpeedHud> createState() => _ScrubSpeedHudState();
}

class _ScrubSpeedHudState extends ConsumerState<ScrubSpeedHud> {
  late final ScrubController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(scrubControllerProvider);
    _controller.addListener(_onControllerChanged);
    _controller.onActiveChanged = _relayActive;
  }

  /// Host relay for [ScrubController.onActiveChanged]. A settle can
  /// converge while the build below syncs a fresh frame — defer the host
  /// callback past the frame so the host never setStates during build.
  void _relayActive(bool active) {
    final ValueChanged<bool>? callback = widget.onScrubActiveChanged;
    if (callback == null) {
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance
          .addPostFrameCallback((Duration _) => callback(active));
    } else {
      callback(active);
    }
  }

  void _onControllerChanged() {
    // Telemetry seeds can notify from inside this element's build (the
    // build below already reads the fresh preview after the listener), so
    // skipping here avoids setState-during-build; every other producer
    // (gesture callbacks, settle timers, WS frames) runs outside build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      return;
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    // Detach before cancelling a drag so this (possibly disposing) subtree
    // gets no rebuild callbacks; the machine still exits Dragging and the
    // host hears `false` through the relay (deferred if we are mid-build).
    _controller.removeListener(_onControllerChanged);
    if (_controller.dragging) {
      _controller.cancelDrag();
    }
    if (_controller.onActiveChanged == _relayActive) {
      _controller.onActiveChanged = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    // Idempotent sync: every provider change rebuilds us, so the machine
    // ingests the frame here; an in-build notify is skipped by
    // _onControllerChanged and picked up by the preview read below.
    _controller.onTelemetry(telemetry);
    final ScrubPreview preview = _controller.preview;
    final bool stale = telemetryAgeMs(telemetry) > kStaleAfter;

    final String left = preview.durationMs <= 0
        ? '--:--:--'
        : formatTimecode(preview.positionMs);
    final String right = formatDurationTimecode(preview.durationMs);
    final String leftLabel =
        stale && !preview.dragging && !preview.settling ? '$left ·' : left;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              OsdBadge(
                key: Key('hud_badge_volume'),
                kind: OsdBadgeKind.volume,
              ),
              SizedBox(width: 6),
              OsdBadge(
                key: Key('hud_badge_speed'),
                kind: OsdBadgeKind.speed,
              ),
            ],
          ),
          const SizedBox(height: 6),
          ScrubTrack(
            key: const Key('hud_track'),
            dragController: _controller,
            preview: preview,
          ),
          const SizedBox(height: 4),
          Opacity(
            opacity: stale ? 0.45 : 1.0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  leftLabel,
                  key: const Key('hud_time_left'),
                  style: _timeStyle(preview.dragging),
                ),
                Text(
                  right,
                  key: const Key('hud_time_right'),
                  style: _timeStyle(false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _timeStyle(bool accent) => AppTypography.timecode.copyWith(
        fontSize: 12,
        height: 1.2,
        color: accent ? AppColors.amber : AppColors.textPrimary,
      );
}
