// Doc 35 §9 — gesture → packet emission tests: fake `UdpSender` recording
// API-level calls (no real sockets) + `HapticHooks` spies + timestamped
// `TestGesture`s driving the full state machine.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/features/trackpad/virtual_trackpad.dart';
import 'package:potpilot_remote/network/udp_sender.dart';

typedef _Button = ({int button, int action});
typedef _Move = ({int dx, int dy});
typedef _Scroll = ({int vertical, int horizontal});

/// In-memory [UdpSender] — records API-level calls; opens no sockets.
class _FakeSender implements UdpSender {
  final List<_Button> buttons = <_Button>[];
  final List<_Move> moves = <_Move>[];
  final List<_Scroll> scrolls = <_Scroll>[];

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
  void sendMove(int dx, int dy) => moves.add((dx: dx, dy: dy));

  @override
  void sendScroll(int verticalDelta, int horizontalDelta) =>
      scrolls.add((vertical: verticalDelta, horizontal: horizontalDelta));

  @override
  void sendButton(int buttonId, int action) =>
      buttons.add((button: buttonId, action: action));

  @override
  void sendScrub(int targetSeconds) {}

  @override
  void flush() {}

  @override
  Future<void> close() async {}
}

/// Records [HapticHooks] invocations in order.
class _HapticSpy {
  final List<String> calls = <String>[];

  HapticHooks get hooks => HapticHooks(
    tapClick: () => calls.add('tapClick'),
    dragStart: () => calls.add('dragStart'),
    dragEnd: () => calls.add('dragEnd'),
    rightClick: () => calls.add('rightClick'),
    scrollTick: (double intensity) => calls.add('scrollTick'),
  );
}

Duration _ms(int milliseconds) => Duration(milliseconds: milliseconds);

TestGesture _touch(WidgetTester tester, int pointer) =>
    TestGesture(dispatcher: tester.sendEventToBinding, pointer: pointer);

