import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/features/display/monitor_power_sheet.dart';

void main() {
  group('SystemCommandBuilder.brightness', () {
    test('brightness(42) is the exact frozen envelope', () {
      expect(
        SystemCommandBuilder.brightness(42),
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'SET_BRIGHTNESS',
          'payload': <String, Object?>{'percent': 42},
        },
      );
    });

    test('percent clamps to 0–100', () {
      expect(
        SystemCommandBuilder.brightness(-10),
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'SET_BRIGHTNESS',
          'payload': <String, Object?>{'percent': 0},
        },
      );
      expect(
        SystemCommandBuilder.brightness(150),
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'SET_BRIGHTNESS',
          'payload': <String, Object?>{'percent': 100},
        },
      );
      expect(
        (SystemCommandBuilder.brightness(0)['payload']!
            as Map<String, Object?>)['percent'],
        0,
      );
      expect(
        (SystemCommandBuilder.brightness(100)['payload']!
            as Map<String, Object?>)['percent'],
        100,
      );
    });
  });

  group('SystemCommandBuilder sleep timers', () {
    test('sleepTimerCountdown(target: SLEEP, minutes: 30) exact envelope', () {
      expect(
        SystemCommandBuilder.sleepTimerCountdown(target: 'SLEEP', minutes: 30),
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'START_SLEEP_TIMER',
          'payload': <String, Object?>{
            'mode': 'COUNTDOWN',
            'target': 'SLEEP',
            'minutes': 30,
          },
        },
      );
    });

    test('sleepTimerOnMovieEnd(target: SHUTDOWN) defaults progress_pct 99', () {
      expect(
        SystemCommandBuilder.sleepTimerOnMovieEnd(target: 'SHUTDOWN'),
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'START_SLEEP_TIMER',
          'payload': <String, Object?>{
            'mode': 'MOVIE_PROGRESS',
            'target': 'SHUTDOWN',
            'progress_pct': 99,
          },
        },
      );
    });

    test('sleepTimerOnMovieEnd honours an explicit progressPct', () {
      final Map<String, Object?> envelope = SystemCommandBuilder
          .sleepTimerOnMovieEnd(target: 'HIBERNATE', progressPct: 80);
      final Map<String, Object?> payload =
          envelope['payload']! as Map<String, Object?>;
      expect(payload['mode'], 'MOVIE_PROGRESS');
      expect(payload['target'], 'HIBERNATE');
      expect(payload['progress_pct'], 80);
    });
  });

  group('SleepPreset table', () {
    test('offers 15/30/45/60 min plus the end-of-movie sentinel', () {
      expect(kSleepPresets, hasLength(5));
      expect(
        kSleepPresets.map((SleepPreset p) => p.minutes).toList(),
        <int?>[15, 30, 45, 60, null],
      );
      expect(kSleepPresets.last.onMovieEnd, isTrue);
      expect(kSleepPresets.last.label, 'End of movie');
    });

    test('power targets are the frozen SLEEP|HIBERNATE|SHUTDOWN set', () {
      expect(
        kSleepTargets.map((({String id, String label}) t) => t.id).toList(),
        <String>['SLEEP', 'HIBERNATE', 'SHUTDOWN'],
      );
      expect(
        kSleepTargets.map((({String id, String label}) t) => t.label).toList(),
        <String>['Sleep', 'Hibernate', 'Shutdown'],
      );
    });
  });
}
