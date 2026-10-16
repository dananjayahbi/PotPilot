// Doc 41 §9 — widget tests for [BlindGesturePad]: mock Doc 30/31/42 sinks
// + fake telemetry (no real network, no real vibration). Covers the
// acceptance table: tap envelope, UDP stream + frozen SEEK commit, throttled
// SET_VOLUME with trailing final, right-edge SET_BRIGHTNESS via the shared
// Doc 40 builder, refusals, mode lock, and the transient OSD layer.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/bed_mode/blind_gesture_pad.dart';
import 'package:potpilot_remote/features/display/monitor_power_sheet.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/udp_sender.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake Doc 31 client — captures envelopes, no sockets.
class _FakeWsClient extends WsClient {
  _FakeWsClient({bool connected = true}) : _connected = connected;

  bool _connected;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();
  final StreamController<WsMessage> _replies =
      StreamController<WsMessage>.broadcast();

  @override
  WsConnectionState get state =>
      _connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  @override
  Stream<WsEnvelope> get envelopes => _replies.stream;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(<String, Object?>{'type': type, 'action': action, 'payload': payload});
  }

  List<Map<String, Object?>> action(String name) =>
      sent.where((Map<String, Object?> e) => e['action'] == name).toList();

  void setConnected(bool value) {
    _connected = value;
    _states.add(state);
  }

  Future<void> close() async {
    await _states.close();
    await _replies.close();
  }
}

/// In-memory [UdpSender] — records `0x04` second targets; opens no sockets.
class _FakeUdpSender implements UdpSender {
  final List<int> scrubs = <int>[];

  @override
  Future<void> configure({
    String host = '',
    String tokenHex = '',
    int port = 0,
  }) async {}

  @override
  bool get isReady => true;

  @override
  int get sequence => 0;

  @override
  set sequence(int value) {}

  @override
  int get droppedCount => 0;

  @override
  int get ioErrorCount => 0;

  @override
  int get authByte => 0;

  @override
  void Function(Uint8List bytes)? sendSink;

  @override
  void sendMove(int dx, int dy) {}

  @override
  void sendScroll(int verticalDelta, int horizontalDelta) {}

  @override
  void sendButton(int buttonId, int action) {}

  @override
  void sendScrub(int targetSeconds) => scrubs.add(targetSeconds);

  @override
  void flush() {}

  @override
  Future<void> close() async {}
}

class _SilentVibrationPort implements VibrationPort {
  @override
  bool get isSupported => true;

  @override
  Future<void> vibrate({
    required List<int> timingsMs,
    required List<int> amplitudes,
  }) async {}

  @override
  Future<void> cancel() async {}
}

/// Doc 42 seam — records pattern plays and scrub-pulse toggles, never
/// vibrates.
class _FakeHapticEngine extends HapticEngine {
  _FakeHapticEngine(SharedPreferences preferences)
    : super(port: _SilentVibrationPort(), preferences: preferences);

  final List<HapticPattern> played = <HapticPattern>[];
  int pulseStarts = 0;
  int pulseStops = 0;

  @override
  Future<void> play(HapticPattern pattern, {int repeat = 1}) async {
    played.add(pattern);
  }

  @override
  void startScrubPulse({
    Duration interval = const Duration(milliseconds: 120),
  }) {
    pulseStarts += 1;
  }

  @override
  void stopScrubPulse() {
    pulseStops += 1;
  }
}

/// Fake telemetry socket — frames pushed via `notifier.handleEnvelope`.
class _FakeSocket implements TelemetrySocket {
  final StreamController<WsMessage> _envelopes =
      StreamController<WsMessage>.broadcast();
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();

  @override
  Stream<WsMessage> get envelopes => _envelopes.stream;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  Future<void> close() async {
    await _envelopes.close();
    await _states.close();
  }
}

