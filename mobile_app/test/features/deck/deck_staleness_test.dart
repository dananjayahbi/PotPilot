import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/deck/potplayer_deck.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Fake Doc 31 client — captures envelopes, connection flag injectable.
class _FakeWsClient extends WsClient {
  bool connected = true;

  final List<WsMessage> sent = <WsMessage>[];
  final StreamController<WsConnectionState> _states =
      StreamController<WsConnectionState>.broadcast();
  final StreamController<WsMessage> _replies =
      StreamController<WsMessage>.broadcast();

  @override
  WsConnectionState get state =>
      connected ? WsConnectionState.connected : WsConnectionState.backoff;

  @override
  Stream<WsConnectionState> get stateChanges => _states.stream;

  @override
  Stream<WsMessage> get envelopes => _replies.stream;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(buildMessage(type: type, action: action, payload: payload));
  }

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

void main() {
  late _FakeWsClient client;
  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late PotPlayerDeckController controller;

  setUp(() async {
    client = _FakeWsClient();
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
    controller = PotPlayerDeckController(
      client: client,
      playHaptic: (HapticPattern pattern) async {},
    );
  });

  tearDown(() async {
    await socket.close();
    await client.close();
  });

  void push({
    int positionMs = 300000,
    int durationMs = 600000,
    double? speed = 2.0,
    bool running = true,
    int ageSecondsBehindNow = 0,
  }) {
    final int nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Fresh frames sit 30 s in the future so full-suite scheduling delays
    // between push and assertion can never read stale; stale frames are
    // pushed [ageSecondsBehindNow] whole seconds into the past (> 1000 ms).
    final int timestamp = ageSecondsBehindNow > 0
        ? nowSec - ageSecondsBehindNow
        : nowSec + 30;
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000003',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: <String, dynamic>{
          'position_ms': positionMs,
          'duration_ms': durationMs,
          'is_playing': true,
          if (speed != null) 'speed': speed,
          'volume': 42,
          'file_title': 'Interstellar',
          'potplayer_found': running,
        },
        timestamp: timestamp,
      ),
    );
  }

  List<Override> overrides() => <Override>[
        telemetryProvider.overrideWith((ref) => notifier),
        // ChangeNotifierProvider disposes the injected notifier itself.
        deckControllerProvider.overrideWith((ref) => controller),
      ];

  Future<void> pumpDeck(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(body: PotPlayerDeck()),
        ),
      ),
    );
    await tester.pump();
  }

  bool keyEnabled(WidgetTester tester, DeckAction action) =>
      tester.widget<DeckButton>(find.byKey(deckKeyFor(action))).enabled;

  testWidgets(
    'stale snapshot (age > 1000 ms) dims the grid to 50 % and disables '
    'the speed row',
    (WidgetTester tester) async {
      // Unix-second clock: age lands at 3+ s (> kStaleAfter = 1000 ms).
      push(ageSecondsBehindNow: 3, speed: 2.0);
      await pumpDeck(tester);

      expect(
        tester.widget<Opacity>(find.byKey(const Key('deck_dim'))).opacity,
        0.5,
        reason: 'stale telemetry dims the whole grid (§4.6)',
      );
      expect(keyEnabled(tester, DeckAction.speedDown), isFalse);
      expect(keyEnabled(tester, DeckAction.speedReset), isFalse);
      expect(keyEnabled(tester, DeckAction.speedUp), isFalse);
      // Seeks stay live while media was known; play still dispatches.
      expect(keyEnabled(tester, DeckAction.seekFwd5), isTrue);
      expect(keyEnabled(tester, DeckAction.playPause), isTrue);
    },
  );

  testWidgets('speed == null (never received) disables the speed row',
      (WidgetTester tester) async {
    push(speed: null); // fresh frame without a `speed` key -> base unknown
    await pumpDeck(tester);

    expect(
      tester.widget<Opacity>(find.byKey(const Key('deck_dim'))).opacity,
      1.0,
      reason: 'fresh frame — staleness dim must not engage',
    );
    expect(keyEnabled(tester, DeckAction.speedDown), isFalse);
    expect(keyEnabled(tester, DeckAction.speedReset), isFalse);
    expect(keyEnabled(tester, DeckAction.speedUp), isFalse);
    expect(
      tester.widget<Text>(find.byKey(const Key('deck_speed_badge'))).data,
      '--',
    );
    expect(keyEnabled(tester, DeckAction.seekFwd5), isTrue);
  });

  testWidgets('potplayer_found == false kills the whole grid (§5)',
      (WidgetTester tester) async {
    push(running: false);
    await pumpDeck(tester);

    expect(find.byKey(const Key('deck_closed_caption')), findsOneWidget);
    expect(
      tester.widget<Opacity>(find.byKey(const Key('deck_dim'))).opacity,
      0.5,
    );
    for (final DeckAction action in DeckAction.values) {
      expect(keyEnabled(tester, action), isFalse, reason: action.name);
    }
  });

  testWidgets('WS not connected: crimson strip, grid disabled, no dispatch',
      (WidgetTester tester) async {
    client.connected = false;
    push();
    await pumpDeck(tester);

    expect(find.byKey(const Key('deck_reconnect_strip')), findsOneWidget);
    expect(
      tester.widget<Opacity>(find.byKey(const Key('deck_dim'))).opacity,
      0.5,
    );
    expect(keyEnabled(tester, DeckAction.playPause), isFalse);

    await tester.tap(find.byKey(deckKeyFor(DeckAction.playPause)));
    await tester.pump();
    expect(client.sent, isEmpty, reason: 'no dispatch attempts while down');
  });
}
