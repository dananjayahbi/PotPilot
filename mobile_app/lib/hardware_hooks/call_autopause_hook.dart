// Doc 44: incoming-call auto-pause hook — observes Android telephony phase
// (`RINGING → OFFHOOK → IDLE` via `phone_state`) and dispatches Doc 03
// `CMD_POTPLAYER/PAUSE` when a call arrives while media is playing, with a
// guarded optional auto-`PLAY` on hangup (only when THIS hook paused and
// every §4.2 step-5 gate still passes). WS-only: this file emits no UDP
// traffic ever (§5).
//
// Seam notes:
//  - `phoneStates` is an injectable `Stream<CallPhase>` (§3) — production
//    wires `PhoneState.stream` through [callPhaseFromStatus] in the provider.
//  - `requestPermission` is an injectable `READ_PHONE_STATE` requester.
//    phone_state 3.0.1 exposes NO permission API (verified against the
//    installed package, §10); the frozen Doc 05 pubspec blocks the
//    `permission_handler` amendment and this doc owns no platform glue, so
//    the default requester probes the `potpilot/phone_permission` channel
//    and falls back to "granted" when no bridge is registered (manifest
//    install-time state is then assumed; denial injected through the seam
//    flips `permissionGranted` and keeps the hook silent — §4.2 step 1).
//
// Settings persist under the Doc 44-owned non-`pp.*` keys (Doc 34's wrapper
// owns the `pp.*` namespace only).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phone_state/phone_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/haptics/haptic_engine.dart';
import '../network/telemetry_provider.dart';
import '../network/ws_client.dart';
import '../network/ws_message_codec.dart';

/// Doc 44-owned `shared_preferences` keys (§10; defaults are both `true`).
const String kCallAutopauseEnabledPrefKey = 'call_autopause_enabled';
const String kCallAutoResumePrefKey = 'call_auto_resume';

/// Best-effort native bridge name for the runtime `READ_PHONE_STATE` dialog
/// (§10 fallback branch — registered by a future native bridge; without it
/// the default requester degrades to optimistic grant).
const String kPhonePermissionChannel = 'potpilot/phone_permission';

/// Mirrors the Android telephony states surfaced by `phone_state` (§3).
enum CallPhase {
  /// No call — media unaffected.
  idle,

  /// Incoming ring (Android `CALL_INCOMING`).
  ringing,

  /// Call live: answered incoming or outgoing (Android `CALL_STARTED` /
  /// `CALL_OUTGOING`).
  offhook,
}

/// Maps a raw `phone_state` status onto the Doc 43/44 phase vocabulary
/// (§4.2 step 2). Exhaustive: every plugin status resolves to a phase.
CallPhase callPhaseFromStatus(PhoneStateStatus status) {
  switch (status) {
    case PhoneStateStatus.NOTHING:
      return CallPhase.idle;
    case PhoneStateStatus.CALL_INCOMING:
      return CallPhase.ringing;
    case PhoneStateStatus.CALL_STARTED:
    case PhoneStateStatus.CALL_OUTGOING:
      return CallPhase.offhook;
    case PhoneStateStatus.CALL_ENDED:
      return CallPhase.idle;
  }
}

/// Immutable snapshot of the hook's decision state (HUD/settings, §3).
@immutable
class CallAutopauseState {
  const CallAutopauseState({
    this.phase = CallPhase.idle,
    this.permissionGranted = true,
    this.pausedByHook = false,
    this.pausedFileTitle,
  });

  /// Current telephony phase.
  final CallPhase phase;

  /// `false` after a denied `READ_PHONE_STATE` request — surfaces the
  /// persistent amber "Call auto-pause needs Phone permission" notice (§7).
  final bool permissionGranted;

  /// True while the hook itself holds playback paused for the live call.
  final bool pausedByHook;

  /// `file_title` captured at pause time — the auto-resume gate (§4.2 step 5).
  final String? pausedFileTitle;
}

