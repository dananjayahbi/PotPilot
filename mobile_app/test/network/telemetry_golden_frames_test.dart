import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/telemetry_provider.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

/// Contract regression guard (Doc 33 §9): the frozen `TELEMETRY_SYNC` key
/// set in `shared_specs/ws_command_schema.json` (03 §5.6) must parse into
/// exactly the expected [TelemetryState] — schema, codec constants, and
/// consumer must never drift apart.
void main() {
  late Map<String, dynamic> schema;

  setUpAll(() {
    final File file = File('../shared_specs/ws_command_schema.json');
    expect(file.existsSync(), isTrue,
        reason: 'shared_specs/ws_command_schema.json must exist');
    schema = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  test('schema telemetry key set matches the codec telemetryKeys list', () {
    final Map<String, dynamic> keys =
        schema['telemetry']['keys'] as Map<String, dynamic>;
    expect(keys.keys.toList(), telemetryKeys);
    expect(schema['telemetry']['interval_ms'], 250);
    expect(kTelemetryCadence.inMilliseconds, 250);
    expect(schema['telemetry']['full_refresh_every_ticks'], 20);
  });

  test('golden FULL_STATE payload (14 keys) parses to exact state', () {
    final Map<String, dynamic> keys =
        schema['telemetry']['keys'] as Map<String, dynamic>;

    // Example values typed exactly as the schema declares them.
    final Map<String, Object?> payload = <String, Object?>{
      'position_ms': 65000,
      'duration_ms': 5400000,
      'is_playing': false,
      'speed': 2.0,
      'volume': 100,
      'file_title': 'Кин-дза-дза',
      'potplayer_found': true,
      'blackout_active': true,
      'brightness': null,
      'sys_volume': 30,
      'sys_muted': true,
      'sleep_timer_active': true,
      'sleep_timer_mode': 'COUNTDOWN',
      'sleep_timer_remaining_s': 900,
    };
    expect(
      payload.keys.toList()..sort(),
      keys.keys.toList()..sort(),
      reason: 'golden payload must cover every frozen schema key',
    );

    final TelemetryNotifier notifier = TelemetryNotifier(_NoopSocket());
    addTearDown(() {
      if (notifier.mounted) {
        notifier.dispose();
      }
    });
    notifier.handleEnvelope(
      WsMessage(
        id: '9b1de3c8-0000-4000-8000-000000000000',
        type: typeTelemetrySync,
        action: actionFullState,
        payload: payload,
        timestamp: 1760000000,
      ),
    );

    final TelemetryState s = notifier.snapshot;
    expect(s.timestamp, 1760000000);
    expect(s.positionMs, 65000);
    expect(s.durationMs, 5400000);
    expect(s.isPlaying, isFalse);
    expect(s.speed, 2.0);
    expect(s.potPlayerVolume, 100);
    expect(s.fileTitle, 'Кин-дза-дза');
    expect(s.isConnected, isTrue);
    expect(s.progress, closeTo(65000 / 5400000, 1e-12));
    expect(s.positionLabel, '00:01:05');
    expect(s.durationLabel, '01:30:00');
    expect(s.extras, <String, Object?>{
      'potplayer_found': true,
      'blackout_active': true,
      'brightness': null,
      'sys_volume': 30,
      'sys_muted': true,
      'sleep_timer_active': true,
      'sleep_timer_mode': 'COUNTDOWN',
      'sleep_timer_remaining_s': 900,
    });
    expect(notifier.parseErrors, 0);
  });

  test('golden envelope JSON survives the Doc 03 codec round-trip', () {
    final String raw = jsonEncode(<String, Object?>{
      'id': '9b1de3c8-1111-4000-8000-000000000000',
      'type': 'TELEMETRY_SYNC',
      'action': 'FULL_STATE',
      'payload': <String, Object?>{'is_playing': true},
      'timestamp': 1760000000,
    });
    final WsMessage parsed = parseMessage(raw);
    expect(parsed.type, typeTelemetrySync);
    expect(parsed.action, actionFullState);
    expect(parsed.payload['is_playing'], isTrue);
    expect(parsed.timestamp, 1760000000);
  });
}

/// Socket seam that never emits — frames are driven directly.
class _NoopSocket implements TelemetrySocket {
  @override
  Stream<WsMessage> get envelopes => const Stream<WsMessage>.empty();

  @override
  Stream<WsConnectionState> get stateChanges =>
      const Stream<WsConnectionState>.empty();
}
