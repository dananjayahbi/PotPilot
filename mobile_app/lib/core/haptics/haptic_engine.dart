// Doc 42: standalone tactile feedback service for the PotPilot remote.
//
// Named, pre-tuned vibration patterns so every remote interaction is
// confirmable without looking at the screen (bedroom ergonomics). The engine
// is 100% local to the phone: it opens no sockets and imports nothing from
// `lib/network/**` (Doc 42 §5). Dispatch is fire-and-forget on the main
// isolate, with a 30 ms coalescer (except `heavyThud`), a timer-driven scrub
// loop, lifecycle-safe cancellation, a `VibrationPort` output seam for tests,
// and a `shared_preferences`-persisted mute flag (`haptics_enabled` key,
// owned by this doc).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

/// Named tactile catalog; each value maps to a tuned amplitude/time profile
/// (Doc 42 §4.2). Closed enum — adding a pattern is an orchestrator change.
enum HapticPattern {
  /// Sharp, thin tick — 5s seek / tap-to-click.
  microTick,

  /// Weighty confirmation — Play/Pause.
  heavyThud,

  /// Two ticks 60 ms apart — 1.0x speed reset marker.
  doubleTick,

  /// Rhythmic scrubbing heartbeat (looped by `startScrubPulse`).
  scrubPulse,

  /// Volume step confirmation (Doc 43).
  volumeTick,

  /// Coarse minute boundary (Doc 41).
  minuteTick,
}

/// Drops one-shot requests arriving within 30 ms of the last emitted pulse
/// (Doc 42 §4.1 coalescer); `heavyThud` always bypasses it.
const int kHapticCoalesceMs = 30;

/// After `cancelAll()`, `play()` stays muted this long (Doc 42 §4.4 step 1).
const int kHapticCancelBlockMs = 50;

/// Watchdog that kills a scrub loop whose consumer forgot `stopScrubPulse()`
/// while the app is backgrounded (Doc 42 §7).
const Duration kScrubWatchdogInterval = Duration(seconds: 5);

/// Persisted "silent mode" toggle key, owned by this doc (Doc 42 §10).
const String kHapticsEnabledPrefKey = 'haptics_enabled';

/// One entry of the §4.2 profile table: a single pulse *unit* (timings and
/// per-segment amplitudes, 0 = off segment) plus how it stacks and repeats.
@immutable
class VibrationProfile {
  const VibrationProfile({
    required this.timingsMs,
    required this.amplitudes,
    this.stackGapMs = 60,
    this.minStacks = 1,
    this.repeating = false,
  });

  /// Segment durations of one unit, back-to-back (gaps are explicit
  /// zero-amplitude segments, Android `createWaveform` semantics).
  final List<int> timingsMs;

  /// Amplitude (0–255) for each segment; same length as [timingsMs].
  final List<int> amplitudes;

  /// Off-time inserted between stacked repeats of the unit.
  final int stackGapMs;

  /// Catalog minimum pulse count — `doubleTick` stacks 2 by design
  /// (Doc 42 §3: "[repeat] stacks identical pulses (doubleTick = 2)").
  final int minStacks;

  /// True for patterns driven as a continuous loop (`scrubPulse`).
  final bool repeating;
}

/// Profile table (Doc 42 §4.2 starting values — hardware-tunable via §10).
abstract final class _ProfileTable {
  static const Map<HapticPattern, VibrationProfile> values =
      <HapticPattern, VibrationProfile>{
        HapticPattern.microTick: VibrationProfile(
          timingsMs: <int>[10],
          amplitudes: <int>[96],
        ),
        // 55 ms @255 + 40 ms gap + 25 ms tail @128.
        HapticPattern.heavyThud: VibrationProfile(
          timingsMs: <int>[55, 40, 25],
          amplitudes: <int>[255, 0, 128],
          stackGapMs: 40,
        ),
        // One 15 ms pulse @160; catalog feel = 2 stacked (60 ms apart).
        HapticPattern.doubleTick: VibrationProfile(
          timingsMs: <int>[15],
          amplitudes: <int>[160],
          stackGapMs: 60,
          minStacks: 2,
        ),
        HapticPattern.scrubPulse: VibrationProfile(
          timingsMs: <int>[25],
          amplitudes: <int>[140],
          repeating: true,
        ),
        HapticPattern.volumeTick: VibrationProfile(
          timingsMs: <int>[12],
          amplitudes: <int>[110],
        ),
        HapticPattern.minuteTick: VibrationProfile(
          timingsMs: <int>[18],
          amplitudes: <int>[180],
        ),
      };
}

/// Output seam (Doc 42 §4.1): production wraps the `vibration` plugin, tests
/// inject a fake. Shaped as Android `createWaveform` segment arrays.
abstract class VibrationPort {
  /// True when the device exposes a usable vibrator.
  bool get isSupported;

