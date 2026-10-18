// Doc 36 addendum (round 6, 2026-10-18): DISPLAY section — controller-
// screen brightness (the OLED deck can be too dim in a dark room).
//
// Uses `screen_brightness` in **application** mode only (window-level,
// no Android WRITE_SETTINGS permission; Doc 05 §6.1). Changes apply live
// through [ScreenBrightness.instance.setApplicationScreenBrightness] and
// persist through ConnectionCache's write-through `saveBrightness`; main()
// re-applies the saved value at startup. Every plugin call is guarded —
// widget tests and unsupported platforms degrade to persistence-only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../core/storage/connection_cache.dart';
import '../../core/theme/oled_theme.dart';

/// Lowest allowed controller brightness (dark-room floor, not 0 — an
/// all-black screen reads as "app crashed").
const double kBrightnessMin = 0.05;

/// Attempts the live platform call; missing channels (tests/web) never
/// surface to the user — persistence still happens in [onChanged].
Future<void> applyBrightness(double value) async {
  try {
    await ScreenBrightness.instance
        .setApplicationScreenBrightness(value.clamp(kBrightnessMin, 1.0));
  } on Object catch (error) {
    debugPrint('brightness apply skipped: $error');
  }
}

/// DISPLAY card: brightness slider with a live percent badge. Applies on
/// every drag tick (the controller screen responds instantly), persists
/// only on `changeEnd` (same write-through contract as the trackpad card).
class DisplaySettingsCard extends StatefulWidget {
  const DisplaySettingsCard({super.key});

  @override
  State<DisplaySettingsCard> createState() => _DisplaySettingsCardState();
}

class _DisplaySettingsCardState extends State<DisplaySettingsCard> {
  late double _brightness;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _brightness = ConnectionCache.instance.brightness;
  }

  Future<void> _persist(double value) async {
    if (_saving) {
      return; // last write wins (same contract as the trackpad card)
    }
    _saving = true;
    try {
      await ConnectionCache.instance.saveBrightness(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save brightness — try again'),
          ),
        );
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'DISPLAY',
            style: AppTypography.label
                .copyWith(color: AppColors.amber, letterSpacing: 1.2),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Text(
                'Screen brightness',
                style: AppTypography.body
                    .copyWith(color: AppColors.textPrimary),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.amberDim,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${(_brightness * 100).round()}%',
                  style: AppTypography.label.copyWith(color: AppColors.amber),
                ),
              ),
            ],
          ),
          Text(
            'Controller-screen brightness for dark rooms. Saved and '
            're-applied automatically on every launch.',
            style:
                AppTypography.bodySmall.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 8),
          Slider(
            key: const Key('settings_brightness'),
            value: _brightness.clamp(kBrightnessMin, 1.0),
            min: kBrightnessMin,
            max: 1.0,
            divisions: 19, // 5% steps
            label: '${(_brightness * 100).round()}%',
            onChanged: (double value) {
              setState(() => _brightness = value);
              unawaited(applyBrightness(value)); // live, instant response
            },
            onChangeEnd: (double value) => unawaited(_persist(value)),
          ),
        ],
      ),
    );
  }
}
