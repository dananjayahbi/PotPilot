import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';

/// DDC/CI throttle window: at most one `SET_BRIGHTNESS` per 200 ms
/// (Doc 19 latency; ≤5 packets/s during a drag).
const Duration kBrightnessThrottle = Duration(milliseconds: 200);

/// Post-release window during which incoming telemetry `brightness` is
/// held back before it may reclaim the slider (§7 brightness fight).
const Duration kBrightnessTelemetryDebounce = Duration(milliseconds: 500);

/// Gap between dispatch and the snap button's check pulse clearing (§4.2).
const Duration kSnapAckDuration = Duration(milliseconds: 700);

/// `SET_BRIGHTNESS_ERROR` hint visibility after a 4006 reply (§7).
const Duration kBrightnessErrorHintDuration = Duration(seconds: 2);

/// Local 1-minute countdown tick driving the Fall Asleep pill (§4.5).
const Duration kLocalMinuteTick = Duration(minutes: 1);

/// Namespaced local cache keys (§4 cache note), written through the
/// Doc 34-style [DisplayCache] wrapper below.
abstract final class DisplayCacheKeys {
  static const String blackoutEnabled = 'display.blackout_enabled';
  static const String lastBrightnessPct = 'display.last_brightness_pct';
}

/// Write-through, synchronous-read cache for the two `display.*` keys
/// (warm-start of the blackout switch + brightness slider).
///
/// Mirrors Doc 34's `ConnectionCache` contract (init once → sync in-memory
/// reads → async write-through) for a namespace the landed wrapper does not
/// export; like Doc 34, callers never touch `SharedPreferences` directly.
class DisplayCache {
  DisplayCache._();

  static final DisplayCache instance = DisplayCache._();

  /// Test/DI constructor so tests can build isolated instances.
  @visibleForTesting
  DisplayCache.forTest();

  SharedPreferences? _prefs;
  bool _ready = false;
  bool _blackout = false;
  int? _lastBrightness;

  bool get isReady => _ready;

  /// Last user-selected blackout state (false until first save).
  bool get blackoutEnabled => _blackout;

  /// Last user-selected brightness 0–100 (null = never saved).
  int? get lastBrightnessPct => _lastBrightness;

  /// Loads persisted state; [showMonitorPowerSheet] awaits this once before
  /// the first frame so warm-start never costs an extra frame.
  Future<void> init({SharedPreferences? injected}) async {
    final SharedPreferences prefs =
        injected ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    _blackout = prefs.getBool(DisplayCacheKeys.blackoutEnabled) ?? false;
    _lastBrightness = prefs.getInt(DisplayCacheKeys.lastBrightnessPct);
    _ready = true;
  }

  Future<void> saveBlackout(bool value) async {
    _blackout = value;
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setBool(DisplayCacheKeys.blackoutEnabled, value);
  }

  Future<void> saveBrightness(int percent) async {
    final int clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    _lastBrightness = clamped;
    final SharedPreferences? prefs = _prefs;
    if (prefs == null) {
      return;
    }
    await prefs.setInt(DisplayCacheKeys.lastBrightnessPct, clamped);
  }
}

/// Pure builders for the throttled system envelopes (shared with Doc 41).
///
/// Every builder returns the complete wire envelope
/// `{type, action, payload}` so callers (this drawer, the Doc 41 edge
/// gesture) dispatch byte-identical frames.
class SystemCommandBuilder {
  SystemCommandBuilder._();

  /// `{"type":"CMD_SYSTEM","action":"SET_BRIGHTNESS","payload":{"percent":P}}`
  /// with `P` clamped to 0–100.
  static Map<String, Object?> brightness(int percent) {
    final int clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    return <String, Object?>{
      'type': typeCmdSystem,
      'action': Action.setBrightness,
      'payload': <String, Object?>{'percent': clamped},
    };
  }

