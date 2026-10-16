import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/theme/oled_theme.dart';
import 'package:potpilot_remote/features/tracks/audio_sub_modal.dart';
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

Map<String, dynamic> _payload({String? fileTitle}) {
  return <String, dynamic>{
    'position_ms': 1000,
    'duration_ms': 60000,
    'is_playing': true,
    'speed': 1.0,
    'volume': 50,
    'file_title': fileTitle,
    'potplayer_found': true,
    'blackout_active': false,
    'brightness': 80,
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

  setUp(() {
    client = _FakeWsClient();
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
  });

  tearDown(() async {
    await socket.close();
    await client.close();
  });

  void pushTelemetry({String? fileTitle, int? timestamp}) {
    notifier.handleEnvelope(
      WsMessage(
        id: '00000000-0000-4000-8000-000000000000',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: _payload(fileTitle: fileTitle),
        timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  List<Override> overrides() => <Override>[
    audioSubControllerProvider.overrideWithValue(
      AudioSubModalController(client: client, playHaptic: (pattern) async {}),
    ),
    telemetryProvider.overrideWith((ref) => notifier),
  ];

  Future<void> pumpModal(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: buildOledTheme(),
          home: const Scaffold(body: AudioSubModal()),
        ),
      ),
    );
    await tester.pump();
  }

  String readout(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('track_sync_readout'))).data!;

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
    testWidgets('each row dispatches exactly one frozen envelope', (
      WidgetTester tester,
    ) async {
      await pumpModal(tester);
      pushTelemetry(fileTitle: 'Arrival');
      await tester.pump();

      // Audio cycle.
      await tester.tap(find.byKey(const Key('track_cycle_audio')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_POTPLAYER', 'CYCLE_AUDIO', <String, dynamic>{}),
      ]);
      expect(find.text('Track 2'), findsOneWidget);
      client.sent.clear();

      // Subtitle cycle (row stays `Off` until subtitles are switched on).
      await tester.tap(find.byKey(const Key('track_cycle_subs')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope('CMD_POTPLAYER', 'CYCLE_SUBS', <String, dynamic>{}),
      ]);
      expect(find.text('Off'), findsOneWidget);
      client.sent.clear();

      // Subtitles toggle — optimistic switch matches payload this frame.
      await tester.tap(find.byKey(const Key('track_subs_switch')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope(
          'CMD_POTPLAYER',
          'SET_SUBS',
          <String, dynamic>{'enabled': true},
        ),
      ]);
      expect(
        tester.widget<Switch>(find.byKey(const Key('track_subs_switch'))).value,
        true,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('track_sub_value'))).data,
        'Track 2',
        reason: 'subs now shown (sub cycled once before switching on)',
      );
      client.sent.clear();

      // Sync nudge: readout steps and payload carries the frozen ∓500 ms.
      await tester.tap(find.byKey(const Key('track_sync_minus')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope(
          'CMD_POTPLAYER',
          'SUB_SYNC_ADJUST',
          <String, dynamic>{'delta_ms': -500},
        ),
      ]);
      expect(readout(tester), '\u22120.5s');
      client.sent.clear();

      await tester.tap(find.byKey(const Key('track_sync_minus')));
      await tester.pump();
      expect(readout(tester), '\u22121.0s');
      client.sent.clear();

      await tester.tap(find.byKey(const Key('track_sync_plus')));
      await tester.pump();
      expect(client.sent, <Map<String, Object?>>[
        envelope(
          'CMD_POTPLAYER',
          'SUB_SYNC_ADJUST',
          <String, dynamic>{'delta_ms': 500},
        ),
      ]);
      expect(readout(tester), '\u22120.5s');
    });

    testWidgets('sync clamps at ±10.0 s with the nudge button disabled', (
      WidgetTester tester,
    ) async {
      await pumpModal(tester);
      pushTelemetry(fileTitle: 'Arrival');
      await tester.pump();

      for (int i = 0; i < 20; i++) {
        await tester.tap(find.byKey(const Key('track_sync_minus')));
        await tester.pump();
      }
      expect(client.sent, hasLength(20));
      expect(readout(tester), '\u221210.0s');

      final TextButton minus = tester.widget<TextButton>(
        find.byKey(const Key('track_sync_minus')),
      );
      expect(minus.onPressed, isNull, reason: 'bound disables the button');

      // A tap at the bound leaves nothing on the wire.
      await tester.tap(find.byKey(const Key('track_sync_minus')));
      await tester.pump();
      expect(client.sent, hasLength(20));

      // The opposite direction re-opens the range.
      final TextButton plus = tester.widget<TextButton>(
        find.byKey(const Key('track_sync_plus')),
      );
      expect(plus.onPressed, isNotNull);
    });
  });

  group('offline gate', () {
    testWidgets('opening offline sends nothing and disables every row', (
      WidgetTester tester,
    ) async {
      client.setConnected(false);
      await pumpModal(tester);

      expect(find.byKey(const Key('track_reconnect_strip')), findsOneWidget);
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('track_subs_switch')))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('track_sync_minus')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('track_cycle_audio')))
            .onPressed,
        isNull,
      );

      await tester.tap(
        find.byKey(const Key('track_cycle_audio')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('track_cycle_subs')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('track_sync_minus')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('track_sync_plus')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const Key('track_subs_switch')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(client.sent, isEmpty);
    });

    testWidgets('reconnecting restores dispatch', (WidgetTester tester) async {
      await pumpModal(tester);
      expect(find.byKey(const Key('track_reconnect_strip')), findsNothing);

      client.setConnected(false);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('track_reconnect_strip')), findsOneWidget);

      client.setConnected(true);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('track_reconnect_strip')), findsNothing);

      await tester.tap(find.byKey(const Key('track_cycle_audio')));
      await tester.pump();
      expect(client.sent, hasLength(1));
    });
  });

  group('reset boundary (§4.4)', () {
    testWidgets('fileTitle change resets counters/offset/toggle', (
      WidgetTester tester,
    ) async {
      await pumpModal(tester);
      pushTelemetry(fileTitle: 'Arrival');
      await tester.pump();

      await tester.tap(find.byKey(const Key('track_cycle_audio')));
      await tester.tap(find.byKey(const Key('track_subs_switch')));
      await tester.tap(find.byKey(const Key('track_sync_plus')));
      await tester.pump();
      expect(find.text('Track 2'), findsOneWidget);
      expect(readout(tester), '+0.5s');
      expect(
        tester.widget<Switch>(find.byKey(const Key('track_subs_switch'))).value,
        true,
      );
      client.sent.clear();

      pushTelemetry(fileTitle: 'Blade Runner');
      await tester.pump();

      expect(find.text('Track 1'), findsOneWidget);
      expect(readout(tester), '0.0s');
      expect(
        tester.widget<Switch>(find.byKey(const Key('track_subs_switch'))).value,
        false,
      );
      expect(client.sent, isEmpty, reason: 'reset never dispatches');
    });

    testWidgets('staleness alone (same fileTitle, old frame) never resets', (
      WidgetTester tester,
    ) async {
      await pumpModal(tester);
      pushTelemetry(fileTitle: 'Arrival');
      await tester.pump();

      await tester.tap(find.byKey(const Key('track_cycle_audio')));
      await tester.tap(find.byKey(const Key('track_sync_plus')));
      await tester.pump();
      client.sent.clear();

      // Same title, stale timestamp (far beyond the 1000 ms window).
      pushTelemetry(fileTitle: 'Arrival', timestamp: 1760000000);
      await tester.pump();

      expect(find.text('Track 2'), findsOneWidget);
      expect(readout(tester), '+0.5s');
      expect(client.sent, isEmpty);
    });

    testWidgets('readout is forced to 0.0s while no file is loaded', (
      WidgetTester tester,
    ) async {
      await pumpModal(tester);
      await tester.pump();
      expect(find.text('No file'), findsOneWidget);
      expect(readout(tester), '0.0s');

      await tester.tap(find.byKey(const Key('track_sync_plus')));
      await tester.pump();
      expect(client.sent, hasLength(1), reason: 'rows stay enabled');
      expect(readout(tester), '0.0s', reason: 'forced readout without media');
    });
  });

  group('presentation', () {
    testWidgets('entry point opens on #000000 and drag-dismisses', (
      WidgetTester tester,
    ) async {
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

      showAudioSubtitleModal(tester.element(find.byType(Scaffold)));
      await tester.pumpAndSettle();

      expect(find.byType(AudioSubModal), findsOneWidget);
      expect(find.text('Audio stream'), findsOneWidget);
      expect(find.text('Subtitle track'), findsOneWidget);
      expect(find.text('Subtitles'), findsOneWidget);
      expect(find.text('Subtitle sync'), findsOneWidget);
      final BottomSheet sheet = tester.widget<BottomSheet>(
        find.byType(BottomSheet),
      );
      expect(sheet.backgroundColor, AppColors.background);

      // Drag-to-dismiss.
      await tester.fling(find.text('Audio stream'), const Offset(0, 600), 1000);
      await tester.pumpAndSettle();
      expect(find.byType(AudioSubModal), findsNothing);
    });
  });
}
