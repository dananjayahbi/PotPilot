// Doc 43: foreground hardware Volume Up/Down hijack — short presses step the
// routed PC volume (absolute targets computed client-side per frozen Doc 03
// actions), long-presses switch to timeline seeking over UDP `0x04`. Pure
// Dart key interception (`HardwareKeyboard.addHandler`) — no MethodChannel,
// no manifest permissions (Doc 43 §4/§10).
//
// Design highlights (§4):
//  - State machine `idle → volumeStep →(hold ≥ 600 ms) seekActive`; the very
//    first keyDown applies one absolute volume target (zero-latency press),
//    OS key-repeats before the threshold are coalesced, each repeat after it
//    advances `repeatIndex` and fires another scrub tick.
//  - Gate filter: attached, lifecycle resumed, `settings.enabled`,
//    `callActive == false` (Doc 44), PC reachable (WS up / UDP armed /
//    paired per Doc 34 cache) — any failure returns false so the system
//    handles the key normally (pass-through).
//  - Routing: telemetry `potplayer_found == true` → `CMD_POTPLAYER
//    SET_VOLUME`; otherwise `CMD_SYSTEM SET_SYSTEM_VOLUME` on `sys_volume`
//    — no user setting (§5).
//  - WS down ⇒ sends dropped (never queued), HUD flips offline (§7); stale
//    telemetry (> 1 s) or duration 0 ⇒ seek suppressed while local minute
//    ticks keep ticking as feedback.
//
// Settings persist under the Doc 43-owned `hijack_*` keys (non-`pp.*`
// namespace, so `shared_preferences` directly — Doc 34's wrapper owns the
// `pp.*` namespace only).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/haptics/haptic_engine.dart';
import '../core/storage/connection_cache.dart';
import '../network/telemetry_provider.dart';
import '../network/udp_sender.dart';
import '../network/ws_client.dart';
import '../network/ws_message_codec.dart';
import 'call_autopause_hook.dart';

/// Default percent per short press (§10).
const int kHijackStepDefaultPct = 5;

/// Default long-press hold before seek mode engages (§10).
const int kHijackHoldDefaultMs = 600;

/// Default seconds per seek tick — matches the deck's ±30s keys (§10).
const int kHijackSeekDefaultSec = 30;

/// HUD badge lifetime after the last applied step (§4.2 step 4 / §8).
const Duration kHudBadgeDuration = Duration(milliseconds: 700);

/// Seek targets are only computable while telemetry is ≤ 1 s old (§5/§7).
const int kSeekMaxStaleMs = 1000;

/// Doc 43-owned `shared_preferences` keys (§10; Doc 34 owns `pp.*` only).
const String kHijackEnabledPrefKey = 'hijack_enabled';
const String kHijackStepPctPrefKey = 'hijack_step_pct';
const String kHijackHoldMsPrefKey = 'hijack_hold_ms';
const String kHijackSeekSecPrefKey = 'hijack_seek_sec';

/// Hijack lifecycle phase (mirrors the state machine in §4.1).
enum VolumeHijackPhase {
  /// No press in flight — keys pass through when the gate is closed.
  idle,

  /// Key held below the threshold; one absolute volume step applied.
  volumeStep,

  /// Hold crossed the threshold — each repeat fires a UDP scrub.
  seekActive,
}

int _clampInt(int value, int min, int max) =>
    value < min ? min : (value > max ? max : value);

/// Immutable persisted settings for the hijack (§3).
@immutable
class VolumeHijackSettings {
  const VolumeHijackSettings({
    this.enabled = true,
    this.stepPct = kHijackStepDefaultPct,
    this.holdThreshold = const Duration(milliseconds: kHijackHoldDefaultMs),
    this.seekStepSec = kHijackSeekDefaultSec,
  });

  /// Reads the Doc 43-owned keys, clamping out-of-range values to sane
  /// bounds (corrupt prefs never break the handler).
  factory VolumeHijackSettings.fromPreferences(SharedPreferences prefs) {
    return VolumeHijackSettings(
      enabled: prefs.getBool(kHijackEnabledPrefKey) ?? true,
      stepPct: _clampInt(
        prefs.getInt(kHijackStepPctPrefKey) ?? kHijackStepDefaultPct,
        1,
        100,
      ),
      holdThreshold: Duration(
        milliseconds: _clampInt(
          prefs.getInt(kHijackHoldMsPrefKey) ?? kHijackHoldDefaultMs,
          100,
          5000,
        ),
      ),
      seekStepSec: _clampInt(
        prefs.getInt(kHijackSeekSecPrefKey) ?? kHijackSeekDefaultSec,
        1,
        3600,
      ),
    );
  }

  /// Master switch for the gate filter (settings toggle, no restart needed).
  final bool enabled;

