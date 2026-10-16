// Doc 42 unit suite: table-driven profile arrays, repeat stacking, 30 ms
// coalescing (heavyThud bypass), scrub-loop idempotency + timer teardown,
// cancelAll window, disabled/unsupported paths, persistence, provider guard.
// Clocks are fake (package:fake_async); the `VibrationPort` seam is faked —
// no plugin, no sockets.

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records every waveform the engine emits; no plugin traffic.
class _FakeVibrationPort implements VibrationPort {
  @override
  bool isSupported = true;

  final List<({List<int> timingsMs, List<int> amplitudes})> emissions =
      <({List<int> timingsMs, List<int> amplitudes})>[];
  int cancelCount = 0;
  Object? throwOnVibrate;

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) async {
    final Object? error = throwOnVibrate;
    if (error != null) {
      throw error;
    }
    emissions.add(
      (
        timingsMs: List<int>.of(timingsMs),
        amplitudes: List<int>.of(amplitudes),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }
}

/// Doc 42 §4.2 profile map as *emitted* waveforms (doubleTick stacks 2).
const Map<HapticPattern, ({List<int> timings, List<int> amps})>
kExpectedWaveforms = <HapticPattern, ({List<int> timings, List<int> amps})>{
  HapticPattern.microTick: (timings: <int>[10], amps: <int>[96]),
  HapticPattern.heavyThud: (
    timings: <int>[55, 40, 25],
    amps: <int>[255, 0, 128],
  ),
  HapticPattern.doubleTick: (
    timings: <int>[15, 60, 15],
    amps: <int>[160, 0, 160],
  ),
  HapticPattern.scrubPulse: (timings: <int>[25], amps: <int>[140]),
  HapticPattern.volumeTick: (timings: <int>[12], amps: <int>[110]),
  HapticPattern.minuteTick: (timings: <int>[18], amps: <int>[180]),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Records `flutter/platform` calls so fallback impacts are assertable.
  final List<MethodCall> platformCalls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    platformCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          platformCalls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('table-driven profile map (Doc 42 §4.2)', () {
    for (final MapEntry<HapticPattern, ({List<int> timings, List<int> amps})>
    entry
        in kExpectedWaveforms.entries) {
      test('${entry.key} emits its exact timings/amplitude arrays', () {
        fakeAsync((FakeAsync async) {
          final _FakeVibrationPort port = _FakeVibrationPort();
          final HapticEngine engine = HapticEngine(port: port);
          engine.play(entry.key);
          expect(port.emissions, hasLength(1));
          expect(port.emissions.single.timingsMs, entry.value.timings);
          expect(port.emissions.single.amplitudes, entry.value.amps);
          expect(port.emissions.single.timingsMs.length, port.emissions.single.amplitudes.length);
          engine.dispose();
          expect(async.pendingTimers, isEmpty);
        });
      });
    }

    test('repeat: 2 on doubleTick = exactly two pulses, 60 ms apart', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.play(HapticPattern.doubleTick, repeat: 2);
        final ({List<int> timingsMs, List<int> amplitudes}) wave =
            port.emissions.single;
        expect(wave.timingsMs, <int>[15, 60, 15]);
        expect(wave.amplitudes, <int>[160, 0, 160]);
        final List<int> pulses = <int>[
          for (int i = 0; i < wave.amplitudes.length; i++)
            if (wave.amplitudes[i] > 0) i,
        ];
        expect(pulses, hasLength(2)); // exactly two pulses
        expect(wave.timingsMs[1], 60); // with the 60 ms gap
        engine.dispose();
      });
    });

    test('repeat: 3 on microTick stacks three pulses with gaps', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.play(HapticPattern.microTick, repeat: 3);
        final ({List<int> timingsMs, List<int> amplitudes}) wave =
            port.emissions.single;
        expect(wave.timingsMs, <int>[10, 60, 10, 60, 10]);
        expect(wave.amplitudes, <int>[96, 0, 96, 0, 96]);
        engine.dispose();
      });
    });
  });

  group('coalescing (30 ms, heavyThud bypass)', () {
    test('two microTicks 10 ms apart produce one emission', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.play(HapticPattern.microTick);
        async.elapse(const Duration(milliseconds: 10));
        engine.play(HapticPattern.microTick);
        expect(port.emissions, hasLength(1)); // second dropped
        async.elapse(const Duration(milliseconds: 35));
        engine.play(HapticPattern.microTick);
        expect(port.emissions, hasLength(2)); // window expired -> delivered
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('two heavyThuds 10 ms apart produce two emissions', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.play(HapticPattern.heavyThud);
        async.elapse(const Duration(milliseconds: 10));
        engine.play(HapticPattern.heavyThud);
        expect(port.emissions, hasLength(2)); // always delivered
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('scrub loop lifecycle', () {
    test('startScrubPulse is idempotent; stop tears down every timer', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.startScrubPulse();
        engine.startScrubPulse(); // no-op — rate must not double
        expect(port.emissions, hasLength(1)); // immediate heartbeat only
        async.elapse(const Duration(milliseconds: 240));
        expect(port.emissions, hasLength(3)); // +120 ms, +240 ms — not +4
        engine.stopScrubPulse();
        async.elapse(const Duration(milliseconds: 1000));
        expect(port.emissions, hasLength(3)); // loop is dead
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('stopScrubPulse when idle does not throw', () {
      fakeAsync((FakeAsync async) {
        final HapticEngine engine = HapticEngine(port: _FakeVibrationPort());
        expect(() => engine.stopScrubPulse(), returnsNormally);
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('cancelAll halts an active scrubPulse within one interval', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.startScrubPulse();
        async.elapse(const Duration(milliseconds: 60));
        expect(port.emissions, hasLength(1));
        unawaited(engine.cancelAll());
        expect(port.cancelCount, 1);
        // §4.4 step 1: play() muted for 50 ms after cancelAll.
        engine.play(HapticPattern.microTick);
        expect(port.emissions, hasLength(1)); // still blocked
        async.elapse(const Duration(milliseconds: 1000));
        expect(port.emissions, hasLength(1)); // loop never resumed either
        engine.play(HapticPattern.microTick);
        expect(port.emissions, hasLength(2)); // block expired
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('app pause stops the loop and cancels in-flight vibration', () {
      fakeAsync((FakeAsync async) {
        final _FakeVibrationPort port = _FakeVibrationPort();
        final HapticEngine engine = HapticEngine(port: port);
        engine.startScrubPulse();
        async.elapse(const Duration(milliseconds: 60));
        final WidgetsBinding binding = WidgetsBinding.instance;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(port.cancelCount, 1); // cancelAll ran from the observer
        async.elapse(const Duration(milliseconds: 1000));
        expect(port.emissions, hasLength(1)); // loop never resumed
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        engine.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('mute, support, and failure paths', () {
    test('enabled == false: zero emissions across all entry points', () async {
      final _FakeVibrationPort port = _FakeVibrationPort();
      final HapticEngine engine = HapticEngine(port: port);
      engine.enabled = false;
      await engine.play(HapticPattern.microTick);
      await engine.play(HapticPattern.heavyThud);
      engine.startScrubPulse();
      await engine.play(HapticPattern.doubleTick, repeat: 2);
      expect(port.emissions, isEmpty);
      expect(port.cancelCount, 1); // muting also cancels anything in flight
      engine.stopScrubPulse(); // safe while idle
      engine.dispose();
      await pumpEventQueue();
    });

    test('unsupported vibrator: port silent, fallback impact, never throws',
        () async {
      final _FakeVibrationPort port = _FakeVibrationPort()..isSupported = false;
      final HapticEngine engine = HapticEngine(port: port);
      await engine.play(HapticPattern.microTick);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await engine.play(HapticPattern.heavyThud);
      await Future<void>.delayed(const Duration(milliseconds: 35));
      await engine.play(HapticPattern.scrubPulse);
      expect(port.emissions, isEmpty); // never touches the vibrator
      await pumpEventQueue();
      final List<Object?> haptics = platformCalls
          .where((MethodCall c) => c.method == 'HapticFeedback.vibrate')
          .map((MethodCall c) => c.arguments)
          .toList();
      // microTick (mean 96) -> light; heavyThud (191.5) -> heavy;
      // scrubPulse (140) -> medium (Doc 42 §4.4 step 4 mapping).
      expect(
        haptics,
        <Object?>[
          'HapticFeedbackType.lightImpact',
          'HapticFeedbackType.heavyImpact',
          'HapticFeedbackType.mediumImpact',
        ],
      );
      engine.dispose();
    });

    test('port vibrate failure degrades to fallback without throwing',
        () async {
      final _FakeVibrationPort port = _FakeVibrationPort();
      final HapticEngine engine = HapticEngine(port: port);
      port
        ..isSupported = true
        ..throwOnVibrate = StateError('VIBRATE permission missing');
      await engine.play(HapticPattern.microTick);
      expect(port.emissions, isEmpty); // vibrate threw before recording
      engine.dispose();
      await pumpEventQueue();
    });
  });

  group('persistence and provider', () {
    test('mute flag persists under the haptics_enabled key', () async {
      final _FakeVibrationPort port = _FakeVibrationPort();
      final HapticEngine engine = HapticEngine(port: port);
      engine.enabled = false;
      await pumpEventQueue();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('haptics_enabled'), isFalse);
      // A new engine started from those prefs boots muted (survives restart).
      final HapticEngine restarted = HapticEngine(
        port: _FakeVibrationPort(),
        preferences: prefs,
      );
      expect(restarted.enabled, isFalse);
      restarted.dispose();
      engine.dispose();
    });

    test('hapticEngineProvider throws when unwired in debug', () {
      final ProviderContainer container = ProviderContainer();
      expect(() => container.read(hapticEngineProvider), throwsStateError);
      container.dispose();
    });
  });
}
