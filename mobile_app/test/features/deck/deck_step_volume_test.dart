// Focused coverage for the redesigned deck's new behavior: the segmented
// seek-step selector (Riverpod state driving both side buttons' labels
// and the frozen `seek_delta` payloads) and the volume slider
// (`CMD_POTPLAYER SET_VOLUME {percent}` commit + gating). Existing deck
// suites cover keys/gating/staleness unchanged.

import 'dart:async';

import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/deck/potplayer_deck.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart'
    show Action, WsMessage, actionFullState, buildMessage, typeTelemetrySync;

/// Fake Doc 31 client — captures envelopes, connection flag injectable.
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

/// Full-state frame with injectable volume / PotPlayer presence; future-
/// second timestamp keeps the staleness clock fresh across the run.
TelemetryState _state({
  int volume = 42,
  bool potplayerFound = true,
  Map<String, Object?> extras = const <String, Object?>{},
}) {
  return TelemetryState(
    timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30,
    positionMs: 300000,
    durationMs: 600000,
    isPlaying: false,
    speed: 2.0,
    potPlayerVolume: volume,
    fileTitle: 'Interstellar',
    extras: <String, Object?>{
      'potplayer_found': potplayerFound,
      ...extras,
    },
    isConnected: true,
  );
}

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

  /// True once a ProviderScope owns the injected controller (the scope
  /// disposes ChangeNotifiers itself on widget-tree teardown).
  bool controllerOwnedByScope = false;

  tearDown(() async {
    if (!controllerOwnedByScope) {
      controller.dispose(); // controller-only group — nobody else disposes
    }
    await socket.close();
    await client.close();
  });

  void push({int volume = 42, bool potplayerFound = true}) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000004',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: <String, dynamic>{
          'position_ms': 300000,
          'duration_ms': 600000,
          'is_playing': false,
          'speed': 2.0,
          'volume': volume,
          'file_title': 'Interstellar',
          'potplayer_found': potplayerFound,
        },
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
    controllerOwnedByScope = true; // scope teardown disposes the notifier
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

  double sliderValue(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const Key('deck_volume'))).value;

  String volumeReadout(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('deck_volume_value'))).data!;

  List<WsMessage> volumeSends() => client.sent
      .where((WsMessage message) => message.action == Action.setVolume)
      .toList();

  group('seek step selector (§6)', () {
    testWidgets(
      'defaults to 5 s; picking 10 s retargets BOTH side buttons '
      '(label + frozen seek_delta payload)',
      (WidgetTester tester) async {
        push();
        await pumpDeck(tester);

        // Default step: side badges read 5s, segment 5 is selected.
        expect(
          tester.widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.seekBack5)))
              .text,
          '5s',
        );
        expect(
          tester.widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.seekFwd5)))
              .text,
          '5s',
        );
        expect(
          tester.widget<DeckStepSegment>(find.byKey(deckStepKeyFor(5))).selected,
          isTrue,
        );

        // Default dispatch keeps the frozen ±5000 ms wire contract.
        await tester.tap(find.byKey(deckKeyFor(DeckAction.seekFwd5)));
        await tester.pump();
        expect(client.sent, hasLength(1));
        expect(client.sent.single.action, deckActionNames[DeckAction.seekFwd5]);
        expect(client.sent.single.payload, <String, dynamic>{'delta_ms': 5000});

        // Switch the selector to 10 s: selection state + both labels flip.
        await tester.tap(find.byKey(deckStepKeyFor(10)));
        await tester.pump();
        expect(
          tester.widget<DeckStepSegment>(find.byKey(deckStepKeyFor(10)))
              .selected,
          isTrue,
        );
        expect(
          tester.widget<DeckStepSegment>(find.byKey(deckStepKeyFor(5))).selected,
          isFalse,
        );
        expect(
          tester.widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.seekBack5)))
              .text,
          '10s',
        );
        expect(
          tester.widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.seekFwd5)))
              .text,
          '10s',
        );

        // The other side button now seeks ±10000 ms — still `seek_delta`.
        client.sent.clear();
        await tester.tap(find.byKey(deckKeyFor(DeckAction.seekBack5)));
        await tester.pump();
        expect(client.sent, hasLength(1));
        expect(client.sent.single.action, deckActionNames[DeckAction.seekBack5]);
        expect(client.sent.single.payload, <String, dynamic>{'delta_ms': -10000});
      },
    );

    testWidgets('selected step survives a telemetry rebuild (Riverpod state)',
        (WidgetTester tester) async {
      push();
      await pumpDeck(tester);
      await tester.tap(find.byKey(deckStepKeyFor(30)));
      await tester.pump();

      push(); // fresh frame rebuilds the deck — provider state persists
      await tester.pump();
      expect(
        tester.widget<DeckStepSegment>(find.byKey(deckStepKeyFor(30))).selected,
        isTrue,
      );
      expect(
        tester.widget<DeckButton>(find.byKey(deckKeyFor(DeckAction.seekFwd5)))
            .text,
        '30s',
      );

      await tester.tap(find.byKey(deckKeyFor(DeckAction.seekFwd5)));
      await tester.pump();
      expect(client.sent, hasLength(1));
      expect(client.sent.single.payload, <String, dynamic>{'delta_ms': 30000});
    });
  });

  group('volume control', () {
    testWidgets(
      'slider mirrors telemetry, commits SET_VOLUME {percent} once, '
      'and yields to a confirming frame',
      (WidgetTester tester) async {
        push(volume: 42);
        await pumpDeck(tester);
        expect(sliderValue(tester), 42.0);
        expect(volumeReadout(tester), '42%');

        // Drag preview updates the readout without sending.
        tester
            .widget<Slider>(find.byKey(const Key('deck_volume')))
            .onChanged!(70);
        await tester.pump();
        expect(sliderValue(tester), 70.0);
        expect(volumeReadout(tester), '70%');
        expect(volumeSends(), isEmpty);

        // Release commits exactly one envelope.
        tester
            .widget<Slider>(find.byKey(const Key('deck_volume')))
            .onChangeEnd!(70);
        await tester.pump();
        expect(volumeSends(), hasLength(1));
        expect(volumeSends().single.type, 'CMD_POTPLAYER');
        expect(volumeSends().single.payload, <String, dynamic>{'percent': 70});
        expect(haptics, <HapticPattern>[HapticPattern.volumeTick]);

        // Re-committing the last value is a no-op (bed-mode §4.5 dedupe).
        tester
            .widget<Slider>(find.byKey(const Key('deck_volume')))
            .onChangeEnd!(70);
        await tester.pump();
        expect(volumeSends(), hasLength(1));

        // A fresh frame's volume wins over the local preview (§4.4).
        push(volume: 55);
        await tester.pump();
        expect(sliderValue(tester), 55.0);
        expect(volumeReadout(tester), '55%');
      },
    );

    testWidgets('slider disables while WS is down or PotPlayer is closed',
        (WidgetTester tester) async {
      client.setConnected(false);
      push();
      await pumpDeck(tester);
      expect(
        tester.widget<Slider>(find.byKey(const Key('deck_volume'))).onChanged,
        isNull,
      );
      expect(
        tester.widget<Slider>(find.byKey(const Key('deck_volume'))).onChangeEnd,
        isNull,
      );

      client.setConnected(true);
      push(potplayerFound: false);
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('deck_volume'))).onChanged,
        isNull,
      );

      push(); // PotPlayer back — the slider re-arms
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('deck_volume'))).onChanged,
        isNotNull,
      );
    });
  });

  group('controller wire contracts', () {
    test('setVolume clamps, gates offline/closed, dedupes the last value',
        () async {
      final TelemetryState state = _state();

      await controller.setVolume(70, state);
      expect(client.sent.single.action, Action.setVolume);
      expect(client.sent.single.payload, <String, dynamic>{'percent': 70});

      await controller.setVolume(70, state); // deduped
      expect(client.sent, hasLength(1));

      await controller.setVolume(150, state); // clamped high
      expect(client.sent.last.payload, <String, dynamic>{'percent': 100});
      await controller.setVolume(-5, state); // clamped low
      expect(client.sent.last.payload, <String, dynamic>{'percent': 0});
      expect(client.sent, hasLength(3));

      // PotPlayer closed — silent reject (§5/§7).
      await controller.setVolume(
        33,
        _state(potplayerFound: false),
      );
      expect(client.sent, hasLength(3));

      // WS down — silent reject, no queueing (§7).
      client.setConnected(false);
      await controller.setVolume(50, state);
      expect(client.sent, hasLength(3));
      expect(haptics, hasLength(3)); // one tick per actual commit
    });

    test('dispatch parameterises seek_back/forward by step; ±30 s stays fixed',
        () async {
      await controller.dispatch(
        DeckAction.seekFwd5,
        _state(),
        seekStepSeconds: 20,
      );
      expect(client.sent.single.payload, <String, dynamic>{'delta_ms': 20000});
      client.sent.clear();

      // Default step keeps the frozen ±5000 ms payloads.
      await controller.dispatch(DeckAction.seekBack5, _state());
      expect(client.sent.single.payload, <String, dynamic>{'delta_ms': -5000});
      client.sent.clear();

      // The fixed quick-jump keys ignore the step.
      await controller.dispatch(
        DeckAction.seekBack30,
        _state(),
        seekStepSeconds: 20,
      );
      expect(client.sent.single.payload, <String, dynamic>{'delta_ms': -30000});
    });
  });
}
