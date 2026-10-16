import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/display/monitor_power_sheet.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
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

  void pushReply(WsMessage message) => _replies.add(message);

  Future<void> close() async {
    await _states.close();
    await _replies.close();
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

Map<String, dynamic> _payload({Object? brightness = 80, bool blackout = false}) {
  return <String, dynamic>{
    'position_ms': 1000,
    'duration_ms': 60000,
    'is_playing': true,
    'speed': 1.0,
    'volume': 50,
    'file_title': 'Interstellar',
    'potplayer_found': true,
    'blackout_active': blackout,
    'brightness': brightness,
    'sys_volume': 50,
    'sys_muted': false,
    'sleep_timer_active': false,
    'sleep_timer_mode': null,
    'sleep_timer_remaining_s': null,
  };
}

void main() {
  late _FakeWsClient client;
  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late List<HapticPattern> haptics;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DisplayCache.instance.init();
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

  void pushTelemetry({Object? brightness = 80, bool blackout = false}) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000000',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: _payload(brightness: brightness, blackout: blackout),
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  List<Override> overrides() => <Override>[
    monitorPowerControllerProvider.overrideWith((ref) {
      final SystemCommandController controller = SystemCommandController(
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

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(body: MonitorPowerSheet()),
        ),
      ),
    );
    await tester.pump();
  }

  Slider sliderOf(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const Key('display_brightness_slider')));

  Switch switchOf(WidgetTester tester) =>
      tester.widget<Switch>(find.byKey(const Key('display_blackout_switch')));

  Map<String, Object?> envelope(
    String type,
    String action,
    Map<String, dynamic> payload,
  ) {
    return <String, Object?>{
      'type': type,
      'action': action,
      'payload': payload,
    };
  }

  group('per-control envelope fidelity (§5)', () {
    testWidgets('snap / blackout / timer / cancel dispatch exact envelopes', (
      WidgetTester tester,
    ) async {
      await pumpSheet(tester);

      // Snap (+700 ms check pulse).
      await tester.tap(find.byKey(const Key('display_snap_button')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_SYSTEM', 'SNAP_TO_PRIMARY_MONITOR', <String, dynamic>{}),
      ]);
      expect(find.text('\u2713'), findsOneWidget);
      await tester.pump(kSnapAckDuration + const Duration(milliseconds: 50));
      expect(find.text('\u2713'), findsNothing);
      client.sent.clear();

      // Blackout toggle.
      await tester.tap(find.byKey(const Key('display_blackout_switch')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_SYSTEM', 'SET_BLACKOUT', <String, dynamic>{'enabled': true}),
      ]);
      expect(switchOf(tester).value, true);
      expect(find.text('On'), findsOneWidget);
      expect(DisplayCache.instance.blackoutEnabled, isTrue);
      client.sent.clear();

      // COUNTDOWN arm (default target SLEEP) + live pill + thud.
      await tester.tap(find.text('15 min'));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope(
          'CMD_SYSTEM',
          'START_SLEEP_TIMER',
          <String, dynamic>{'mode': 'COUNTDOWN', 'target': 'SLEEP', 'minutes': 15},
        ),
      ]);
      expect(find.text('Fall asleep in 15 min'), findsOneWidget);
      expect(find.byKey(const Key('sleep_timer_pill')), findsOneWidget);
      expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);
      client.sent.clear();

      // Cancel clears the pill and dispatches CANCEL_SLEEP_TIMER {}.
      await tester.tap(find.byKey(const Key('display_timer_cancel')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_SYSTEM', 'CANCEL_SLEEP_TIMER', <String, dynamic>{}),
      ]);
      expect(find.byKey(const Key('sleep_timer_pill')), findsNothing);
      expect(find.byKey(const Key('display_timer_cancel')), findsNothing);
      client.sent.clear();

      // Target change is local (no dispatch) …
      await tester.tap(find.text('Shutdown'));
      await tester.pump();
      expect(client.sent, isEmpty);

      // … and lands in every subsequent arm.
      await tester.tap(find.text('End of movie'));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope(
          'CMD_SYSTEM',
          'START_SLEEP_TIMER',
          <String, dynamic>{
            'mode': 'MOVIE_PROGRESS',
            'target': 'SHUTDOWN',
            'progress_pct': 99,
          },
        ),
      ]);
    });
  });

  group('offline gate', () {
    testWidgets(
      'opening offline dispatches nothing; every control disables with a strip',
      (WidgetTester tester) async {
        client.setConnected(false);
        await pumpSheet(tester);

        // Open is read-only: no packets from warm-start/initState.
        expect(client.sent, isEmpty, reason: 'opening offline dispatches nothing');
        expect(find.byKey(const Key('display_reconnect_strip')), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('display_snap_button')))
              .onPressed,
          isNull,
        );
        expect(switchOf(tester).onChanged, isNull);
        expect(sliderOf(tester).onChanged, isNull);
        final ChoiceChip preset = tester.widget<ChoiceChip>(
          find.ancestor(
            of: find.text('15 min'),
            matching: find.byType(ChoiceChip),
          ),
        );
        expect(preset.onSelected, isNull);

        await tester.tap(
          find.byKey(const Key('display_snap_button')),
          warnIfMissed: false,
        );
        await tester.tap(
          find.byKey(const Key('display_blackout_switch')),
          warnIfMissed: false,
        );
        await tester.tap(find.text('15 min'), warnIfMissed: false);
        await tester.tap(
          find.byKey(const Key('display_brightness_slider')),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(client.sent, isEmpty);
      },
    );

    testWidgets('reconnecting restores dispatch', (WidgetTester tester) async {
      await pumpSheet(tester);
      expect(find.byKey(const Key('display_reconnect_strip')), findsNothing);

      client.setConnected(false);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('display_reconnect_strip')), findsOneWidget);

      client.setConnected(true);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('display_reconnect_strip')), findsNothing);

      await tester.tap(find.byKey(const Key('display_snap_button')));
      await tester.pump();
      expect(client.action('SNAP_TO_PRIMARY_MONITOR'), hasLength(1));
    });
  });

  group('brightness slider', () {
    testWidgets(
      'drag throttles ≤5 packets/s and the released value is the last packet',
      (WidgetTester tester) async {
        await pumpSheet(tester);

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('display_brightness_slider'))),
        );
        await gesture.moveBy(const Offset(120, 0));
        await tester.pump();
        // First window elapses (200 ms) → at most one mid-drag packet.
        await tester.pump(
          kBrightnessThrottle + const Duration(milliseconds: 50),
        );
        final int midCount = client.action('SET_BRIGHTNESS').length;
        expect(midCount, greaterThanOrEqualTo(1));

        await gesture.moveBy(const Offset(60, 0));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        final List<Map<String, Object?>> packets = client.action(
          'SET_BRIGHTNESS',
        );
        expect(
          (packets.last['payload']! as Map)['percent'],
          sliderOf(tester).value.round(),
          reason: 'finger-lifted value is always the last packet sent',
        );
        // 1 window packet + 1 trailing packet over >250 ms ⇒ ≤5 packets/s.
        expect(packets.length, lessThanOrEqualTo(midCount + 1));
        expect(packets.length, greaterThanOrEqualTo(2));

        // The post-release telemetry debounce must not leak stray sends.
        final int count = packets.length;
        await tester.pump(kBrightnessTelemetryDebounce + const Duration(milliseconds: 50));
        expect(client.action('SET_BRIGHTNESS'), hasLength(count));
      },
    );

    testWidgets(
      'incoming brightness telemetry is ignored mid-drag and wins after release',
      (WidgetTester tester) async {
        await pumpSheet(tester);
        pushTelemetry(brightness: 55);
        await tester.pump();
        expect(sliderOf(tester).value, 55.0, reason: 'first frame snaps');

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('display_brightness_slider'))),
        );
        await gesture.moveBy(const Offset(80, 0));
        await tester.pump();

        pushTelemetry(brightness: 5);
        await tester.pump();
        expect(
          sliderOf(tester).value,
          isNot(5.0),
          reason: 'actively-dragged slider ignores telemetry',
        );

        await gesture.up();
        await tester.pump();
        pushTelemetry(brightness: 5);
        await tester.pump();
        await tester.pump(
          kBrightnessTelemetryDebounce + const Duration(milliseconds: 50),
        );
        expect(sliderOf(tester).value, 5.0, reason: 'telemetry wins after release');
      },
    );

    testWidgets(
      'SET_BRIGHTNESS_ERROR 4006 reverts to last accepted + 2 s hint',
      (WidgetTester tester) async {
        await pumpSheet(tester);
        pushTelemetry(brightness: 55);
        await tester.pump();
        expect(sliderOf(tester).value, 55.0);

        final TestGesture gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('display_brightness_slider'))),
        );
        await gesture.moveBy(const Offset(120, 0));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        expect(sliderOf(tester).value, isNot(55.0));

        client.pushReply(
          WsMessage(
            id: '00000000-0000-4000-8000-000000000001',
            type: typeCmdSystem,
            action: 'SET_BRIGHTNESS_ERROR',
            payload: <String, dynamic>{
              'code': errorHardwareUnavailable,
              'message': 'no DDC/CI monitor',
            },
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
        );
        await tester.pump();
        expect(sliderOf(tester).value, 55.0, reason: 'reverted to accepted');
        expect(find.byKey(const Key('display_brightness_hint')), findsOneWidget);

        await tester.pump(kBrightnessErrorHintDuration + const Duration(milliseconds: 50));
        expect(find.byKey(const Key('display_brightness_hint')), findsNothing);
      },
    );

    testWidgets(
      'warm-starts brightness + blackout from cache within one frame of open',
      (WidgetTester tester) async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          DisplayCacheKeys.lastBrightnessPct: 42,
          DisplayCacheKeys.blackoutEnabled: true,
        });
        await DisplayCache.instance.init();

        await tester.pumpWidget(
          ProviderScope(
            overrides: overrides(),
            child: MaterialApp(
              theme: buildOledTheme(),
              home: const Scaffold(body: SizedBox()),
            ),
          ),
        );
        await tester.pump();

        showMonitorPowerSheet(tester.element(find.byType(Scaffold)));
        await tester.pump();
        await tester.pump();

        expect(find.byType(MonitorPowerSheet), findsOneWidget);
        expect(sliderOf(tester).value, 42.0, reason: 'cache value on frame 1');
        expect(switchOf(tester).value, true);
        expect(client.sent, isEmpty, reason: 'open is read-only');
        // No telemetry yet → optional readouts dim to `--` (stale).
        expect(find.text('--'), findsOneWidget);
      },
    );
  });
}
