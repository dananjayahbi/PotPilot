// Doc 36: PotPlayer remote deck grid — the app's primary control tab.
//
// Every key is data-driven from the const [deckRows] table (Play/Pause,
// ±5s/±30s, speed −0.1/1.0/+0.1, Next/Prev Frame, Fullscreen, Aspect) and
// dispatches guaranteed-delivery Doc 03 `CMD_POTPLAYER` envelopes over
// Doc 31's `WsClient` with instant optimistic feedback reconciled by
// 250 ms Doc 33 telemetry. Discrete seeks are WS-only (UDP `0x04` SCRUB_SEEK
// stays reserved for continuous drags in Doc 38); `SET_SPEED` carries an
// absolute `multiplier` the client computes on the 0.1 grid (0.2x-4.0x).
// The timeline/OSD header is Doc 38's `ScrubSpeedHud` (call-site embed only).

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics/haptic_engine.dart';
import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../../network/ws_client.dart';
import '../../network/ws_message_codec.dart';
import '../hud/scrub_speed_hud.dart';

/// Per-action tap debounce (last-tap-wins — a rapid double-tap on
/// Play/Pause collapses to one effective toggle, §4.2 / §7).
const int kDeckDebounceMs = 80;

/// PotPlayer speed bounds (Doc 03 wire range; Doc 09 re-clamps too).
const double kSpeedMin = 0.2;
const double kSpeedMax = 4.0;

/// Every dispatchable deck key; wire mapping in §5 (frozen Doc 03 §5.3).
enum DeckAction {
  playPause,
  seekBack5,
  seekFwd5,
  seekBack30,
  seekFwd30,
  speedDown,
  speedReset,
  speedUp,
  framePrev,
  frameNext,
  fullscreen,
  aspectCycle,
}

/// Doc 03 action name per deck key (WS `type` is always `CMD_POTPLAYER`).
const Map<DeckAction, String> deckActionNames = <DeckAction, String>{
  DeckAction.playPause: Action.playPause,
  DeckAction.seekBack5: Action.seekDelta,
  DeckAction.seekFwd5: Action.seekDelta,
  DeckAction.seekBack30: Action.seekDelta,
  DeckAction.seekFwd30: Action.seekDelta,
  DeckAction.speedDown: Action.setSpeed,
  DeckAction.speedReset: Action.setSpeed,
  DeckAction.speedUp: Action.setSpeed,
  DeckAction.framePrev: Action.frameStep,
  DeckAction.frameNext: Action.frameStep,
  DeckAction.fullscreen: Action.toggleFullscreen,
  DeckAction.aspectCycle: Action.cycleAspectRatio,
};

/// Doc 42 haptic pattern per action (§4 mapping; fired only on a dispatch
/// that actually sends — disabled keys are silent rejects).
HapticPattern hapticPatternFor(DeckAction action) {
  switch (action) {
    case DeckAction.playPause:
      return HapticPattern.heavyThud;
    case DeckAction.speedReset:
      return HapticPattern.doubleTick;
    default:
      return HapticPattern.microTick;
  }
}

/// Immutable declarative spec for one grid cell (§3): glyph/label, action,
/// column span (of 4), and whether the key needs loaded media.
class DeckKeySpec {
  const DeckKeySpec({
    required this.action,
    required this.label,
    required this.span,
    this.requiresMedia = false,
  });

  final DeckAction action;
  final String label;
  final int span;
  final bool requiresMedia;
}

/// Fixed 4-row key table (§4.1): transport, seek, speed, utility. Rendering
/// is pure data → widget; no hand-placed buttons.
const List<List<DeckKeySpec>> deckRows = <List<DeckKeySpec>>[
  <DeckKeySpec>[
    DeckKeySpec(action: DeckAction.playPause, label: '\u25b6', span: 2),
  ],
  <DeckKeySpec>[
    DeckKeySpec(
      action: DeckAction.seekBack30,
      label: '\u221230s',
      span: 1,
      requiresMedia: true,
    ),
    DeckKeySpec(
      action: DeckAction.seekBack5,
      label: '\u22125s',
      span: 1,
      requiresMedia: true,
    ),
    DeckKeySpec(
      action: DeckAction.seekFwd5,
      label: '+5s',
      span: 1,
      requiresMedia: true,
    ),
    DeckKeySpec(
      action: DeckAction.seekFwd30,
      label: '+30s',
      span: 1,
      requiresMedia: true,
    ),
  ],
  <DeckKeySpec>[
    DeckKeySpec(action: DeckAction.speedDown, label: '\u22120.1x', span: 1),
    DeckKeySpec(action: DeckAction.speedReset, label: '1.0x', span: 1),
    DeckKeySpec(action: DeckAction.speedUp, label: '+0.1x', span: 1),
  ],
  <DeckKeySpec>[
    DeckKeySpec(
      action: DeckAction.framePrev,
      label: 'PREV \u23ee',
      span: 1,
      requiresMedia: true,
    ),
    DeckKeySpec(
      action: DeckAction.frameNext,
      label: 'NEXT \u23ed',
      span: 1,
      requiresMedia: true,
    ),
    DeckKeySpec(action: DeckAction.fullscreen, label: '\u26f6 FULL', span: 1),
    DeckKeySpec(action: DeckAction.aspectCycle, label: 'ASPECT', span: 1),
  ],
];

