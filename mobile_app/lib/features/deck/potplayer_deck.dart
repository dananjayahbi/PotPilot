// Doc 36 (deck redesign): PotPlayer remote deck — the app's primary
// control tab, laid out for one-hand reach in a dark room.
//
// Hierarchy (top → bottom): Doc 38's ScrubSpeedHud timeline header
// (badges + time readout); the deck header row (file caption + volume
// popup button + Settings gear); the compact secondary rows (fixed
// ±30 s jumps + frame stepping, speed keys + badge, fullscreen/aspect/
// tracks); then the transport cluster — big rewind / Play-Pause /
// forward — anchored in the lower half, the segmented seek-step selector
// it is driven by, and — at the very bottom — the speed-sensing ruler
// seek slider (round 5, 2026-10-17) that replaced the tiny top track.
// Every key dispatches guaranteed-delivery Doc 03 `CMD_POTPLAYER`
// envelopes over Doc 31's `WsClient`; optimistic play feedback reconciles
// against 250 ms Doc 33 telemetry. Seeks are parameterised by the chosen
// step but the wire stays frozen: `seek_delta {delta_ms: …}`.
//
// Test-visible contracts live on: [deckKeyFor] keys on every
// [DeckAction] key (all rendered as [DeckButton] with `.enabled`),
// `deck_dim` (staleness/gate opacity), `deck_speed_badge` (Text, `--`
// when unknown), `deck_closed_caption` (PotPlayer not found),
// `deck_volume_button` / `deck_settings_button` (header), and the
// `ruler_*` keys on the bottom ruler.

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import '../hud/scrub_speed_hud.dart';
import '../tracks/audio_sub_modal.dart';
import 'deck_actions.dart';
import 'deck_controller.dart';
import 'deck_header_row.dart';
import 'deck_secondary_rows.dart';
import 'deck_step_selector.dart';
import 'deck_transport_row.dart';
import 'ruler/ruler_seek_slider.dart';

export 'deck_actions.dart';
export 'deck_button.dart';
export 'deck_controller.dart';
export 'deck_header_row.dart';
export 'deck_secondary_rows.dart';
export 'deck_step_selector.dart';
export 'deck_transport_row.dart';
export 'deck_volume_control.dart';
export 'ruler/ruler_seek_slider.dart';
export 'volume_popup.dart';

/// Viewport heights below this never bottom-anchor — they stack from the
/// top inside a scroll view. 560 covers the worst-case content (reconnect
/// strip + closed caption + full control cluster ≈ 540) with margin, so
/// an anchored Column can never overflow (small phones scroll instead).
// Minimum height for the bottom-anchored deck layout. Below this the deck
// stacks from the top in a scroll view. Round 6 restored the top general
// seek bar (ScrubTrack): measured natural content heights are 631 (normal)
// .. 666 (reconnecting + closed, worst case), so anchoring only engages
// above 700 — anything lower would overflow instead of scrolling.
const double kDeckAnchoredMinHeight = 700;

/// Root deck widget: consumes Doc 33 telemetry, hosts the Doc 38 HUD
/// header plus the transport/selector/volume cluster and the secondary
/// rows with §5 gating and staleness dimming (§3).
class PotPlayerDeck extends ConsumerWidget {
  const PotPlayerDeck({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    final PotPlayerDeckController controller =
        ref.watch(deckControllerProvider);
    final int stepSeconds = ref.watch(deckSeekStepProvider);
    controller.reconcile(telemetry); // telemetry wins on glyph mismatch

    final bool wsUp = controller.isConnected;
    final bool stale = telemetryAgeMs(telemetry) > kStaleAfter;
    final bool running = telemetry.extras['potplayer_found'] != false;
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

    void pressed(DeckAction action) => unawaited(
          controller.dispatch(action, telemetry, seekStepSeconds: stepSeconds),
        );

    final bool playing = controller.optimisticPlaying ?? telemetry.isPlaying;
    final String speedLabel = (speedKnown && !stale)
        ? '${formatSpeed(telemetry.speed)}x'
        : '--';
    const EdgeInsets horizontal = EdgeInsets.symmetric(horizontal: 16);

    final Column column = Column(
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
        DeckHeaderRow(
          fileTitle: telemetry.fileTitle ?? '',
          volumeEnabled: wsUp && running,
        ),
        const Spacer(), // anchors the cluster in the lower half
        Opacity(
          key: const Key('deck_dim'),
          opacity: dim ? 0.5 : 1.0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DeckJumpRow(onTap: pressed, enabled: enabledFor),
              const SizedBox(height: 8),
              DeckSpeedRow(
                speedLabel: speedLabel,
                onTap: pressed,
                enabled: enabledFor,
              ),
              const SizedBox(height: 8),
              DeckUtilityRow(
                onTap: pressed,
                enabled: enabledFor,
                tracksEnabled: wsUp && running,
                onOpenTracks: () =>
                    unawaited(showAudioSubtitleModal(context)),
              ),
              const SizedBox(height: 16), // more space above the transport
              DeckTransportRow(
                stepSeconds: stepSeconds,
                playing: playing,
                enabledFor: enabledFor,
                onPressed: pressed,
              ),
              const SizedBox(height: 10),
              const DeckStepSelector(),
              const SizedBox(height: 10),
              // Bottom of the deck: the speed-sensing ruler scrubber
              // (round 5) — the volume row moved into the header popup.
              RulerSeekSlider(enabled: wsUp && running),
            ],
          ),
        ),
      ],
    );

    // Tall screens bottom-anchor the cluster (one-hand reach); short ones
    // stack from the top inside a scroll view — never an overflow.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool anchored = constraints.maxHeight.isFinite &&
            constraints.maxHeight >= kDeckAnchoredMinHeight;
        if (anchored) {
          return column;
        }
        final List<Widget> stacked = <Widget>[
          for (final Widget child in column.children)
            if (child is Spacer) const SizedBox(height: 8) else child,
        ];
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 0,
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: stacked),
          ),
        );
      },
    );
  }
}
