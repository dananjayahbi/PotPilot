// Doc 36 (deck redesign): the one-hand transport cluster — prominent
// rewind (left), largest Play/Pause (center, crimson primary), prominent
// fast-forward (right). Side labels echo the active seek step, so the
// selector's choice is visible exactly where it applies.

import 'package:flutter/material.dart';

import 'deck_actions.dart';
import 'deck_button.dart';

/// Transport row: [DeckAction.seekBack5] (step-driven) — Play/Pause —
/// [DeckAction.seekFwd5] (step-driven). 96 dp tall; the side keys sit at
/// ≥48 dp with stacked icon + step badge, the center key is largest.
class DeckTransportRow extends StatelessWidget {
  const DeckTransportRow({
    super.key,
    required this.stepSeconds,
    required this.playing,
    required this.enabledFor,
    required this.onPressed,
  });

  final int stepSeconds;
  final bool playing;
  final bool Function(DeckAction action) enabledFor;
  final ValueChanged<DeckAction> onPressed;

  @override
  Widget build(BuildContext context) {
    final String stepLabel = '${stepSeconds}s';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 96,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: DeckButton(
                key: deckKeyFor(DeckAction.seekBack5),
                spec: kSeekBackSpec,
                text: stepLabel,
                icon: Icons.fast_rewind,
                iconSize: 26,
                fontSize: 16,
                stacked: true,
                accent: true,
                enabled: enabledFor(DeckAction.seekBack5),
                semanticLabel: 'Rewind $stepSeconds seconds',
                onPressed: () => onPressed(DeckAction.seekBack5),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 112,
              child: DeckButton(
                key: deckKeyFor(DeckAction.playPause),
                spec: kPlaySpec,
                icon: playing ? Icons.pause : Icons.play_arrow,
                iconSize: 44,
                emphasis: true,
                enabled: enabledFor(DeckAction.playPause),
                semanticLabel: playing ? 'Pause' : 'Play',
                onPressed: () => onPressed(DeckAction.playPause),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DeckButton(
                key: deckKeyFor(DeckAction.seekFwd5),
                spec: kSeekFwdSpec,
                text: stepLabel,
                icon: Icons.fast_forward,
                iconSize: 26,
                fontSize: 16,
                stacked: true,
                accent: true,
                enabled: enabledFor(DeckAction.seekFwd5),
                semanticLabel: 'Forward $stepSeconds seconds',
                onPressed: () => onPressed(DeckAction.seekFwd5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