/// Stable widget-test handle for one key's [DeckButton].
Key deckKeyFor(DeckAction action) => Key('deck_key_${action.name}');

/// Payload builder + dispatch gate for one deck action (WS only, no UDP).
/// Exposed via [deckControllerProvider]; tests inject a fake `WsClient`.
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
  Future<void> dispatch(DeckAction action, TelemetryState state) async {
    final int now = _nowMs();
    final int? previousTap = _lastTapAtMs[action];
    if (previousTap != null && now - previousTap < kDeckDebounceMs) {
      return; // 80 ms debounce, last-tap-wins (§4.2 / §7)
    }
    if (!isConnected) {
      return; // offline: no dispatch attempts, no queueing (§7)
    }
    final Map<String, dynamic>? payload = _payloadFor(action, state);
    if (payload == null) {
      return; // gated: unknown speed base / bound-adjacent no-op
    }
    _lastTapAtMs[action] = now;
    await _playHaptic(hapticPatternFor(action));
    await _client.send(typeCmdPotplayer, deckActionNames[action]!, payload);
    if (action == DeckAction.playPause) {
      _optimisticPlaying = !(_optimisticPlaying ?? state.isPlaying);
      _optimisticBaseline = state;
      notifyListeners(); // glyph flips in the same frame (§4.4)
    }
  }

  Map<String, dynamic>? _payloadFor(DeckAction action, TelemetryState state) {
    switch (action) {
      case DeckAction.playPause:
      case DeckAction.fullscreen:
      case DeckAction.aspectCycle:
        return <String, dynamic>{};
      case DeckAction.seekBack5:
        return <String, dynamic>{'delta_ms': -5000};
      case DeckAction.seekFwd5:
        return <String, dynamic>{'delta_ms': 5000};
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

/// Responsive N-column grid materialising a fixed [DeckKeySpec] row (§3):
/// four logical columns with 8 dp gutters; `span` widens a cell.
class DeckGrid extends StatelessWidget {
  const DeckGrid({
    super.key,
    required this.specs,
    required this.onTap,
    this.enabled,
    this.labelFor,
    this.rowHeight = 56,
  });

  final List<DeckKeySpec> specs;
  final ValueChanged<DeckAction> onTap;
  final bool Function(DeckAction action)? enabled;
  final String Function(DeckKeySpec spec)? labelFor;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    const double gutter = 8;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double colWidth = (constraints.maxWidth - 3 * gutter) / 4;
        final List<Widget> children = <Widget>[];
        for (int i = 0; i < specs.length; i++) {
          final DeckKeySpec spec = specs[i];
          final double width =
              colWidth * spec.span + gutter * (spec.span - 1);
          children.add(
            Padding(
              padding: EdgeInsets.only(
                right: i == specs.length - 1 ? 0 : gutter,
              ),
              child: SizedBox(
                width: width,
                height: rowHeight,
                child: DeckButton(
                  key: deckKeyFor(spec.action),
                  spec: spec,
                  text: labelFor?.call(spec),
                  enabled: enabled?.call(spec.action) ?? true,
                  onPressed: () => onTap(spec.action),
                ),
              ),
            ),
          );
        }
        return Row(children: children);
      },
    );
  }
}

/// Single tactile key: OLED rest/pressed states, disabled styling, silent
/// reject when disabled (Doc 42 owns haptics — feedback fires from the
/// controller only on an actual dispatch).
class DeckButton extends StatelessWidget {
  const DeckButton({
    super.key,
    required this.spec,
    required this.enabled,
    required this.onPressed,
    this.text,
  });

  final DeckKeySpec spec;
  final bool enabled;
  final VoidCallback onPressed;

  /// Overrides [DeckKeySpec.label] (e.g. the optimistic ▶/⏸ glyph).
  final String? text;

