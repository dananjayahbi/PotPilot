// Doc 44 unit suite (§9): table-driven §4.1 transition rows (exact PAUSE/
// PLAY envelopes), the resume-gate matrix, duplicate-event filtering,
// PC-offline-at-ring, the permission-denied seam, the `callActive` truth
// table consumed by Doc 43, and settings persistence. Telephony and WS are
// faked — no real network, no telephony, no UDP anywhere in this file.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/hardware_hooks/call_autopause_hook.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Capturing Doc 31 fake — one fresh-uuid envelope per send, no sockets.
class _FakeWsClient extends WsClient {
  bool connected = true;

  final List<WsMessage> sent = <WsMessage>[];

  @override
  WsConnectionState get state =>
      connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(buildMessage(type: type, action: action, payload: payload));
  }
}

/// Records emitted waveforms — used for the optional `heavyThud` confirm.
class _FakeVibrationPort implements VibrationPort {
  @override
  bool isSupported = true;

  final List<({List<int> timingsMs, List<int> amplitudes})> emissions =
      <({List<int> timingsMs, List<int> amplitudes})>[];

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) async {
    emissions.add(
      (
        timingsMs: List<int>.of(timingsMs),
        amplitudes: List<int>.of(amplitudes),
      ),
    );
  }

  @override
  Future<void> cancel() async {}
}

