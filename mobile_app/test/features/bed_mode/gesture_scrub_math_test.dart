// Doc 41 §9 — scrub math: delta accumulation, sensitivity multiplier,
// `[0, duration − 500]` clamps, 60 s minute-tick counting (incl. direction
// reversals), and the Doc 30/31 sink split — floored `targetSeconds` for
// the UDP `0x04` stream vs exact `position_ms` for the WS `SEEK` commit.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/bed_mode/blind_gesture_pad.dart';
import 'package:potpilot_remote/network/udp_sender.dart';
import 'package:potpilot_remote/network/ws_client.dart';

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

/// Fake Doc 31 client — captures envelopes, no sockets.
class _FakeWsClient extends WsClient {
  bool connected = true;
  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];

  @override
  WsConnectionState get state =>
      connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(<String, Object?>{'type': type, 'action': action, 'payload': payload});
  }
}

const Size _canvas = Size(400, 800);

PointerDownEvent _down({Offset at = const Offset(100, 400), int t = 0}) =>
    PointerDownEvent(
      position: at,
      timeStamp: Duration(milliseconds: t),
    );

PointerMoveEvent _move({required Offset at, int t = 0}) => PointerMoveEvent(
  position: at,
  timeStamp: Duration(milliseconds: t),
);

PointerUpEvent _up({required Offset at, int t = 0}) => PointerUpEvent(
  position: at,
  timeStamp: Duration(milliseconds: t),
);

