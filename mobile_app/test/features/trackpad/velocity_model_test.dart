// Doc 35 §9 — VelocityModel pure-math unit tests.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/features/trackpad/virtual_trackpad.dart';

void main() {
  const VelocityModel model = VelocityModel.fromProfile(
    TrackpadProfile.defaults, // sensitivity 1.0, gain 2.0, threshold 0.8
  );

  group('amplify — linear zone', () {
    test('velocities at or below the threshold scale by sensitivity only', () {
      expect(model.amplify(10, 0), 10);
      expect(model.amplify(10, 0.8), 10); // threshold boundary is inclusive
      expect(model.amplify(10, -0.4), 10); // negative velocity is absolute
      expect(model.amplify(-8, 0.5), -8); // delta sign is preserved
    });

    test('sensitivity scales the linear zone', () {
      const VelocityModel m = VelocityModel.fromProfile(
        TrackpadProfile(sensitivity: 1.5),
      );
      expect(m.amplify(20, 0.1), 30);
      expect(m.amplify(-20, 0.1), -30);
    });
  });

  group('amplify — acceleration zone', () {
    test('matches the documented gain formula exactly', () {
      for (final double v in <double>[0.9, 2.0, 3.4, 5.5, 6.0]) {
        final double t = (v - 0.8) / (kMaxVelocity - 0.8);
        final double gain = 1.0 * (1.0 + t * (2.0 - 1.0));
        expect(model.amplify(10, v), 10 * gain);
        expect(model.amplify(-10, v), -(10 * gain));
        expect(model.amplify(10, -v), 10 * gain); // sign-agnostic input
      }
    });

    test('gain rises monotonically and stays bounded', () {
      double previous = 0;
      for (int i = 0; i <= 52; i++) {
        final double v = 0.8 + i * 0.1; // 0.8 → 6.0
        final double out = model.amplify(10, v);
        expect(out, greaterThanOrEqualTo(previous));
        expect(out, lessThanOrEqualTo(20)); // sensitivity × accelerationGain
        previous = out;
      }
      expect(model.amplify(10, 6.0), 20); // exactly the bound at kMaxVelocity
      expect(model.amplify(10, 99), 20); // clamped velocity
      expect(model.amplify(10, -99), 20);
    });

    test('custom profile: bound is sensitivity × accelerationGain', () {
      const VelocityModel m = VelocityModel.fromProfile(
        TrackpadProfile(sensitivity: 1.5, accelerationGain: 3.0),
      );
      expect(m.amplify(10, 99), 45); // 10 × 1.5 × 3.0
      expect(m.amplify(10, 0.5), 15); // linear: 10 × 1.5
    });

    test('threshold at the clamp keeps the whole curve linear', () {
      const VelocityModel m = VelocityModel.fromProfile(
        TrackpadProfile(accelerationThreshold: kMaxVelocity),
      );
      expect(m.amplify(10, 99), 10);
      expect(m.amplify(10, 5), 10);
    });
  });

  group('scrollUnits', () {
    test('converts finger px to wheel ticks, truncating toward zero', () {
      expect(model.scrollUnits(15.9), 0); // sub-tick drift never emits
      expect(model.scrollUnits(-15.9), 0);
      expect(model.scrollUnits(16), 1);
      expect(model.scrollUnits(-16), -1);
      expect(model.scrollUnits(48), 3); // exact multiple
      expect(model.scrollUnits(50), 3); // 3.125 → 3
      expect(model.scrollUnits(-50), -3);
    });

    test('scales by the profile scrollMultiplier', () {
      const VelocityModel m = VelocityModel.fromProfile(
        TrackpadProfile(scrollMultiplier: 2.0),
      );
      expect(m.scrollUnits(16), 2); // 16 px → 2 ticks at ×2
      expect(m.scrollUnits(8), 1);
      expect(m.scrollUnits(7), 0); // 0.875 → 0
      expect(m.scrollUnits(-8), -1);
    });
  });

  group('inertia', () {
    test('decay chain matches kInertiaFriction^n', () {
      double v = 3.0;
      for (int n = 1; n <= 40; n++) {
        v = model.decay(v);
        expect(
          v,
          closeTo(3.0 * math.pow(kInertiaFriction, n).toDouble(), 1e-9),
        );
      }
    });

    test('inertiaActive honors the floor at both signs', () {
      expect(model.inertiaActive(kInertiaMinVelocity), isTrue); // inclusive
      expect(model.inertiaActive(-kInertiaMinVelocity), isTrue);
      expect(model.inertiaActive(kInertiaMinVelocity * 0.99), isFalse);
      expect(model.inertiaActive(-kInertiaMinVelocity * 0.99), isFalse);
      expect(model.inertiaActive(0), isFalse);
      expect(model.inertiaActive(0.5), isTrue);
    });
  });
}
