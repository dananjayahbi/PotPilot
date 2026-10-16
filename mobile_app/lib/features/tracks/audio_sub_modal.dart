import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';

/// Optimistic wrap point for the 1-based local track counters (§4.3): after
/// this many cycles the visual `Track n` wraps back to 1.
const int kMaxOptimisticTracks = 8;

/// One frozen `SUB_SYNC_ADJUST` nudge step — Doc 03 §5.3 allows only
/// multiples of ±500 ms.
const int kSyncStepMs = 500;

/// UI/wire clamp for the subtitle-sync offset (Doc 03 §5.3: ±10000 ms).
const int kSyncMaxMs = 10000;

/// Row action: what a tap on one of the four controls dispatches.
enum TrackAction { cycleAudio, cycleSubs, toggleSubs, syncMinus, syncPlus }

/// Formats [offsetMs] as the sheet readout: `0.0s`, `+0.5s`, `−1.5s`,
/// `−10.0s`. Always one decimal (the offset is a whole number of ±500 ms
/// steps, so no float artifacts), true minus U+2212 for optical alignment,
/// explicit `+` only on positive offsets.
String formatSyncOffset(int offsetMs) {
  final String body = '${(offsetMs.abs() / 1000).toStringAsFixed(1)}s';
  if (offsetMs < 0) {
    return '\u2212$body';
  }
  if (offsetMs > 0) {
    return '+$body';
  }
  return '0.0s';
}

/// Cycles/counter/toggle state local to the current file (§4.3).
///
/// Doc 03 §5.6 telemetry carries *no* track-identity fields, so these
/// optimistic counters are the designed source of truth for the sheet UI.
@immutable
class TrackModalState {
  const TrackModalState({
    required this.audioIndex,
    required this.subIndex,
    required this.subsOn,
    required this.syncOffsetMs,
    required this.fileTitle,
  });

  /// 1-based local audio-stream counter (wraps at [kMaxOptimisticTracks]).
  final int audioIndex;

  /// 1-based local subtitle-track counter (wraps at [kMaxOptimisticTracks]).
  final int subIndex;

  /// Optimistic desired subtitle visibility.
  final bool subsOn;

  /// Accumulated subtitle-sync offset in ms (±500 steps, clamped ±10000).
  final int syncOffsetMs;

  /// Telemetry `file_title` this state belongs to — the §4.4 reset boundary.
  final String? fileTitle;

  /// Returns the next state after [action] (pure, unit-testable).
  TrackModalState apply(TrackAction action) {
    switch (action) {
      case TrackAction.cycleAudio:
        return TrackModalState(
          audioIndex: audioIndex >= kMaxOptimisticTracks ? 1 : audioIndex + 1,
          subIndex: subIndex,
          subsOn: subsOn,
          syncOffsetMs: syncOffsetMs,
          fileTitle: fileTitle,
        );
      case TrackAction.cycleSubs:
        return TrackModalState(
          audioIndex: audioIndex,
          subIndex: subIndex >= kMaxOptimisticTracks ? 1 : subIndex + 1,
          subsOn: subsOn,
          syncOffsetMs: syncOffsetMs,
          fileTitle: fileTitle,
        );
      case TrackAction.toggleSubs:
        return TrackModalState(
          audioIndex: audioIndex,
          subIndex: subIndex,
          subsOn: !subsOn,
          syncOffsetMs: syncOffsetMs,
          fileTitle: fileTitle,
        );
      case TrackAction.syncMinus:
        return TrackModalState(
          audioIndex: audioIndex,
          subIndex: subIndex,
          subsOn: subsOn,
          syncOffsetMs: _clampSync(syncOffsetMs - kSyncStepMs),
          fileTitle: fileTitle,
        );
      case TrackAction.syncPlus:
        return TrackModalState(
          audioIndex: audioIndex,
          subIndex: subIndex,
          subsOn: subsOn,
          syncOffsetMs: _clampSync(syncOffsetMs + kSyncStepMs),
          fileTitle: fileTitle,
        );
    }
  }

  /// §4.4 reset boundary: defaults when [fileTitle] differs from the title
  /// this state was built for (incl. null↔non-null transitions); an
  /// identical title returns `this` — staleness alone never resets.
  TrackModalState syncFile(String? fileTitle) {
    if (fileTitle == this.fileTitle) {
      return this;
    }
    return TrackModalState(
      audioIndex: 1,
      subIndex: 1,
      subsOn: false,
      syncOffsetMs: 0,
      fileTitle: fileTitle,
    );
  }

  /// True when the corresponding nudge button must disable (no silent
  /// clamped dispatch — the boundary haptic already fired on arrival).
  bool get atLowerSyncBound => syncOffsetMs <= -kSyncMaxMs;

  bool get atUpperSyncBound => syncOffsetMs >= kSyncMaxMs;