  /// Emits one waveform: segment [i] runs `timingsMs[i]` at `amplitudes[i]`.
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  });

  /// Cancels any in-flight vibration; safe when idle.
  Future<void> cancel();
}

/// Production port: thin wrapper over the `vibration` plugin (Doc 42 §6).
class _PluginVibrationPort implements VibrationPort {
  _PluginVibrationPort() {
    unawaited(_probe());
  }

  bool _supported = true;

  Future<void> _probe() async {
    try {
      _supported = await Vibration.hasVibrator();
    } catch (_) {
      _supported = false; // emulators, budget devices, missing permission
    }
  }

  @override
  bool get isSupported => _supported;

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) {
    return Vibration.vibrate(
      pattern: timingsMs,
      intensities: amplitudes,
      repeat: -1,
    );
  }

  @override
  Future<void> cancel() => Vibration.cancel();
}

/// Silent port for the release-mode no-op engine (Doc 42 §7).
class _NoopVibrationPort implements VibrationPort {
  @override
  bool get isSupported => false;

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) async {}

  @override
  Future<void> cancel() async {}
}

/// Standalone haptic service. Fire-and-forget, main-isolate safe,
/// network-free (Doc 42 §3).
class HapticEngine with WidgetsBindingObserver {
  /// [port] and [preferences] are injectable test/DI seams; production
  /// defaults wrap the `vibration` plugin and load the persisted mute flag.
  HapticEngine({VibrationPort? port, SharedPreferences? preferences})
    : _port = port ?? _PluginVibrationPort(),
      _prefs = preferences != null
          ? Future<SharedPreferences?>.value(preferences)
          : _loadPreferences() {
    if (preferences != null) {
      _enabled = preferences.getBool(kHapticsEnabledPrefKey) ?? true;
    } else {
      unawaited(_prefs.then(_readPersistedFlag));
    }
    _attachLifecycle();
  }

  /// Release-mode fallback when the provider was never wired (Doc 42 §7).
  factory HapticEngine.noOp() {
    final HapticEngine engine = HapticEngine(port: _NoopVibrationPort());
    engine._enabled = false;
    return engine;
  }

  final VibrationPort _port;
  final Future<SharedPreferences?> _prefs;

  bool _enabled = true;
  bool _coolingDown = false;
  bool _cancelBlock = false;
  bool _paused = false;
  Timer? _cooldownTimer;
  Timer? _cancelBlockTimer;
  Timer? _scrubTimer;
  Timer? _scrubWatchdogTimer;
  WidgetsBinding? _lifecycleBinding;
  bool _loggedPluginFailure = false;

  /// True when the device exposes a usable vibrator at runtime.
  bool get isSupported => _port.isSupported;

  /// Current mute state (false = silent mode).
  bool get enabled => _enabled;

  /// Globally mutes haptics; persisted under `haptics_enabled`.
  set enabled(bool value) {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    if (!value) {
      stopScrubPulse();
      unawaited(_mutePort());
    }
    unawaited(_persistEnabled(value));
  }

  /// Plays a one-shot pattern; [repeat] stacks identical pulses
  /// (doubleTick = 2 — its catalog feel is two ticks, Doc 42 §3).
  Future<void> play(HapticPattern pattern, {int repeat = 1}) async {
    if (!_enabled || _cancelBlock) {
      return;
    }
    final VibrationProfile profile = _ProfileTable.values[pattern]!;
    final bool alwaysDeliver = pattern == HapticPattern.heavyThud;
    if (!alwaysDeliver && _coolingDown) {
      return; // coalescer: sub-30 ms repeat dropped
    }
    _armCooldown();

    if (!_port.isSupported) {
      _fallbackImpact(profile);
      return;
    }
    final (List<int> timings, List<int> amps) = _stack(profile, repeat);
    try {
      await _port.vibrate(timingsMs: timings, amplitudes: amps);
    } catch (error) {
      // VIBRATE permission missing / plugin failure — degrade silently.
      _logPluginFailureOnce(error);
      _fallbackImpact(profile);
    }
  }

  /// Starts the rhythmic scrubbing pulse; idempotent (repeated calls no-op).
  void startScrubPulse({
    Duration interval = const Duration(milliseconds: 120),
  }) {
    if (!_enabled || _scrubTimer != null) {
      return;
    }
    unawaited(play(HapticPattern.scrubPulse)); // immediate heartbeat
    _scrubTimer = Timer.periodic(interval, (_) => _emitScrubTick());
    _scrubWatchdogTimer = Timer.periodic(kScrubWatchdogInterval, (_) {
      if (!_enabled || _paused) {
        stopScrubPulse(); // orphaned loop (Doc 42 §7)
      }
    });
  }

  /// Stops the scrubbing pulse; safe to call when not running.
  void stopScrubPulse() {
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _scrubWatchdogTimer?.cancel();
    _scrubWatchdogTimer = null;
  }