  /// % per short press (default 5).
  final int stepPct;

  /// Long-press threshold before seek mode (default 600 ms).
  final Duration holdThreshold;

  /// Seconds per seek tick (default 30).
  final int seekStepSec;

  @override
  bool operator ==(Object other) =>
      other is VolumeHijackSettings &&
      other.enabled == enabled &&
      other.stepPct == stepPct &&
      other.holdThreshold == holdThreshold &&
      other.seekStepSec == seekStepSec;

  @override
  int get hashCode =>
      Object.hash(enabled, stepPct, holdThreshold, seekStepSec);
}

/// Foreground interceptor for hardware volume keys (§3).
///
/// Lifecycle: [attach] registers the process-wide key handler (returns false
/// when already attached), [detach] unregisters it and resets the state
/// machine. The handler only consumes keys while the app is foregrounded,
/// the hijack is enabled, Doc 44 reports no active call, and a PC is
/// reachable — otherwise it returns false (stock system volume, §4.2 step 2).
class VolumeButtonHijack with WidgetsBindingObserver {
  VolumeButtonHijack({
    required WsClient ws,
    required UdpSender udp,
    required TelemetryState Function() telemetry,
    required HapticEngine haptics,
    bool Function()? callActive,
    bool Function()? isPaired,
    int Function()? nowSec,
    SharedPreferences? preferences,
  })  : _ws = ws,
        _udp = udp,
        _telemetry = telemetry,
        _haptics = haptics,
        _callActive = callActive ?? _neverInCall,
        _isPaired = isPaired ?? _cachePaired,
        _nowSec = nowSec ?? _systemNowSec {
    if (preferences != null) {
      _prefs = preferences;
      _settings = VolumeHijackSettings.fromPreferences(preferences);
    } else {
      unawaited(_loadSettings());
    }
  }

  static bool _neverInCall() => false;
  static int _systemNowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Doc 34 pairing probe: a paired host means "PC known" even before the
  /// socket reconnects (§4.2 step 2 "PC paired or seek data available").
  static bool _cachePaired() {
    final ConnectionCache cache = ConnectionCache.instance;
    if (!cache.isReady) {
      return false;
    }
    try {
      return cache.activeHost != null;
    } on StateError {
      return false;
    }
  }

  final WsClient _ws;
  final UdpSender _udp;
  final TelemetryState Function() _telemetry;
  final HapticEngine _haptics;

  /// Doc 44 `callActive` gate (injected so tests need no telephony).
  final bool Function() _callActive;
  final bool Function() _isPaired;
  final int Function() _nowSec;

  SharedPreferences? _prefs;
  VolumeHijackSettings _settings = const VolumeHijackSettings();
  bool _settingsTouched = false;

  bool _attached = false;
  bool _observerAdded = false;
  bool _resumed = true;

  VolumeHijackPhase _phase = VolumeHijackPhase.idle;
  LogicalKeyboardKey? _heldKey;
  int _direction = 1;
  int _repeatIndex = 0;

  /// Hold-repeat seek anchor (round 7). Captured on the first successful scrub
  /// of a hold and reused for every later repeat: re-reading the live position
  /// mid-hold mixed fresh telemetry with the repeat index and made targets
  /// skip backwards/forwards ("goes here and there").
  int? _seekAnchorSec;
  Timer? _holdTimer;
  Timer? _hudTimer;

  final ValueNotifier<int?> _hudValue = ValueNotifier<int?>(null);
  final ValueNotifier<bool> _hudOffline = ValueNotifier<bool>(false);

  /// Current phase, for HUD rendering (§3).
  VolumeHijackPhase get phase => _phase;

  /// Last applied step (0–100); `null` clears the badge / shows "—"
  /// while seeking without position data (§3, §7).
  ValueNotifier<int?> get hudValue => _hudValue;

  /// True when a step was attempted with the WS down — the HUD badge turns
  /// dim crimson "PC offline" instead (§7).
  ValueNotifier<bool> get hudOffline => _hudOffline;

  /// Current persisted settings (defaults until the async load lands).
  VolumeHijackSettings get settings => _settings;

  /// Runtime settings update (settings surface); persisted best-effort.
  set settings(VolumeHijackSettings next) {
    _settings = next;
    _settingsTouched = true;
    unawaited(_persistSettings());
  }

