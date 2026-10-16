import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Fake Doc 31 client seam — no sockets, no timers.
class _FakeSocket implements TelemetrySocket {
  final StreamController<WsMessage> envelopeCtrl =
      StreamController<WsMessage>.broadcast();
  final StreamController<WsConnectionState> stateCtrl =
      StreamController<WsConnectionState>.broadcast();

  @override
  Stream<WsMessage> get envelopes => envelopeCtrl.stream;

  @override
  Stream<WsConnectionState> get stateChanges => stateCtrl.stream;

  Future<void> close() async {
    await envelopeCtrl.close();
    await stateCtrl.close();
  }
}

const int _ts = 1760000000;

WsMessage _frame(String action, Map<String, dynamic> payload, {int ts = _ts}) {
  return WsMessage(
    id: '00000000-0000-4000-8000-000000000000',
    type: typeTelemetrySync,
    action: action,
    payload: payload,
    timestamp: ts,
  );
}

/// Doc 03 §5.6 golden FULL_STATE payload — all fourteen frozen keys.
const Map<String, Object?> _golden = <String, Object?>{
  'position_ms': 3661000,
  'duration_ms': 7200000,
  'is_playing': true,
  'speed': 1.5,
  'volume': 42,
  'file_title': 'Interstellar',
  'potplayer_found': true,
  'blackout_active': false,
  'brightness': 80,
  'sys_volume': 55,
  'sys_muted': false,
  'sleep_timer_active': false,
  'sleep_timer_mode': null,
  'sleep_timer_remaining_s': null,
};

Map<String, dynamic> _goldenPayload() =>
    Map<String, dynamic>.from(_golden);

/// The eight non-core keys expected verbatim in `extras`.
const Map<String, Object?> _goldenExtras = <String, Object?>{
  'potplayer_found': true,
  'blackout_active': false,
  'brightness': 80,
  'sys_volume': 55,
  'sys_muted': false,
  'sleep_timer_active': false,
  'sleep_timer_mode': null,
  'sleep_timer_remaining_s': null,
};