  /// Frozen `START_SLEEP_TIMER` COUNTDOWN form:
  /// `{"mode":"COUNTDOWN","target":T,"minutes":M}`.
  static Map<String, Object?> sleepTimerCountdown({
    required String target,
    required int minutes,
  }) {
    return <String, Object?>{
      'type': typeCmdSystem,
      'action': Action.startSleepTimer,
      'payload': <String, Object?>{
        'mode': 'COUNTDOWN',
        'target': target,
        'minutes': minutes,
      },
    };
  }

  /// Frozen MOVIE_PROGRESS form:
  /// `{"mode":"MOVIE_PROGRESS","target":T,"progress_pct":P}` (P=99 default).
  static Map<String, Object?> sleepTimerOnMovieEnd({
    required String target,
    int progressPct = 99,
  }) {
    return <String, Object?>{
      'type': typeCmdSystem,
      'action': Action.startSleepTimer,
      'payload': <String, Object?>{
        'mode': 'MOVIE_PROGRESS',
        'target': target,
        'progress_pct': progressPct,
      },
    };
  }
}

/// Sleep-timer preset row model: label + minutes (15/30/45/60) or the
/// end-of-movie sentinel.
class SleepPreset {
  const SleepPreset({required this.label, this.minutes, this.onMovieEnd});

  /// Chip label (`15 min` … `60 min`, `End of movie`).
  final String label;

  /// COUNTDOWN duration; null for the end-of-movie preset.
  final int? minutes;

  /// True for the `MOVIE_PROGRESS` sentinel preset.
  final bool? onMovieEnd;
}

/// The frozen `Sleep`/`Hibernate`/`Shutdown` power-target chips (§4.5).
const List<({String id, String label})> kSleepTargets =
    <({String id, String label})>[
      (id: 'SLEEP', label: 'Sleep'),
      (id: 'HIBERNATE', label: 'Hibernate'),
      (id: 'SHUTDOWN', label: 'Shutdown'),
    ];

/// Preset chips rendered by the Fall Asleep section (§4.5 table).
const List<SleepPreset> kSleepPresets = <SleepPreset>[
  SleepPreset(label: '15 min', minutes: 15),
  SleepPreset(label: '30 min', minutes: 30),
  SleepPreset(label: '45 min', minutes: 45),
  SleepPreset(label: '60 min', minutes: 60),
  SleepPreset(label: 'End of movie', onMovieEnd: true),
];

/// Throttle + optimistic bookkeeping for continuous/rapid system commands.
class SystemCommandController extends ChangeNotifier {
  SystemCommandController({
    WsClient? client,
    Future<void> Function(HapticPattern pattern)? playHaptic,
  }) : _client = client ?? WsClient.instance,
       _playHaptic = playHaptic ?? _noHaptics;

  final WsClient _client;
  final Future<void> Function(HapticPattern pattern) _playHaptic;

  Timer? _throttle;
  int? _pendingBrightness;
  bool _timerArmed = false;
  int? _remainingMinutes;
  Timer? _minuteTicker;

  /// Doc 31 seam; tests inject a fake client here.
  WsClient get client => _client;

  /// Doc 31 connected gate — every dispatch below respects it.
  bool get connected => _client.state == WsConnectionState.connected;

  /// True while a timer is armed (drives the countdown pill).
  bool get timerArmed => _timerArmed;

  /// Locally-tracked minutes remaining (null for end-of-movie / cancelled).
  int? get remainingMinutes => _remainingMinutes;

  /// Doc 42 sink for widget-level cues (slider detents).
  Future<void> cue(HapticPattern pattern) => _playHaptic(pattern);

  /// Sends `SET_BRIGHTNESS` at most every 200 ms (latest value wins);
  /// the trailing [commitBrightness] on release delivers the final value.
  void setBrightness(int percent) {
    if (!connected) {
      return;
    }
    final int clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    _pendingBrightness = clamped;
    if (_throttle != null) {
      return;
    }
    _throttle = Timer(kBrightnessThrottle, () {
      _throttle = null;
      final int? value = _pendingBrightness;
      _pendingBrightness = null;
      if (value != null) {
        _sendBrightness(value);
      }
    });
  }

