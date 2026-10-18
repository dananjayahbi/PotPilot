// Doc 36 addendum (round 5, 2026-10-17): Settings screen.
//
// First surface: Trackpad cursor speed — edits the existing
// `TrackpadProfile.sensitivity` (0.2–3.0) through ConnectionCache's
// write-through `saveTrackpadProfile`; the trackpad re-resolves the
// profile on every pointer-down, so changes apply on the next touch.
// No new persistence keys (Doc 34 owns `pp.trackpad.profile.v1`).

import 'package:flutter/material.dart';

import '../../core/storage/connection_cache.dart';
import '../../core/theme/oled_theme.dart';

/// Pushed from the deck header gear and the library app-bar gear.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TrackpadProfile _profile;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _profile = ConnectionCache.instance.trackpadProfile;
  }

  Future<void> _save(TrackpadProfile next) async {
    setState(() => _profile = next);
    if (_saving) {
      return; // last write wins; no queue needed for a settings form
    }
    _saving = true;
    try {
      await ConnectionCache.instance.saveTrackpadProfile(next);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save settings — try again'),
          ),
        );
      }
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _SectionCard(
            title: 'TRACKPAD',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Cursor speed',
                      style: AppTypography.body
                          .copyWith(color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    _SpeedBadge(sensitivity: _profile.sensitivity),
                  ],
                ),
                Text(
                  'How far the on-screen cursor travels per finger swipe '
                  '(DPI). Low = precise targeting, high = fast crossing.',
                  style: AppTypography.bodySmall
                      .copyWith(color: AppColors.textTertiary),
                ),
                const SizedBox(height: 8),
                Slider(
                  key: const Key('settings_cursor_speed'),
                  value: _profile.sensitivity.clamp(0.2, 3.0),
                  min: 0.2,
                  max: 3.0,
                  divisions: 56, // 0.05 steps
                  label: '${_profile.sensitivity.toStringAsFixed(2)}\u00d7',
                  onChanged: (double value) =>
                      setState(() => _profile = _withSensitivity(value)),
                  onChangeEnd: (double value) => unawaitedSave(value),
                ),
                Row(
                  children: <Widget>[
                    TextButton(
                      key: const Key('settings_speed_slow'),
                      onPressed: () => unawaitedSave(0.60),
                      child: const Text('Slow'),
                    ),
                    TextButton(
                      key: const Key('settings_speed_default'),
                      onPressed: () => unawaitedSave(1.0),
                      child: const Text('Default'),
                    ),
                    TextButton(
                      key: const Key('settings_speed_fast'),
                      onPressed: () => unawaitedSave(1.60),
                      child: const Text('Fast'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const Key('settings_speed_max'),
                      onPressed: () => unawaitedSave(3.0),
                      child: const Text('Max'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TrackpadProfile _withSensitivity(double sensitivity) => TrackpadProfile(
        sensitivity: sensitivity,
        accelerationGain: _profile.accelerationGain,
        accelerationThreshold: _profile.accelerationThreshold,
        scrollMultiplier: _profile.scrollMultiplier,
      );

  void unawaitedSave(double sensitivity) {
    _save(_withSensitivity(sensitivity));
  }
}

/// Rounded card section matching the OLED theme (radius 12 + outline).
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

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
            title,
            style: AppTypography.label
                .copyWith(color: AppColors.amber, letterSpacing: 1.2),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Live `1.00×` readout so the slider value is never a mystery.
class _SpeedBadge extends StatelessWidget {
  const _SpeedBadge({required this.sensitivity});

  final double sensitivity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.amberDim,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${sensitivity.toStringAsFixed(2)}\u00d7',
        style: AppTypography.label.copyWith(color: AppColors.amber),
      ),
    );
  }
}
