// Doc 37 unit tests — KeyboardController: modifier latches, SEND_COMBO
// promotion, text coalescing (50 ms window, 64-char cap, ordering) and
// offline queue/flush. Clocks are fake (package:fake_async); the Doc 31
// client is a capturing fake — no sockets.

import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/keyboard/full_keyboard.dart';
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

  List<Map<String, Object?>> action(String name) =>
      sent.where((Map<String, Object?> e) => e['action'] == name).toList();

  void setConnected(bool value) {
    _connected = value;
    _states.add(state);
  }

  Future<void> close() => _states.close();
}

Map<String, Object?> envelope(
  String type,
  String action,
  Map<String, dynamic> payload,
) {
  return <String, Object?>{'type': type, 'action': action, 'payload': payload};
}

void main() {
  late _FakeWsClient client;
  late KeyboardController controller;
  late List<HapticPattern> haptics;

  setUp(() {
    client = _FakeWsClient();
    haptics = <HapticPattern>[];
    controller = KeyboardController(
      client: client,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
    );
  });

  tearDown(() async {
    controller.dispose();
    await client.close();
  });

  group('modifier latch', () {
    test('Shift latch upper-cases the char, then unlatches (§4.3 pin)', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.shift);
        expect(controller.describeLatched(), 'Shift');

        controller.tapChar('a');
        async.elapse(const Duration(milliseconds: 50));

        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'A'}),
        ]);
        expect(controller.describeLatched(), '');
        expect(haptics, <HapticPattern>[HapticPattern.microTick]);
      });
    });

    test('Shift latch translates digit-row punctuation for SEND_TEXT', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.shift);
        controller.tapChar('1');
        async.elapse(const Duration(milliseconds: 50));

        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': '!'}),
        ]);
        expect(controller.describeLatched(), '');
      });
    });

    test('Ctrl + char promotes to SEND_COMBO with the char VK', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.ctrl);
        controller.tapChar('c');

        // Combos dispatch immediately (no 50 ms coalescing).
        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 67,
            'modifiers': <String>['CTRL'],
          }),
        ]);
        expect(controller.describeLatched(), '');

        async.elapse(const Duration(milliseconds: 200));
        expect(client.sent, hasLength(1), reason: 'no delayed duplicate');
      });
    });

    test('Ctrl latch applies to a special key as SEND_COMBO', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.ctrl);
        controller.tapSpecial(SpecialKey.arrowUp);

        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 38,
            'modifiers': <String>['CTRL'],
          }),
        ]);
        expect(controller.describeLatched(), '');
      });
    });

    test('Shift latch applies to a special key as SEND_COMBO', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.shift);
        controller.tapSpecial(SpecialKey.arrowLeft);

        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 37,
            'modifiers': <String>['SHIFT'],
          }),
        ]);
        expect(controller.describeLatched(), '');
      });
    });

    test('describeLatched orders Ctrl+Alt+Shift+Win and clears on close', () {
      controller.latchModifier(Modifier.shift);
      controller.latchModifier(Modifier.ctrl);
      expect(controller.describeLatched(), 'Ctrl+Shift');
      controller.clearLatches();
      expect(controller.describeLatched(), '');
    });

    test('Alt+F4 is self-contained: ignores latches, never consumes them', () {
      fakeAsync((FakeAsync async) {
        controller.latchModifier(Modifier.ctrl);
        controller.tapSpecial(SpecialKey.altF4);

        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 115,
            'modifiers': <String>['ALT'],
          }),
        ]);
        expect(controller.describeLatched(), 'Ctrl', reason: 'untouched');
      });
    });
  });

  group('Win latch (§4.5)', () {
    test('holding Win latches; Win then D → SEND_COMBO ["WIN"]', () {
      fakeAsync((FakeAsync async) {
        controller.startRepeat(SpecialKey.win);
        async.elapse(const Duration(milliseconds: 400));
        expect(controller.describeLatched(), 'Win');
        controller.stopRepeat(SpecialKey.win);

        controller.tapChar('d');
        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 68,
            'modifiers': <String>['WIN'],
          }),
        ]);
        expect(controller.describeLatched(), '');
      });
    });

    test('plain Win tap dispatches SEND_KEY 91 with no modifiers', () {
      controller.tapSpecial(SpecialKey.win);
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 91}),
      ]);
    });
  });

  group('SEND_TEXT coalescing (§4.3 / §7)', () {
    test('chars inside the 50 ms window flush as one ordered batch', () {
      fakeAsync((FakeAsync async) {
        for (final String ch in 'hello'.split('')) {
          controller.tapChar(ch);
        }
        async.elapse(const Duration(milliseconds: 49));
        expect(client.action('SEND_TEXT'), isEmpty, reason: 'still coalescing');

        async.elapse(const Duration(milliseconds: 1));
        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'hello'}),
        ]);
        expect(controller.pendingChars, 0);
      });
    });

    test('gaps beyond 50 ms produce separate envelopes, order preserved', () {
      fakeAsync((FakeAsync async) {
        controller.tapChar('a');
        async.elapse(const Duration(milliseconds: 60));
        controller.tapChar('b');
        async.elapse(const Duration(milliseconds: 60));

        final List<String> texts = client
            .action('SEND_TEXT')
            .map(
              (Map<String, Object?> e) =>
                  (e['payload']! as Map<String, dynamic>)['text']! as String,
            )
            .toList();
        expect(texts, <String>['a', 'b']);
      });
    });

    test('64-char cap: 100 rapid chars split 64 + 36, none dropped', () {
      fakeAsync((FakeAsync async) {
        final String long = 'x' * 100;
        for (final String ch in long.split('')) {
          controller.tapChar(ch);
        }
        async.elapse(const Duration(milliseconds: 60));

        final List<String> texts = client
            .action('SEND_TEXT')
            .map(
              (Map<String, Object?> e) =>
                  (e['payload']! as Map<String, dynamic>)['text']! as String,
            )
            .toList();
        expect(texts.map((String t) => t.length).toList(), <int>[64, 36]);
        expect(texts.join(), long);
      });
    });

    test('pending text flushes ahead of a key event (order preserved)', () {
      fakeAsync((FakeAsync async) {
        controller.tapChar('a');
        controller.tapSpecial(SpecialKey.esc);

        expect(client.sent, <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'a'}),
          envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 27}),
        ]);
        expect(haptics, <HapticPattern>[
          HapticPattern.microTick, // char tap
          HapticPattern.heavyThud, // Enter/Esc cue
        ]);
      });
    });
  });

  group('offline queue / reconnect flush (§7)', () {
    test('chars typed offline queue and flush exactly once on reconnect', () {
      fakeAsync((FakeAsync async) {
        client.setConnected(false);
        async.flushMicrotasks();

        controller.tapChar('q');
        async.elapse(const Duration(milliseconds: 100));
        expect(controller.pendingChars, 1, reason: 'held in the buffer');
        expect(client.sent, isEmpty, reason: 'no envelope while offline');

        client.setConnected(true);
        async.flushMicrotasks();
        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'q'}),
        ]);
        expect(controller.pendingChars, 0);

        async.elapse(const Duration(milliseconds: 500));
        expect(client.action('SEND_TEXT'), hasLength(1), reason: 'no duplicate');
      });
    });

    test('key dispatch is dropped while offline (never queued)', () {
      fakeAsync((FakeAsync async) {
        client.setConnected(false);
        async.flushMicrotasks();

        controller.tapSpecial(SpecialKey.esc);
        controller.startRepeat(SpecialKey.arrowUp);
        async.elapse(const Duration(seconds: 2));
        expect(client.sent, isEmpty);

        client.setConnected(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(client.sent, isEmpty, reason: 'nothing replays after reconnect');
      });
    });
  });
}