final RegExp _uuid4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
  r'[0-9a-f]{12}$',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWsClient ws;
  late _FakeVibrationPort port;
  late HapticEngine engine;
  late SharedPreferences prefs;
  late TelemetryState current;
  StreamController<CallPhase>? activeController;
  final List<CallAutopauseHook> hooks = <CallAutopauseHook>[];
  final List<StreamController<CallPhase>> controllers =
      <StreamController<CallPhase>>[];
  bool permissionGranted = true;

  TelemetryState telemetry({
    bool playing = true,
    String? title = 'Interstellar',
  }) {
    return TelemetryState(
      timestamp: 1760000000,
      positionMs: 60000,
      durationMs: 600000,
      isPlaying: playing,
      speed: 1.0,
      potPlayerVolume: 42,
      fileTitle: title,
      extras: const <String, Object?>{},
      isConnected: ws.connected,
    );
  }

  Future<CallAutopauseHook> startHook({
    bool autoResume = true,
    bool enabled = true,
    Future<bool> Function()? requestPermission,
  }) async {
    final StreamController<CallPhase> controller =
        StreamController<CallPhase>.broadcast();
    controllers.add(controller);
    final CallAutopauseHook hook = CallAutopauseHook(
      ws: ws,
      telemetry: () => current,
      phoneStates: controller.stream,
      requestPermission: requestPermission ?? () async => permissionGranted,
      haptics: engine,
      preferences: prefs,
    );
    hooks.add(hook);
    hook.autoResumeOnHangup = autoResume;
    if (!enabled) {
      hook.enabled = false;
    }
    await hook.start();
    activeController = controller;
    await pumpEventQueue();
    return hook;
  }

  Future<void> emit(CallPhase phase) async {
    activeController!.add(phase);
    await pumpEventQueue();
  }

  setUp(() async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    permissionGranted = true;
    ws = _FakeWsClient();
    port = _FakeVibrationPort();
    engine = HapticEngine(port: port, preferences: prefs);
    current = telemetry(playing: true, title: 'Interstellar');
  });

  tearDown(() async {
    for (final CallAutopauseHook hook in hooks) {
      hook.stop();
    }
    hooks.clear();
    for (final StreamController<CallPhase> controller in controllers) {
      await controller.close();
    }
    controllers.clear();
    activeController = null;
    engine.dispose();
  });

  group('§4.1 transition table (exact envelopes, §5)', () {
    // One row per machine edge: `phases` are telephony events in order,
    // `playing` is the telemetry `is_playing` at each step, `actions` is
    // the exact sequence of CMD_POTPLAYER actions the PC must receive.
    final List<({
      String label,
      List<CallPhase> phases,
      List<bool> playing,
      List<String> actions,
    })> rows = <({
      String label,
      List<CallPhase> phases,
      List<bool> playing,
      List<String> actions,
    })>[
      (
        label: 'ring → pause, reject → resume',
        phases: <CallPhase>[CallPhase.ringing, CallPhase.idle],
        playing: <bool>[true, false],
        actions: <String>['PAUSE', 'PLAY'],
      ),
      (
        label: 'ring → pause, answer → noop, hangup → resume',
        phases: <CallPhase>[
          CallPhase.ringing,
          CallPhase.offhook,
          CallPhase.idle,
        ],
        playing: <bool>[true, true, false],
        actions: <String>['PAUSE', 'PLAY'],
      ),
      (
        label: 'outgoing (idle → offhook) → pause, hangup → resume',
        phases: <CallPhase>[CallPhase.offhook, CallPhase.idle],
        playing: <bool>[true, false],
        actions: <String>['PAUSE', 'PLAY'],
      ),
      (
        label: 'autoResume off: ring pauses, reject stays paused',
        phases: <CallPhase>[CallPhase.ringing, CallPhase.idle],
        playing: <bool>[true, false],
        actions: <String>['PAUSE'],
      ),
      (
        label: 'already paused at ring: no PAUSE, no resume',
        phases: <CallPhase>[CallPhase.ringing, CallPhase.idle],
        playing: <bool>[false, false],
        actions: <String>[],
      ),
      (
        label: 'user resumed mid-call: PAUSE only, never a second PLAY',
        phases: <CallPhase>[CallPhase.ringing, CallPhase.idle],
        playing: <bool>[true, true],
        actions: <String>['PAUSE'],
      ),
    ];

    for (final ({
      String label,
      List<CallPhase> phases,
      List<bool> playing,
      List<String> actions,
    })
    row
    in rows) {
      test(row.label, () async {
        final bool autoResume = row.actions.contains('PLAY');
        final CallAutopauseHook hook =
            await startHook(autoResume: autoResume);
        for (int i = 0; i < row.phases.length; i++) {
          current = telemetry(
            playing: row.playing[i],
            title: 'Interstellar',
          );
          await emit(row.phases[i]);
        }
        expect(
          ws.sent.map((WsMessage m) => m.action).toList(),
          row.actions,
          reason: 'exact action sequence on the wire',
        );
        for (final WsMessage envelope in ws.sent) {
          expect(envelope.type, 'CMD_POTPLAYER');
          expect(envelope.payload, <String, dynamic>{},
              reason: 'payload stays the frozen empty object');
          expect(envelope.id, matches(_uuid4));
          expect(envelope.timestamp, greaterThan(1700000000));
        }
        expect(hook.state.value.phase, row.phases.last);
        expect(hook.callActive, row.phases.last != CallPhase.idle);
      });
    }

    test('pause snapshots the file title for the resume gate', () async {
      final CallAutopauseHook hook = await startHook();
      await emit(CallPhase.ringing);
      expect(hook.state.value.pausedByHook, isTrue);
      expect(hook.state.value.pausedFileTitle, 'Interstellar');
      expect(hook.state.value.permissionGranted, isTrue);
    });

    test('pause fires the optional Doc 42 heavyThud confirmation', () async {
      await startHook();
      await emit(CallPhase.ringing);
      expect(
        port.emissions.any(
          (({List<int> timingsMs, List<int> amplitudes}) wave) =>
              wave.timingsMs.length == 3 && wave.timingsMs.first == 55,
        ),
        isTrue,
        reason: 'heavyThud bypasses the coalescer and lands immediately',
      );
    });
  });

  group('resume-gate matrix (§4.2 step 5, §9)', () {
    final List<({
      String label,
      bool resumeEnabled,
      bool wasPlaying,
      bool stillPaused,
      bool sameTitle,
      bool pcOnline,
      bool expectPlay,
    })> cases = <({
      String label,
      bool resumeEnabled,
      bool wasPlaying,
      bool stillPaused,
      bool sameTitle,
      bool pcOnline,
      bool expectPlay,
    })>[
      (
        label: 'all gates pass → PLAY',
        resumeEnabled: true,
        wasPlaying: true,
        stillPaused: true,
        sameTitle: true,
        pcOnline: true,
        expectPlay: true,
      ),
      (
        label: 'autoResume disabled → no PLAY',
        resumeEnabled: false,
        wasPlaying: true,
        stillPaused: true,
        sameTitle: true,
        pcOnline: true,
        expectPlay: false,
      ),
      (
        label: 'hook never paused (wasPlaying false) → no PLAY',
        resumeEnabled: true,
        wasPlaying: false,
        stillPaused: true,
        sameTitle: true,
        pcOnline: true,
        expectPlay: false,
      ),
      (
        label: 'still playing at IDLE (manual resume) → no PLAY',
        resumeEnabled: true,
        wasPlaying: true,
        stillPaused: false,
        sameTitle: true,
        pcOnline: true,
        expectPlay: false,
      ),
      (
        label: 'file switched mid-call → no PLAY',
        resumeEnabled: true,
        wasPlaying: true,
        stillPaused: true,
        sameTitle: false,
        pcOnline: true,
        expectPlay: false,
      ),
      (
        label: 'different file loaded at hangup → no PLAY',
        resumeEnabled: true,
        wasPlaying: true,
        stillPaused: true,
        sameTitle: false,
        pcOnline: true,
        expectPlay: false,
      ),
      (
        label: 'PC offline at hangup → no PLAY, no retry',
        resumeEnabled: true,
        wasPlaying: true,
        stillPaused: true,
        sameTitle: true,
        pcOnline: false,
        expectPlay: false,
      ),
    ];

    for (final ({
      String label,
      bool resumeEnabled,
      bool wasPlaying,
      bool stillPaused,
      bool sameTitle,
      bool pcOnline,
      bool expectPlay,
    })
    c
    in cases) {
      test(c.label, () async {
        final CallAutopauseHook hook =
            await startHook(autoResume: c.resumeEnabled);
        // Ring while (maybe) playing → maybe PAUSE.
        current = telemetry(playing: c.wasPlaying, title: 'Interstellar');
        await emit(CallPhase.ringing);
        final int afterRing = ws.sent.length;

        // Call ends; telemetry reflects the mid-call situation.
        if (c.pcOnline == false) {
          ws.connected = false;
        }
        current = telemetry(
          playing: !c.stillPaused,
          title: c.sameTitle ? 'Interstellar' : 'Inception',
        );
        await emit(CallPhase.idle);

        expect(
          ws.sent.length,
          afterRing + (c.expectPlay ? 1 : 0),
          reason: 'exactly one PLAY iff every gate passes',
        );
        if (c.expectPlay) {
          expect(ws.sent.last.action, 'PLAY');
        }
        expect(hook.state.value.pausedByHook, isFalse,
            reason: 'call session flags clear on IDLE either way');
        expect(hook.callActive, isFalse);
      });
    }
  });

  group('robustness seams (§9)', () {
    test('duplicate events: two consecutive ringings → one PAUSE', () async {
      await startHook();
      await emit(CallPhase.ringing);
      await emit(CallPhase.ringing);
      expect(ws.sent, hasLength(1));
      expect(ws.sent.single.action, 'PAUSE');
    });

    test('CALL_ENDED then NOTHING both map to IDLE without extra sends',
        () async {
      await startHook();
      await emit(CallPhase.ringing);
      current = telemetry(playing: false);
      await emit(CallPhase.idle); // CALL_ENDED → resume attempt
      await emit(CallPhase.idle); // NOTHING → duplicate, filtered
      expect(
        ws.sent.map((WsMessage m) => m.action).toList(),
        <String>['PAUSE', 'PLAY'],
      );
    });

    test('disconnected at ring: zero sends, pausedByHook stays false, '
        'so IDLE never resumes', () async {
      ws.connected = false;
      await startHook();
      await emit(CallPhase.ringing);
      expect(ws.sent, isEmpty, reason: 'no queued late PAUSE (§7)');
      expect(hooks.last.state.value.pausedByHook, isFalse);

      await emit(CallPhase.idle);
      expect(ws.sent, isEmpty, reason: 'resume gate fails at its first hop');
      expect(hooks.last.callActive, isFalse);
    });

    test('paused without a captured title → conservative no-resume', () async {
      final CallAutopauseHook hook = await startHook();
      current = telemetry(playing: true, title: null);
      await emit(CallPhase.ringing);
      expect(hook.state.value.pausedByHook, isTrue);
      expect(hook.state.value.pausedFileTitle, isNull);

      current = telemetry(playing: false, title: null);
      await emit(CallPhase.idle);
      expect(
        ws.sent.map((WsMessage m) => m.action).toList(),
        <String>['PAUSE'],
        reason: 'same-file gate cannot prove identity — never blind-PLAY',
      );
    });

    test('permission denied: amber flag, no subscription, stop() safe',
        () async {
      final CallAutopauseHook hook = await startHook(
        requestPermission: () async => false,
      );
      expect(hook.state.value.permissionGranted, isFalse,
          reason: 'persistent amber notice flag (§7)');
      expect(hook.callActive, isFalse);

      await emit(CallPhase.ringing); // dropped: never subscribed
      expect(ws.sent, isEmpty, reason: 'zero WS calls from a denied hook');
      expect(hook.state.value.phase, CallPhase.idle);

      expect(() => hook.stop(), returnsNormally);
      expect(hook.state.value.permissionGranted, isFalse,
          reason: 'stop() never hides the denial');
      expect(hook.callActive, isFalse);
    });

    test('callActive truth table across phases (Doc 43 gate input)', () async {
      final CallAutopauseHook hook = await startHook();
      expect(hook.callActive, isFalse, reason: 'IDLE');

      await emit(CallPhase.ringing);
      expect(hook.callActive, isTrue, reason: 'RINGING');

      await emit(CallPhase.offhook);
      expect(hook.callActive, isTrue, reason: 'OFFHOOK');

      await emit(CallPhase.idle);
      expect(hook.callActive, isFalse, reason: 'back to IDLE');

      // stop() mid-call forces pass-through re-arm (§3).
      await emit(CallPhase.ringing);
      expect(hook.callActive, isTrue);
      hook.stop();
      expect(hook.callActive, isFalse, reason: 'stop() → false');
    });

    test('enabled toggle: disabled → silence, re-enabled → instant re-arm',
        () async {
      final CallAutopauseHook hook = await startHook();
      hook.enabled = false;
      expect(hook.enabled, isFalse);
      expect(prefs.getBool(kCallAutopauseEnabledPrefKey), isFalse);

      await emit(CallPhase.ringing); // controller broadcasts; nobody listens
      expect(ws.sent, isEmpty);

      hook.enabled = true;
      await pumpEventQueue(); // start() re-subscribes
      expect(hook.enabled, isTrue);
      await emit(CallPhase.ringing);
      expect(ws.sent, hasLength(1), reason: 'toggle works without restart');
      expect(ws.sent.single.action, 'PAUSE');
    });
  });

  group('settings persistence (§8, §10 keys)', () {
    test('defaults: both toggles on when nothing persisted', () async {
      final CallAutopauseHook hook = await startHook();
      expect(hook.enabled, isTrue);
      expect(hook.autoResumeOnHangup, isTrue);
    });

    test('enabled/autoResume persist across an app restart', () async {
      final CallAutopauseHook hook = await startHook();
      hook.enabled = false;
      hook.autoResumeOnHangup = false;
      await pumpEventQueue();

      expect(prefs.getBool(kCallAutopauseEnabledPrefKey), isFalse);
      expect(prefs.getBool(kCallAutoResumePrefKey), isFalse);

      final CallAutopauseHook reloaded = CallAutopauseHook(
        ws: ws,
        telemetry: () => current,
        phoneStates: const Stream<CallPhase>.empty(),
        requestPermission: () async => true,
        haptics: engine,
        preferences: prefs,
      );
      hooks.add(reloaded);
      expect(reloaded.enabled, isFalse);
      expect(reloaded.autoResumeOnHangup, isFalse);
    });
  });
}