  /// Trailing send on finger release: cancels the open throttle window and
  /// guarantees the released value is the last packet on the wire.
  void commitBrightness() {
    _throttle?.cancel();
    _throttle = null;
    final int? value = _pendingBrightness;
    _pendingBrightness = null;
    if (value == null || !connected) {
      return;
    }
    _sendBrightness(value);
  }

  /// Fire-and-forget `SNAP_TO_PRIMARY_MONITOR {}`.
  Future<void> snapToPrimary() async {
    if (!connected) {
      return;
    }
    await _client.send(typeCmdSystem, Action.snapToPrimaryMonitor, <String, dynamic>{});
  }

  /// Fire-and-forget `SET_BLACKOUT {"enabled": …}`.
  Future<void> setBlackout(bool enabled) async {
    if (!connected) {
      return;
    }
    await _client.send(typeCmdSystem, Action.setBlackout, <String, dynamic>{'enabled': enabled});
  }

  /// Arms the sleep timer (target ∈ SLEEP|HIBERNATE|SHUTDOWN) and tracks
  /// remaining minutes locally via a 1-min ticker (telemetry overrides the
  /// display when it reports `sleep_timer_active`).
  Future<void> armTimer({
    required String target,
    int? minutes,
    bool onMovieEnd = false,
  }) async {
    if (!connected) {
      return;
    }
    if (!onMovieEnd && minutes == null) {
      throw ArgumentError('minutes required for a COUNTDOWN timer');
    }
    final Map<String, Object?> envelope = onMovieEnd
        ? SystemCommandBuilder.sleepTimerOnMovieEnd(target: target)
        : SystemCommandBuilder.sleepTimerCountdown(
            target: target,
            minutes: minutes!,
          );
    await _sendEnvelope(envelope);
    _timerArmed = true;
    _remainingMinutes = onMovieEnd ? null : minutes;
    _startMinuteTicker();
    await _playHaptic(HapticPattern.heavyThud);
    notifyListeners();
  }

  /// Dispatches `CANCEL_SLEEP_TIMER {}` and clears the local countdown.
  Future<void> cancelTimer() async {
    if (connected) {
      await _client.send(typeCmdSystem, Action.cancelSleepTimer, <String, dynamic>{});
    }
    _timerArmed = false;
    _remainingMinutes = null;
    _minuteTicker?.cancel();
    _minuteTicker = null;
    notifyListeners();
  }

  void _startMinuteTicker() {
    _minuteTicker?.cancel();
    _minuteTicker = null;
    if (_remainingMinutes == null) {
      return; // end-of-movie: no local number exists to tick
    }
    _minuteTicker = Timer.periodic(kLocalMinuteTick, (Timer timer) {
      final int? current = _remainingMinutes;
      if (current == null) {
        return;
      }
      _remainingMinutes = current > 0 ? current - 1 : 0;
      notifyListeners();
    });
  }

  void _sendBrightness(int percent) {
    _client.send(typeCmdSystem, Action.setBrightness, <String, dynamic>{'percent': percent});
  }

  Future<void> _sendEnvelope(Map<String, Object?> envelope) {
    final Object? payload = envelope['payload'];
    return _client.send(
      envelope['type']! as String,
      envelope['action']! as String,
      Map<String, dynamic>.from(payload! as Map),
    );
  }

  @override
  void dispose() {
    _throttle?.cancel();
    _throttle = null;
    _minuteTicker?.cancel();
    _minuteTicker = null;
    super.dispose();
  }

  static Future<void> _noHaptics(HapticPattern pattern) async {}
}

