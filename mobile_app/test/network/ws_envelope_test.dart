// Doc 31 envelope parity suite: frames built the way `WsClient.send()`
// builds them validate byte-for-byte against the frozen
// shared_specs/ws_command_schema.json contract, golden literals round-trip
// through the Doc 03 codec, and Doc 31's frozen constants mirror the schema.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:potpilot_remote/network/ws_client.dart';
import 'package:potpilot_remote/network/ws_message_codec.dart';

Map<String, dynamic> loadSharedSpec(String name) {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final file = File('${dir.path}/shared_specs/$name');
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
    dir = dir.parent;
  }
  throw StateError('shared_specs/$name not found above ${Directory.current.path}');
}

void expectValidEnvelope(Map<String, dynamic> env, Map<String, dynamic> schema) {
  expect(env.keys.toSet(), unorderedEquals(envelopeKeys));
  expect(env['id'], matches(RegExp(schema['envelope']['id']['pattern'] as String)));
  expect(
    (schema['envelope']['type']['enum'] as List).cast<String>(),
    contains(env['type']),
  );
  expect(
    env['action'],
    matches(RegExp(schema['envelope']['action']['pattern'] as String)),
  );
  expect(env['payload'], isA<Map<String, dynamic>>());
  expect(env['timestamp'], isA<int>());
}

/// Validates a payload against one action's frozen `payload` spec. Field
/// presence/type/range/enum are checked; `required_when` (conditional) fields
/// are treated as optional. Specs that are pure `semantics` notes (server
/// telemetry) are skipped — their keys live under `telemetry.keys`.
void expectPayloadMatchesSpec(
  Map<String, dynamic> payload,
  Map<String, dynamic> spec,
) {
  if (spec.isEmpty) {
    expect(payload, isEmpty, reason: 'action takes no payload fields');
    return;
  }
  if (spec.keys.every((String key) => key == 'semantics')) {
    return;
  }
  for (final MapEntry<String, dynamic> entry in spec.entries) {
    final String field = entry.key;
    final Map<String, dynamic> rule = entry.value as Map<String, dynamic>;
    final bool optional =
        rule['optional'] == true || rule.containsKey('required_when');
    if (!payload.containsKey(field)) {
      expect(optional, isTrue, reason: 'missing required payload field $field');
      continue;
    }
    final Object? value = payload[field];
    final String type = rule['type'] as String;
    if (type == 'integer') {
      expect(value, isA<int>(), reason: 'field $field');
    } else if (type == 'number') {
      expect(value, isA<num>(), reason: 'field $field');
    } else if (type == 'string') {
      expect(value, isA<String>(), reason: 'field $field');
    } else if (type == 'boolean') {
      expect(value, isA<bool>(), reason: 'field $field');
    } else if (type == 'array') {
      expect(value, isA<List>(), reason: 'field $field');
    } else if (type.contains('null') && value == null) {
      // nullable variants accept explicit null
    } else {
      fail('unhandled schema type "$type" for field $field');
    }
    if (value is num) {
      if (rule['minimum'] is num) {
        expect(value, greaterThanOrEqualTo(rule['minimum']! as num),
            reason: 'field $field minimum');
      }
      if (rule['maximum'] is num) {
        expect(value, lessThanOrEqualTo(rule['maximum']! as num),
            reason: 'field $field maximum');
      }
    }
    if (rule['enum'] is List) {
      expect((rule['enum'] as List), contains(value), reason: 'field $field');
    }
    if (rule['items'] is Map && value is List) {
      final Map<String, dynamic> items =
          rule['items'] as Map<String, dynamic>;
      for (final Object? element in value) {
        if (items['enum'] is List) {
          expect((items['enum'] as List), contains(element),
              reason: 'array item in $field');
        }
      }
    }
  }
  final Set<String> extra =
      payload.keys.toSet().difference(spec.keys.toSet());
  expect(extra, isEmpty, reason: 'payload fields outside the frozen spec');
}

