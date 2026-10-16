// Doc 36 (deck redesign): the seek-step segmented selector — Riverpod
// state (5 s default, survives rebuilds) driving both big transport
// buttons. Selected segment = amber fill + w700 weight (contrast AND
// weight, never color alone) + Semantics(selected:).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/oled_theme.dart';
import 'deck_actions.dart';

/// Stable widget-test handle for one step segment.
Key deckStepKeyFor(int seconds) => Key('deck_step_$seconds');

/// Selected seek step (one of [kSeekStepOptions]) in Riverpod state so it
/// survives rebuilds and tab switches.
class DeckSeekStepNotifier extends Notifier<int> {
  @override
  int build() => kDefaultSeekStep;

  void select(int seconds) {
    if (kSeekStepOptions.contains(seconds) && state != seconds) {
      state = seconds;
    }
  }
}

final NotifierProvider<DeckSeekStepNotifier, int> deckSeekStepProvider =
    NotifierProvider<DeckSeekStepNotifier, int>(DeckSeekStepNotifier.new);

/// Segmented 5 / 10 / 20 / 30 selector under the transport row; the
/// chosen step drives [DeckAction.seekBack5] / [DeckAction.seekFwd5].
class DeckStepSelector extends ConsumerWidget {
  const DeckStepSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int step = ref.watch(deckSeekStepProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 48,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
          children: <Widget>[
            for (final int seconds in kSeekStepOptions)
              Expanded(
                child: DeckStepSegment(
                  key: deckStepKeyFor(seconds),
                  seconds: seconds,
                  selected: seconds == step,
                  onTap: () =>
                      ref.read(deckSeekStepProvider.notifier).select(seconds),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One 40 dp-tall segment of the selector (48 dp hit row with padding).
class DeckStepSegment extends StatelessWidget {
  const DeckStepSegment({
    super.key,
    required this.seconds,
    required this.selected,
    required this.onTap,
  });

  final int seconds;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: 'Seek step $seconds seconds',
      child: Material(
        color: selected ? AppColors.amberDim : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          enableFeedback: false,
          highlightColor: AppColors.surfaceHigh,
          child: Center(
            child: Text(
              '${seconds}s',
              maxLines: 1,
              style: AppTypography.label.copyWith(
                fontSize: 14,
                height: 1.0,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? AppColors.onAccent : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
