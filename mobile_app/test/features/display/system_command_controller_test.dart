import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/display/monitor_power_sheet.dart';
import 'package:potpilot_remote/network/ws_client.dart';

/// Fake Doc 31 client — captures envelopes, no sockets.
class _FakeWsClient extends WsClient {
  _FakeWsClient({bool connected = true}) : _connected = connected;

  bool _connected;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();

  @override
  WsConnectionState get state =>
      _connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(<String, Object?>{'type': type, 'action': action, 'payload': payload});
  }

  void setConnected(bool value) {
    _connected = value;
    _states.add(state);
  }

  List<Map<String, Object?>> action(String name) =>
      sent.where((Map<String, Object?> e) => e['action'] == name).toList();

  Future<void> close() => _states.close();
}

/// The plan calls for `fakeAsync`; the test binding's fake clock
/// (`tester.pump(duration)`) provides exactly that without an extra dep.
void main() {
  late _FakeWsClient client;
  late SystemCommandController controller;
  late List<HapticPattern> haptics;

  setUp(() {
    client = _FakeWsClient();
    haptics = <HapticPattern>[];
    controller = SystemCommandController(
      client: client,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
    );
  });

  Future<void> flush(WidgetTester tester) => tester.pump();

  group('SET_BRIGHTNESS throttle (200 ms)', () {
    testWidgets('5 drags inside 100 ms → 1 packet carrying the latest value', (
      WidgetTester tester,
    ) async {
      for (final int value in <int>[10, 25, 40, 55, 70]) {
        controller.setBrightness(value);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        client.action('SET_BRIGHTNESS'),
        isEmpty,
        reason: 'still inside the first 200 ms window',
      );

      // Window opens 200 ms after the first call (t = 100 ms so far).
      await tester.pump(const Duration(milliseconds: 100));
      final List<Map<String, Object?>> packets = client.action(
        'SET_BRIGHTNESS',
      );
      expect(packets, hasLength(1));
      expect(
        (packets.single['payload']! as Map)['percent'],
        70,
        reason: 'latest value wins',
      );

      // Window drains cleanly — no duplicate sends.
      await tester.pump(const Duration(milliseconds: 500));
      expect(client.action('SET_BRIGHTNESS'), hasLength(1));

      controller.dispose();
    });

    testWidgets('trailing send on release is the final packet', (
      WidgetTester tester,
    ) async {
      controller.setBrightness(20);
      await tester.pump(const Duration(milliseconds: 50));
      controller.setBrightness(64);
      await tester.pump(const Duration(milliseconds: 50));

      // Release before the window closes: pending value goes out now.
      controller.commitBrightness();
      await flush(tester);

      final List<Map<String, Object?>> packets = client.action(
        'SET_BRIGHTNESS',
      );
      expect(packets, isNotEmpty);
      expect(
        (packets.last['payload']! as Map)['percent'],
        64,
        reason: 'finger-lifted value is the last packet sent',
      );

      final int count = packets.length;
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        client.action('SET_BRIGHTNESS'),
        hasLength(count),
        reason: 'cancelled window leaves no stray packet',
      );

      controller.dispose();
    });

    testWidgets('offline setBrightness never touches the wire', (
      WidgetTester tester,
    ) async {
      client.setConnected(false);
      controller.setBrightness(50);
      controller.commitBrightness();
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.sent, isEmpty);

      controller.dispose();
    });
  });

  group('sleep-timer bookkeeping', () {
    testWidgets(
      'local countdown decrements and survives a missing telemetry field',
      (WidgetTester tester) async {
        // The controller has no telemetry dependency at all: the countdown
        // must tick purely from its local 1-min timer.
        controller.armTimer(target: 'SLEEP', minutes: 30);
        await flush(tester);
        expect(controller.timerArmed, true);
        expect(controller.remainingMinutes, 30);
        expect(client.action('START_SLEEP_TIMER'), <Map<String, Object?>>[
          <String, Object?>{
            'type': 'CMD_SYSTEM',
            'action': 'START_SLEEP_TIMER',
            'payload': <String, dynamic>{
              'mode': 'COUNTDOWN',
              'target': 'SLEEP',
              'minutes': 30,
            },
          },
        ]);
        expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);

        await tester.pump(const Duration(minutes: 1));
        expect(controller.remainingMinutes, 29);
        await tester.pump(const Duration(minutes: 2));
        expect(controller.remainingMinutes, 27);

        // Re-arming overwrites (no queued duplicates).
        controller.armTimer(target: 'HIBERNATE', minutes: 15);
        await flush(tester);
        expect(controller.remainingMinutes, 15);
        expect(
          (client.action('START_SLEEP_TIMER').last['payload']! as Map)['target'],
          'HIBERNATE',
        );

        controller.dispose();
      },
    );

    testWidgets('end-of-movie arm tracks no local number; cancel clears all', (
      WidgetTester tester,
    ) async {
      controller.armTimer(target: 'SHUTDOWN', onMovieEnd: true);
      await flush(tester);
      expect(controller.timerArmed, true);
      expect(controller.remainingMinutes, isNull);
      expect(
        (client.action('START_SLEEP_TIMER').single['payload']! as Map),
        <String, dynamic>{
          'mode': 'MOVIE_PROGRESS',
          'target': 'SHUTDOWN',
          'progress_pct': 99,
        },
      );

      controller.cancelTimer();
      await flush(tester);
      expect(controller.timerArmed, false);
      expect(controller.remainingMinutes, isNull);
      expect(client.action('CANCEL_SLEEP_TIMER'), <Map<String, Object?>>[
        <String, Object?>{
          'type': 'CMD_SYSTEM',
          'action': 'CANCEL_SLEEP_TIMER',
          'payload': <String, dynamic>{},
        },
      ]);

      // The minute ticker is dead: no further ticks, no pending timers.
      await tester.pump(const Duration(minutes: 10));
      expect(controller.timerArmed, false);
      expect(controller.remainingMinutes, isNull);

      controller.dispose();
    });

    testWidgets('arming offline dispatches nothing', (
      WidgetTester tester,
    ) async {
      client.setConnected(false);
      controller.armTimer(target: 'SLEEP', minutes: 15);
      await flush(tester);
      expect(client.sent, isEmpty);
      expect(controller.timerArmed, false);

      controller.dispose();
    });
  });
}