void main() {
  late _FakeWsClient ws;
  late _FakeUdpSender udp;
  late _FakeHapticEngine engine;
  late _FakeSocket socket;
  late TelemetryNotifier notifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    ws = _FakeWsClient();
    udp = _FakeUdpSender();
    engine = _FakeHapticEngine(preferences);
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
  });

  tearDown(() async {
    await socket.close();
    await ws.close();
  });

  int futureTs() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30; // load-proof

  void push({
    int positionMs = 10000,
    int durationMs = 600000,
    int volume = 50,
    Object? brightness = 80,
    bool isPlaying = true,
    int? timestamp,
  }) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000041',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: <String, dynamic>{
          'position_ms': positionMs,
          'duration_ms': durationMs,
          'is_playing': isPlaying,
          'speed': 1.0,
          'volume': volume,
          'file_title': 'Interstellar',
          'brightness': brightness,
        },
        timestamp: timestamp ?? futureTs(),
      ),
    );
  }

  List<Override> overrides() => <Override>[
    telemetryProvider.overrideWith((ref) => notifier),
    hapticEngineProvider.overrideWithValue(engine),
    gestureCommandSinkProvider.overrideWithValue(
      GestureCommandSink(
        ws: ws,
        udp: udp,
        durationMs: () => 600000,
      ),
    ),
  ];

  Future<void> pumpPad(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(body: BlindGesturePad()),
        ),
      ),
    );
    await tester.pump();
  }

  TestGesture touch(WidgetTester tester, int pointer) =>
      TestGesture(dispatcher: tester.sendEventToBinding, pointer: pointer);

  List<int> percents(String action) => ws
      .action(action)
      .map(
        (Map<String, Object?> e) =>
            (e['payload']! as Map<String, dynamic>)['percent']! as int,
      )
      .toList();

  testWidgets(
    'single tap -> exactly one PLAY_PAUSE + heavyThud + glyph flash',
    (WidgetTester tester) async {
      push();
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(400, 300));
      await gesture.up();
      await tester.pump();

      final List<Map<String, Object?>> taps = ws.action('PLAY_PAUSE');
      expect(taps, hasLength(1)); // exactly one envelope
      expect(taps.single['type'], 'CMD_POTPLAYER');
      expect(taps.single['payload'], <String, dynamic>{});
      expect(engine.played, <HapticPattern>[HapticPattern.heavyThud]);

      // Glyph flash: playing -> tap pauses -> ⏸, auto-hides after 1.2 s.
      expect(find.text('\u23f9'), findsOneWidget);
      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
      expect(find.byKey(const Key('blind_gesture_osd')), findsNothing);
    },
  );

  testWidgets(
    'horizontal drag streams UDP 0x04, commits exactly one SEEK on lift',
    (WidgetTester tester) async {
      push(positionMs: 10000, durationMs: 600000);
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(200, 300));
      await gesture.moveBy(const Offset(40, 0)); // lock + first UDP packet
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveBy(const Offset(60, 0)); // net 160 dp = 160 media-s
      await tester.pump();

      expect(udp.scrubs, isNotEmpty); // ≥ 1 packet during the drag
      expect(udp.scrubs.first, 50); // 10 s base + 40 dp, floored seconds
      expect(find.text('+02:40'), findsOneWidget); // live scrub preview OSD
      expect(engine.pulseStarts, 1); // scrubPulse for the whole drag

      await gesture.up();
      await tester.pump();

      expect(engine.pulseStops, 1); // stopped on lift
      final List<Map<String, Object?>> seeks = ws.action('SEEK');
      expect(seeks, hasLength(1)); // one frozen millisecond commit
      expect(seeks.single['type'], 'CMD_POTPLAYER');
      expect(
        (seeks.single['payload']! as Map<String, dynamic>)['position_ms'],
        170000, // 10 000 + 160 dp * 1000 ms, clamped inside [0, 599 500]
      );
      // 160 media-seconds crossed exactly two 60 s boundaries.
      expect(
        engine.played.where((HapticPattern p) => p == HapticPattern.minuteTick),
        hasLength(2),
      );
      expect(
        engine.played.where((HapticPattern p) => p == HapticPattern.heavyThud),
        isEmpty,
      );

      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'two-finger vertical slide -> throttled SET_VOLUME with trailing final',
    (WidgetTester tester) async {
      push(volume: 50);
      await pumpPad(tester);

      final TestGesture first = touch(tester, 1);
      final TestGesture second = touch(tester, 2);
      await first.down(const Offset(380, 300));
      await second.down(const Offset(430, 300));
      await first.moveBy(const Offset(0, -40)); // 50 + 20 = 70
      await tester.pump();
      expect(find.text('Vol 70%'), findsOneWidget);

      // Movement -> packet within the 100 ms window.
      await tester.pump(kVolumeThrottle);
      expect(percents('SET_VOLUME'), <int>[70]);

      // Inside a window the latest value wins (no mid-window packet).
      await first.moveBy(const Offset(0, -10)); // 75
      await tester.pump(const Duration(milliseconds: 50));
      expect(percents('SET_VOLUME'), <int>[70]);

      // Lift before the window closes: the trailing send delivers 75.
      await first.up();
      await second.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(percents('SET_VOLUME'), <int>[70, 75]);

      expect(
        engine.played
            .where((HapticPattern p) => p == HapticPattern.volumeTick),
        hasLength(2), // 50->70 and 70->75 each crossed a 5 % gridline
      );
      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'stale telemetry -> scrub refused with doubleTick, zero packets',
    (WidgetTester tester) async {
      // Doc 33 staleness clock: frame 10 s old -> stale (§5/§7).
      push(timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 10);
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(200, 300));
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();

      expect(udp.scrubs, isEmpty); // no blind commit to an unknown position
      expect(ws.action('SEEK'), isEmpty);
      expect(engine.pulseStarts, 0);
      expect(engine.played, contains(HapticPattern.doubleTick));
      expect(find.byKey(const Key('blind_gesture_osd')), findsNothing);

      await gesture.up();
      await tester.pump();
      expect(udp.scrubs, isEmpty);
      expect(ws.action('SEEK'), isEmpty);
      expect(engine.pulseStops, 0);
    },
  );

  testWidgets(
    'OSD tracks the scrub preview and hides 1.2 s after the last event',
    (WidgetTester tester) async {
      push();
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(200, 300));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(find.text('+00:40'), findsOneWidget);

      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(find.text('+01:40'), findsOneWidget); // updates live

      await gesture.up();
      await tester.pump();
      expect(find.text('+01:40'), findsOneWidget); // lingers after lift

      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
      expect(find.byKey(const Key('blind_gesture_osd')), findsNothing);
    },
  );

  testWidgets(
    'stale frames prefix the OSD with ? but volume still works (§5/§7)',
    (WidgetTester tester) async {
      push(volume: 50, timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3);
      await pumpPad(tester);

      final TestGesture first = touch(tester, 1);
      final TestGesture second = touch(tester, 2);
      await first.down(const Offset(380, 300));
      await second.down(const Offset(430, 300));
      await first.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(find.text('?Vol 70%'), findsOneWidget); // staleness prefix

      await tester.pump(kVolumeThrottle);
      expect(percents('SET_VOLUME'), <int>[70]); // cache-based volume works

      await first.up();
      await second.up();
      await tester.pump(kVolumeThrottle + const Duration(milliseconds: 50));
      expect(percents('SET_VOLUME'), <int>[70]); // deduped, no duplicate
      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'single-finger vertical swipe is inert — no commands fire',
    (WidgetTester tester) async {
      push();
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(400, 300));
      await gesture.moveBy(const Offset(0, 80));
      await gesture.up();
      await tester.pump(
        kVolumeThrottle + kBrightnessThrottle + const Duration(milliseconds: 50),
      );

      expect(ws.sent, isEmpty);
      expect(udp.scrubs, isEmpty);
      expect(engine.played, isEmpty);
      expect(find.byKey(const Key('blind_gesture_osd')), findsNothing);
    },
  );

  testWidgets(
    'mode lock: mid-scrub second finger never switches to volume; full lift re-arms',
    (WidgetTester tester) async {
      push();
      await pumpPad(tester);

      final TestGesture first = touch(tester, 1);
      final TestGesture second = touch(tester, 2);
      await first.down(const Offset(200, 300));
      await first.moveBy(const Offset(40, 0)); // scrub locks
      await second.down(const Offset(250, 300)); // mid-scrub second finger
      await second.moveBy(const Offset(0, -50)); // extra pointer: ignored
      await first.moveBy(const Offset(0, -50)); // primary: still scrubbing
      await tester.pump(
        kVolumeThrottle + const Duration(milliseconds: 50),
      );

      expect(ws.action('SET_VOLUME'), isEmpty); // mode never switched

      await first.up();
      await second.up();
      await tester.pump();
      expect(ws.action('SEEK'), hasLength(1)); // single scrub commit

      // Only a full lift re-arms the pad — a tap fires again.
      final TestGesture third = touch(tester, 3);
      await third.down(const Offset(400, 300));
      await third.up();
      await tester.pump();
      expect(ws.action('PLAY_PAUSE'), hasLength(1));

      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'right-edge slide -> SET_BRIGHTNESS via the Doc 40 builder (200 ms + trailing)',
    (WidgetTester tester) async {
      push(brightness: 80);
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(790, 300)); // >= width - 28 dp
      await gesture.moveBy(const Offset(0, -20)); // 80 + 10 = 90
      await gesture.up(); // lift inside the throttle window

      await tester.pump(kBrightnessThrottle);
      expect(percents('SET_BRIGHTNESS'), <int>[90]); // one throttled packet
      final Map<String, Object?> envelope = ws.action('SET_BRIGHTNESS').single;
      expect(envelope['type'], 'CMD_SYSTEM');
      expect(envelope['payload'], <String, dynamic>{'percent': 90});
      expect(ws.action('PLAY_PAUSE'), isEmpty); // edge tap is not a tap
      expect(
        engine.played
            .where((HapticPattern p) => p == HapticPattern.microTick),
        hasLength(1), // 80 -> 90 crossed a 10 % detent
      );

      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );

  testWidgets(
    'brightness null in telemetry -> edge gesture refuses immediately (§7)',
    (WidgetTester tester) async {
      push(brightness: null); // Doc 03: DDC/CI unsupported
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(790, 300));
      await tester.pump();
      // Refusal cue lands at touch-down — before any movement.
      expect(engine.played, contains(HapticPattern.doubleTick));

      await gesture.moveBy(const Offset(0, -40));
      await gesture.up();
      await tester.pump(
        kBrightnessThrottle + const Duration(milliseconds: 50),
      );
      expect(ws.action('SET_BRIGHTNESS'), isEmpty); // no doomed calls
      expect(ws.sent, isEmpty);
      expect(engine.pulseStarts, 0);
    },
  );

  testWidgets(
    'disconnect mid-gesture: OSD shows !, commit dropped, doubleTick on lift',
    (WidgetTester tester) async {
      push();
      await pumpPad(tester);

      final TestGesture gesture = touch(tester, 1);
      await gesture.down(const Offset(200, 300));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(udp.scrubs, isNotEmpty); // UDP stream runs while the socket lives

      ws.setConnected(false); // WS drops mid-drag
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(find.text('!+01:20'), findsOneWidget); // disconnect prefix (§7)

      await gesture.up();
      await tester.pump();
      expect(ws.action('SEEK'), isEmpty); // dropped, never queued
      expect(engine.played, contains(HapticPattern.doubleTick)); // miss cue

      await tester.pump(kOsdHideDelay + const Duration(milliseconds: 50));
    },
  );
}