void main() {
  late _FakeSender sender;
  late _HapticSpy haptics;

  setUp(() {
    sender = _FakeSender();
    haptics = _HapticSpy();
  });

  Future<void> pumpPad(WidgetTester tester, {TrackpadProfile? profile}) {
    return tester.pumpWidget(
      VirtualTrackpad(
        sender: sender,
        profile: profile ?? const TrackpadProfile(),
        haptics: haptics.hooks,
      ),
    );
  }

  group('tap recognition', () {
    testWidgets('quick tap emits exactly one (left, click)', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);
      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.up(timeStamp: _ms(60));

      expect(sender.buttons, <_Button>[(button: 1, action: 3)]);
      expect(sender.moves, isEmpty);
      expect(sender.scrolls, isEmpty);
      expect(haptics.calls, <String>['tapClick']);
    });

    testWidgets('slow release reaches the PC as a hold (down + up)', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);
      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.up(timeStamp: _ms(250)); // > kTapMaxDuration (180 ms)

      expect(sender.buttons, <_Button>[
        (button: 1, action: 1),
        (button: 1, action: 2),
      ]);
      expect(haptics.calls, isEmpty);
    });
  });

  group('drag abort', () {
    testWidgets('40 px move then release: zero buttons, at least one move', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);
      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.moveBy(const Offset(40, 0), timeStamp: _ms(16));
      await finger.up(timeStamp: _ms(200));

      expect(sender.buttons, isEmpty);
      expect(sender.moves, isNotEmpty);
      expect(sender.scrolls, isEmpty);
    });
  });

  group('double-tap-and-hold drag lock', () {
    testWidgets('hold produces exactly one down and one up, moves in between', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);

      // First tap → click.
      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.up(timeStamp: _ms(50));
      // Second tap held past kDoubleTapHoldMs (250 ms) → drag lock.
      await finger.down(const Offset(200, 300), timeStamp: _ms(300));
      await tester.pump(_ms(260)); // fires the hold timer

      expect(sender.buttons, <_Button>[
        (button: 1, action: 3),
        (button: 1, action: 1),
      ]);

      await finger.moveBy(const Offset(30, 10), timeStamp: _ms(600));
      await finger.up(timeStamp: _ms(650));

      expect(sender.buttons, <_Button>[
        (button: 1, action: 3),
        (button: 1, action: 1),
        (button: 1, action: 2),
      ]);
      expect(sender.moves, isNotEmpty);
      expect(haptics.calls, <String>['tapClick', 'dragStart', 'dragEnd']);
    });

    testWidgets('quick double-tap: two clicks and no down/up pair', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);

      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.up(timeStamp: _ms(50));
      await finger.down(const Offset(200, 300), timeStamp: _ms(150));
      await finger.up(timeStamp: _ms(200)); // quick second release

      expect(sender.buttons, <_Button>[
        (button: 1, action: 3),
        (button: 1, action: 3),
      ]);
      expect(haptics.calls, <String>['tapClick', 'tapClick']);
    });
  });

  group('two-finger right-click', () {
    testWidgets('two-finger tap: one (2, 3) and no left leakage', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture first = _touch(tester, 1);
      final TestGesture second = _touch(tester, 2);

      await first.down(const Offset(200, 300), timeStamp: _ms(0));
      await second.down(const Offset(200, 320), timeStamp: _ms(30)); // fused
      await second.up(timeStamp: _ms(120));
      await first.up(timeStamp: _ms(150)); // ≤ kTwoFingerTapMaxMs (250)

      expect(sender.buttons, <_Button>[(button: 2, action: 3)]);
      expect(sender.scrolls, isEmpty);
      expect(sender.moves, isEmpty);
      expect(haptics.calls, <String>['rightClick']);
    });
  });

  group('two-finger scroll', () {
    testWidgets('slide up: positive wheel ticks, no clicks', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture first = _touch(tester, 1);
      final TestGesture second = _touch(tester, 2);

      await first.down(const Offset(200, 300), timeStamp: _ms(0));
      await second.down(const Offset(200, 320), timeStamp: _ms(30));
      // Finger-up travel: 30 px each ⇒ natural direction = positive wheel.
      await first.moveBy(const Offset(0, -30), timeStamp: _ms(50));
      await second.moveBy(const Offset(0, -30), timeStamp: _ms(66));
      // Lifts well after the last motion ⇒ no inertia coast.
      await second.up(timeStamp: _ms(300));
      await first.up(timeStamp: _ms(320));

      expect(sender.scrolls, <_Scroll>[
        (vertical: 1, horizontal: 0),
        (vertical: 2, horizontal: 0),
      ]);
      expect(sender.buttons, isEmpty);
      expect(haptics.calls, <String>['scrollTick']); // one direction edge
    });

    testWidgets('sub-threshold drift emits no packets', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture first = _touch(tester, 1);
      final TestGesture second = _touch(tester, 2);

      await first.down(const Offset(200, 300), timeStamp: _ms(0));
      await second.down(const Offset(200, 320), timeStamp: _ms(30));
      // 12 px total travel engages scroll but stays below one wheel tick.
      await first.moveBy(const Offset(0, 6), timeStamp: _ms(100));
      await second.moveBy(const Offset(0, 6), timeStamp: _ms(116));
      await second.up(timeStamp: _ms(400));
      await first.up(timeStamp: _ms(420));

      expect(sender.scrolls, isEmpty);
      expect(sender.buttons, isEmpty);
      expect(haptics.calls, isEmpty);
    });
  });

  group('inertia', () {
    // Scripted flick: 60 px / 16 ms per finger ⇒ lift with v ≈ 2.4 px/ms.
    Future<void> flickAndLift(WidgetTester tester) async {
      final TestGesture first = _touch(tester, 1);
      final TestGesture second = _touch(tester, 2);
      await first.down(const Offset(200, 400), timeStamp: _ms(0));
      await second.down(const Offset(200, 420), timeStamp: _ms(30));
      await first.moveBy(const Offset(0, -60), timeStamp: _ms(46));
      await second.moveBy(const Offset(0, -60), timeStamp: _ms(62));
      await second.up(timeStamp: _ms(70));
      await first.up(timeStamp: _ms(78));
    }

    testWidgets('flick coasts with decaying scrolls, then terminates', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      await flickAndLift(tester);

      final int atLift = sender.scrolls.length;
      expect(atLift, 2); // one packet per fused move

      for (int i = 0; i < 80; i++) {
        await tester.pump(_ms(16)); // ~1.28 s of coast (floor ≈ 63 ticks)
      }

      final List<_Scroll> coast = sender.scrolls.sublist(atLift);
      expect(coast.length, greaterThanOrEqualTo(3));
      expect(coast.every((_Scroll s) => s.vertical > 0), isTrue);
      expect(coast.last.vertical, lessThanOrEqualTo(coast.first.vertical));

      // Terminates: no packets once |v| drops below kInertiaMinVelocity.
      final int settled = sender.scrolls.length;
      for (int i = 0; i < 20; i++) {
        await tester.pump(_ms(16));
      }
      expect(sender.scrolls.length, settled);
    });

    testWidgets('new touch cancels the coast immediately', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      await flickAndLift(tester);

      await tester.pump(_ms(16));
      await tester.pump(_ms(16));
      final int before = sender.scrolls.length;
      expect(before, greaterThan(2));

      final TestGesture interrupt = _touch(tester, 3);
      await interrupt.down(const Offset(400, 300), timeStamp: _ms(100));
      for (int i = 0; i < 20; i++) {
        await tester.pump(_ms(16));
      }
      expect(sender.scrolls.length, before); // immediate, permanent stop

      await interrupt.up(timeStamp: _ms(150));
    });
  });

  group('pointer cancellation', () {
    testWidgets('cancel mid-drag emits a synthetic (left, up)', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester);
      final TestGesture finger = _touch(tester, 1);

      await finger.down(const Offset(200, 300), timeStamp: _ms(0));
      await finger.up(timeStamp: _ms(50)); // tap → click
      await finger.down(const Offset(200, 300), timeStamp: _ms(300));
      await tester.pump(_ms(260)); // drag lock engages
      await finger.cancel(timeStamp: _ms(700)); // notification shade / call

      expect(sender.buttons, <_Button>[
        (button: 1, action: 3),
        (button: 1, action: 1),
        (button: 1, action: 2),
      ]);
      expect(haptics.calls, <String>['tapClick', 'dragStart', 'dragEnd']);
    });
  });

  group('profile swap', () {
    testWidgets('rebuild with new sensitivity amplifies subsequent deltas', (
      WidgetTester tester,
    ) async {
      await pumpPad(tester, profile: const TrackpadProfile(sensitivity: 1.0));
      final TestGesture first = _touch(tester, 1);
      await first.down(const Offset(200, 300), timeStamp: _ms(0));
      await first.moveBy(const Offset(20, 0), timeStamp: _ms(500));
      await first.up(timeStamp: _ms(600));

      await pumpPad(tester, profile: const TrackpadProfile(sensitivity: 2.0));
      final TestGesture second = _touch(tester, 2);
      await second.down(const Offset(200, 300), timeStamp: _ms(2000));
      await second.moveBy(const Offset(20, 0), timeStamp: _ms(2500));
      await second.up(timeStamp: _ms(2600));

      // Slow moves (0.04 px/ms) stay in the linear zone: gain = sensitivity.
      expect(sender.moves.map((_Move m) => m.dx), <int>[20, 40]);
      expect(sender.buttons, isEmpty);
    });
  });
}
