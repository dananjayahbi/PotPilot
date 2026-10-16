// Doc 36 (deck redesign): the compact secondary rows — fixed ±30 s jumps
// + frame stepping (media-gated), the speed keys with their read-only
// badge, and fullscreen/aspect with the tracks-modal entry (audio cycle,
// subtitle cycle/visibility, sub sync — Doc 37 capabilities stay one tap
// away from the deck).

import 'package:flutter/material.dart';

import '../../core/theme/oled_theme.dart';
import 'deck_actions.dart';
import 'deck_button.dart';

/// Fixed ±30 s quick-jumps + frame stepping (all media-gated).
class DeckJumpRow extends StatelessWidget {
  const DeckJumpRow({super.key, required this.onTap, required this.enabled});

  final ValueChanged<DeckAction> onTap;
  final bool Function(DeckAction action) enabled;

  static IconData? _iconFor(DeckKeySpec spec) {
    switch (spec.action) {
      case DeckAction.seekBack30:
        return Icons.replay_30;
      case DeckAction.seekFwd30:
        return Icons.forward_30;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: DeckGrid(
        specs: deckJumpRow,
        rowHeight: 48,
        onTap: onTap,
        enabled: enabled,
        iconFor: _iconFor,
      ),
    );
  }
}

/// Speed keys (gated by known base + staleness + bounds) beside the
/// read-only `deck_speed_badge` (`--` until speed is known and fresh).
class DeckSpeedRow extends StatelessWidget {
  const DeckSpeedRow({
    super.key,
    required this.speedLabel,
    required this.onTap,
    required this.enabled,
  });

  final String speedLabel;
  final ValueChanged<DeckAction> onTap;
  final bool Function(DeckAction action) enabled;

  Widget _key(DeckKeySpec spec) {
    return DeckButton(
      key: deckKeyFor(spec.action),
      spec: spec,
      enabled: enabled(spec.action),
      onPressed: () => onTap(spec.action),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 48,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _key(deckSpeedRow[0])),
            const SizedBox(width: 8),
            Expanded(child: _key(deckSpeedRow[1])),
            const SizedBox(width: 8),
            Expanded(child: _key(deckSpeedRow[2])),
            const SizedBox(width: 8),
            SizedBox(
              width: 96,
              child: Center(
                child: Text(
                  speedLabel,
                  key: const Key('deck_speed_badge'),
                  maxLines: 1,
                  style: AppTypography.timecode.copyWith(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fullscreen + aspect keys with the tracks-modal entry (audio/subtitle/
/// sub-sync). Not a [DeckAction] — it opens Doc 37's bottom sheet.
class DeckUtilityRow extends StatelessWidget {
  const DeckUtilityRow({
    super.key,
    required this.onTap,
    required this.enabled,
    required this.tracksEnabled,
    required this.onOpenTracks,
  });

  final ValueChanged<DeckAction> onTap;
  final bool Function(DeckAction action) enabled;
  final bool tracksEnabled;
  final VoidCallback onOpenTracks;

  Widget _key(DeckKeySpec spec, IconData icon) {
    return DeckButton(
      key: deckKeyFor(spec.action),
      spec: spec,
      text: spec.label,
      icon: icon,
      iconSize: 18,
      fontSize: 13,
      enabled: enabled(spec.action),
      onPressed: () => onTap(spec.action),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 48,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _key(deckUtilityRow[0], Icons.fullscreen)),
            const SizedBox(width: 8),
            Expanded(child: _key(deckUtilityRow[1], Icons.aspect_ratio)),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: DeckButtonChrome(
                enabled: tracksEnabled,
                onPressed: onOpenTracks,
                semanticLabel: 'Audio and subtitle tracks',
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        Icons.tune,
                        size: 18,
                        color: tracksEnabled
                            ? AppColors.textPrimary
                            : AppColors.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'TRACKS',
                        maxLines: 1,
                        style: AppTypography.label.copyWith(
                          fontSize: 13,
                          height: 1.1,
                          color: tracksEnabled
                              ? AppColors.textPrimary
                              : AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
