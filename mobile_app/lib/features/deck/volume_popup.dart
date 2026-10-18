// Doc 36 (round 5, 2026-10-17): volume moved out of the deck's bottom
// cluster (freeing it for the ruler slider) into a compact popup:
// the header's speaker button opens [showVolumePopup].
//
// Semantics are the old bottom row, verbatim: optimistic drag preview
// until a telemetry frame speaks (telemetry always wins), commit
// `SET_VOLUME {percent}` on release, WS-down / closed-player gates.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import '../../network/telemetry_provider.dart';
import 'deck_controller.dart';

/// Opens the volume popup centred above the deck (a simple dialog — the
/// spec's "button to open a simple popup to control the volume").
Future<void> showVolumePopup(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: AppColors.outline),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: _VolumePopupBody(),
        ),
      ),
    );

class _VolumePopupBody extends ConsumerStatefulWidget {
  const _VolumePopupBody();

  @override
  ConsumerState<_VolumePopupBody> createState() => _VolumePopupBodyState();
}

class _VolumePopupBodyState extends ConsumerState<_VolumePopupBody> {
  /// Unconfirmed drag preview; cleared the moment telemetry speaks.
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
    final bool enabled = controller.isConnected &&
        telemetry.extras['potplayer_found'] != false;
    final IconData levelIcon = volume <= 0
        ? Icons.volume_off
        : (volume < 50 ? Icons.volume_down : Icons.volume_up);

    void commit(double value) =>
        unawaited(controller.setVolume(value.round(), telemetry));

    return SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(levelIcon, size: 18, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                'Volume',
                style: AppTypography.label
                    .copyWith(color: AppColors.textSecondary),
              ),
              const Spacer(),
              Text(
                '$volume%',
                key: const Key('deck_volume_value'),
                style: AppTypography.label.copyWith(
                  fontSize: 13,
                  color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
                ),
              ),
            ],
          ),
          Slider(
            key: const Key('deck_volume'),
            value: volume.toDouble().clamp(0.0, 100.0),
            min: 0,
            max: 100,
            divisions: 100,
            label: '$volume%',
            onChanged: enabled
                ? (double value) => setState(() => _previewVolume = value)
                : null,
            onChangeEnd: enabled ? commit : null,
          ),
        ],
      ),
    );
  }
}