  @override
  Widget build(BuildContext context) {
    final String label = text ?? spec.label;
    final bool large = spec.span >= 2;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: enabled
              ? AppColors.outline
              : AppColors.outline.withValues(alpha: 0.4),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        enableFeedback: false,
        highlightColor: AppColors.surfaceHigh,
        child: Center(
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.label.copyWith(
              fontSize: large ? 30 : 15,
              height: 1.1,
              color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Root deck widget: consumes Doc 33 telemetry, hosts the Doc 38 HUD header
/// plus the [DeckGrid] rows with §5 gating and staleness dimming (§3).
class PotPlayerDeck extends ConsumerWidget {
  const PotPlayerDeck({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    final PotPlayerDeckController controller =
        ref.watch(deckControllerProvider);
    controller.reconcile(telemetry); // telemetry wins on glyph mismatch

    final bool wsUp = controller.isConnected;
    final bool stale = telemetryAgeMs(telemetry) > kStaleAfter;
    final bool running = telemetry.extras['potplayer_running'] != false;
    final bool mediaKnown = telemetry.durationMs > 0;
    final bool speedKnown = telemetry.speed >= kSpeedMin;
    final bool dim = !wsUp || stale || !running;

    bool enabledFor(DeckAction action) {
      if (!wsUp || !running) {
        return false;
      }
      switch (action) {
        case DeckAction.seekBack5:
        case DeckAction.seekFwd5:
        case DeckAction.seekBack30:
        case DeckAction.seekFwd30:
        case DeckAction.framePrev:
        case DeckAction.frameNext:
          return mediaKnown; // requiresMedia keys (§4.5)
        case DeckAction.speedDown:
          return speedKnown &&
              !stale &&
              controller.stepSpeed(telemetry.speed, -0.1) != telemetry.speed;
        case DeckAction.speedUp:
          return speedKnown &&
              !stale &&
              controller.stepSpeed(telemetry.speed, 0.1) != telemetry.speed;
        case DeckAction.speedReset:
          return speedKnown &&
              !stale &&
              PotPlayerDeckController.roundTenth(telemetry.speed) != 1.0;
        default:
          return true;
      }
    }

    String labelFor(DeckKeySpec spec) {
      if (spec.action == DeckAction.playPause) {
        final bool playing =
            controller.optimisticPlaying ?? telemetry.isPlaying;
        return playing ? '\u23f8' : '\u25b6';
      }
      return spec.label;
    }

    void pressed(DeckAction action) => unawaited(controller.dispatch(action, telemetry));

    final String speedLabel = (speedKnown && !stale)
        ? '${formatSpeed(telemetry.speed)}x'
        : '--';
    const EdgeInsets horizontal = EdgeInsets.symmetric(horizontal: 16);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!wsUp)
          Container(
            key: const Key('deck_reconnect_strip'),
            height: 18,
            alignment: Alignment.center,
            color: AppColors.crimsonDim,
            child: Text(
              'RECONNECTING\u2026',
              style: AppTypography.label.copyWith(
                fontSize: 10,
                color: AppColors.onAccent,
              ),
            ),
          ),
        if (!running)
          Padding(
            padding: horizontal,
            child: Text(
              'PotPlayer closed',
              key: const Key('deck_closed_caption'),
              textAlign: TextAlign.center,
              style: AppTypography.label.copyWith(color: AppColors.crimson),
            ),
          ),
        const ScrubSpeedHud(), // Doc 38 header — owns its own h margins
        Padding(
          padding: horizontal,
          child: SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                telemetry.fileTitle ?? '',
                key: const Key('deck_caption'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.label
                    .copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ),
        Opacity(
          key: const Key('deck_dim'),
          opacity: dim ? 0.5 : 1.0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Transport row: Play/Pause (span 2) + read-only speed badge.
              Padding(
                padding: horizontal,
                child: SizedBox(
                  height: 88,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(
                        flex: 2,
                        child: DeckButton(
                          key: deckKeyFor(DeckAction.playPause),
                          spec: deckRows[0].single,
                          text: labelFor(deckRows[0].single),
                          enabled: enabledFor(DeckAction.playPause),
                          onPressed: () => pressed(DeckAction.playPause),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: Center(
                          child: Text(
                            speedLabel,
                            key: const Key('deck_speed_badge'),
                            style: AppTypography.timecode.copyWith(
                              fontSize: 22,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: horizontal,
                child: DeckGrid(
                  specs: deckRows[1],
                  rowHeight: 64,
                  onTap: pressed,
                  enabled: enabledFor,
                  labelFor: labelFor,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: horizontal,
                child: DeckGrid(
                  specs: deckRows[2],
                  onTap: pressed,
                  enabled: enabledFor,
                  labelFor: labelFor,
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: horizontal,
                child: DeckGrid(
                  specs: deckRows[3],
                  onTap: pressed,
                  enabled: enabledFor,
                  labelFor: labelFor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
