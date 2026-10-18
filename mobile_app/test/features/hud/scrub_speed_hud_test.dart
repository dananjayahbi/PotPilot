import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/deck/ruler/ruler_seek_slider.dart';
import 'package:potpilot_remote/features/hud/scrub_speed_hud.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Fake Doc 30/31 sinks — no sockets, pure captures.
class _FakeTransport implements ScrubTransport {
  final List<int> scrubs = <int>[];
  final List<int> seeks = <int>[];
  bool connected = true;

  @override
  void sendScrub(int targetSeconds) => scrubs.add(targetSeconds);

  @override
  void sendSeek(int positionMs) => seeks.add(positionMs);

  @override
  bool get wsConnected => connected;
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
  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late _FakeTransport transport;
  late List<HapticPattern> haptics;
  late ScrubController controller;
  late List<bool> activeLog;

  setUp(() async {
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
    transport = _FakeTransport();
    haptics = <HapticPattern>[];
    controller = ScrubController(
      transport: transport,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
    );
    activeLog = <bool>[];
  });

  tearDown(() async {
    // The ProviderScope tree teardown disposes the controller (single
    // dispose); here we only close the fake telemetry streams.
    await socket.close();
  });

  int futureTs() =>
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30; // load-proof

  void push({
    required int positionMs,
    required int durationMs,
    double speed = 1.0,
    int volume = 42,
    int? timestamp,
  }) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000001',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: <String, dynamic>{
          'position_ms': positionMs,
          'duration_ms': durationMs,
          'is_playing': true,
          'speed': speed,
          'volume': volume,
          'file_title': 'Interstellar',
        },
        // Fresh frames carry next-second timestamps: unix-second truncation
        // plus test execution time can otherwise cross a second boundary and
        // trip the >1000 ms staleness clock spuriously (house formula from
        // Docs 36/39: now - timestamp * 1000).
        timestamp: timestamp ?? futureTs(),
      ),
    );
  }

  List<Override> overrides() => <Override>[
        telemetryProvider.overrideWith((ref) => notifier),
        scrubControllerProvider.overrideWith((ref) {
          ref.onDispose(controller.dispose);
          return controller;
        }),
        // The ruler reads this provider on every notch tick; the controller's
        // own haptics go through its injected playHaptic (captured above).
        hapticEngineProvider.overrideWith((ref) => HapticEngine.noOp()),
      ];

  Future<void> pumpHud(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ScrubSpeedHud(onScrubActiveChanged: activeLog.add),
                // The deck ruler is the prod gesture surface these drag
                // tests drive (the old top track was replaced by it).
                const RulerSeekSlider(enabled: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String leftLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('hud_time_left'))).data ?? '';

  testWidgets(
    'drag across the ruler streams UDP, freezes labels, commits SEEK, settles',
    (WidgetTester tester) async {
      push(positionMs: 5050000, durationMs: 8100000); // 01:24:10 / 02:15:00
      await pumpHud(tester);

      // Idle: labels track telemetry (acceptance example).  The ruler bubble
      // mirrors the same position, so scope the match to the HUD row.
      expect(leftLabel(tester), '01:24:10');
      expect(find.text('02:15:00'), findsOneWidget);
      expect(activeLog, isEmpty);

      // Drag leftward across the track (past touch slop, no right-edge clamp).
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('ruler_track'))),
      );
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-150, 0));
      await tester.pump();

      expect(controller.dragging, true);
      expect(activeLog, <bool>[true]);
      expect(transport.scrubs, isNotEmpty); // >= 1 UDP 0x04 preview
      final String frozen = leftLabel(tester);
      expect(frozen, isNot('01:24:10')); // preview followed the finger

      // Telemetry position is ignored mid-drag; badges keep updating.
      push(positionMs: 6000000, durationMs: 8100000, volume: 77);
      await tester.pump();
      expect(leftLabel(tester), frozen);
      expect(find.text('77%'), findsOneWidget);

      // Release: exactly one WS SEEK equal to the preview target.
      await gesture.up();
      await tester.pump();
      expect(controller.settling, true);
      expect(transport.seeks, hasLength(1));
      expect(transport.seeks.single, controller.preview.positionMs);

      // A newer frame within 1500 ms re-attaches to telemetry.
      final int commit = transport.seeks.single;
      push(
        positionMs: commit + 500,
        durationMs: 8100000,
        timestamp: futureTs() + 1, // strictly newer than the commit frame
      );
      await tester.pump();
      expect(controller.phase, ScrubPhase.idle);
      expect(leftLabel(tester), formatTimecode(commit + 500));
      expect(activeLog, <bool>[true, false]);
      expect(haptics, isNotEmpty); // minute ticks fired while crossing
    },
  );

  testWidgets('fresh snapshot renders speed and volume badges',
      (WidgetTester tester) async {
    push(positionMs: 1000, durationMs: 600000, speed: 1.4, volume: 42);
    await pumpHud(tester);
    expect(find.text('1.4x'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('--'), findsNothing);
  });

  testWidgets('stale snapshot dims both badges to --',
      (WidgetTester tester) async {
    push(
      positionMs: 1000,
      durationMs: 600000,
      speed: 1.4,
      volume: 42,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2,
    );
    await pumpHud(tester);
    expect(find.text('--'), findsNWidgets(2));
    for (final Key badge in <Key>[
      const Key('hud_badge_volume'),
      const Key('hud_badge_speed'),
    ]) {
      final Opacity opacity = tester.widget<Opacity>(
        find.descendant(of: find.byKey(badge), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, 0.45);
    }
  });

  testWidgets('zero duration: --:--:-- / 00:00:00 and gestures are inert',
      (WidgetTester tester) async {
    push(positionMs: 0, durationMs: 0);
    await pumpHud(tester);
    expect(find.text('--:--:--'), findsOneWidget);
    expect(find.text('00:00:00'), findsOneWidget);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('ruler_track'))),
    );
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(transport.scrubs, isEmpty);
    expect(transport.seeks, isEmpty);
    expect(controller.phase, ScrubPhase.idle);
    expect(activeLog, isEmpty); // beginDrag never fired the host hook
  });
}