void main() {
  late List<HapticPattern> haptics;
  late int? startPositionMs;
  late int durationMs;

  GestureRecognizer makeRecognizer({double sensitivity = 1.0}) {
    return GestureRecognizer(
      startSession: (PointerDownEvent down, GestureMode mode) => GestureSession(
        mode: mode,
        startX: down.localPosition.dx,
        startY: down.localPosition.dy,
        startPositionMs: startPositionMs,
        startVolume: 50,
        startBrightness: 80,
      ),
      durationMs: () => durationMs,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
      sensitivity: sensitivity,
    );
  }

  String? feed(GestureRecognizer recognizer, PointerEvent e) =>
      recognizer.feed(e, canvasSize: _canvas, twoFinger: false);

  int count(HapticPattern pattern) =>
      haptics.where((HapticPattern p) => p == pattern).length;

  setUp(() {
    haptics = <HapticPattern>[];
    startPositionMs = 10000;
    durationMs = 3600000;
  });

  group('scrub preview math (§4.3)', () {
    test('delta accumulates from the session-start anchor', () {
      final GestureRecognizer recognizer = makeRecognizer();
      feed(recognizer, _down(at: const Offset(100, 400)));
      feed(recognizer, _move(at: const Offset(115, 400), t: 50)); // 15 dp
      expect(recognizer.scrubTargetMs, 25000); // 10 s base + 15 dp * 1 s/dp

      feed(recognizer, _move(at: const Offset(130, 400), t: 100)); // net 30
      expect(recognizer.scrubTargetMs, 40000); // from DOWN, not from last move
      expect(recognizer.scrubPreview, '+00:30');
    });

    test('sensitivity multiplier scales media-seconds per dp', () {
      final GestureRecognizer recognizer = makeRecognizer(sensitivity: 2.0);
      feed(recognizer, _down(at: const Offset(100, 400)));
      feed(recognizer, _move(at: const Offset(125, 400), t: 100));
      expect(recognizer.scrubTargetMs, 60000); // 10 s + 25 dp * 2 s/dp
      expect(recognizer.scrubPreview, '+00:50');
    });

    test('clamps to [0, duration − 500]', () {
      durationMs = 60000; // hi bound = 59 500
      final GestureRecognizer recognizer = makeRecognizer();

      // Lower bound: drag past the start of media.
      feed(recognizer, _down(at: const Offset(300, 400)));
      feed(recognizer, _move(at: const Offset(280, 400), t: 100));
      expect(recognizer.scrubTargetMs, 0);
      expect(recognizer.scrubPreview, '\u221200:10');

      recognizer.reset();

      // Upper bound: throw past the overshoot guard.
      feed(recognizer, _down(at: const Offset(100, 400)));
      feed(recognizer, _move(at: const Offset(200, 400), t: 100));
      expect(recognizer.scrubTargetMs, 59500);
      expect(recognizer.scrubPreview, '+00:49');
    });
  });

  group('minute-tick counting (§4.4)', () {
    test('one tick per 60 s boundary; reversal never un-fires or re-fires',
      () {
        final GestureRecognizer recognizer = makeRecognizer();
        feed(recognizer, _down(at: const Offset(100, 400)));

        feed(recognizer, _move(at: const Offset(165, 400), t: 100)); // +65 s
        expect(count(HapticPattern.minuteTick), 1);

        feed(recognizer, _move(at: const Offset(170, 400), t: 200)); // +70 s
        expect(count(HapticPattern.minuteTick), 1); // same boundary

        feed(recognizer, _move(at: const Offset(110, 400), t: 300)); // back
        expect(count(HapticPattern.minuteTick), 1); // resets nothing

        feed(recognizer, _move(at: const Offset(165, 400), t: 400)); // re-cross
        expect(count(HapticPattern.minuteTick), 1); // no re-fire

        // +305 s crosses boundaries 2, 3, 4 and the 5-minute mark.
        feed(recognizer, _move(at: const Offset(405, 400), t: 500));
        expect(count(HapticPattern.minuteTick), 4);
        expect(count(HapticPattern.heavyThud), 1); // 5-minute boundary
      },
    );

    test('drag start/resolution cues stay absent for valid scrubs', () {
      final GestureRecognizer recognizer = makeRecognizer();
      feed(recognizer, _down(at: const Offset(100, 400)));
      feed(recognizer, _move(at: const Offset(150, 400), t: 100));
      feed(recognizer, _up(at: const Offset(150, 400), t: 200));
      expect(count(HapticPattern.doubleTick), 0);
      expect(count(HapticPattern.heavyThud), 0);
    });
  });

  group('Doc 30/31 sink split (§5)', () {
    late _FakeUdpSender udp;
    late _FakeWsClient ws;
    late GestureCommandSink sink;
    late int nowMs;

    const GestureSession session = GestureSession(
      mode: GestureMode.horizontalScrub,
      startX: 100,
      startY: 400,
      startPositionMs: 10000,
      startVolume: 50,
      startBrightness: 80,
    );

    setUp(() {
      udp = _FakeUdpSender();
      ws = _FakeWsClient();
      nowMs = 1000;
      sink = GestureCommandSink(
        ws: ws,
        udp: udp,
        nowMs: () => nowMs,
        durationMs: () => 600000,
      );
    });

    tearDown(() {
      sink.dispose();
    });

    test('streamScrub: integer-second change + ≥16 ms spacing', () {
      sink.streamScrub(30);
      expect(udp.scrubs, <int>[30]);

      sink.streamScrub(30); // same second -> suppressed
      expect(udp.scrubs, <int>[30]);

      sink.streamScrub(31); // second changed but inside the 16 ms window
      expect(udp.scrubs, <int>[30]);

      nowMs += 20;
      sink.streamScrub(31);
      expect(udp.scrubs, <int>[30, 31]);

      sink.streamScrub(31); // already the last sent second
      expect(udp.scrubs, <int>[30, 31]);
    });

    test('commitScrub sends exact position_ms, clamped to duration − 500',
      () {
        sink.commitScrub(session, 31700); // exact ms, no flooring
        expect(ws.sent.single['type'], 'CMD_POTPLAYER');
        expect(ws.sent.single['action'], 'SEEK');
        expect(
          (ws.sent.single['payload']! as Map<String, dynamic>)['position_ms'],
          31700,
        );

        sink.commitScrub(session, 999999); // 600 000 duration -> hi 599 500
        expect(
          (ws.sent.last['payload']! as Map<String, dynamic>)['position_ms'],
          599500,
        );
      },
    );

    test('floored seconds feed UDP while the WS commit keeps milliseconds',
      () {
        final GestureRecognizer recognizer = makeRecognizer(sensitivity: 0.1);
        feed(recognizer, _down(at: const Offset(100, 400)));
        feed(recognizer, _move(at: const Offset(117, 400), t: 100)); // 17 dp
        final int target = recognizer.scrubTargetMs!;
        expect(target, 11700); // 10 000 + 17 dp * 100 ms/dp

        sink.streamScrub(target ~/ 1000); // pad-side flooring
        expect(udp.scrubs, <int>[11]);

        sink.commitScrub(session, target);
        expect(
          (ws.sent.single['payload']! as Map<String, dynamic>)['position_ms'],
          11700,
        );
      },
    );

    test('WS-down drops the release commit, never queues (§7)', () {
      ws.connected = false;
      sink.commitScrub(session, 31700);
      expect(ws.sent, isEmpty);

      // Re-arming still happens so the next drag streams immediately.
      ws.connected = true;
      sink.streamScrub(42);
      expect(udp.scrubs, <int>[42]);
    });
  });
}