  static int _clampSync(int value) {
    if (value < -kSyncMaxMs) {
      return -kSyncMaxMs;
    }
    if (value > kSyncMaxMs) {
      return kSyncMaxMs;
    }
    return value;
  }
}

/// Row action → frozen Doc 03 §5.3 action name.
String _wireAction(TrackAction action) {
  switch (action) {
    case TrackAction.cycleAudio:
      return Action.cycleAudio;
    case TrackAction.cycleSubs:
      return Action.cycleSubs;
    case TrackAction.toggleSubs:
      return Action.setSubs;
    case TrackAction.syncMinus:
    case TrackAction.syncPlus:
      return Action.subSyncAdjust;
  }
}

/// Payload for one dispatch, derived from the *post-apply* state so
/// `SET_SUBS` always carries the optimistic desired `enabled`.
Map<String, dynamic> _payloadFor(TrackAction action, TrackModalState next) {
  switch (action) {
    case TrackAction.cycleAudio:
    case TrackAction.cycleSubs:
      return <String, dynamic>{};
    case TrackAction.toggleSubs:
      return <String, dynamic>{'enabled': next.subsOn};
    case TrackAction.syncMinus:
      return <String, dynamic>{'delta_ms': -kSyncStepMs};
    case TrackAction.syncPlus:
      return <String, dynamic>{'delta_ms': kSyncStepMs};
  }
}

/// The bottom-sheet presenter + dispatch gate.
class AudioSubModalController {
  AudioSubModalController({
    WsClient? client,
    Future<void> Function(HapticPattern pattern)? playHaptic,
  }) : _client = client ?? WsClient.instance,
       _playHaptic = playHaptic ?? _noHaptics;

  final WsClient _client;
  final Future<void> Function(HapticPattern pattern) _playHaptic;

  /// Doc 31 seam; tests inject a fake client here.
  WsClient get client => _client;

  /// Doc 31 connected gate (§4.2 step 1).
  bool get connected => _client.state == WsConnectionState.connected;

  /// Applies [action] to local state, dispatches the §5 envelope via Doc 31
  /// `WsClient.send("CMD_POTPLAYER", action, payload)`, fires the Doc 42
  /// haptic (heavyThud exactly at a sync zero-crossing, else microTick).
  /// Fire-and-forget: unmounted callers are safe (no callback dependency).
  Future<void> dispatch(TrackAction action, TrackModalState current) async {
    if (!connected) {
      return;
    }
    // A bound-clamped nudge never leaves the client (buttons disable too).
    if (action == TrackAction.syncMinus && current.atLowerSyncBound) {
      return;
    }
    if (action == TrackAction.syncPlus && current.atUpperSyncBound) {
      return;
    }
    final TrackModalState next = current.apply(action);
    await _client.send(
      typeCmdPotplayer,
      _wireAction(action),
      _payloadFor(action, next),
    );
    final bool isNudge =
        action == TrackAction.syncMinus || action == TrackAction.syncPlus;
    final HapticPattern pattern = isNudge && next.syncOffsetMs == 0
        ? HapticPattern.heavyThud
        : HapticPattern.microTick;
    await _playHaptic(pattern);
  }

  static Future<void> _noHaptics(HapticPattern pattern) async {}
}

/// Module controller seam: widget tests override this with a real
/// controller wired to a fake Doc 31 client.
final Provider<AudioSubModalController> audioSubControllerProvider =
    Provider<AudioSubModalController>((ref) {
      return AudioSubModalController(
        playHaptic: (HapticPattern pattern) async {
          try {
            await ref.read(hapticEngineProvider).play(pattern);
          } on Object {
            // Doc 42 engine is wired in main (Session 3); haptics are
            // best-effort until then.
          }
        },
      );
    });

/// Presents the modal bottom sheet above the calling surface.
Future<void> showAudioSubtitleModal(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.background,
    elevation: 0,
    isScrollControlled: true,
    builder: (BuildContext context) => const AudioSubModal(),
  );
}

/// Root sheet widget: 4 control rows over a TelemetryNotifier watch.
class AudioSubModal extends ConsumerStatefulWidget {
  const AudioSubModal({super.key});

  @override
  ConsumerState<AudioSubModal> createState() => _AudioSubModalState();
}

