// Doc 36 (deck redesign): in-deck volume control — icon + amber slider
// (Doc 29 theme already styles scrub/volume sliders) + current-percent
// affordance. Commits `CMD_POTPLAYER SET_VOLUME {percent}` on change end;
// the drag preview persists until a telemetry frame speaks (telemetry
// always wins, §4.4).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import 'deck_controller.dart';

/// Volume row: level icon — slider (0-100, integer steps) — `NN%` value.
/// Disabled (mirroring the deck's gate) when WS is down or PotPlayer is
/// closed; staleness does not gate volume (cached mixer base, Doc 41 §5).
class DeckVolumeControl extends ConsumerStatefulWidget {
  const DeckVolumeControl({super.key, required this.enabled});

  final bool enabled;

  @override
  ConsumerState<DeckVolumeControl> createState() => _DeckVolumeControlState();
}

class _DeckVolumeControlState extends ConsumerState<DeckVolumeControl> {
  /// Unconfirmed drag preview; cleared the moment a telemetry frame
  /// changes the volume (confirmation or external change alike).
  double? _previewVolume;
  int _lastTelemetryVolume = -1;

  @override
  Widget build(BuildContext context) {
    final TelemetryState telemetry = ref.watch(telemetryProvider);
    if (telemetry.potPlayerVolume != _lastTelemetryVolume) {
      _lastTelemetryVolume = telemetry.potPlayerVolume;
      _previewVolume = null;
    }
    final int volume =
        (_previewVolume ?? telemetry.potPlayerVolume.toDouble()).round();
    final PotPlayerDeckController controller = ref.read(deckControllerProvider);
    final bool enabled = widget.enabled;
    final Color fg =
        enabled ? AppColors.textPrimary : AppColors.textTertiary;
    final IconData levelIcon = volume <= 0
        ? Icons.volume_off
        : (volume < 50 ? Icons.volume_down : Icons.volume_up);

    void commit(double value) =>
        unawaited(controller.setVolume(value.round(), telemetry));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 48,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Semantics(
              label: enabled
                  ? 'Volume, $volume percent'
                  : 'Volume unavailable',
              child: Icon(
                levelIcon,
                size: 20,
                color: enabled ? AppColors.textSecondary : fg,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Slider(
                key: const Key('deck_volume'),
                value: volume.toDouble().clamp(0.0, 100.0),
                min: 0,
                max: 100,
                divisions: 100,
                label: '$volume%',
                onChanged: enabled
                    ? (double value) {
                        setState(() => _previewVolume = value);
                      }
                    : null,
                onChangeEnd: enabled ? commit : null,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              child: Text(
                '$volume%',
                key: const Key('deck_volume_value'),
                textAlign: TextAlign.right,
                maxLines: 1,
                style: AppTypography.label.copyWith(
                  fontSize: 13,
                  height: 1.0,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
