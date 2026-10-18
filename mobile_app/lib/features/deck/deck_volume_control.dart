// Doc 36 (round 5, 2026-10-17): the deck's volume affordance is now a
// compact header button (the full slider lives in the popup from
// volume_popup.dart).  Replaces the old bottom `DeckVolumeControl` row,
// which vacated the deck's bottom slot for the ruler seek slider.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import 'volume_popup.dart';

/// Speaker icon showing the live level; opens [showVolumePopup].
/// Disabled (dimmed) while WS is down or PotPlayer is closed — same
/// gate the old bottom row used.
class DeckVolumeButton extends ConsumerWidget {
  const DeckVolumeButton({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    final int volume = telemetry.potPlayerVolume;
    final IconData levelIcon = volume <= 0
        ? Icons.volume_off
        : (volume < 50 ? Icons.volume_down : Icons.volume_up);
    final Color color =
        enabled ? AppColors.textSecondary : AppColors.textTertiary;

    return IconButton(
      tooltip: enabled ? 'Volume, $volume%' : 'Volume unavailable',
      icon: Icon(levelIcon, size: 20),
      color: color,
      onPressed: enabled ? () => showVolumePopup(context) : null,
    );
  }
}
