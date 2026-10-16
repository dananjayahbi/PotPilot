import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/hud/scrub_speed_hud.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';

/// Fake Doc 30/31 sinks — no sockets, pure captures.
class _FakeTransport implements ScrubTransport {
  final List<int> scrubs = <int>[];
  final List<int> seeks = <int>[];
  bool connected = true;

  @override
  void sendScrub(int targetSeconds) => scrubs.add(targetSeconds);

  @override
  void sendSeek(int positionMs) => seeks.add(positionMs);

  @override
  bool get wsConnected => connected;
}

/// Captured one-shot timer (fake settle clock).
class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function(Timer timer) callback;
  bool cancelled = false;

  void fire() {
    if (!cancelled) {
      callback(this);
    }
  }

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => cancelled ? 0 : 1;
}

TelemetryState _frame({
  int timestamp = 1000,
  int positionMs = 0,
  int durationMs = 600000,
  double speed = 1.0,
  int volume = 50,
}) {
  return TelemetryState(
    timestamp: timestamp,
    positionMs: positionMs,
    durationMs: durationMs,
    isPlaying: true,
    speed: speed,
    potPlayerVolume: volume,
    fileTitle: 'Interstellar',
    extras: const <String, Object?>{},
    isConnected: true,
  );
}

void main() {
  late _FakeTransport transport;
  late int nowMs;
  late List<HapticPattern> haptics;
  late List<_FakeTimer> timers;
  late ScrubController controller;

  setUp(() {
    transport = _FakeTransport();
    nowMs = 1000000;
    haptics = <HapticPattern>[];
    timers = <_FakeTimer>[];
    controller = ScrubController(
      transport: transport,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
      nowMs: () => nowMs,
    );
    controller.timerFactory =
        (Duration duration, void Function(Timer) callback) {
      final _FakeTimer timer = _FakeTimer(duration, callback);
      timers.add(timer);
      return timer;
    };
  });

  tearDown(() {
    controller.dispose();
  });

  group('UDP throttle math (§4.3: second change AND >=16 ms)', () {
    test('two updates 8 ms apart in the same second -> 1 UDP packet', () {
      controller.onTelemetry(_frame(positionMs: 100000, durationMs: 600000));
      controller.beginDrag(400);
      controller.updateDrag(40); // target 160000 ms -> second 160
      nowMs += 8;
      controller.updateDrag(1); // same second, only 8 ms later
      expect(transport.scrubs, <int>[160]);
    });

    test('updates in different seconds >=16 ms apart -> 2 UDP packets', () {
      controller.onTelemetry(_frame(positionMs: 100000, durationMs: 600000));
      controller.beginDrag(400);
      controller.updateDrag(40); // 160000 -> 160
      nowMs += 16;
      controller.updateDrag(40); // 220000 -> 220 (new second, spaced ok)
      expect(transport.scrubs, <int>[160, 220]);
    });

    test('second change within 16 ms of the last send is throttled', () {
      controller.onTelemetry(_frame(positionMs: 100000, durationMs: 600000));
      controller.beginDrag(400);
      controller.updateDrag(40); // 160
      nowMs += 8;
      controller.updateDrag(60); // different second but only 8 ms later
      expect(transport.scrubs, <int>[160]); // <=60 Hz cap wins
    });

    test('UDP stream uses floored integer seconds', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 100000));
      controller.beginDrag(1000);
      controller.updateDrag(509.99); // raw 50_999 ms -> floor 50 s
      expect(transport.scrubs, <int>[50]);
    });
  });

  group('WS SEEK commit (§4.5)', () {
    test('endDrag commits position_ms equal to the preview target', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(271); // 271000 ms exactly
      final int previewTarget = controller.preview.positionMs;
      expect(previewTarget, 271000);
      controller.endDrag();
      expect(transport.seeks, <int>[previewTarget]); // ms precision
      expect(transport.scrubs.last, 271); // final UDP bridge, floored
      expect(controller.phase, ScrubPhase.settling);
      final _FakeTimer timer = timers.single;
      expect(timer.duration, const Duration(milliseconds: kSettleTimeout));
    });

    test('targets clamp to [0, duration - kCommitOvershootGuard]', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(100000); // far past the right edge
      expect(controller.preview.positionMs, 599500);
      controller.updateDrag(-1000000); // far past the left edge
      expect(controller.preview.positionMs, 0);
      controller.endDrag();
      expect(transport.seeks, <int>[0]);
    });

    test('WS down at release drops the SEEK; settle times out to Idle', () {
      transport.connected = false;
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(300);
      controller.endDrag();
      expect(transport.seeks, isEmpty);
      expect(transport.scrubs, isNotEmpty); // UDP preview still streamed
      expect(controller.phase, ScrubPhase.settling);
      timers.single.fire();
      expect(controller.phase, ScrubPhase.idle);
    });
  });

  group('Settling (§4.6)', () {
    test('ignores frames older than the commit, converges at Δ<=1500', () {
      controller.onTelemetry(
        _frame(timestamp: 1000, positionMs: 0, durationMs: 600000),
      );
      controller.beginDrag(600);
      controller.updateDrag(300); // 300000
      controller.endDrag(); // commit frame ts = 1000

      // Same-second frame — predates the commit, must be ignored.
      controller.onTelemetry(_frame(timestamp: 1000, positionMs: 300500));
      expect(controller.phase, ScrubPhase.settling);
      expect(controller.preview.positionMs, 300000);

      // Newer frame within the 1500 ms window -> re-attach.
      controller.onTelemetry(_frame(timestamp: 1001, positionMs: 300900));
      expect(controller.phase, ScrubPhase.idle);
      expect(controller.preview.positionMs, 300900);
    });

    test('newer frame far from target keeps Settling, thumb follows it', () {
      controller.onTelemetry(
        _frame(timestamp: 1000, positionMs: 0, durationMs: 600000),
      );
      controller.beginDrag(600);
      controller.updateDrag(300);
      controller.endDrag();
      controller.onTelemetry(_frame(timestamp: 1001, positionMs: 100000));
      expect(controller.phase, ScrubPhase.settling);
      expect(controller.preview.positionMs, 100000);
    });

    test('750 ms timeout falls back to Idle and notifies the host', () {
      final List<bool> active = <bool>[];
      controller.onActiveChanged = active.add;
      controller.onTelemetry(
        _frame(timestamp: 1000, positionMs: 0, durationMs: 600000),
      );
      controller.beginDrag(600);
      expect(active, <bool>[true]);
      controller.updateDrag(300);
      controller.endDrag();
      timers.single.fire();
      expect(controller.phase, ScrubPhase.idle);
      expect(active, <bool>[true, false]);
    });
  });

  group('telemetry handling (§4.4 / §7)', () {
    test('position is ignored while Dragging; duration is re-read', () {
      controller.onTelemetry(_frame(positionMs: 100000, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(60); // 160000
      controller.onTelemetry(_frame(positionMs: 500000, durationMs: 600000));
      expect(controller.preview.dragging, true);
      expect(controller.preview.positionMs, 160000);

      // Mid-drag file/duration switch re-clamps against the new total.
      controller.onTelemetry(_frame(positionMs: 500000, durationMs: 700000));
      expect(controller.preview.durationMs, 700000);
    });

    test('zero-duration media disables drags — no packets emitted', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 0));
      controller.beginDrag(600);
      expect(controller.phase, ScrubPhase.idle);
      controller.updateDrag(100);
      controller.endDrag();
      controller.cancelDrag();
      expect(transport.scrubs, isEmpty);
      expect(transport.seeks, isEmpty);
      expect(controller.preview.positionMs, 0);
      expect(controller.preview.durationMs, 0);
    });
  });

  group('cancelDrag (§4.7)', () {
    test('sub-second drift aborts with no packets, host notified false', () {
      final List<bool> active = <bool>[];
      controller.onActiveChanged = active.add;
      controller.onTelemetry(_frame(positionMs: 100000, durationMs: 600000));
      controller.beginDrag(600);
      expect(active, <bool>[true]);
      controller.updateDrag(0.5); // 500 ms drift — under the 1 s guard
      expect(controller.preview.positionMs, 100500);
      controller.cancelDrag();
      expect(controller.phase, ScrubPhase.idle);
      expect(active, <bool>[true, false]);
      expect(transport.seeks, isEmpty);
    });

    test('drift >= 1 full second commits the SEEK exactly once', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(60); // +60_000 ms drift
      final int target = controller.preview.positionMs;
      controller.cancelDrag();
      expect(controller.phase, ScrubPhase.idle);
      expect(transport.seeks, <int>[target]);
    });
  });

  group('haptics (Doc 42 via §4.3)', () {
    test('one minuteTick per 60 s of media crossed; none while idle', () {
      controller.onTelemetry(_frame(positionMs: 0, durationMs: 600000));
      controller.beginDrag(600);
      controller.updateDrag(150); // -> 150000 ms: crosses 60 s and 120 s
      expect(haptics, <HapticPattern>[
        HapticPattern.minuteTick,
        HapticPattern.minuteTick,
      ]);
      controller.updateDrag(30); // -> 180000 ms: one more boundary
      expect(haptics, hasLength(3));

      controller.endDrag();
      controller.onTelemetry(_frame(timestamp: 1001, positionMs: 180500));
      expect(haptics, hasLength(3)); // no ticks when idle
    });
  });
}