/// Builds a minimal valid payload for one action spec (skips `optional` and
/// `required_when` fields; picks the first enum member / minimum bound).
Map<String, dynamic> samplePayloadFor(Map<String, dynamic> spec) {
  if (spec.isEmpty || spec.keys.every((String key) => key == 'semantics')) {
    return <String, dynamic>{};
  }
  final Map<String, dynamic> payload = <String, dynamic>{};
  for (final MapEntry<String, dynamic> entry in spec.entries) {
    final Map<String, dynamic> rule = entry.value as Map<String, dynamic>;
    if (rule['optional'] == true || rule.containsKey('required_when')) {
      continue;
    }
    final String type = rule['type'] as String;
    if (type == 'integer') {
      payload[entry.key] = rule['minimum'] is int ? rule['minimum'] : 1;
    } else if (type == 'number') {
      payload[entry.key] =
          rule['minimum'] is num ? rule['minimum'] : 1.0;
    } else if (type == 'boolean') {
      payload[entry.key] = true;
    } else if (type == 'array') {
      final Map<String, dynamic> items =
          rule['items'] as Map<String, dynamic>;
      payload[entry.key] = <Object?>[
        items['enum'] is List ? (items['enum'] as List).first : 'x',
      ];
    } else if (type == 'string') {
      payload[entry.key] =
          rule['enum'] is List ? (rule['enum'] as List).first : 'x';
    } else if (type.contains('null')) {
      payload[entry.key] = rule['enum'] is List
          ? (rule['enum'] as List).firstWhere(
              (Object? v) => v != null,
              orElse: () => 'x',
            )
          : 'x';
    }
  }
  return payload;
}