/// Telephony observer that pauses/resumes PotPlayer across incoming calls
/// (§3). Subscribes only after [start] resolves a granted permission;
/// [callActive] gates Doc 43's volume-key pass-through.
class CallAutopauseHook {
  CallAutopauseHook({
    required WsClient ws,
    required TelemetryState Function() telemetry,
    required Stream<CallPhase> phoneStates,
    Future<bool> Function()? requestPermission,
    HapticEngine? haptics,
    SharedPreferences? preferences,
  })  : _ws = ws,
        _telemetry = telemetry,
        _phoneStates = phoneStates,
        _requestPermission = requestPermission ?? _defaultPermissionRequest,
        _haptics = haptics {
    if (preferences != null) {
      _prefs = preferences;
      _enabled = preferences.getBool(kCallAutopauseEnabledPrefKey) ?? true;
      _autoResume =
          preferences.getBool(kCallAutoResumePrefKey) ?? true;
    } else {
      unawaited(_loadSettings());
    }
  }

  static Future<bool> _defaultPermissionRequest() async {
    try {
      final bool? granted = await const MethodChannel(kPhonePermissionChannel)
          .invokeMethod<bool>('request');
      if (granted != null) {
        return granted;
      }
    } on MissingPluginException {
      // No native bridge registered (see file header §10 note): assume the
      // manifest grant so the hook works out of the box; the injectable
      // seam reports real denial once a bridge/permission_handler lands.
      return true;
    } on PlatformException {
      return false; // bridge answered with an error — treat as denial (§7)
    }
    return true;
  }

  final WsClient _ws;
  final TelemetryState Function() _telemetry;
  final Stream<CallPhase> _phoneStates;
  final Future<bool> Function() _requestPermission;
  final HapticEngine? _haptics;

  SharedPreferences? _prefs;
  bool _enabled = true;
  bool _autoResume = true;

  bool _started = false;
  StreamSubscription<CallPhase>? _subscription;
  CallPhase _phase = CallPhase.idle;
  bool _pausedByHook = false;
  String? _pausedFileTitle;

  final ValueNotifier<CallAutopauseState> _state =
      ValueNotifier<CallAutopauseState>(const CallAutopauseState());

  /// True while RINGING or OFFHOOK — gates Doc 43's key pass-through (§3).
  bool get callActive => _phase != CallPhase.idle;

  /// Live state for the settings banner / permission notice (§3).
  ValueNotifier<CallAutopauseState> get state => _state;

  /// Master switch (persisted under `call_autopause_enabled`).
  bool get enabled => _enabled;

  set enabled(bool value) {
    if (_enabled == value) {
      return;
    }
    _enabled = value;
    unawaited(_persistSettings());
    if (value) {
      unawaited(start()); // one gentle re-ask on re-enable (§7)
    } else {
      stop();
    }
  }

  /// Resume-after-hangup preference (persisted under `call_auto_resume`,
  /// default true — safe by construction, §10).
  bool get autoResumeOnHangup => _autoResume;

  set autoResumeOnHangup(bool value) {
    if (_autoResume == value) {
      return;
    }
    _autoResume = value;
    unawaited(_persistSettings());
  }

  /// Requests permission and subscribes to the phone-state stream (§3).
  /// Idempotent; a denied request leaves the hook silent with
  /// `permissionGranted == false` (§4.2 step 1) — no retry loop.
  Future<void> start() async {
    if (_started || !_enabled) {
      return;
    }
    final bool granted = await _requestPermission();
    if (!granted) {
      _emit(
        CallAutopauseState(
          phase: _phase,
          permissionGranted: false,
          pausedByHook: _pausedByHook,
          pausedFileTitle: _pausedFileTitle,
        ),
      );
      return;
    }
    if (_started || !_enabled) {
      return; // raced with stop()/disable during the await
    }
    _started = true;
    _subscription = _phoneStates.listen(_onPhase);
    _emit(
      CallAutopauseState(
        phase: _phase,
        permissionGranted: true,
        pausedByHook: _pausedByHook,
        pausedFileTitle: _pausedFileTitle,
      ),
    );
  }