  /// Registers the global key handler + lifecycle observer; false when
  /// already attached (§3).
  bool attach() {
    if (_attached) {
      return false;
    }
    _attached = true;
    _resumed = _currentLifecycleResumed();
    HardwareKeyboard.instance.addHandler(_onKey);
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    } catch (_) {
      _observerAdded = false; // headless environments — gate stays `_resumed`
    }
    return true;
  }

  /// Unregisters the handler and resets the state machine (§3).
  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_observerAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAdded = false;
    }
    _resetMachine(clearHud: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumed = true;
      return;
    }
    // §4.2 step 6: backgrounding resets the machine; keys fall through.
    _resumed = false;
    _resetMachine(clearHud: true);
  }

  // -------------------------------------------------------------------------
  // Gate + key handler
  // -------------------------------------------------------------------------

  bool _wsConnected() => _ws.state == WsConnectionState.connected;

  bool _gateOpen() {
    if (!_attached || !_resumed || !_settings.enabled) {
      return false;
    }
    if (_callActive()) {
      return false; // OFFHOOK: keys must adjust the phone's call volume (§7)
    }
    return _wsConnected() || _udp.isReady || _isPaired();
  }

  bool _onKey(KeyEvent event) {
    if (!_attached) {
      return false;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.audioVolumeUp &&
        key != LogicalKeyboardKey.audioVolumeDown) {
      return false;
    }

    // Releases always close out a consumed press first — the gates may have
    // flipped mid-hold (call arrived, app backgrounded) and the machine must
    // still reset; a press that was never consumed falls through (§4.1).
    if (event is KeyUpEvent) {
      if (_phase == VolumeHijackPhase.idle || key != _heldKey) {
        return false;
      }
      _release();
      return true;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    if (!_gateOpen()) {
      return false; // pass-through: system owns the key (§4.2 step 2)
    }
    switch (_phase) {
      case VolumeHijackPhase.idle:
        _beginHold(key);
        return true;
      case VolumeHijackPhase.volumeStep:
        return true; // OS repeat before the threshold — coalesced (§7)
      case VolumeHijackPhase.seekActive:
        _repeatSeek();
        return true;
    }
  }

  // -------------------------------------------------------------------------
  // State machine
  // -------------------------------------------------------------------------

  void _beginHold(LogicalKeyboardKey key) {
    _direction = key == LogicalKeyboardKey.audioVolumeUp ? 1 : -1;
    _heldKey = key;
    _repeatIndex = 0;
    _seekAnchorSec = null;
    _phase = VolumeHijackPhase.volumeStep;
    _holdTimer?.cancel();
    _holdTimer = Timer(_settings.holdThreshold, _onHoldThreshold);
    _applyVolumeStep(); // zero-latency first press (§4.2 step 3)
  }

  void _onHoldThreshold() {
    _holdTimer = null;
    if (_phase != VolumeHijackPhase.volumeStep) {
      return;
    }
    if (!_gateOpen()) {
      // §4.1: gates closing mid-hold drop the machine without any traffic.
      _resetMachine(clearHud: false);
      return;
    }
    _phase = VolumeHijackPhase.seekActive;
    _hudValue.value = null; // "—" until the HUD renders live position (§7)
    _repeatIndex = 1;
    _fireScrub();
  }

  void _repeatSeek() {
    if (!_gateOpen()) {
      _resetMachine(clearHud: false);
      return;
    }
    _repeatIndex++;
    _fireScrub();
  }

  void _release() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _phase = VolumeHijackPhase.idle;
    _heldKey = null;
    _repeatIndex = 0;
    _seekAnchorSec = null;
    if (_hudValue.value != null) {
      _armHudHide(); // badge lives 700 ms after key release (§8)
    }
  }

  void _resetMachine({required bool clearHud}) {
    _holdTimer?.cancel();
    _holdTimer = null;
    _phase = VolumeHijackPhase.idle;
    _heldKey = null;
    _repeatIndex = 0;
    _seekAnchorSec = null;
    if (clearHud) {
      _hudTimer?.cancel();
      _hudTimer = null;
      _hudValue.value = null;
      _hudOffline.value = false;
    }
  }

  // -------------------------------------------------------------------------
  // Actions (§5 wire compliance)
  // -------------------------------------------------------------------------

  /// One absolute volume step: `base ± stepPct`, clamped 0–100, routed by
  /// telemetry `potplayer_found` (§4.2 step 7).
  void _applyVolumeStep() {
    final TelemetryState snapshot = _telemetry();
    final Object? found = snapshot.extras['potplayer_found'];
    final bool potRoute = found == true;

    int? base;
    if (potRoute) {
      base = snapshot.potPlayerVolume;
    } else {
      final Object? sys = snapshot.extras['sys_volume'];
      if (sys is int) {
        base = sys;
      }
    }
    if (base == null) {
      // Cold start, system route: no cached base to step from — swallow the
      // press with wall feedback, never guess a value onto the wire (§7).
      unawaited(_haptics.play(HapticPattern.microTick));
      return;
    }

    final int target =
        _clampInt(base + _direction * _settings.stepPct, 0, 100);
    if (target == base) {
      // Already at the bound: step swallowed, single "wall" tick, no traffic.
      _hudValue.value = base;
      _armHudHide();
      unawaited(_haptics.play(HapticPattern.microTick));
      return;
    }
    if (!_wsConnected()) {
      // Mid-hold disconnect: step dropped (stale volume is harmful), badge
      // turns crimson "PC offline" (§7).
      _hudOffline.value = true;
      return;
    }
    final String type = potRoute ? typeCmdPotplayer : typeCmdSystem;
    final String action = potRoute ? Action.setVolume : Action.setSystemVolume;
    unawaited(_ws.send(type, action, <String, dynamic>{'percent': target}));
    _hudOffline.value = false;
    _hudValue.value = target;
    _armHudHide();
    unawaited(_haptics.play(HapticPattern.volumeTick));
  }

  /// Fires one UDP `0x04` scrub for `anchor ± seekStep * repeatIndex`,
  /// clamped to `[0, duration]` (§4.2 step 5). The anchor is captured once
  /// per hold (round 7) — see [_seekAnchorSec]. Suppressed — but locally
  /// ticked — while WS is down, UDP is unconfigured, or position data is
  /// stale/absent (§5, §7).
  void _fireScrub() {
    final TelemetryState snapshot = _telemetry();
    final int ageMs = _nowSec() * 1000 - snapshot.timestamp * 1000;
    final bool fresh =
        snapshot.durationMs > 0 && ageMs >= 0 && ageMs <= kSeekMaxStaleMs;
    if (_wsConnected() && _udp.isReady && fresh) {
      final int positionSec = snapshot.positionMs ~/ 1000;
      final int durationSec = snapshot.durationMs ~/ 1000;
      final int anchor = _seekAnchorSec ?? positionSec;
      _seekAnchorSec = anchor; // hold start — telemetry must not re-base it
      final int raw =
          anchor + _direction * _settings.seekStepSec * _repeatIndex;
      final int target = raw < 0 ? 0 : (raw > durationSec ? durationSec : raw);
      _hudOffline.value = false;
      _udp.sendScrub(target);
    } else {
      if (!_wsConnected()) {
        _hudOffline.value = true;
      }
      _hudValue.value = null; // "—" for position (§7)
    }
    // Local confirmation even when the packet was suppressed (§7).
    unawaited(_haptics.play(HapticPattern.minuteTick));
  }

  void _armHudHide() {
    _hudTimer?.cancel();
    _hudTimer = Timer(kHudBadgeDuration, () {
      _hudTimer = null;
      _hudValue.value = null;
    });
  }

  // -------------------------------------------------------------------------
  // Settings persistence (Doc 43-owned keys)
  // -------------------------------------------------------------------------

  Future<void> _loadSettings() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      if (!_settingsTouched) {
        _settings = VolumeHijackSettings.fromPreferences(prefs);
      }
    } catch (_) {
      // Platform channel unavailable (tests): defaults stay in effect.
    }
  }

  Future<void> _persistSettings() async {
    try {
      final SharedPreferences prefs =
          _prefs ??= await SharedPreferences.getInstance();
      await prefs.setBool(kHijackEnabledPrefKey, _settings.enabled);
      await prefs.setInt(kHijackStepPctPrefKey, _settings.stepPct);
      await prefs.setInt(
        kHijackHoldMsPrefKey,
        _settings.holdThreshold.inMilliseconds,
      );
      await prefs.setInt(kHijackSeekSecPrefKey, _settings.seekStepSec);
    } catch (_) {
      // Best-effort: in-memory settings stay authoritative (Doc 34 pattern).
    }
  }

  bool _currentLifecycleResumed() {
    try {
      final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
      return state == null || state == AppLifecycleState.resumed;
    } catch (_) {
      return true;
    }
  }
}

/// Riverpod provider for the process-wide hijack instance. The app root
/// (Session 3 shell) calls [VolumeButtonHijack.attach] once after pairing;
/// Doc 44's `callActive` feeds the pass-through gate (§6).
final Provider<VolumeButtonHijack> volumeHijackProvider =
    Provider<VolumeButtonHijack>((Ref ref) {
  HapticEngine haptics;
  try {
    haptics = ref.read(hapticEngineProvider);
  } catch (_) {
    // Doc 42 §7: unwired composition root — degrade to a silent engine
    // instead of breaking the provider graph.
    haptics = HapticEngine.noOp();
  }
  final VolumeButtonHijack hijack = VolumeButtonHijack(
    ws: WsClient.instance,
    udp: UdpSender.instance,
    telemetry: () => ref.read(telemetryProvider),
    haptics: haptics,
    callActive: () => ref.read(callAutopauseHookProvider).callActive,
  );
  ref.onDispose(hijack.detach);
  return hijack;
});