void main() {
  final Map<String, dynamic> schema = loadSharedSpec('ws_command_schema.json');

  group('Doc 31 constants mirror the frozen schema', () {
    test('ports and service type', () {
      expect(kWsDefaultPort, 50506);
      expect(kWsDefaultPort, wsPort);
      expect(kWsDefaultPort, schema['ws_port']);
      expect(kMdnsServiceType, '_potpilot._tcp.local.');
      expect(kMdnsServiceType, mdnsServiceType);
      expect(kMdnsServiceType, schema['mdns_service_type']);
    });

    test('heartbeat contract values (03 §4.2)', () {
      expect(kPingInterval.inSeconds,
          schema['heartbeat']['client_ping_interval_s']);
      expect(closeCodeUnauthorized, 4401);
      expect(schema['close_codes']['4401']['name'], 'UNAUTHORIZED');
      expect(closeCodeProtocolError, 4400);
      expect(schema['close_codes']['4400']['name'], 'PROTOCOL_ERROR');
      expect(closeCodeHeartbeatTimeout, 4408);
      expect(schema['close_codes']['4408']['name'], 'HEARTBEAT_TIMEOUT');
      expect(schema['auth']['value_format'],
          '32 lowercase hex chars (16-byte secret, Doc 15)');
      expect(
          schema['auth']['invalid_or_missing_at_upgrade']['http_status'], 401);
      expect(schema['auth']['mid_session_revocation_close_code'], 4401);
    });

    test('tuning defaults locked by Doc 31', () {
      expect(kBackoffInitial, const Duration(milliseconds: 500));
      expect(kBackoffMultiplier, 2.0);
      expect(kBackoffMax, const Duration(seconds: 15));
      expect(kJitterRatio, 0.20);
      expect(kLivenessTimeout, const Duration(seconds: 5));
      expect(kConnectTimeout, const Duration(seconds: 5));
      expect(kMdnsFallbackAfter, 3);
      expect(kSendQueueCapacity, 32);
    });
  });

  group('golden frames round-trip byte-for-byte', () {
    const Map<String, String> goldens = <String, String>{
      'CMD_POTPLAYER/PLAY_PAUSE':
          '{"id":"0b3a9f2c-1d4e-4a6b-8c9d-0e1f2a3b4c5d","type":"CMD_POTPLAYER","action":"PLAY_PAUSE","payload":{},"timestamp":1760500000}',
      'CMD_POTPLAYER/SEEK':
          '{"id":"7c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f","type":"CMD_POTPLAYER","action":"SEEK","payload":{"position_ms":61000},"timestamp":1760500001}',
      'CMD_KEY/SEND_KEY':
          '{"id":"11112222-3333-4444-8555-666677778888","type":"CMD_KEY","action":"SEND_KEY","payload":{"vk":65},"timestamp":1760500002}',
      'CMD_SYSTEM/SET_BLACKOUT':
          '{"id":"aaaabbbb-cccc-4ddd-8eee-ffff00001111","type":"CMD_SYSTEM","action":"SET_BLACKOUT","payload":{"enabled":true},"timestamp":1760500003}',
      'CMD_MEDIA/LIST_MEDIA':
          '{"id":"99998888-7777-4666-8555-444433332222","type":"CMD_MEDIA","action":"LIST_MEDIA","payload":{"offset":0,"limit":50},"timestamp":1760500004}',
      'TELEMETRY_SYNC/STATE_DELTA':
          '{"id":"12345678-1234-4abc-8def-1234567890ab","type":"TELEMETRY_SYNC","action":"STATE_DELTA","payload":{"position_ms":123456},"timestamp":1760500005}',
      'CMD_SYSTEM/AUTH_OK greeting':
          '{"id":"fedcba98-7654-4321-8abc-def012345678","type":"CMD_SYSTEM","action":"AUTH_OK","payload":{"ok":true},"timestamp":1760500006}',
    };

    for (final MapEntry<String, String> golden in goldens.entries) {
      test('${golden.key} parses and re-encodes identically', () {
        final WsMessage message = parseMessage(golden.value);
        expect(message.type, golden.key.split('/').first);
        expect(jsonEncode(message.toJson()), golden.value);
        expectValidEnvelope(message.toJson(), schema);

        if (golden.key.endsWith('greeting')) {
          expect(message.toJson()['payload'], <String, dynamic>{'ok': true});
          expect(schema['greeting']['action'], message.action);
          expect(schema['greeting']['type'], message.type);
        } else if (golden.key == 'TELEMETRY_SYNC/STATE_DELTA') {
          expect(
            message.payload.keys.toSet().difference(
                  (schema['telemetry']['keys'] as Map<String, dynamic>)
                      .keys
                      .toSet(),
                ),
            isEmpty,
          );
        } else {
          final Map<String, dynamic> actions = (schema['types'][message.type]
              as Map<String, dynamic>)['actions'] as Map<String, dynamic>;
          final Map<String, dynamic> actionSpec =
              actions[message.action] as Map<String, dynamic>;
          expectPayloadMatchesSpec(
            message.payload,
            (actionSpec['payload'] ?? <String, dynamic>{})
                as Map<String, dynamic>,
          );
        }
      });
    }

    test('greeting buildAuthOk matches the frozen greeting frame shape', () {
      final WsMessage greeting = buildAuthOk();
      expect(greeting.type, schema['greeting']['type']);
      expect(greeting.action, schema['greeting']['action']);
      expect(greeting.payload, <String, dynamic>{'ok': true});
      expectValidEnvelope(greeting.toJson(), schema);
      expect(parseMessage(jsonEncode(greeting.toJson())).action,
          greeting.action);
    });
  });

  group('build/parse parity across the whole client registry', () {
    final Map<String, dynamic> types = schema['types'] as Map<String, dynamic>;
    for (final MapEntry<String, dynamic> typeEntry in types.entries) {
      final Map<String, dynamic> typeSpec =
          typeEntry.value as Map<String, dynamic>;
      if (typeSpec['direction'] != 'client_to_server') {
        continue; // clients may not originate TELEMETRY_SYNC frames
      }
      final Map<String, dynamic> actions =
          typeSpec['actions'] as Map<String, dynamic>;
      for (final MapEntry<String, dynamic> actionEntry in actions.entries) {
        test('${typeEntry.key}/${actionEntry.key} builds a schema-valid frame',
            () {
          final Map<String, dynamic> spec =
              actionEntry.value as Map<String, dynamic>;
          final Map<String, dynamic> payloadSpec =
              (spec['payload'] ?? <String, dynamic>{}) as Map<String, dynamic>;
          final Map<String, dynamic> payload = samplePayloadFor(payloadSpec);

          final WsMessage message = buildMessage(
            type: typeEntry.key,
            action: actionEntry.key,
            payload: payload,
          );
          final String frame = jsonEncode(message.toJson());
          final Map<String, dynamic> decoded =
              jsonDecode(frame) as Map<String, dynamic>;

          expectValidEnvelope(decoded, schema);
          expectPayloadMatchesSpec(
              decoded['payload'] as Map<String, dynamic>, payloadSpec);

          final WsMessage reparsed = parseMessage(frame);
          expect(reparsed.id, message.id);
          expect(reparsed.type, message.type);
          expect(reparsed.action, message.action);
          expect(reparsed.payload, message.payload);
          expect(reparsed.timestamp, message.timestamp);

          // Registry membership exactly as frozen in the schema.
          expect(actions.keys, contains(message.action));
        });
      }
    }
  });
}
