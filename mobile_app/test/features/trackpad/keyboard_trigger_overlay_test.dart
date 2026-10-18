// Round 6: phone-OS-keyboard trigger zone on the trackpad — focus
// raising, delta forwarding (`SEND_TEXT` appends / `SEND_KEY`
// backspaces), submit -> Enter, and hit-test isolation from the
// trackpad underneath (taps on the chip must not move the cursor).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/storage/connection_cache.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/keyboard/full_keyboard.dart';
import 'package:potpilot_remote/features/trackpad/keyboard_trigger_overlay.dart';
import 'package:potpilot_remote/features/trackpad/virtual_trackpad.dart';
import 'package:potpilot_remote/network/udp_sender.dart';
import 'package:potpilot_remote/network/ws_client.dart';

import 'dart:typed_data';

/// Fake Doc 31 client — captures envelopes, no sockets.
class _FakeWsClient extends WsClient {
  final bool _connected = true;
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
    sent.add(<String, Object?>{
      'type': type,
      'action': action,
      'payload': payload,
    });
  }

  List<Map<String, Object?>> action(String name) =>
      sent.where((Map<String, Object?> e) => e['action'] == name).toList();

  Future<void> close() => _states.close();
}

/// Minimal UdpSender fake — only records button events (hit-test proof).
class _FakeSender implements UdpSender {
  final List<int> buttons = <int>[];

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
  void sendButton(int buttonId, int action) => buttons.add(buttonId);

  @override
  void sendScrub(int targetSeconds) {}

  @override
  void flush() {}

  @override
  Future<void> close() async {}
}

void main() {
  late _FakeWsClient client;
  late KeyboardController controller;
  late _FakeSender sender;

  setUp(() {
    client = _FakeWsClient();
    controller = KeyboardController(client: client, playHaptic: null);
    sender = _FakeSender();
  });

  tearDown(() async {
    controller.dispose();
    await client.close();
  });

  /// Mirrors the shell composition: trackpad fills the frame, overlay is
  /// docked top-right above it.
  Future<void> pumpPad(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          keyboardControllerProvider.overrideWith((ref) => controller),
        ],
        child: MaterialApp(
          theme: buildOledTheme(),
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: VirtualTrackpad(
                    sender: sender,
                    profile: const TrackpadProfile(),
                    haptics: HapticHooks(
                      tapClick: () {},
                      dragStart: () {},
                      dragEnd: () {},
                      rightClick: () {},
                      scrollTick: (double _) {},
                    ),
                  ),
                ),
                const Positioned(
                  top: 8,
                  right: 8,
                  child: KeyboardTriggerOverlay(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  TextField hiddenField(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('trackpad_keyboard_input')));

  testWidgets('tapping the chip focuses the hidden field (IME gate opens)',
      (WidgetTester tester) async {
    await pumpPad(tester);
    expect(hiddenField(tester).focusNode?.hasFocus, isFalse);

    await tester.tap(find.byKey(const Key('trackpad_keyboard_trigger')));
    await tester.pump();
    expect(hiddenField(tester).focusNode?.hasFocus, isTrue);

    // Second tap closes again (chip toggles).
    await tester.tap(find.byKey(const Key('trackpad_keyboard_trigger')));
    await tester.pump();
    expect(hiddenField(tester).focusNode?.hasFocus, isFalse);
  });

  testWidgets('typed text flushes as SEND_TEXT after the 50 ms coalesce',
      (WidgetTester tester) async {
    await pumpPad(tester);
    await tester.enterText(find.byKey(const Key('trackpad_keyboard_input')), 'hi');
    expect(controller.pendingChars, 2); // buffered, not yet on the wire

    await tester.pump(const Duration(milliseconds: 60));
    expect(client.action('SEND_TEXT'), hasLength(1));
    expect(
      client.action('SEND_TEXT').single['payload'],
      <String, dynamic>{'text': 'hi'},
    );
  });

  testWidgets('deleting characters forwards SEND_KEY backspaces',
      (WidgetTester tester) async {
    await pumpPad(tester);
    await tester.enterText(find.byKey(const Key('trackpad_keyboard_input')), 'hi');
    await tester.pump(const Duration(milliseconds: 60));

    await tester.enterText(find.byKey(const Key('trackpad_keyboard_input')), 'h');
    await tester.pump(const Duration(milliseconds: 60));

    expect(client.action('SEND_KEY'), hasLength(1)); // one backspace (VK 8)
    expect(
      client.action('SEND_KEY').single['payload'],
      <String, dynamic>{'vk': 8},
    );
    expect(client.action('SEND_TEXT'), hasLength(1)); // unchanged prefix kept
  });

  testWidgets('submit forwards Enter (VK 13)', (WidgetTester tester) async {
    await pumpPad(tester);
    await tester.enterText(find.byKey(const Key('trackpad_keyboard_input')), 'q');
    await tester.pump(const Duration(milliseconds: 60));

    tester
        .widget<TextField>(find.byKey(const Key('trackpad_keyboard_input')))
        .onSubmitted!
        .call('q');
    await tester.pump();

    expect(client.action('SEND_KEY'), hasLength(1));
    expect(
      client.action('SEND_KEY').single['payload'],
      <String, dynamic>{'vk': 13},
    );
  });

  testWidgets('chip taps never reach the trackpad; outside taps still click',
      (WidgetTester tester) async {
    await pumpPad(tester);

    // Tap dead-center of the chip (top-right): no left-click to the PC.
    await tester.tap(find.byKey(const Key('trackpad_keyboard_trigger')));
    await tester.pump();
    expect(sender.buttons, isEmpty);

    // A tap in the open trackpad area still emits the classic click.
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 60));
    expect(sender.buttons, <int>[1]);
  });
}
