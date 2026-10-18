// Doc 36 (round 5, 2026-10-17): pure-model coverage for the ruler's
// velocity → time-frame ladder — thresholds, hysteresis, the ±5-minute
// gesture budget, chip labels and notch geometry.

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/features/deck/ruler/seek_scale.dart';

void main() {
  group('tier ladder thresholds', () {
    test('slow drags stay in the 1 s frame; 150 px/s enters 5 s', () {
      final SeekTierResolver resolver = SeekTierResolver();
      expect(resolver.resolve(0).label, '1 s');
      expect(resolver.resolve(149).label, '1 s');
      expect(resolver.resolve(kRulerFineFloorPxPerSec).label, '5 s');
    });

    test('a full-speed flick unlocks the 5 m frame', () {
      final SeekTierResolver resolver = SeekTierResolver();
      expect(resolver.resolve(4000).label, '5 m');
      expect(resolver.resolve(99999).label, '5 m');
    });

    test('direction is ignored: fast backward flicks climb tiers too', () {
      final SeekTierResolver resolver = SeekTierResolver();
      expect(resolver.resolve(-4000).label, '5 m');
      expect(resolver.resolve(-149).label, '1 s');
    });

    test('the ladder runs 1 s → 5 m with rising entry speeds', () {
      expect(
        kRulerTiers.map((RulerTier tier) => tier.label).toList(),
        <String>['1 s', '5 s', '10 s', '30 s', '1 m', '2 m', '5 m'],
      );
      for (int i = 1; i < kRulerTiers.length; i++) {
        expect(
          kRulerTiers[i].enterPxPerSec,
          greaterThan(kRulerTiers[i - 1].enterPxPerSec),
        );
        expect(
          kRulerTiers[i].msPerNotch,
          greaterThan(kRulerTiers[i - 1].msPerNotch),
        );
      }
    });
  });

  group('hysteresis', () {
    test('climbs instantly but drops only below 65 % of the entry', () {
      final SeekTierResolver resolver = SeekTierResolver();
      expect(resolver.resolve(500).label, '10 s'); // instant climb (400)
      expect(resolver.resolve(300).label, '10 s'); // 300 >= 0.65 * 400
      expect(resolver.resolve(259).label, '5 s'); // below 260 → drop
      expect(resolver.resolve(259).label, '5 s'); // settled: no flapping
    });

    test('reset returns to the finest frame', () {
      final SeekTierResolver resolver = SeekTierResolver();
      resolver.resolve(5000);
      expect(resolver.tier.label, '5 m');
      resolver.reset();
      expect(resolver.tier.label, '1 s');
      expect(resolver.index, 0);
    });
  });

  group('travel budget', () {
    test('passes deltas through while under the 5-minute cap', () {
      expect(clampGestureMs(1500, 0), 1500);
      expect(clampGestureMs(-1500, 0), -1500);
      expect(clampGestureMs(100000, 250000), 50000);
    });

    test('trims so one gesture can never exceed ±5 minutes', () {
      expect(clampGestureMs(999999, 0), kRulerBudgetMs);
      expect(clampGestureMs(-999999, 0), -kRulerBudgetMs);
      expect(clampGestureMs(100000, 300000), 0); // budget spent
      expect(clampGestureMs(-100000, -300000), 0);
    });
  });

  group('delta chip labels', () {
    test('sub-second travel reads 0', () {
      expect(formatDeltaLabel(0), '0');
      expect(formatDeltaLabel(999), '0');
    });

    test('seconds and minutes are sign-aware with U+2212 minus', () {
      expect(formatDeltaLabel(18000), '+18 s');
      expect(formatDeltaLabel(-18000), '\u221218 s');
      expect(formatDeltaLabel(60000), '+1:00');
      expect(formatDeltaLabel(154000), '+2:34');
      expect(formatDeltaLabel(-154000), '\u22122:34');
    });
  });

  group('notch geometry', () {
    test('per-pixel scale and label cadence derive from the tier', () {
      expect(kRulerTiers.first.msPerPx, closeTo(1000 / 24, 1e-9));
      expect(kRulerTiers.last.msPerPx, closeTo(300000 / 24, 1e-9));
      expect(kRulerTiers.first.labelMs, 5000); // 1 s x 5 notches
      expect(kRulerTiers[3].labelMs, 30000); // 30 s x 1
    });
  });
}