/// Module controller seam: widget tests override this with a real
/// controller wired to a fake Doc 31 client.
final Provider<SystemCommandController> monitorPowerControllerProvider =
    Provider<SystemCommandController>((ref) {
      final SystemCommandController controller = SystemCommandController(
        playHaptic: (HapticPattern pattern) async {
          try {
            await ref.read(hapticEngineProvider).play(pattern);
          } on Object {
            // Doc 42 engine is wired in main (Session 3); haptics are
            // best-effort until then.
          }
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// Presents the quick-control drawer (end-aligned modal sheet,
/// drag-dismissible).
///
/// Awaits the DisplayCache warm-start read first so the slider and blackout
/// switch land on persisted values within the first frame of the open.
Future<void> showMonitorPowerSheet(BuildContext context) async {
  try {
    await DisplayCache.instance.init();
  } on Object {
    // Prefs unavailable → defaults; the drawer must still open.
  }
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.background,
    elevation: 0,
    isScrollControlled: true,
    builder: (BuildContext context) => const MonitorPowerSheet(),
  );
}

/// Root drawer widget: snap button, blackout toggle, brightness slider,
/// sleep-timer block.
class MonitorPowerSheet extends ConsumerStatefulWidget {
  const MonitorPowerSheet({super.key});

  @override
  ConsumerState<MonitorPowerSheet> createState() => _MonitorPowerSheetState();
}

class _MonitorPowerSheetState extends ConsumerState<MonitorPowerSheet> {
  late SystemCommandController _controller;
  StreamSubscription<WsMessage>? _replies;
  Timer? _releaseDebounce;
  Timer? _errorHintTimer;
  Timer? _snapTimer;

  bool _snapAck = false;
  bool _dragging = false;
  int _lastDetent = -1;

  double _brightness = 50;
  double _preDragBrightness = 50;
  int? _lastAccepted;
  bool? _ddcSupported;
  bool _showErrorHint = false;

  bool _blackoutOn = false;
  String _target = 'SLEEP';
  String? _armedPresetLabel;
  bool _suppressTelemetryTimer = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(monitorPowerControllerProvider);
    _controller.addListener(_onControllerTick);

    // Warm-start from the Doc 34-style cache, then snap to whatever the
    // telemetry already carries (cache first, telemetry wins — §4.4).
    final DisplayCache cache = DisplayCache.instance;
    if (cache.isReady) {
      _blackoutOn = cache.blackoutEnabled;
      final int? saved = cache.lastBrightnessPct;
      if (saved != null) {
        _brightness = saved.toDouble();
        _preDragBrightness = _brightness;
        _lastAccepted = saved;
      }
    }
    _adoptFromTelemetry(ref.read(telemetryProvider));
    _lastDetent = _brightness ~/ 5;

    _replies = _controller.client.envelopes.listen(_onReply);
  }

  @override
  void dispose() {
    _replies?.cancel();
    _releaseDebounce?.cancel();
    _errorHintTimer?.cancel();
    _snapTimer?.cancel();
    _controller.removeListener(_onControllerTick);
    super.dispose();
  }

  void _onControllerTick() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Doc 03 §5.8: `SET_BRIGHTNESS_ERROR` with code 4006 (no DDC/CI) reverts
  /// the slider to the last accepted value and hints for 2 s (§7).
  void _onReply(WsMessage message) {
    if (message.action != Action.setBrightness + errorSuffix) {
      return;
    }
    if (message.payload['code'] != errorHardwareUnavailable) {
      return;
    }
    if (!mounted) {
      return;
    }
    final int revert = _lastAccepted ?? _preDragBrightness.round();
    _errorHintTimer?.cancel();
    setState(() {
      _brightness = revert.toDouble();
      _lastDetent = revert ~/ 5;
      _showErrorHint = true;
    });
    _errorHintTimer = Timer(kBrightnessErrorHintDuration, () {
      if (mounted) {
        setState(() {
          _showErrorHint = false;
        });
      }
    });
  }

  bool _adoptBrightness(TelemetryState telemetry) {
    if (!telemetry.isConnected || !telemetry.extras.containsKey('brightness')) {
      return false;
    }
    final Object? value = telemetry.extras['brightness'];
    if (value is int) {
      final int pct = value < 0 ? 0 : (value > 100 ? 100 : value);
      final bool changed = _ddcSupported != true || _brightness.round() != pct;
      _ddcSupported = true;
      _brightness = pct.toDouble();
      _preDragBrightness = _brightness;
      _lastAccepted = pct;
      return changed;
    }
    if (value == null) {
      final bool changed = _ddcSupported != false;
      _ddcSupported = false;
      return changed;
    }
    return false;
  }

  void _adoptFromTelemetry(TelemetryState telemetry) {
    if (!telemetry.isConnected) {
      return;
    }
    final Object? blackout = telemetry.extras['blackout_active'];
    if (blackout is bool) {
      _blackoutOn = blackout;
    }
    _adoptBrightness(telemetry);
  }

  /// Telemetry reconciliation (§4.3/§4.4): `blackout_active` every frame
  /// while connected; `brightness` only when the finger is off the slider
  /// and the post-release debounce has elapsed.
  void _onTelemetry(TelemetryState telemetry) {
    if (!mounted) {
      return;
    }
    bool changed = false;
    if (telemetry.isConnected) {
      final Object? blackout = telemetry.extras['blackout_active'];
      if (blackout is bool && blackout != _blackoutOn) {
        _blackoutOn = blackout;
        changed = true;
      }
      if (telemetry.extras['sleep_timer_active'] == false) {
        _suppressTelemetryTimer = false;
      }
      if (!_dragging && _releaseDebounce == null) {
        changed = _adoptBrightness(telemetry) || changed;
      }
    }
    if (changed) {
      setState(() {});
    }
  }

  void _onReleaseDebounceElapsed() {
    _releaseDebounce = null;
    // A re-grab during the window re-enters drag mode: telemetry must not
    // fight the finger (next release re-arms its own debounce).
    if (_dragging || !mounted) {
      return;
    }
    // Telemetry wins after release — the current snapshot is the truth,
    // even if the last frame itself predates the drag.
    if (_adoptBrightness(ref.read(telemetryProvider))) {
      setState(() {});
    }
  }

  void _onBrightnessChanged(double value) {
    if (_ddcSupported == false) {
      return;
    }
    if (!_dragging) {
      _dragging = true;
      _preDragBrightness = _brightness;
    }
    final int pct = value.round();
    final int detent = pct ~/ 5;
    if (detent != _lastDetent) {
      _lastDetent = detent;
      _controller.cue(HapticPattern.volumeTick);
    }
    setState(() {
      _brightness = value;
    });
    _controller.setBrightness(pct);
  }

  void _onBrightnessChangedEnd(double value) {
    _dragging = false;
    final int pct = value.round();
    _lastDetent = pct ~/ 5;
    _controller.commitBrightness();
    DisplayCache.instance.saveBrightness(pct);
    _releaseDebounce?.cancel();
    _releaseDebounce = Timer(
      kBrightnessTelemetryDebounce,
      _onReleaseDebounceElapsed,
    );
  }

  void _onSnap() {
    _controller.snapToPrimary();
    _snapTimer?.cancel();
    setState(() {
      _snapAck = true;
    });
    _snapTimer = Timer(kSnapAckDuration, () {
      if (mounted) {
        setState(() {
          _snapAck = false;
        });
      }
    });
  }

  void _onBlackoutChanged(bool value) {
    setState(() {
      _blackoutOn = value;
    });
    _controller.setBlackout(value);
    DisplayCache.instance.saveBlackout(value);
  }

  Future<void> _onArm(SleepPreset preset) async {
    await _controller.armTimer(
      target: _target,
      minutes: preset.minutes,
      onMovieEnd: preset.onMovieEnd == true,
    );
    if (!_controller.timerArmed || !mounted) {
      return;
    }
    setState(() {
      _armedPresetLabel = preset.label;
      _suppressTelemetryTimer = false;
    });
  }

  Future<void> _onCancelTimer() async {
    await _controller.cancelTimer();
    if (!mounted) {
      return;
    }
    setState(() {
      _armedPresetLabel = null;
      // Optimistic clear: the still-active telemetry frame must not keep
      // the pill alive while CANCEL_SLEEP_TIMER lands on the agent.
      _suppressTelemetryTimer = true;
    });
  }

  /// §4.5 pill: telemetry `sleep_timer_remaining_s` wins while active &
  /// fresh; the local 1-min countdown is the fallback; `Armed` when no
  /// trustworthy number exists (never a wrong countdown).
  String? _pillText(TelemetryState telemetry) {
    final bool telemetryActive = telemetry.extras['sleep_timer_active'] == true;
    final Object? remainingRaw = telemetry.extras['sleep_timer_remaining_s'];
    final int? remainingSeconds = remainingRaw is int ? remainingRaw : null;
    final int ageMs =
        DateTime.now().millisecondsSinceEpoch - telemetry.timestamp * 1000;
    final bool fresh = telemetry.isConnected && ageMs <= 1000;
    if (telemetryActive &&
        !_suppressTelemetryTimer &&
        fresh &&
        remainingSeconds != null) {
      final int minutes = (remainingSeconds + 59) ~/ 60;
      return 'Fall asleep in ${minutes < 1 ? 1 : minutes} min';
    }
    if (_controller.timerArmed) {
      final int? local = _controller.remainingMinutes;
      return local != null ? 'Fall asleep in $local min' : 'Armed';
    }
    if (telemetryActive && !_suppressTelemetryTimer) {
      return 'Armed';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    ref.listen<TelemetryState>(
      telemetryProvider,
      (TelemetryState? previous, TelemetryState next) => _onTelemetry(next),
    );
    final SystemCommandController controller = ref.read(
      monitorPowerControllerProvider,
    );

    final int ageMs =
        DateTime.now().millisecondsSinceEpoch - telemetry.timestamp * 1000;
    final bool stale = !telemetry.isConnected || ageMs > 1000;
    final String pill = _pillText(telemetry) ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: StreamBuilder<WsConnectionState>(
          stream: controller.client.stateChanges,
          initialData: controller.client.state,
          builder: (
            BuildContext context,
            AsyncSnapshot<WsConnectionState> snap,
          ) {
            final bool connected = snap.data == WsConnectionState.connected;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!connected) _reconnectStrip(),
                Opacity(
                  opacity: connected ? 1 : 0.45,
                  child: AbsorbPointer(
                    absorbing: !connected,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        const SizedBox(height: 8),
                        _buildSnapButton(connected),
                        const Divider(),
                        _buildBlackoutRow(),
                        const Divider(),
                        _buildBrightnessSection(stale),
                        const Divider(),
                        _buildSleepSection(telemetry, pill, connected),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildSnapButton(bool connected) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        key: const Key('display_snap_button'),
        onPressed: connected ? _onSnap : null,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _snapAck ? '\u2713' : '\u26F6',
              key: const Key('display_snap_glyph'),
              style: AppTypography.body.copyWith(
                color: _snapAck ? AppColors.amber : AppColors.onAccent,
              ),
            ),
            const SizedBox(width: 8),
            const Text('Snap to Main Screen'),
          ],
        ),
      ),
    );
  }

  Widget _buildBlackoutRow() {
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          Text(
            'Blackout Other Monitors',
            style: AppTypography.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const Spacer(),
          Text(
            _blackoutOn ? 'On' : 'Off',
            key: const Key('display_blackout_state'),
            style: AppTypography.bodySmall.copyWith(
              color: _blackoutOn ? AppColors.amber : AppColors.textTertiary,
            ),
          ),
          Switch(
            key: const Key('display_blackout_switch'),
            value: _blackoutOn,
            onChanged: _controller.connected ? _onBlackoutChanged : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBrightnessSection(bool stale) {
    final bool supported = _ddcSupported != false;
    final String readout = stale ? '--' : '${_brightness.round()}%';
    final bool showHint = !supported || _showErrorHint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                '\u2600',
                key: Key('display_brightness_glyph'),
                style: TextStyle(fontSize: 16, color: AppColors.amber),
              ),
              Expanded(
                child: Slider(
                  key: const Key('display_brightness_slider'),
                  value: _brightness.clamp(0.0, 100.0),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '${_brightness.round()}%',
                  onChanged: supported && _controller.connected
                      ? _onBrightnessChanged
                      : null,
                  onChangeEnd: supported && _controller.connected
                      ? _onBrightnessChangedEnd
                      : null,
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  readout,
                  key: const Key('display_brightness_readout'),
                  textAlign: TextAlign.right,
                  style: AppTypography.bodySmall.copyWith(
                    fontFamilyFallback: const <String>[
                      'Roboto Mono',
                      'monospace',
                    ],
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          if (showHint)
            const Padding(
              padding: EdgeInsets.only(left: 28, top: 2),
              child: Text(
                'Not supported',
                key: Key('display_brightness_hint'),
                style: TextStyle(fontSize: 12, color: AppColors.crimson),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSleepSection(
    TelemetryState telemetry,
    String pill,
    bool connected,
  ) {
    final bool armed = _controller.timerArmed;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 36,
            child: Row(
              children: <Widget>[
                if (pill.isNotEmpty)
                  _countdownPill(pill)
                else
                  Text(
                    'Fall Asleep',
                    style: AppTypography.label.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final ({String id, String label}) target in kSleepTargets)
                ChoiceChip(
                  key: Key('display_target_${target.id}'),
                  label: Text(target.label),
                  selected: _target == target.id,
                  selectedColor: AppColors.amberDim,
                  labelStyle: TextStyle(
                    color: _target == target.id
                        ? AppColors.onAccent
                        : AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  onSelected: !connected
                      ? null
                      : (bool selected) {
                          if (!selected) {
                            return;
                          }
                          setState(() {
                            _target = target.id;
                          });
                        },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final SleepPreset preset in kSleepPresets)
                ChoiceChip(
                  key: Key('display_preset_${preset.label}'),
                  label: Text(preset.label),
                  selected: armed && _armedPresetLabel == preset.label,
                  selectedColor: AppColors.amberDim,
                  labelStyle: TextStyle(
                    color: armed && _armedPresetLabel == preset.label
                        ? AppColors.onAccent
                        : AppColors.textSecondary,
                    fontSize: 13,
                  ),
                  onSelected: !connected
                      ? null
                      : (bool selected) {
                          if (selected) {
                            _onArm(preset);
                          }
                        },
                ),
              if (armed)
                ActionChip(
                  key: const Key('display_timer_cancel'),
                  label: const Text('Cancel'),
                  backgroundColor: AppColors.crimsonDim,
                  labelStyle: const TextStyle(
                    color: AppColors.onAccent,
                    fontSize: 13,
                  ),
                  onPressed: connected ? _onCancelTimer : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _countdownPill(String text) {
    return Container(
      key: const Key('sleep_timer_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.amber, width: 1),
      ),
      child: Text(
        text,
        style: AppTypography.label.copyWith(color: AppColors.amber),
      ),
    );
  }

  Widget _reconnectStrip() {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Column(
        key: Key('display_reconnect_strip'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(height: 2, child: ColoredBox(color: AppColors.crimson)),
          SizedBox(height: 6),
          Text(
            'Reconnecting\u2026',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              color: AppColors.crimson,
            ),
          ),
        ],
      ),
    );
  }
}