  /// Cancels any active vibration and halts the scrub loop (app pause,
  /// incoming call, route change — Doc 42 §7).
  Future<void> cancelAll() async {
    stopScrubPulse();
    _cancelBlock = true;
    _cancelBlockTimer?.cancel();
    _cancelBlockTimer = Timer(
      const Duration(milliseconds: kHapticCancelBlockMs),
      () {
        _cancelBlock = false;
        _cancelBlockTimer = null;
      },
    );
    await _mutePort();
  }

  /// Releases timers and the lifecycle observer.
  void dispose() {
    stopScrubPulse();
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _cancelBlockTimer?.cancel();
    _cancelBlockTimer = null;
    final WidgetsBinding? binding = _lifecycleBinding;
    if (binding != null) {
      binding.removeObserver(this);
      _lifecycleBinding = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _paused = false;
      return;
    }
    _paused = true;
    stopScrubPulse();
    unawaited(cancelAll());
  }

  // ---------------------------------------------------------------------

  void _emitScrubTick() {
    // Routed through `play` so enabled/cancel rules stay uniform; the
    // default 120 ms interval never trips the 30 ms coalescer.
    unawaited(play(HapticPattern.scrubPulse));
  }

  /// Builds the stacked waveform for `repeat` copies of the unit
  /// (floored at the pattern's `minStacks`).
  (List<int>, List<int>) _stack(VibrationProfile profile, int repeat) {
    final int stacks = repeat > profile.minStacks
        ? repeat
        : profile.minStacks;
    if (stacks == 1) {
      return (profile.timingsMs, profile.amplitudes);
    }
    final List<int> timings = <int>[];
    final List<int> amps = <int>[];
    for (int i = 0; i < stacks; i++) {
      if (i > 0) {
        timings.add(profile.stackGapMs);
        amps.add(0);
      }
      timings.addAll(profile.timingsMs);
      amps.addAll(profile.amplitudes);
    }
    return (timings, amps);
  }

  void _armCooldown() {
    _coolingDown = true;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(
      const Duration(milliseconds: kHapticCoalesceMs),
      () {
        _coolingDown = false;
        _cooldownTimer = null;
      },
    );
  }

  /// Nearest `HapticFeedback.*` impact for devices without a vibrator,
  /// mapped from the profile's mean non-zero amplitude (Doc 42 §4.4 step 4).
  void _fallbackImpact(VibrationProfile profile) {
    int sum = 0;
    int count = 0;
    for (final int amplitude in profile.amplitudes) {
      if (amplitude > 0) {
        sum += amplitude;
        count++;
      }
    }
    final double mean = count == 0 ? 0 : sum / count;
    final Future<void> future;
    if (mean >= 150) {
      future = HapticFeedback.heavyImpact();
    } else if (mean >= 100) {
      future = HapticFeedback.mediumImpact();
    } else {
      future = HapticFeedback.lightImpact();
    }
    try {
      unawaited(future.catchError((Object _) {}));
    } catch (_) {
      // No bindings in headless unit tests — degrade to silence.
    }
  }

  Future<void> _mutePort() async {
    try {
      await _port.cancel();
    } catch (error) {
      _logPluginFailureOnce(error);
    }
  }

  void _logPluginFailureOnce(Object error) {
    if (_loggedPluginFailure) {
      return;
    }
    _loggedPluginFailure = true;
    debugPrint('HapticEngine: vibration plugin failed, degrading ($error)');
  }

  void _attachLifecycle() {
    try {
      final WidgetsBinding binding = WidgetsBinding.instance;
      binding.addObserver(this);
      _lifecycleBinding = binding;
    } catch (_) {
      // Headless unit tests without a binding — no lifecycle hooks needed.
    }
  }

  static Future<SharedPreferences?> _loadPreferences() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null; // platform channel unavailable (tests)
    }
  }

  void _readPersistedFlag(SharedPreferences? preferences) {
    final bool? stored = preferences?.getBool(kHapticsEnabledPrefKey);
    if (stored != null) {
      _enabled = stored;
    }
  }

  Future<void> _persistEnabled(bool value) async {
    try {
      final SharedPreferences? preferences = await _prefs;
      await preferences?.setBool(kHapticsEnabledPrefKey, value);
    } catch (_) {
      // Persistence is best-effort; in-memory state stays authoritative.
    }
  }
}

/// Riverpod provider exposing the process-wide singleton engine. Must be
/// overridden at the composition root (main wires it after SharedPreferences
/// init); debug builds throw a descriptive error when unwired, release
/// builds degrade to a silent no-op engine (Doc 42 §7).
final hapticEngineProvider = Provider<HapticEngine>((Ref ref) {
  if (kReleaseMode) {
    return HapticEngine.noOp();
  }
  throw StateError(
    'hapticEngineProvider is not wired — override it at the composition '
    'root with HapticEngine(preferences: prefs) (Doc 42 §7).',
  );
});