void main() {
  late _FakeSocket socket;
  late TelemetryNotifier notifier;

  setUp(() {
    socket = _FakeSocket();
    notifier = TelemetryNotifier(socket);
    notifier.bind();
  });

  tearDown(() async {
    if (notifier.mounted) {
      notifier.dispose();
    }
    await socket.close();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('golden FULL_STATE parse', () {
    test('maps every 03 §5.6 key to the expected TelemetryState', () {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      final TelemetryState s = notifier.snapshot;

      expect(s.timestamp, _ts);
      expect(s.positionMs, 3661000);
      expect(s.durationMs, 7200000);
      expect(s.isPlaying, isTrue);
      expect(s.speed, 1.5);
      expect(s.potPlayerVolume, 42);
      expect(s.fileTitle, 'Interstellar');
      expect(s.isConnected, isTrue);
      expect(s.extras, _goldenExtras);
      expect(s.progress, closeTo(3661000 / 7200000, 1e-9));
      expect(s.positionLabel, '01:01:01');
      expect(s.durationLabel, '02:00:00');
      expect(notifier.parseErrors, 0);
    });

    test('stream delivery: envelope pushed to the fake socket binds through',
        () async {
      socket.envelopeCtrl.add(_frame(actionFullState, _goldenPayload()));
      await pump();
      expect(notifier.snapshot.isPlaying, isTrue);
      expect(notifier.snapshot.isConnected, isTrue);
    });
  });

  group('envelope filter', () {
    test('CMD_POTPLAYER frame and its _RESULT ack leave state untouched',
        () {
      final TelemetryState before = notifier.snapshot;
      notifier.handleEnvelope(
        const WsMessage(
          id: '00000000-0000-4000-8000-000000000001',
          type: typeCmdPotplayer,
          action: Action.playPause,
          payload: <String, dynamic>{},
          timestamp: _ts,
        ),
      );
      notifier.handleEnvelope(
        const WsMessage(
          id: '00000000-0000-4000-8000-000000000001',
          type: typeCmdPotplayer,
          action: '${Action.playPause}$resultSuffix',
          payload: <String, dynamic>{'ok': true},
          timestamp: _ts,
        ),
      );
      expect(identical(notifier.snapshot, before), isTrue);
      expect(notifier.parseErrors, 0);
    });
  });

  group('STATE_DELTA merge', () {
    test('delta {is_playing:false} changes exactly one field', () {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      final TelemetryState full = notifier.snapshot;

      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'is_playing': false}),
      );
      final TelemetryState delta = notifier.snapshot;

      expect(delta.isPlaying, isFalse);
      expect(delta.timestamp, full.timestamp);
      expect(delta.positionMs, full.positionMs);
      expect(delta.durationMs, full.durationMs);
      expect(delta.speed, full.speed);
      expect(delta.potPlayerVolume, full.potPlayerVolume);
      expect(delta.fileTitle, full.fileTitle);
      expect(delta.isConnected, full.isConnected);
      expect(delta.extras, full.extras);
    });

    test('absent keys in a delta never erase fields', () {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'volume': 7}),
      );
      expect(notifier.snapshot.potPlayerVolume, 7);
      expect(notifier.snapshot.fileTitle, 'Interstellar');
      expect(notifier.snapshot.positionMs, 3661000);
    });

    test('FULL_STATE replaces the snapshot wholesale (extras key vanishes)',
        () {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      expect(notifier.snapshot.extras.containsKey('brightness'), isTrue);

      final Map<String, dynamic> smaller = _goldenPayload()
        ..remove('brightness');
      notifier.handleEnvelope(_frame(actionFullState, smaller));
      expect(notifier.snapshot.extras.containsKey('brightness'), isFalse);
      // Field itself keeps last-known value (key absent from snapshot).
      expect(notifier.snapshot.isConnected, isTrue);
    });

    test('unknown action is treated as FULL_STATE (defensive)', () {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      notifier.handleEnvelope(_frame('SOME_FUTURE_ACTION', <String, dynamic>{
        'is_playing': false,
      }));
      // Whole snapshot replaced: only is_playing survives from before…
      expect(notifier.snapshot.isPlaying, isFalse);
      expect(notifier.snapshot.extras, <String, Object?>{});
    });
  });

  group('normalization / clamps', () {
    Future<void> seed() async {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
    }

    test('position_ms -1 normalizes to 0', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'position_ms': -1}),
      );
      expect(notifier.snapshot.positionMs, 0);
      expect(notifier.parseErrors, 0);
    });

    test('volume 150 clamps to 100, -5 clamps to 0', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'volume': 150}),
      );
      expect(notifier.snapshot.potPlayerVolume, 100);
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'volume': -5}),
      );
      expect(notifier.snapshot.potPlayerVolume, 0);
      expect(notifier.parseErrors, 0);
    });

    test('string position_ms ⇒ prior value + parseErrors', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{
          'position_ms': 'not-a-number',
        }),
      );
      expect(notifier.snapshot.positionMs, 3661000);
      expect(notifier.parseErrors, 1);
    });

    test('speed 9.9 ⇒ prior value + parseErrors', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'speed': 9.9}),
      );
      expect(notifier.snapshot.speed, 1.5);
      expect(notifier.parseErrors, 1);
    });

    test('speed NaN ⇒ prior value + parseErrors', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'speed': double.nan}),
      );
      expect(notifier.snapshot.speed, 1.5);
      expect(notifier.parseErrors, 1);
    });

    test('explicit null on speed ⇒ prior value + parseErrors', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'speed': null}),
      );
      expect(notifier.snapshot.speed, 1.5);
      expect(notifier.parseErrors, 1);
    });

    test('array file_title ⇒ prior title + parseErrors', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{
          'file_title': <String>['nope'],
        }),
      );
      expect(notifier.snapshot.fileTitle, 'Interstellar');
      expect(notifier.parseErrors, 1);
    });

    test('whitespace-only file_title keeps previous (no parseError)',
        () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'file_title': '   '}),
      );
      expect(notifier.snapshot.fileTitle, 'Interstellar');
      expect(notifier.parseErrors, 0);
    });

    test('legal explicit null file_title clears to idle', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'file_title': null}),
      );
      expect(notifier.snapshot.fileTitle, isNull);
      expect(notifier.parseErrors, 0);
    });

    test('malformed value heals: next valid frame applies cleanly', () async {
      await seed();
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'speed': 9.9}),
      );
      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'speed': 2.25}),
      );
      expect(notifier.snapshot.speed, 2.25);
      expect(notifier.parseErrors, 1);
    });
  });

  group('equal-state suppression', () {
    test('identical frame twice ⇒ same state instance, one notification',
        () {
      int notified = 0;
      notifier.addListener((TelemetryState _) => notified++);
      // state_notifier's addListener fires immediately with the current
      // state (fireImmediately defaults true) — that is registration, not
      // a change notification; capture it as the baseline.
      final int baseline = notified;
      expect(baseline, 1);

      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      final TelemetryState afterFirst = notifier.snapshot;
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));

      expect(identical(notifier.snapshot, afterFirst), isTrue);
      expect(notified, baseline + 1);
    });

    test('duplicate non-changing delta does not churn state', () async {
      int notified = 0;
      notifier.addListener((TelemetryState _) => notified++);
      final int baseline = notified;
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      expect(notified, baseline + 1);

      notifier.handleEnvelope(
        _frame(actionStateDelta, <String, dynamic>{'volume': 42}),
      );
      expect(notified, baseline + 1);
    });
  });

  group('connection transitions', () {
    test('backoff greys out once; values preserved; frame restores',
        () async {
      int notified = 0;
      notifier.addListener((TelemetryState _) => notified++);

      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      final TelemetryState live = notifier.snapshot;
      expect(live.isConnected, isTrue);
      final int afterLive = notified;

      socket.stateCtrl.add(WsConnectionState.backoff);
      await pump();
      final TelemetryState down = notifier.snapshot;
      expect(down.isConnected, isFalse);
      expect(notified, afterLive + 1);

      // Idempotent: another backoff adds no notification.
      socket.stateCtrl.add(WsConnectionState.backoff);
      await pump();
      expect(notifier.snapshot.isConnected, isFalse);
      expect(notified, afterLive + 1);

      // Values byte-identical to the live snapshot apart from the flag.
      expect(
        notifier.snapshot.copyWith(isConnected: true),
        live,
      );

      // `connected` alone does not re-enable…
      socket.stateCtrl.add(WsConnectionState.connected);
      await pump();
      expect(notifier.snapshot.isConnected, isFalse);

      // …only an actual TELEMETRY_SYNC frame does.
      socket.envelopeCtrl.add(_frame(actionFullState, _goldenPayload()));
      await pump();
      expect(notifier.snapshot.isConnected, isTrue);
      expect(notifier.snapshot, live);
    });

    test('authRejected and closed both mark disconnected', () async {
      notifier.handleEnvelope(_frame(actionFullState, _goldenPayload()));
      socket.stateCtrl.add(WsConnectionState.authRejected);
      await pump();
      expect(notifier.snapshot.isConnected, isFalse);

      socket.envelopeCtrl.add(_frame(actionFullState, _goldenPayload()));
      await pump();
      expect(notifier.snapshot.isConnected, isTrue);

      socket.stateCtrl.add(WsConnectionState.closed);
      await pump();
      expect(notifier.snapshot.isConnected, isFalse);
    });
  });

  group('progress / labels', () {
    test('durationMs 0 ⇒ progress 0 and dash labels', () {
      notifier.handleEnvelope(
        _frame(
          actionFullState,
          <String, dynamic>{
            'position_ms': 0,
            'duration_ms': 0,
            'is_playing': false,
            'speed': 1.0,
            'volume': 0,
            'file_title': null,
          },
        ),
      );
      final TelemetryState s = notifier.snapshot;
      expect(s.progress, 0.0);
      expect(s.positionLabel, '--:--:--');
      expect(s.durationLabel, '--:--:--');
      expect(s.fileTitle, isNull);
    });

    test('positionMs > durationMs caps progress at 1.0', () {
      notifier.handleEnvelope(
        _frame(
          actionFullState,
          <String, dynamic>{
            'position_ms': 900000,
            'duration_ms': 600000,
            'is_playing': true,
            'speed': 1.0,
            'volume': 50,
            'file_title': 'x',
          },
        ),
      );
      expect(notifier.snapshot.progress, 1.0);
      expect(notifier.snapshot.positionLabel, '00:15:00');
      expect(notifier.snapshot.durationLabel, '00:10:00');
    });
  });

  group('staleness clock', () {
    test('timestamp never moves backwards but fields still update', () {
      notifier.handleEnvelope(
        _frame(actionFullState, _goldenPayload(), ts: 1760001000),
      );
      expect(notifier.snapshot.timestamp, 1760001000);

      notifier.handleEnvelope(
        _frame(
          actionStateDelta,
          <String, dynamic>{'position_ms': 4242},
          ts: 1760000500, // rewound PC clock
        ),
      );
      expect(notifier.snapshot.timestamp, 1760001000);
      expect(notifier.snapshot.positionMs, 4242);
    });

    test('frame timestamp < 1 falls back to local epoch seconds', () {
      notifier.handleEnvelope(
        _frame(actionFullState, _goldenPayload(), ts: 0),
      );
      expect(notifier.snapshot.timestamp, greaterThan(1000000000));
    });
  });

  group('cadence soak (scaled)', () {
    test('2400 delta frames: no parse errors, single final state, one '
        'notification each', () {
      int notified = 0;
      notifier.addListener((TelemetryState _) => notified++);
      // Registration fire (state_notifier fireImmediately default) excluded.
      final int baseline = notified;

      const int base = 1760000000;
      notifier.handleEnvelope(
        _frame(
          actionFullState,
          <String, dynamic>{'is_playing': true, 'speed': 1.0},
          ts: base,
        ),
      );
      for (int i = 1; i < 2400; i++) {
        notifier.handleEnvelope(
          _frame(
            actionStateDelta,
            <String, dynamic>{'position_ms': i * 250},
            ts: base + (i ~/ 4), // ~250 ms cadence ⇒ unix-second ticks
          ),
        );
      }

      final TelemetryState s = notifier.snapshot;
      expect(s.positionMs, 2399 * 250);
      expect(s.isPlaying, isTrue);
      expect(s.speed, 1.0);
      expect(s.timestamp, base + (2399 ~/ 4));
      expect(notifier.parseErrors, 0);
      // initial full frame + 2399 deltas, each with a changed position
      expect(notified, baseline + 2400);
    });
  });

  group('dispose safety', () {
    test('after dispose, envelopes and calls are inert', () async {
      final Future<void> envelopes = socket.envelopeCtrl.close();
      notifier.dispose();

      expect(notifier.mounted, isFalse);
      expect(
        () => notifier.handleEnvelope(_frame(actionFullState, _goldenPayload())),
        returnsNormally,
      );
      expect(() => notifier.markDisconnected(), returnsNormally);
      await envelopes;
    });
  });

  group('telemetryProvider wiring', () {
    test('reads as a non-autoDispose provider starting at initial state', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);

      final TelemetryState first = container.read(telemetryProvider);
      expect(first, TelemetryState.initial);
      expect(identical(container.read(telemetryProvider), first), isTrue);
      // Provider survives losing all listeners (autoDispose: false).
      final TelemetryState third = container.read(telemetryProvider);
      expect(identical(third, first), isTrue);
    });
  });
}
