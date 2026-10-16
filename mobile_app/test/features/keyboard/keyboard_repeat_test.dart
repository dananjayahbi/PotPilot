// Doc 37 hold-repeat state machine (§4.4): 400 ms delay → 25 Hz cadence of
// identical `SEND_KEY` re-dispatches (the freeze has no KEY_REPEAT action),
// release stops it, and a cancelled press dispatches nothing. Clocks are
// fake (package:fake_async); the Doc 31 client is a capturing fake.

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

  test('400 ms delay → first SEND_KEY, then 25 Hz cadence (≈25 sends/s)', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.arrowUp);

      async.elapse(const Duration(milliseconds: 399));
      expect(client.sent, isEmpty, reason: 'no dispatch before the delay');

      async.elapse(const Duration(milliseconds: 1)); // t = 400 ms exactly
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 38}),
      ]);

      final int afterFirst = client.sent.length;
      async.elapse(const Duration(milliseconds: 1000)); // t = 1400 ms
      // Periodic ticks at 440, 480, … 1400 ms = 25 repeats.
      expect(
        client.sent.length - afterFirst,
        25,
        reason: '≈25 identical SEND_KEY envelopes per second',
      );
      for (final Map<String, Object?> e in client.sent) {
        expect(e['type'], 'CMD_KEY');
        expect(e['action'], 'SEND_KEY');
        expect(e['payload'], <String, dynamic>{'vk': 38});
      }
      // One micro-tick on engagement, not one per repeat tick.
      expect(haptics, <HapticPattern>[HapticPattern.microTick]);
    });
  });

  test('release stops the repeat immediately (no stray ticks)', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.backspace);
      async.elapse(const Duration(milliseconds: 500));
      // First at 400 ms, then 440 / 480 ms.
      expect(client.action('SEND_KEY'), hasLength(3));
      expect(client.action('SEND_KEY').first['payload'], <String, dynamic>{
        'vk': 8,
      });

      controller.stopRepeat(SpecialKey.backspace);
      final int atRelease = client.sent.length;
      async.elapse(const Duration(seconds: 2));
      expect(client.sent.length, atRelease, reason: 'stopped <50 ms after release');
    });
  });

  test('tap shorter than 400 ms: controller dispatches nothing on stop', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.arrowDown);
      async.elapse(const Duration(milliseconds: 200));
      controller.stopRepeat(SpecialKey.arrowDown); // finger lift (tap)
      async.elapse(const Duration(seconds: 2));
      expect(
        client.sent,
        isEmpty,
        reason: 'stopRepeat never dispatches — the widget issues the tap',
      );

      // The sheet's release path issues exactly one one-shot dispatch.
      controller.tapSpecial(SpecialKey.arrowDown);
      expect(client.action('SEND_KEY'), hasLength(1));
      expect(client.action('SEND_KEY').single['payload'], <String, dynamic>{
        'vk': 40,
      });
    });
  });

  test('10 dp move cancels the press with zero dispatch, ever', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.arrowUp);
      async.elapse(const Duration(milliseconds: 150));
      controller.stopRepeat(SpecialKey.arrowUp); // drag-off cancel path
      async.elapse(const Duration(seconds: 5));
      expect(client.sent, isEmpty);
      expect(controller.repeatEngaged(SpecialKey.arrowUp), isFalse);
    });
  });

  test('non-repeatable keys never enter the cadence', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.f5);
      async.elapse(const Duration(seconds: 2));
      expect(client.sent, isEmpty, reason: 'F-keys are not repeatable');
      controller.stopRepeat(SpecialKey.f5);
      controller.tapSpecial(SpecialKey.f5); // tap dispatch on release
      expect(client.action('SEND_KEY'), hasLength(1));
      expect(client.action('SEND_KEY').single['payload'], <String, dynamic>{
        'vk': 116,
      });
    });
  });

  test('disconnect force-stops repeats; reconnect fires no queued repeats', () {
    fakeAsync((FakeAsync async) {
      controller.startRepeat(SpecialKey.arrowRight);
      async.elapse(const Duration(milliseconds: 460)); // engaged (400 + 440)
      expect(client.action('SEND_KEY'), isNotEmpty);

      client.setConnected(false);
      async.flushMicrotasks();
      final int atDisconnect = client.sent.length;

      client.setConnected(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      expect(
        client.sent.length,
        atDisconnect,
        reason: 'only the char buffer queues — repeats never replay',
      );
    });
  });
}
