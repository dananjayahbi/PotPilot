// Doc 36 (round 5, 2026-10-17): slim deck header — file caption on the
// left, then the two icon affordances that replaced the bulky bottom
// volume row: a volume button opening a compact popup, and the gear
// that opens the Settings screen (trackpad cursor speed etc.).

import 'package:flutter/material.dart';

import '../../../core/theme/oled_theme.dart';
import '../settings/settings_screen.dart';
import 'deck_volume_control.dart';

/// `title … [volume] [settings]` row; height matches the old caption row
/// so the deck's vertical rhythm is unchanged.
class DeckHeaderRow extends StatelessWidget {
  const DeckHeaderRow({
    super.key,
    required this.fileTitle,
    required this.volumeEnabled,
  });

  final String fileTitle;
  final bool volumeEnabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 40,
        child: Row(
          children: <Widget>[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileTitle,
                key: const Key('deck_caption'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.label
                    .copyWith(color: AppColors.textTertiary),
              ),
            ),
            DeckVolumeButton(
              key: const Key('deck_volume_button'),
              enabled: volumeEnabled,
            ),
            IconButton(
              key: const Key('deck_settings_button'),
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SettingsScreen(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
