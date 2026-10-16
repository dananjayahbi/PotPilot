// Doc 41 §9 — pure `GestureRecognizer.feed()` traces: mode-discrimination
// table (§4.2), refusal cues (§7), mode lock and rotation cancel. No
// widgets, no sockets — raw `PointerEvent`s with explicit time stamps.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/bed_mode/blind_gesture_pad.dart';

const Size _canvas = Size(400, 800);

PointerDownEvent _down({
  Offset at = const Offset(100, 400),
  int pointer = 1,
  int t = 0,
}) => PointerDownEvent(
  pointer: pointer,
  position: at,
  timeStamp: Duration(milliseconds: t),
);

PointerMoveEvent _move({
  required Offset at,
  int pointer = 1,
  int t = 0,
}) => PointerMoveEvent(
  pointer: pointer,
  position: at,
  timeStamp: Duration(milliseconds: t),
);

PointerUpEvent _up({
  required Offset at,
  int pointer = 1,
  int t = 0,
}) => PointerUpEvent(
  pointer: pointer,
  position: at,
  timeStamp: Duration(milliseconds: t),
);

void main() {
  late List<HapticPattern> haptics;
  late int? startPositionMs;
  late int startVolume;
  late int startBrightness;
  late int durationMs;

  GestureRecognizer makeRecognizer({double sensitivity = 1.0}) {
    return GestureRecognizer(
      startSession: (PointerDownEvent down, GestureMode mode) => GestureSession(
        mode: mode,
        startX: down.localPosition.dx,
        startY: down.localPosition.dy,
        startPositionMs: startPositionMs,
        startVolume: startVolume,
        startBrightness: startBrightness,
      ),
      durationMs: () => durationMs,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
      sensitivity: sensitivity,
    );
  }

  String? feed(
    GestureRecognizer recognizer,
    PointerEvent e, {
    Size size = _canvas,
    bool twoFinger = false,
  }) => recognizer.feed(e, canvasSize: size, twoFinger: twoFinger);

  setUp(() {
    haptics = <HapticPattern>[];
    startPositionMs = 10000;
    startVolume = 50;
    startBrightness = 80;
    durationMs = 3600000;
  });

  test('tap (100 ms, 3 dp) -> tapPlayPause with exactly one heavyThud', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400), t: 0));
    // Nothing decides on touch-down outside the edge zone.
    expect(recognizer.mode, GestureMode.none);

    final String? text = feed(
      recognizer,
      _up(at: const Offset(103, 401), t: 100),
    );
    expect(recognizer.mode, GestureMode.tapPlayPause);
    expect(recognizer.session, isNotNull);
    expect(recognizer.session!.mode, GestureMode.tapPlayPause);
    expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);
    expect(text, isNull); // the pad renders the ▶/⏸ glyph itself
  });

  test('slow 3 s hold then drag -> horizontalScrub (hold-then-drag path)', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400), t: 0));
    feed(recognizer, _move(at: const Offset(130, 400), t: 3000));

    expect(recognizer.mode, GestureMode.horizontalScrub);
    expect(recognizer.refused, isFalse);
    expect(recognizer.scrubTargetMs, 40000); // 10 000 base + 30 dp * 1 s
    expect(recognizer.scrubPreview, '+00:30');
    expect(haptics, isEmpty);
  });

  test('12 dp exact boundary stays indecisive; past it decides', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400)));
    feed(recognizer, _move(at: const Offset(112, 400))); // net exactly 12 dp
    expect(recognizer.mode, GestureMode.none);
    expect(recognizer.session, isNull); // still deciding, not inert-locked

    feed(recognizer, _move(at: const Offset(113, 400))); // net 13 dp
    expect(recognizer.mode, GestureMode.horizontalScrub);
    expect(recognizer.scrubTargetMs, 23000);
  });

  test('right-edge down -> brightness even for horizontal motion', () {
    final GestureRecognizer recognizer = makeRecognizer();
    // Canvas 400 dp wide -> edge zone starts at 372.
    feed(recognizer, _down(at: const Offset(390, 400)));
    expect(recognizer.mode, GestureMode.edgeBrightness);

    final String? text = feed(recognizer, _move(at: const Offset(420, 400)));
    expect(recognizer.mode, GestureMode.edgeBrightness);
    expect(recognizer.brightnessPercent, 80); // pure horizontal: base stands
    expect(text, 'Bright 80%');
    expect(haptics, isEmpty);

    // A quick touch inside the zone is *not* a tap (§8: tap lives outside
    // the 28 dp edge).
    feed(recognizer, _up(at: const Offset(420, 400), t: 90));
    expect(recognizer.mode, GestureMode.edgeBrightness);
    expect(haptics, isEmpty);
  });

  test('two-pointer vertical slide -> twoFingerVolume with volumeTick', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400), pointer: 1));
    feed(
      recognizer,
      _down(at: const Offset(150, 400), pointer: 2),
      twoFinger: true,
    );
    // Nothing decides until net travel passes the slop.
    expect(recognizer.mode, GestureMode.none);

    final String? text = feed(
      recognizer,
      _move(at: const Offset(100, 370), pointer: 1),
      twoFinger: true,
    );
    expect(recognizer.mode, GestureMode.twoFingerVolume);
    expect(recognizer.volumePercent, 65); // 50 - (-30 dp * 0.5)
    expect(text, 'Vol 65%');
    expect(haptics, <HapticPattern>[HapticPattern.volumeTick]);
  });

  test('single-finger vertical swipe is inert (swallowed)', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400)));
    final String? text = feed(recognizer, _move(at: const Offset(100, 460)));

    expect(recognizer.mode, GestureMode.none);
    expect(recognizer.session, isNull);
    expect(text, isNull);

    feed(recognizer, _up(at: const Offset(100, 460), t: 200));
    expect(recognizer.mode, GestureMode.none);
    expect(haptics, isEmpty);
  });

  test('mode lock: mid-scrub second finger never switches; full lift re-arms',
    () {
      final GestureRecognizer recognizer = makeRecognizer();
      feed(recognizer, _down(at: const Offset(100, 400), pointer: 1));
      feed(recognizer, _move(at: const Offset(120, 400), t: 100));
      expect(recognizer.mode, GestureMode.horizontalScrub);
      expect(recognizer.scrubTargetMs, 30000);

      // Second finger lands mid-scrub, then the pair moves vertically.
      feed(
        recognizer,
        _down(at: const Offset(160, 400), pointer: 2),
        twoFinger: true,
      );
      feed(
        recognizer,
        _move(at: const Offset(120, 360), pointer: 1, t: 200),
        twoFinger: true,
      );
      expect(recognizer.mode, GestureMode.horizontalScrub); // still locked
      expect(recognizer.volumePercent, isNull);
      expect(recognizer.scrubTargetMs, 30000); // dy never feeds the scrub

      // Primary lifts first: state held for the pad's last-lift finalize.
      feed(recognizer, _up(at: const Offset(120, 360), pointer: 1, t: 300));
      expect(recognizer.mode, GestureMode.horizontalScrub);
      feed(recognizer, _up(at: const Offset(160, 400), pointer: 2, t: 320));
      expect(recognizer.mode, GestureMode.horizontalScrub);

      // Only a full lift re-arms the pad.
      recognizer.reset();
      expect(recognizer.mode, GestureMode.none);
      expect(recognizer.session, isNull);
      feed(recognizer, _down(at: const Offset(200, 500), t: 400));
      feed(recognizer, _up(at: const Offset(201, 501), t: 450));
      expect(recognizer.mode, GestureMode.tapPlayPause);
      expect(
        haptics,
        <HapticPattern>[HapticPattern.heavyThud],
      );
    },
  );

  test('rotation/resize mid-session cancels without commit state', () {
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400)));
    feed(recognizer, _move(at: const Offset(140, 400), t: 100));
    expect(recognizer.mode, GestureMode.horizontalScrub);

    // Same event stream, rotated canvas -> session dropped, no leftovers.
    final String? text = feed(
      recognizer,
      _move(at: const Offset(180, 400), t: 200),
      size: const Size(800, 400),
    );
    expect(text, isNull);
    expect(recognizer.mode, GestureMode.none);
    expect(recognizer.session, isNull);
    expect(recognizer.scrubTargetMs, isNull); // nothing left to commit

    feed(recognizer, _up(at: const Offset(180, 400), t: 250));
    expect(recognizer.mode, GestureMode.none);
    expect(haptics, isEmpty);
  });

  test('stale scrub base refuses with doubleTick and no preview (§7)', () {
    startPositionMs = null; // stale telemetry -> pad passes a null base
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400)));
    final String? text = feed(recognizer, _move(at: const Offset(150, 400)));

    expect(recognizer.mode, GestureMode.horizontalScrub);
    expect(recognizer.refused, isTrue);
    expect(recognizer.scrubTargetMs, isNull);
    expect(recognizer.scrubPreview, isNull);
    expect(text, isNull);
    expect(haptics, <HapticPattern>[HapticPattern.doubleTick]);

    feed(recognizer, _up(at: const Offset(200, 400), t: 300));
    expect(recognizer.scrubTargetMs, isNull); // zero packets downstream
  });

  test('zero-duration media refuses the scrub (§7)', () {
    durationMs = 0;
    final GestureRecognizer recognizer = makeRecognizer();
    feed(recognizer, _down(at: const Offset(100, 400)));
    feed(recognizer, _move(at: const Offset(150, 400)));

    expect(recognizer.mode, GestureMode.horizontalScrub);
    expect(recognizer.refused, isTrue);
    expect(haptics, <HapticPattern>[HapticPattern.doubleTick]);
  });

  test('unsupported brightness refuses the edge gesture immediately (§7)', () {
    startBrightness = kBrightnessUnknown;
    final GestureRecognizer recognizer = makeRecognizer();
    // Refusal lands at touch-down — before any movement, before any send.
    feed(recognizer, _down(at: const Offset(390, 400)));
    expect(recognizer.mode, GestureMode.edgeBrightness);
    expect(recognizer.refused, isTrue);
    expect(haptics, <HapticPattern>[HapticPattern.doubleTick]);

    final String? text = feed(recognizer, _move(at: const Offset(390, 340)));
    expect(text, isNull);
    expect(recognizer.brightnessPercent, isNull);
  });

  test('two-finger tap never fires PLAY_PAUSE (multi-touch vetoes the tap)',
    () {
      final GestureRecognizer recognizer = makeRecognizer();
      feed(recognizer, _down(at: const Offset(100, 400), pointer: 1, t: 0));
      feed(
        recognizer,
        _down(at: const Offset(140, 400), pointer: 2, t: 20),
        twoFinger: true,
      );
      feed(recognizer, _up(at: const Offset(100, 400), pointer: 1, t: 60));
      expect(recognizer.mode, GestureMode.none);
      expect(haptics, isEmpty);
    },
  );
}