class _AudioSubModalState extends ConsumerState<AudioSubModal> {
  late AudioSubModalController _controller;
  late TrackModalState _state;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(audioSubControllerProvider);
    _state = TrackModalState(
      audioIndex: 1,
      subIndex: 1,
      subsOn: false,
      syncOffsetMs: 0,
      fileTitle: ref.read(telemetryProvider).fileTitle,
    );
  }

  void _onAction(TrackAction action) {
    final TrackModalState previous = _state;
    // Optimistic: the UI flips in this frame; the envelope follows below.
    setState(() {
      _state = previous.apply(action);
    });
    _controller.dispatch(action, previous);
  }

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    // Reset boundary (§4.4): only a fileTitle *change* resets local state —
    // staleness and unrelated frame churn never touch it.
    ref.listen<TelemetryState>(
      telemetryProvider,
      (TelemetryState? prev, TelemetryState next) {
        if (_state.fileTitle != next.fileTitle && mounted) {
          setState(() {
            _state = _state.syncFile(next.fileTitle);
          });
        }
      },
    );

    final int ageMs =
        DateTime.now().millisecondsSinceEpoch - telemetry.timestamp * 1000;
    final bool stale = !telemetry.isConnected || ageMs > 1000;
    final String caption = telemetry.fileTitle ?? 'No file';
    // §7: no media loaded ⇒ readout forced to 0.0s.
    final String readout = _state.fileTitle == null
        ? '0.0s'
        : formatSyncOffset(_state.syncOffsetMs);
    final bool syncNeutral = _state.syncOffsetMs == 0;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: StreamBuilder<WsConnectionState>(
          stream: _controller.client.stateChanges,
          initialData: _controller.client.state,
          builder: (
            BuildContext context,
            AsyncSnapshot<WsConnectionState> snap,
          ) {
            final bool connected = snap.data == WsConnectionState.connected;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Opacity(
                  opacity: stale ? 0.5 : 1,
                  child: Text(
                    caption,
                    key: const Key('track_caption'),
                    style: AppTypography.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!connected) _reconnectStrip(),
                const SizedBox(height: 8),
                Opacity(
                  opacity: connected ? 1 : 0.45,
                  child: AbsorbPointer(
                    absorbing: !connected,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _cycleRow(
                          label: 'Audio stream',
                          value: 'Track ${_state.audioIndex}',
                          valueKey: const Key('track_audio_value'),
                          buttonKey: const Key('track_cycle_audio'),
                          enabled: connected,
                        ),
                        const Divider(),
                        _cycleRow(
                          label: 'Subtitle track',
                          value: _state.subsOn
                              ? 'Track ${_state.subIndex}'
                              : 'Off',
                          valueKey: const Key('track_sub_value'),
                          buttonKey: const Key('track_cycle_subs'),
                          enabled: connected,
                        ),
                        const Divider(),
                        SizedBox(
                          height: 56,
                          child: Row(
                            children: <Widget>[
                              _rowLabel('Subtitles'),
                              const Spacer(),
                              Switch(
                                key: const Key('track_subs_switch'),
                                value: _state.subsOn,
                                onChanged: connected
                                    ? (bool value) =>
                                          _onAction(TrackAction.toggleSubs)
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        const Divider(),
                        SizedBox(
                          height: 56,
                          child: Row(
                            children: <Widget>[
                              _rowLabel('Subtitle sync'),
                              const Spacer(),
                              TextButton(
                                key: const Key('track_sync_minus'),
                                onPressed: connected &&
                                        !_state.atLowerSyncBound
                                    ? () => _onAction(TrackAction.syncMinus)
                                    : null,
                                child: const Text('\u22120.5s'),
                              ),
                              SizedBox(
                                width: 72,
                                child: Text(
                                  readout,
                                  key: const Key('track_sync_readout'),
                                  textAlign: TextAlign.center,
                                  style: AppTypography.body.copyWith(
                                    fontFamilyFallback: const <String>[
                                      'Roboto Mono',
                                      'monospace',
                                    ],
                                    color: syncNeutral
                                        ? AppColors.textPrimary
                                        : AppColors.amber,
                                  ),
                                ),
                              ),
                              TextButton(
                                key: const Key('track_sync_plus'),
                                onPressed: connected &&
                                        !_state.atUpperSyncBound
                                    ? () => _onAction(TrackAction.syncPlus)
                                    : null,
                                child: const Text('+0.5s'),
                              ),
                            ],
                          ),
                        ),
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

  Widget _rowLabel(String text) => Text(
    text,
    style: AppTypography.bodySmall.copyWith(color: AppColors.textSecondary),
  );

  Widget _cycleRow({
    required String label,
    required String value,
    required Key valueKey,
    required Key buttonKey,
    required bool enabled,
  }) {
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          _rowLabel(label),
          const Spacer(),
          Text(value, key: valueKey, style: AppTypography.body),
          IconButton(
            key: buttonKey,
            onPressed: enabled
                ? () => _onAction(
                      label == 'Audio stream'
                          ? TrackAction.cycleAudio
                          : TrackAction.cycleSubs,
                    )
                : null,
            icon: const Icon(Icons.sync, size: 20, color: AppColors.amber),
          ),
        ],
      ),
    );
  }

  Widget _reconnectStrip() {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Column(
        key: Key('track_reconnect_strip'),
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
