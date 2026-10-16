import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/core/haptics/haptic_engine.dart';
import 'package:potpilot_remote/features/tracks/audio_sub_modal.dart';
import 'package:potpilot_remote/network/ws_client.dart';

/// Fake Doc 31 client — captures envelopes, no sockets.
class _FakeWsClient extends WsClient {
  _FakeWsClient({bool connected = true}) : _connected = connected;

  final bool _connected;
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

  Future<void> close() => _states.close();
}

void main() {
  group('formatSyncOffset readout formatting', () {
    test('renders one-decimal seconds with true minus / explicit plus', () {
      expect(formatSyncOffset(0), '0.0s');
      expect(formatSyncOffset(500), '+0.5s');
      expect(formatSyncOffset(-500), '\u22120.5s');
      expect(formatSyncOffset(-1500), '\u22121.5s');
      expect(formatSyncOffset(1500), '+1.5s');
    });

    test('±10.0 s edges render exactly (no float artifacts)', () {
      expect(formatSyncOffset(-10000), '\u221210.0s');
      expect(formatSyncOffset(10000), '+10.0s');
      // The classic double-formatting failure this formatter must avoid.
      expect(formatSyncOffset(300), isNot(contains('3000000')));
      expect(formatSyncOffset(-300), isNot(contains('3000000')));
    });
  });

  group('dispatch haptics (mock sink)', () {
    test('sync zero-crossing triggers exactly one heavyThud', () async {
      final _FakeWsClient client = _FakeWsClient();
      final List<HapticPattern> haptics = <HapticPattern>[];
      final AudioSubModalController controller = AudioSubModalController(
        client: client,
        playHaptic: (HapticPattern pattern) async {
          haptics.add(pattern);
        },
      );

      const TrackModalState before = TrackModalState(
        audioIndex: 1,
        subIndex: 1,
        subsOn: false,
        syncOffsetMs: -500,
        fileTitle: 'Arrival',
      );
      await controller.dispatch(TrackAction.syncPlus, before);

      expect(haptics, <HapticPattern>[HapticPattern.heavyThud]);
      expect(client.sent, hasLength(1));
      expect(
        client.sent.single['payload'],
        <String, dynamic>{'delta_ms': 500},
      );
    });

    test('non-zero nudges fire a single microTick', () async {
      final _FakeWsClient client = _FakeWsClient();
      final List<HapticPattern> haptics = <HapticPattern>[];
      final AudioSubModalController controller = AudioSubModalController(
        client: client,
        playHaptic: (HapticPattern pattern) async {
          haptics.add(pattern);
        },
      );

      await controller.dispatch(
        TrackAction.syncPlus,
        const TrackModalState(
          audioIndex: 1,
          subIndex: 1,
          subsOn: false,
          syncOffsetMs: 0,
          fileTitle: 'Arrival',
        ),
      );

      expect(haptics, <HapticPattern>[HapticPattern.microTick]);
      expect(client.sent, hasLength(1));
    });

    test('nudge already at the ±10000 bound dispatches nothing', () async {
      final _FakeWsClient client = _FakeWsClient();
      final List<HapticPattern> haptics = <HapticPattern>[];
      final AudioSubModalController controller = AudioSubModalController(
        client: client,
        playHaptic: (HapticPattern pattern) async {
          haptics.add(pattern);
        },
      );

      const TrackModalState atBound = TrackModalState(
        audioIndex: 1,
        subIndex: 1,
        subsOn: false,
        syncOffsetMs: -kSyncMaxMs,
        fileTitle: 'Arrival',
      );
      await controller.dispatch(TrackAction.syncMinus, atBound);

      expect(client.sent, isEmpty, reason: 'no silent clamped dispatch');
      expect(haptics, isEmpty);
    });

    test('offline dispatch is a complete no-op', () async {
      final _FakeWsClient client = _FakeWsClient(connected: false);
      final AudioSubModalController controller = AudioSubModalController(
        client: client,
        playHaptic: (HapticPattern pattern) async {},
      );

      await controller.dispatch(
        TrackAction.cycleAudio,
        const TrackModalState(
          audioIndex: 1,
          subIndex: 1,
          subsOn: false,
          syncOffsetMs: 0,
          fileTitle: null,
        ),
      );

      expect(client.sent, isEmpty);
    });
  });
}
