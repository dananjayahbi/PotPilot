import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/features/hud/scrub_speed_hud.dart';

void main() {
  group('formatTimecode (Doc 38 §9 unit)', () {
    test('0 -> 00:00', () {
      expect(formatTimecode(0), '00:00');
    });

    test('59_999 -> 00:59', () {
      expect(formatTimecode(59999), '00:59');
    });

    test('3_730_000 -> 01:02:10', () {
      expect(formatTimecode(3730000), '01:02:10');
    });

    test('8_100_000 -> 02:15:00', () {
      expect(formatTimecode(8100000), '02:15:00');
    });

    test('null -> --:--:--', () {
      expect(formatTimecode(null), '--:--:--');
    });

    test('hour rollover renders padded hours', () {
      expect(formatTimecode(3600000), '01:00:00');
      expect(formatTimecode(3600000 + 61000), '01:01:01');
      expect(formatTimecode(36000000), '10:00:00');
      expect(formatTimecode(35999999), '09:59:59');
    });

    test('negative input falls back to the null placeholder', () {
      expect(formatTimecode(-1), '--:--:--');
    });
  });

  group('formatDurationTimecode (fixed HH:MM:SS row)', () {
    test('zero duration renders 00:00:00 (zero-media label, §7)', () {
      expect(formatDurationTimecode(0), '00:00:00');
    });

    test('sub-hour durations keep the hour slots', () {
      expect(formatDurationTimecode(59999), '00:00:59');
      expect(formatDurationTimecode(61000), '00:01:01');
    });

    test('movie-length durations match the acceptance example', () {
      expect(formatDurationTimecode(8100000), '02:15:00');
      expect(formatDurationTimecode(5050000), '01:24:10');
    });

    test('null -> --:--:--', () {
      expect(formatDurationTimecode(null), '--:--:--');
    });
  });
}