  /// Unsubscribes and resets state (app dispose / manual disable, §3);
  /// `callActive` returns false afterwards.
  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
    _pausedByHook = false;
    _pausedFileTitle = null;
    if (_phase != CallPhase.idle) {
      _phase = CallPhase.idle;
    }
    _emit(
      CallAutopauseState(
        phase: CallPhase.idle,
        permissionGranted: _state.value.permissionGranted,
        pausedByHook: false,
        pausedFileTitle: null,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Call-state machine (§4.1)
  // -------------------------------------------------------------------------

  bool _wsConnected() => _ws.state == WsConnectionState.connected;

  void _onPhase(CallPhase next) {
    if (next == _phase) {
      return; // duplicate-event filter (§4.2 step 2)
    }
    final CallPhase previous = _phase;
    _phase = next;
    if (next == CallPhase.ringing ||
        (next == CallPhase.offhook && previous == CallPhase.idle)) {
      // Incoming ring, or outgoing call placed while the app is open (§10).
      _pauseForCall();
    } else if (next == CallPhase.idle) {
      _resumeIfGated();
    }
    _emit(
      CallAutopauseState(
        phase: _phase,
        permissionGranted: _state.value.permissionGranted,
        pausedByHook: _pausedByHook,
        pausedFileTitle: _pausedFileTitle,
      ),
    );
  }

  /// `RINGING`/`OFFHOOK` entry: pause only when media is actually playing
  /// and the PC is reachable — no queueing of stale pauses (§4.2 step 3, §7).
  void _pauseForCall() {
    final TelemetryState snapshot = _telemetry();
    if (!snapshot.isPlaying) {
      return; // already paused/stopped — no PAUSE on the wire (§8)
    }
    if (!_wsConnected()) {
      return; // PC offline: skip; pausedByHook stays false → no resume (§7)
    }
    unawaited(
      _ws.send(typeCmdPotplayer, Action.pause, const <String, dynamic>{}),
    );
    _pausedByHook = true;
    _pausedFileTitle = snapshot.fileTitle;
    final HapticEngine? haptics = _haptics;
    if (haptics != null) {
      unawaited(haptics.play(HapticPattern.heavyThud)); // local confirm (§6)
    }
  }

  /// `IDLE` entry: auto-`PLAY` iff the hook paused, resume is enabled,
  /// telemetry still shows paused, and the same file is loaded (§4.2 step 5).
  /// Flags clear first — resume is attempted at most once per call session.
  void _resumeIfGated() {
    final bool hookPaused = _pausedByHook;
    final String? title = _pausedFileTitle;
    _pausedByHook = false;
    _pausedFileTitle = null;
    if (!hookPaused || !_autoResume) {
      return;
    }
    final TelemetryState snapshot = _telemetry();
    if (snapshot.isPlaying) {
      return; // user resumed manually mid-call — never double-play (§7)
    }
    if (title == null || snapshot.fileTitle != title) {
      return; // file switched/stopped during the call (§7)
    }
    if (!_wsConnected()) {
      return; // PC offline at hangup — gate fails once, never retried (§7)
    }
    unawaited(
      _ws.send(typeCmdPotplayer, Action.play, const <String, dynamic>{}),
    );
  }

  void _emit(CallAutopauseState next) {
    _state.value = next;
  }

  // -------------------------------------------------------------------------
  // Settings persistence (Doc 44-owned keys)
  // -------------------------------------------------------------------------

  Future<void> _loadSettings() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _enabled = prefs.getBool(kCallAutopauseEnabledPrefKey) ?? true;
      _autoResume = prefs.getBool(kCallAutoResumePrefKey) ?? true;
      if (!_enabled && _started) {
        stop(); // persisted disable raced an in-flight start (§7)
      }
    } catch (_) {
      // Platform channel unavailable (tests): defaults stay in effect.
    }
  }

  Future<void> _persistSettings() async {
    try {
      final SharedPreferences prefs =
          _prefs ??= await SharedPreferences.getInstance();
      await prefs.setBool(kCallAutopauseEnabledPrefKey, _enabled);
      await prefs.setBool(kCallAutoResumePrefKey, _autoResume);
    } catch (_) {
      // Best-effort: in-memory state stays authoritative (Doc 34 pattern).
    }
  }
}

/// Riverpod provider for the process-wide hook. Production wires the
/// `phone_state` event stream; the Session 3 shell calls [start] once at
/// startup and owns the settings toggles (§6).
final Provider<CallAutopauseHook> callAutopauseHookProvider =
    Provider<CallAutopauseHook>((Ref ref) {
  HapticEngine? haptics;
  try {
    haptics = ref.read(hapticEngineProvider);
  } catch (_) {
    haptics = null; // optional confirmation haptic (§2) — hook works silent
  }
  final CallAutopauseHook hook = CallAutopauseHook(
    ws: WsClient.instance,
    telemetry: () => ref.read(telemetryProvider),
    phoneStates:
        PhoneState.stream.map((PhoneState event) => callPhaseFromStatus(event.status)),
    haptics: haptics,
  );
  ref.onDispose(hook.stop);
  return hook;
});
