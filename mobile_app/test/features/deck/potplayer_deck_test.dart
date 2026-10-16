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

/// Fake Doc 31 client — captures one fresh-uuid envelope per send.
class _FakeWsClient extends WsClient {
  bool _connected = true;

  final List<WsMessage> sent = <WsMessage>[];
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
  Stream<WsMessage> get envelopes => _replies.stream;

  @override
  Future<void> send(
    String type,
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    sent.add(buildMessage(type: type, action: action, payload: payload));
  }

  void setConnected(bool value) {
    _connected = value;
    _states.add(state);
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

final RegExp _uuid4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  late _FakeWsClient client;
  late _FakeSocket socket;
  late TelemetryNotifier notifier;
  late PotPlayerDeckController controller;
  late List<HapticPattern> haptics;

  setUp(() async {
    client = _FakeWsClient();
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
    haptics = <HapticPattern>[];
    controller = PotPlayerDeckController(
      client: client,
      playHaptic: (HapticPattern pattern) async {
        haptics.add(pattern);
      },
    );
  });

  tearDown(() async {
    await socket.close();
    await client.close();
  });

  void push({
    int positionMs = 300000,
    int durationMs = 600000,
    bool isPlaying = false,
    double speed = 2.0,
    String? fileTitle = 'Interstellar',
    bool emit = true,
  }) {
    final Map<String, dynamic> payload = <String, dynamic>{
      'position_ms': positionMs,
      'duration_ms': durationMs,
      'is_playing': isPlaying,
      'volume': 42,
      'file_title': fileTitle,
      if (emit) 'speed': speed,
    };
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000002',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: payload,
        // Future-second freshness: the unix-second staleness clock must not
        // trip across a second boundary during the test run — a 30 s margin
        // survives full-suite scheduling delays too.
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30,
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

  group('per-key envelope fidelity (§5)', () {
    testWidgets('all 12 keys emit exactly one frozen CMD_POTPLAYER envelope',
        (WidgetTester tester) async {
      push();
      await pumpDeck(tester);

      final Map<DeckAction, Map<String, dynamic>> expected =
          <DeckAction, Map<String, dynamic>>{
        DeckAction.playPause: <String, dynamic>{},
        DeckAction.seekBack5: <String, dynamic>{'delta_ms': -5000},
        DeckAction.seekFwd5: <String, dynamic>{'delta_ms': 5000},
        DeckAction.seekBack30: <String, dynamic>{'delta_ms': -30000},
        DeckAction.seekFwd30: <String, dynamic>{'delta_ms': 30000},
        DeckAction.speedDown: <String, dynamic>{'multiplier': 1.9},
        DeckAction.speedReset: <String, dynamic>{'multiplier': 1.0},
        DeckAction.speedUp: <String, dynamic>{'multiplier': 2.1},
        DeckAction.framePrev: <String, dynamic>{'direction': 'BACKWARD'},
        DeckAction.frameNext: <String, dynamic>{'direction': 'FORWARD'},
        DeckAction.fullscreen: <String, dynamic>{},
        DeckAction.aspectCycle: <String, dynamic>{},
      };

      final List<String> ids = <String>[];
      for (final MapEntry<DeckAction, Map<String, dynamic>> entry
          in expected.entries) {
        client.sent.clear();
        haptics.clear();
        await tester.tap(find.byKey(deckKeyFor(entry.key)));
        await tester.pump();
        expect(client.sent, hasLength(1), reason: '${entry.key} send count');
        final WsMessage envelope = client.sent.single;
        expect(envelope.type, 'CMD_POTPLAYER');
        expect(envelope.action, deckActionNames[entry.key]);
        expect(envelope.payload, entry.value);
        expect(envelope.id, matches(_uuid4), reason: 'fresh uuid4 id');
        expect(haptics, <HapticPattern>[hapticPatternFor(entry.key)]);
        ids.add(envelope.id);
      }
      expect(ids.toSet(), hasLength(12), reason: 'ids unique across sends');
    });

    testWidgets('play glyph flips before any telemetry arrives',
        (WidgetTester tester) async {
      await pumpDeck(tester); // no telemetry pushed at all
      expect(find.text('\u25b6'), findsOneWidget);
      expect(find.text('\u23f8'), findsNothing);

      await tester.tap(find.byKey(deckKeyFor(DeckAction.playPause)));
      await tester.pump(); // same-frame optimistic flip
      expect(find.text('\u23f8'), findsOneWidget);
      expect(client.sent, hasLength(1));
      expect(client.sent.single.action, 'PLAY_PAUSE');
      expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);
    });
  });

  group('media gating (§4.5 / acceptance)', () {
    testWidgets('seek/frame keys disabled at durationMs: 0 (offstage-safe)',
        (WidgetTester tester) async {
      push(durationMs: 0, positionMs: 0);
      await pumpDeck(tester);

      const List<DeckAction> mediaKeys = <DeckAction>[
        DeckAction.seekBack5,
        DeckAction.seekFwd5,
        DeckAction.seekBack30,
        DeckAction.seekFwd30,
        DeckAction.framePrev,
        DeckAction.frameNext,
      ];
      for (final DeckAction action in mediaKeys) {
        final DeckButton button = tester.widget<DeckButton>(
          find.byKey(deckKeyFor(action), skipOffstage: false),
        );
        expect(button.enabled, isFalse, reason: '${action.name} gating');
      }

      // Disabled keys are silent rejects.
      client.sent.clear();
      await tester.tap(find.byKey(deckKeyFor(DeckAction.seekFwd5)));
      await tester.pump();
      expect(client.sent, isEmpty);

      // Non-media keys stay live without media.
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.fullscreen)))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.aspectCycle)))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.speedUp)))
            .enabled,
        isTrue,
      );
    });

    testWidgets('speed keys disabled at the 0.2x / 4.0x bounds',
        (WidgetTester tester) async {
      push(speed: 4.0);
      await pumpDeck(tester);
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.speedUp)))
            .enabled,
        isFalse,
        reason: '4.0 + 0.1 clamps to current — no clamped no-op dispatch',
      );
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.speedDown)))
            .enabled,
        isTrue,
      );

      // Pump again with 0.2x: the down key becomes bound-adjacent.
      push(speed: 0.2);
      await tester.pump(); // same tree — telemetry rebuild only
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.speedDown)))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.speedUp)))
            .enabled,
        isTrue,
      );
    });
  });
}
