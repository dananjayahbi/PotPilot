// Doc 36 (deck redesign): the registry behind every deck key —
// [DeckAction] values, their frozen Doc 03 wire names, per-action haptics,
// the shared seek-step options, and the immutable [DeckKeySpec] cells the
// grids render. Payload building/dispatch lives in deck_controller.dart.

import 'package:flutter/material.dart' hide Action;

import '../../core/haptics/haptic_engine.dart';
import '../../network/ws_message_codec.dart';

/// Per-action tap debounce (last-tap-wins — a rapid double-tap on
/// Play/Pause collapses to one effective toggle, §4.2 / §7).
const int kDeckDebounceMs = 80;

/// PotPlayer speed bounds (Doc 03 wire range; Doc 09 re-clamps too).
const double kSpeedMin = 0.2;
const double kSpeedMax = 4.0;

/// Seek-step choices offered by the deck's segmented selector; the chosen
/// step drives both big transport buttons (§6). The wire payload stays
/// `seek_delta {delta_ms: ±step * 1000}` — no protocol change.
const List<int> kSeekStepOptions = <int>[5, 10, 20, 30];

/// Initial seek step; also the fallback when [PotPlayerDeckController]
/// dispatches without an explicit step (keeps the frozen ±5 s payloads).
const int kDefaultSeekStep = 5;

/// Every dispatchable deck key; wire mapping in deck_controller (frozen
/// Doc 03 §5.3).
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

/// Immutable declarative spec for one grid cell (§3): label, action,
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

/// Stable widget-test handle for one key's [DeckButton].
Key deckKeyFor(DeckAction action) => Key('deck_key_${action.name}');

// ---------------------------------------------------------------------------
// Key tables. The transport cluster (rewind / play / forward) is bespoke —
// deck_transport_row.dart — everything else renders from these const rows.
// ---------------------------------------------------------------------------

/// Big transport cell specs (side labels echo the active seek step).
const DeckKeySpec kSeekBackSpec = DeckKeySpec(
  action: DeckAction.seekBack5,
  label: '5s',
  span: 1,
  requiresMedia: true,
);
const DeckKeySpec kSeekFwdSpec = DeckKeySpec(
  action: DeckAction.seekFwd5,
  label: '5s',
  span: 1,
  requiresMedia: true,
);
const DeckKeySpec kPlaySpec = DeckKeySpec(
  action: DeckAction.playPause,
  label: 'PLAY',
  span: 2,
);

/// Fixed ±30 s quick-jumps + frame stepping (all media-gated). The big
/// side buttons follow the step selector; these stay fixed jumps.
const List<DeckKeySpec> deckJumpRow = <DeckKeySpec>[
  DeckKeySpec(
    action: DeckAction.seekBack30,
    label: '\u221230s',
    span: 1,
    requiresMedia: true,
  ),
  DeckKeySpec(
    action: DeckAction.seekFwd30,
    label: '+30s',
    span: 1,
    requiresMedia: true,
  ),
  DeckKeySpec(
    action: DeckAction.framePrev,
    label: 'PREV FRAME',
    span: 1,
    requiresMedia: true,
  ),
  DeckKeySpec(
    action: DeckAction.frameNext,
    label: 'NEXT FRAME',
    span: 1,
    requiresMedia: true,
  ),
];

/// Speed step keys; the fourth cell of the row hosts the read-only
/// `deck_speed_badge` (deck_secondary_rows.dart).
const List<DeckKeySpec> deckSpeedRow = <DeckKeySpec>[
  DeckKeySpec(action: DeckAction.speedDown, label: '\u22120.1x', span: 1),
  DeckKeySpec(action: DeckAction.speedReset, label: '1.0x', span: 1),
  DeckKeySpec(action: DeckAction.speedUp, label: '+0.1x', span: 1),
];

/// Fullscreen + aspect keys; the right half of the row hosts the tracks
/// modal entry (audio/subtitle/sub-sync capabilities, Doc 37).
const List<DeckKeySpec> deckUtilityRow = <DeckKeySpec>[
  DeckKeySpec(action: DeckAction.fullscreen, label: 'FULL', span: 1),
  DeckKeySpec(action: DeckAction.aspectCycle, label: 'ASPECT', span: 1),
];
