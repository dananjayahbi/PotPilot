// Doc 37 widget tests — Full PC keyboard sheet.
//
// Fake Doc 31 client + fake Doc 42 haptics; no real network, no sockets.
// Surface is pinned to portrait 360×800 dp (the doc's reference width).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/keyboard/full_keyboard.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

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

Map<String, Object?> envelope(
  String type,
  String action,
  Map<String, dynamic> payload,
) {
  return <String, Object?>{'type': type, 'action': action, 'payload': payload};
}

void main() {
  late _FakeWsClient client;
  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late List<HapticPattern> haptics;

  setUp(() async {
    client = _FakeWsClient();
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
    haptics = <HapticPattern>[];
  });

  tearDown(() async {
    await socket.close();
    await client.close();
  });

  List<Override> overrides() => <Override>[
    keyboardControllerProvider.overrideWith((ref) {
      final KeyboardController controller = KeyboardController(
        client: client,
        playHaptic: (HapticPattern pattern) async {
          haptics.add(pattern);
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    }),
    telemetryProvider.overrideWith((ref) => notifier),
  ];

  void setPortraitPhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpKeyboard(
    WidgetTester tester, {
    bool connected = true,
  }) async {
    if (!connected) {
      client.setConnected(false);
    }
    setPortraitPhone(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(body: FullKeyboardSheet()),
        ),
      ),
    );
    await tester.pump();
  }

  /// Drains the 80 ms key-flash / 50 ms coalesce / 400 ms repeat timers so
  /// no timer is left pending at the end of the test.
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 500));

  group('presentation (§4.2)', () {
    testWidgets('sheet opens on pure #000000 and is drag-dismissible', (
      WidgetTester tester,
    ) async {
      setPortraitPhone(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides(),
          child: MaterialApp(
            theme: buildOledTheme(),
            home: Builder(
              builder: (BuildContext context) {
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      key: const Key('open_kb'),
                      onPressed: () => showFullKeyboardSheet(context),
                      child: const Text('Open keyboard'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open_kb')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('kbd_esc')), findsOneWidget);
      expect(AppColors.background, const Color(0xFF000000));
      final BottomSheet sheet = tester.widget<BottomSheet>(
        find.byType(BottomSheet),
      );
      expect(sheet.backgroundColor, const Color(0xFF000000));

      // Drag-dismissible: pull the sheet down from its header.
      await tester.drag(find.byKey(const Key('kbd_header')), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('kbd_esc')), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('echo line updates per forwarded char; caption shows file_title', (
      WidgetTester tester,
    ) async {
      await pumpKeyboard(tester);

      notifier.handleEnvelope(
        WsMessage(
          id: '00000000-0000-4000-8000-000000000000',
          type: typeTelemetrySync,
          action: actionFullState,
          payload: <String, dynamic>{'file_title': 'Inception'},
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ),
      );
      await tester.pump();
      expect(find.text('Inception'), findsOneWidget);

      await tester.tap(find.byKey(const Key('kbd_h')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('kbd_i')));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('kbd_echo'))).data, 'hi');
      expect(haptics, <HapticPattern>[
        HapticPattern.microTick,
        HapticPattern.microTick,
      ]);

      await drain(tester);
    });
  });

  group('envelope fidelity (§5)', () {
    Future<void> tapOnce(
      WidgetTester tester,
      String keyId,
      Map<String, Object?> expected,
    ) async {
      final int before = client.sent.length;
      await tester.tap(find.byKey(ValueKey<String>(keyId)));
      await tester.pump();
      expect(
        client.sent.length,
        before + 1,
        reason: '$keyId must dispatch exactly one envelope per tap',
      );
      expect(client.sent.last, expected);
    }

    testWidgets(
      'Esc / F12 / Win / Alt+F4 / arrow each dispatch their exact §5 payload',
      (WidgetTester tester) async {
        await pumpKeyboard(tester);

        await tapOnce(tester, 'kbd_esc', envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 27}));
        expect(haptics, contains(HapticPattern.heavyThud));
        await tapOnce(tester, 'kbd_tab', envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 9}));
        await tapOnce(tester, 'kbd_f12', envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 123}));
        await tapOnce(tester, 'kbd_win', envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 91}));
        await tapOnce(
          tester,
          'kbd_altF4',
          envelope('CMD_KEY', 'SEND_COMBO', <String, dynamic>{
            'vk': 115,
            'modifiers': <String>['ALT'],
          }),
        );
        await tapOnce(tester, 'kbd_arrowUp', envelope('CMD_KEY', 'SEND_KEY', <String, dynamic>{'vk': 38}));

        expect(client.sent, hasLength(5 + 1)); // six taps, six envelopes

        await drain(tester);
      },
    );

    testWidgets('F-row and arrow cluster are present at 360 dp width', (
      WidgetTester tester,
    ) async {
      await pumpKeyboard(tester);

      expect(
        tester.getSize(find.byKey(const Key('kbd_esc'))).width,
        greaterThan(0),
      );
      for (final String label in <String>[
        'Esc',
        'F1',
        'F2',
        'F3',
        'F4',
        'F5',
        'F6',
        'F7',
        'F8',
        'F9',
        'F10',
        'F11',
        'F12',
        'Tab',
        'Shift',
        'Enter',
        'Win',
        'Alt+F4',
        'Space',
        'Home',
        'End',
        'PgUp',
        'PgDn',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing $label');
      }
      for (final String id in <String>[
        'arrowLeft',
        'arrowUp',
        'arrowDown',
        'arrowRight',
      ]) {
        expect(find.byKey(ValueKey<String>('kbd_$id')), findsOneWidget);
      }

      // F12 is reachable without scrolling at the 360 dp reference width.
      await tester.tap(find.byKey(const Key('kbd_f12')));
      await tester.pump();
      expect(client.action('SEND_KEY'), hasLength(1));

      await drain(tester);
    });
  });

  group('modifier latch (§4.6)', () {
    testWidgets(
      'Shift latches (underline), then Shift+a pins uppercase SEND_TEXT',
      (WidgetTester tester) async {
        await pumpKeyboard(tester);

        await tester.tap(find.byKey(const Key('kbd_shift')));
        await tester.pump();
        expect(
          tester.widget<KeyCap>(find.byKey(const Key('kbd_shift'))).latched,
          isTrue,
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('kbd_latch_status'))).data,
          'Shift',
        );

        await tester.tap(find.byKey(const Key('kbd_a')));
        await tester.pump(const Duration(milliseconds: 60));
        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'A'}),
        ]);
        expect(
          tester.widget<KeyCap>(find.byKey(const Key('kbd_shift'))).latched,
          isFalse,
          reason: 'latch underline clears after consumption',
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('kbd_latch_status'))).data,
          '',
        );

        await drain(tester);
      },
    );
  });

  group('pointer handling (§4.4)', () {
    testWidgets('drag >10 dp off a keycap cancels the press with zero dispatch', (
      WidgetTester tester,
    ) async {
      await pumpKeyboard(tester);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('kbd_arrowUp'))),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0)); // past the 10 dp threshold
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(client.sent, isEmpty, reason: 'cancelled press dispatches nothing');
      await tester.pump(const Duration(milliseconds: 600));
      expect(client.sent, isEmpty, reason: 'no late repeat fires either');

      await drain(tester);
    });

    testWidgets(
      'holding ArrowUp: 400 ms delay → ≈25 SEND_KEY/s, stops on release',
      (WidgetTester tester) async {
        await pumpKeyboard(tester);

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('kbd_arrowUp'))),
        );
        await tester.pump();

        await tester.pump(const Duration(milliseconds: 400));
        expect(client.action('SEND_KEY'), hasLength(1), reason: 'first tick at 400 ms');

        await tester.pump(const Duration(milliseconds: 1000));
        // 440 ms … 1400 ms at 40 ms cadence = 25 repeats after the first.
        expect(client.action('SEND_KEY'), hasLength(26));

        await gesture.up();
        await tester.pump();
        final int atRelease = client.sent.length;
        await tester.pump(const Duration(milliseconds: 500));
        expect(client.sent.length, atRelease, reason: 'release stops the repeat');
      },
    );
  });

  group('disconnect handling (§7)', () {
    testWidgets(
      'keys grey out immediately; queued chars flush once on reconnect',
      (WidgetTester tester) async {
        // Type one char, then drop the socket before the 50 ms flush lands.
        await pumpKeyboard(tester);
        await tester.tap(find.byKey(const Key('kbd_a')));
        await tester.pump();
        client.setConnected(false);
        await tester.pump(const Duration(milliseconds: 60));

        expect(client.sent, isEmpty, reason: 'char held while offline');
        expect(find.byKey(const Key('kbd_queue_pill')), findsOneWidget);
        expect(
          tester.widget<Text>(
            find.descendant(
              of: find.byKey(const Key('kbd_queue_pill')),
              matching: find.byType(Text),
            ),
          ).data,
          'queued 1 chars',
        );

        // Offline: keys are greyed out and inert.
        expect(
          tester.widget<KeyCap>(find.byKey(const Key('kbd_esc'))).enabled,
          isFalse,
        );
        final Container escCap = tester.widget<Container>(
          find
              .descendant(
                of: find.byKey(const Key('kbd_esc')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (escCap.decoration! as BoxDecoration).color,
          AppColors.surfaceHigh,
        );
        await tester.tap(find.byKey(const Key('kbd_esc')));
        await tester.pump();
        expect(client.sent, isEmpty, reason: 'offline keys dispatch nothing');

        // Reconnect: the queued char flushes exactly once, no duplicates.
        // (A duration-bearing pump flushes the state-stream microtask before
        // the frame is drawn, so the widget rebuilds with pending=0.)
        client.setConnected(true);
        await tester.pump(const Duration(milliseconds: 1));
        expect(client.action('SEND_TEXT'), <Map<String, Object?>>[
          envelope('CMD_KEY', 'SEND_TEXT', <String, dynamic>{'text': 'a'}),
        ]);
        expect(find.byKey(const Key('kbd_queue_pill')), findsNothing);
        await tester.pump(const Duration(milliseconds: 500));
        expect(client.action('SEND_TEXT'), hasLength(1), reason: 'no duplicate flush');

        await drain(tester);
      },
    );

    testWidgets('fully disconnected sheet renders disabled visuals at open', (
      WidgetTester tester,
    ) async {
      await pumpKeyboard(tester, connected: false);

      final KeyCap esc = tester.widget<KeyCap>(
        find.byKey(const Key('kbd_esc')),
      );
      expect(esc.enabled, isFalse);
      final KeyCap shift = tester.widget<KeyCap>(
        find.byKey(const Key('kbd_shift')),
      );
      expect(shift.enabled, isFalse);

      await tester.tap(find.byKey(const Key('kbd_esc')));
      await tester.pump();
      expect(client.sent, isEmpty);
    });
  });
}
