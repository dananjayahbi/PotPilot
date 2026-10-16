import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/deck/potplayer_deck.dart';
import 'package:potpilot_remote/features/hud/scrub_speed_hud.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Fake Doc 31 client — captures one fresh-uuid envelope per send.
class _FakeWsClient extends WsClient {
  bool _connected = true;

  final List<WsMessage> sent = <WsMessage>[];
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
  Stream<WsMessage> get envelopes => _replies.stream;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(buildMessage(type: type, action: action, payload: payload));
  }

  Future<void> close() async {
    await _states.close();
    await _replies.close();
  }
}

TelemetryState _state({
  double speed = 1.0,
  bool isPlaying = false,
  int durationMs = 600000,
}) {
  return TelemetryState(
    timestamp: 1000,
    positionMs: 300000,
    durationMs: durationMs,
    isPlaying: isPlaying,
    speed: speed,
    potPlayerVolume: 42,
    fileTitle: 'Interstellar',
    extras: const <String, Object?>{},
    isConnected: true,
  );
}

void main() {
  late _FakeWsClient client;
  late PotPlayerDeckController controller;
  late List<HapticPattern> haptics;
  late int nowMs;

  setUp(() {
    client = _FakeWsClient();
    haptics = <HapticPattern>[];
    nowMs = 5000;
    controller = PotPlayerDeckController(
      client: client,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
      nowMs: () => nowMs,
    );
  });

  tearDown(() async {
    controller.dispose();
    await client.close();
  });

  group('stepSpeed (§4.3 arithmetic)', () {
    test('1.0 + 0.1 -> 1.1 stays on the 0.1 grid', () {
      expect(controller.stepSpeed(1.0, 0.1), 1.1);
    });

    test('4.0 + 0.1 clamps to 4.0', () {
      expect(controller.stepSpeed(4.0, 0.1), 4.0);
    });

    test('0.2 - 0.1 clamps to 0.2', () {
      expect(controller.stepSpeed(0.2, -0.1), 0.2);
    });

    test('1.35 display rounding -> single decimal', () {
      expect(formatSpeed(1.35), '1.4');
      expect(formatSpeed(1.4000000000000001), '1.4');
      expect(formatSpeed(2), '2.0');
    });

    test('repeated ±0.1 x30 stays on the 0.1 grid (and inside bounds)', () {
      double up = 1.0;
      for (int i = 0; i < 30; i++) {
        up = controller.stepSpeed(up, 0.1);
        final double tenths = up * 10;
        expect(tenths - tenths.roundToDouble(), 0.0,
            reason: 'up-step $i drifted off grid: $up');
      }
      expect(up, 4.0); // clamped at the PotPlayer bound

      double down = 1.0;
      for (int i = 0; i < 30; i++) {
        down = controller.stepSpeed(down, -0.1);
        final double tenths = down * 10;
        expect(tenths - tenths.roundToDouble(), 0.0,
            reason: 'down-step $i drifted off grid: $down');
      }
      expect(down, 0.2);
    });
  });

  group('dispatch (§5 payloads + §4.2 pipeline)', () {
    test('SET_SPEED carries the absolute computed multiplier, not a delta',
        () async {
      await controller.dispatch(DeckAction.speedUp, _state(speed: 2.0));
      expect(client.sent, hasLength(1));
      expect(client.sent.single.action, 'SET_SPEED');
      expect(client.sent.single.payload, <String, dynamic>{'multiplier': 2.1});

      client.sent.clear();
      await controller.dispatch(DeckAction.speedDown, _state(speed: 2.0));
      expect(client.sent.single.payload, <String, dynamic>{'multiplier': 1.9});

      client.sent.clear();
      await controller.dispatch(DeckAction.speedReset, _state(speed: 2.0));
      expect(client.sent.single.payload, <String, dynamic>{'multiplier': 1.0});
    });

    test('aspectCycle sends CYCLE_ASPECT_RATIO with no payload; frame keys '
        'send FRAME_STEP with direction', () async {
      // ASPECT reporting: exact wire literals (not deckActionNames lookups)
      // so a wrong mapping entry or a frame-branch fall-through fails loudly.
      await controller.dispatch(DeckAction.aspectCycle, _state());
      expect(client.sent, hasLength(1));
      expect(client.sent.single.type, 'CMD_POTPLAYER');
      expect(client.sent.single.action, 'CYCLE_ASPECT_RATIO');
      expect(client.sent.single.payload, <String, dynamic>{});

      client.sent.clear();
      await controller.dispatch(DeckAction.frameNext, _state());
      expect(client.sent.single.type, 'CMD_POTPLAYER');
      expect(client.sent.single.action, 'FRAME_STEP');
      expect(client.sent.single.payload, <String, dynamic>{
        'direction': 'FORWARD',
      });

      client.sent.clear();
      await controller.dispatch(DeckAction.framePrev, _state());
      expect(client.sent.single.type, 'CMD_POTPLAYER');
      expect(client.sent.single.action, 'FRAME_STEP');
      expect(client.sent.single.payload, <String, dynamic>{
        'direction': 'BACKWARD',
      });
    });

    test('debounce: two taps within 80 ms -> one send, third goes through',
        () async {
      await controller.dispatch(DeckAction.playPause, _state());
      expect(client.sent, hasLength(1));

      nowMs += 40; // inside the window — dropped (last-tap-wins)
      await controller.dispatch(DeckAction.playPause, _state());
      expect(client.sent, hasLength(1));

      nowMs += 40; // 80 ms since the accepted tap — allowed
      await controller.dispatch(DeckAction.playPause, _state());
      expect(client.sent, hasLength(2));
    });

    test('haptic mapping: play/pause thud, reset double-tick, rest tick',
        () async {
      await controller.dispatch(DeckAction.playPause, _state());
      expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);

      await controller.dispatch(DeckAction.speedReset, _state(speed: 2.0));
      expect(haptics, <HapticPattern>[
        HapticPattern.heavyThud,
        HapticPattern.doubleTick,
      ]);

      await controller.dispatch(DeckAction.seekFwd5, _state());
      expect(haptics, <HapticPattern>[
        HapticPattern.heavyThud,
        HapticPattern.doubleTick,
        HapticPattern.microTick,
      ]);
    });

    test('offline WS (Doc 31 state != connected) dispatches nothing', () async {
      client._connected = false;
      await controller.dispatch(DeckAction.playPause, _state());
      expect(client.sent, isEmpty);
      expect(haptics, isEmpty);
      expect(controller.isConnected, isFalse);
    });

    test('speed gates: unknown base and bound-adjacent keys send nothing',
        () async {
      // speed never received (0.0 = unknown) — no haptic, no envelope.
      await controller.dispatch(DeckAction.speedUp, _state(speed: 0.0));
      await controller.dispatch(DeckAction.speedReset, _state(speed: 0.0));
      expect(client.sent, isEmpty);
      expect(haptics, isEmpty);

      // At 1.0x the reset is a no-op; at 4.0x the up key is bound-adjacent.
      await controller.dispatch(DeckAction.speedReset, _state(speed: 1.0));
      await controller.dispatch(DeckAction.speedUp, _state(speed: 4.0));
      await controller.dispatch(DeckAction.speedDown, _state(speed: 0.2));
      expect(client.sent, isEmpty);
      expect(haptics, isEmpty);
    });

    test('playPause flips optimistic state; telemetry reconciles it', () async {
      final TelemetryState paused = _state(isPlaying: false);
      await controller.dispatch(DeckAction.playPause, paused);
      expect(controller.optimisticPlaying, isTrue);

      // Same snapshot (no frame yet) — optimistic flag survives rebuilds.
      controller.reconcile(paused);
      expect(controller.optimisticPlaying, isTrue);

      // A new frame wins — telemetry is authoritative (§4.4).
      controller.reconcile(_state(isPlaying: true));
      expect(controller.optimisticPlaying, isNull);
    });

    test('each envelope carries a fresh uuid4 id', () async {
      await controller.dispatch(DeckAction.seekFwd5, _state());
      await controller.dispatch(DeckAction.seekBack5, _state());
      expect(client.sent, hasLength(2));
      final RegExp uuid4 = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      );
      expect(client.sent[0].id, matches(uuid4));
      expect(client.sent[1].id, matches(uuid4));
      expect(client.sent[0].id, isNot(client.sent[1].id));
    });
  });
}
