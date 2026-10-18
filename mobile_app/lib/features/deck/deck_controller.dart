// Doc 36 (deck redesign): payload builder + dispatch gate for deck keys
// (WS only, no UDP). Exposed via [deckControllerProvider]; tests inject a
// fake `WsClient`. Seek keys carry the caller's step as `delta_ms`
// (wire contract frozen: `CMD_POTPLAYER seek_delta {delta_ms: …}`).

import 'dart:async';

import 'package:flutter/material.dart' hide Action;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../network/telemetry_provider.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';
import 'deck_actions.dart';

/// Controller provider: production wires the Doc 42 engine; tests override
/// with a fake-`WsClient` instance (same pattern as Docs 19/39).
/// `ChangeNotifierProvider` disposes the notifier itself — no `onDispose`.
final ChangeNotifierProvider<PotPlayerDeckController> deckControllerProvider =
    ChangeNotifierProvider<PotPlayerDeckController>((Ref ref) {
  return PotPlayerDeckController(
    playHaptic: (HapticPattern pattern) =>
        ref.read(hapticEngineProvider).play(pattern),
  );
});

class PotPlayerDeckController extends ChangeNotifier {
  PotPlayerDeckController({
    WsClient? client,
    Future<void> Function(HapticPattern pattern)? playHaptic,
    int Function()? nowMs,
  })  : _client = client ?? WsClient.instance,
        _playHaptic = playHaptic ?? _silentHaptic,
        _nowMs = nowMs ?? _systemNow;

  static Future<void> _silentHaptic(HapticPattern pattern) async {}

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  final WsClient _client;
  final Future<void> Function(HapticPattern) _playHaptic;
  final int Function() _nowMs;
  final Map<DeckAction, int> _lastTapAtMs = <DeckAction, int>{};

  bool? _optimisticPlaying;
  TelemetryState? _optimisticBaseline;
  int? _lastVolumeSent;

  /// Doc 31 state: false disables the whole grid (no client-side queueing —
  /// avoids stale play/pause after reconnect, §7).
  bool get isConnected => _client.state == WsConnectionState.connected;

  /// Optimistic play glyph; `null` once telemetry has spoken (§4.4).
  bool? get optimisticPlaying => _optimisticPlaying;

  /// Drops the optimistic play flag as soon as a telemetry frame differs
  /// from the snapshot captured at dispatch — telemetry always wins.
  void reconcile(TelemetryState state) {
    if (_optimisticPlaying != null && state != _optimisticBaseline) {
      _optimisticPlaying = null;
      _optimisticBaseline = null;
    }
  }

  /// Integer-tenth rounding: keeps speed math on the 0.1 grid so
  /// `0.30000000000000004` artifacts can never reach the wire (§4.3).
  static double roundTenth(double value) =>
      ((value * 10).round() / 10).toDouble();

  /// Returns current ± [delta] rounded to 0.1 and clamped to PotPlayer's
  /// 0.2x-4.0x range (`SET_SPEED` always carries an absolute `multiplier`).
  double stepSpeed(double current, double delta) {
    final double stepped = roundTenth(current + delta);
    if (stepped < kSpeedMin) {
      return kSpeedMin;
    }
    if (stepped > kSpeedMax) {
      return kSpeedMax;
    }
    return stepped;
  }

  /// Maps [action] to the Doc 03 frozen registry envelope and sends it via
  /// Doc 31 `WsClient.send("CMD_POTPLAYER", action, payload)`; [state]
  /// supplies the speed base and the optimistic play flip (§3).
  /// [seekStepSeconds] parameterises the big side buttons'
  /// [DeckAction.seekBack5]/[DeckAction.seekFwd5] (5 s default keeps the
  /// frozen payloads when called without it); the ±30 s keys stay fixed.
  Future<void> dispatch(
    DeckAction action,
    TelemetryState state, {
    int seekStepSeconds = kDefaultSeekStep,
  }) async {
    final int now = _nowMs();
    final int? previousTap = _lastTapAtMs[action];
    if (previousTap != null && now - previousTap < kDeckDebounceMs) {
      return; // 80 ms debounce, last-tap-wins (§4.2 / §7)
    }
    if (!isConnected) {
      return; // offline: no dispatch attempts, no queueing (§7)
    }
    final Map<String, dynamic>? payload =
        _payloadFor(action, state, seekStepSeconds);
    if (payload == null) {
      return; // gated: unknown speed base / bound-adjacent no-op
    }
    _lastTapAtMs[action] = now;
    await _playHaptic(hapticPatternFor(action));
    await _client.send(typeCmdPotplayer, deckActionNames[action]!, payload);
    if (action == DeckAction.playPause) {
      _optimisticPlaying = !(_optimisticPlaying ?? state.isPlaying);
      _optimisticBaseline = state;
      notifyListeners();
    }
  }

  /// Commits the deck volume slider: `CMD_POTPLAYER SET_VOLUME` with a
  /// clamped integer percent (Doc 03 §5.3; bed-mode §4.5 dedupe — the last
  /// committed value never re-sends). WS-down / PotPlayer-closed are
  /// silent rejects (§7); stale telemetry does NOT gate volume (the mixer
  /// base comes from the cached frame).
  Future<void> setVolume(int percent, TelemetryState state) async {
    final int clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    if (!isConnected) {
      return;
    }
    if (state.extras['potplayer_found'] == false) {
      return;
    }
    if (_lastVolumeSent == clamped) {
      return; // no clamped no-op packets
    }
    _lastVolumeSent = clamped;
    await _playHaptic(HapticPattern.volumeTick);
    await _client.send(
      typeCmdPotplayer,
      Action.setVolume,
      <String, dynamic>{'percent': clamped},
    );
  }

  Map<String, dynamic>? _payloadFor(
    DeckAction action,
    TelemetryState state,
    int seekStepSeconds,
  ) {
    switch (action) {
      case DeckAction.playPause:
      case DeckAction.fullscreen:
      case DeckAction.aspectCycle:
        return <String, dynamic>{};
      case DeckAction.seekBack5:
        return <String, dynamic>{'delta_ms': -1000 * seekStepSeconds};
      case DeckAction.seekFwd5:
        return <String, dynamic>{'delta_ms': 1000 * seekStepSeconds};
      case DeckAction.seekBack30:
        return <String, dynamic>{'delta_ms': -30000};
      case DeckAction.seekFwd30:
        return <String, dynamic>{'delta_ms': 30000};
      case DeckAction.framePrev:
        return <String, dynamic>{'direction': 'BACKWARD'};
      case DeckAction.frameNext:
        return <String, dynamic>{'direction': 'FORWARD'};
      case DeckAction.speedDown:
        return _speedPayload(state, -0.1);
      case DeckAction.speedUp:
        return _speedPayload(state, 0.1);
      case DeckAction.speedReset:
        if (state.speed < kSpeedMin) {
          return null; // speed base never received (§5 gating)
        }
        if (roundTenth(state.speed) == 1.0) {
          return null; // already at 1.0x — bound-adjacent no-op
        }
        return <String, dynamic>{'multiplier': 1.0};
    }
  }

  Map<String, dynamic>? _speedPayload(TelemetryState state, double delta) {
    if (state.speed < kSpeedMin) {
      return null; // speed base never received (§5 gating)
    }
    final double next = stepSpeed(state.speed, delta);
    if (next == state.speed) {
      return null; // already at 0.2x / 4.0x bound (§7)
    }
    return <String, dynamic>{'multiplier': next};
  }
}
