// Doc 36 (round 5, 2026-10-17): widget coverage for the deck's
// speed-sensing ruler — chrome, budget-capped gestures committing
// through the shared scrub engine, fine tap-seeks, and disabled gating.
//
// The harness pumps the HUD above the ruler exactly like the deck does:
// the HUD is what feeds telemetry snapshots into the shared controller.

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
  const int startPositionMs = 5050000; // 01:24:10
  const int durationMs = 8100000; // 02:15:00

  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late _FakeTransport transport;
  late List<HapticPattern> haptics;
  late ScrubController controller;

  setUp(() {
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
  });

  tearDown(() async {
    await socket.close();
  });

  int futureTs() => DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30;

  void push({int positionMs = startPositionMs, int? timestamp}) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000001',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: <String, dynamic>{
          'position_ms': positionMs,
          'duration_ms': durationMs,
          'is_playing': true,
          'speed': 1.0,
          'volume': 42,
          'file_title': 'Interstellar',
        },
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
        hapticEngineProvider.overrideWith((ref) => HapticEngine.noOp()),
      ];

  Future<void> pumpRuler(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const ScrubSpeedHud(),
                RulerSeekSlider(enabled: enabled),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Text under [key] — the chip keys sit on their Container wrappers,
  /// the bubble key on its Text (either shape is tolerated).
  String chipText(WidgetTester tester, Key key) {
    final Finder direct = find.byKey(key);
    final Widget widget = tester.widget(direct);
    if (widget is Text) {
      return widget.data ?? '';
    }
    return tester
        .widget<Text>(
          find.descendant(of: direct, matching: find.byType(Text)),
        )
        .data ??
        '';
  }

  testWidgets('chrome: bubble time, tier chip, delta chip and hint',
      (WidgetTester tester) async {
    push();
    await pumpRuler(tester);

    expect(chipText(tester, const Key('ruler_time')), '01:24:10');
    expect(chipText(tester, const Key('ruler_tier')), '1 s');
    expect(chipText(tester, const Key('ruler_delta')), '0');
    expect(find.byKey(const Key('ruler_hint')), findsOneWidget);
    expect(find.byKey(const Key('ruler_track')), findsOneWidget);
  });

  testWidgets(
      'fast swipe clamps travel to the 5-minute budget, then commits one SEEK',
      (WidgetTester tester) async {
    push();
    await pumpRuler(tester);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('ruler_track'))),
    );
    // Huge single move: worst-case velocity still lands in the 5 m tier,
    // so the budget (300 000 ms) trims the contribution exactly.
    // The accept move may deliver only the drag start; the next move
    // carries the update.  Either way the top tier is reached (worst-case
    // dt still yields >4000 px/s) and the budget trims to exactly +5 min.
    await gesture.moveBy(const Offset(800, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(800, 0));
    await tester.pump();

    expect(controller.dragging, true);
    expect(controller.preview.positionMs, startPositionMs + 300000);
    expect(transport.scrubs, isNotEmpty);
    expect(chipText(tester, const Key('ruler_delta')), '+5:00');
    expect(haptics, isNotEmpty); // minute ticks while crossing frames

    await gesture.up();
    await tester.pump();
    expect(controller.settling, true);
    expect(transport.seeks, hasLength(1));
    expect(transport.seeks.single, startPositionMs + 300000);

    // A newer telemetry frame re-attaches to idle (settle convergence).
    push(
      positionMs: transport.seeks.single + 500,
      timestamp: futureTs() + 1,
    );
    await tester.pump();
    expect(controller.phase, ScrubPhase.idle);
  });

  testWidgets('tap right of centre seeks a few fine seconds forward',
      (WidgetTester tester) async {
    push();
    await pumpRuler(tester);

    final Offset centre = tester.getCenter(find.byKey(const Key('ruler_track')));
    await tester.tapAt(centre + const Offset(100, 0));
    await tester.pump();

    final int delta = controller.preview.positionMs - startPositionMs;
    // 100 px x (1000 ms / 24 px) ~ 4167 ms in the fine tier.
    expect(delta, greaterThan(4000));
    expect(delta, lessThan(4300));
    expect(transport.seeks, hasLength(1)); // tap commits immediately

    push(
      positionMs: controller.preview.positionMs + 500,
      timestamp: futureTs() + 1,
    );
    await tester.pump();
    expect(controller.phase, ScrubPhase.idle);
  });

  testWidgets('disabled ruler never engages the scrub engine',
      (WidgetTester tester) async {
    push();
    await pumpRuler(tester, enabled: false);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('ruler_track'))),
    );
    await gesture.moveBy(const Offset(400, 0));
    await gesture.moveBy(const Offset(400, 0));
    await gesture.up();
    await tester.pump();

    expect(controller.dragging, isFalse);
    expect(transport.scrubs, isEmpty);
    expect(transport.seeks, isEmpty);
    expect(controller.phase, ScrubPhase.idle);
  });
}
