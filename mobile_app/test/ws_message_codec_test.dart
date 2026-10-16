// Doc 03 Dart conformance suite: envelope round-trip, reply builders, registry
// equality against shared_specs/ws_command_schema.json, and the client
// merge rules of §4.3.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

final RegExp uuid4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Client merge rules of Doc 03 §4.3 (reference mirror for Doc 33).
Map<String, dynamic> mergeTelemetry(Map<String, dynamic> current, WsMessage frame) {
  if (frame.action == actionFullState) {
    return Map<String, dynamic>.of(frame.payload);
  }
  if (frame.action == actionStateDelta) {
    final merged = Map<String, dynamic>.of(current);
    for (final entry in frame.payload.entries) {
      if (telemetryKeys.contains(entry.key)) {
        merged[entry.key] = entry.value;
      }
    }
    return merged;
  }
  return Map<String, dynamic>.of(current);
}

String validFrame([Map<String, dynamic>? overrides]) {
  final frame = buildMessage(
    type: typeCmdPotplayer,
    action: Action.playPause,
    payload: <String, dynamic>{},
  ).toJson();
  if (overrides != null) {
    frame.addAll(overrides);
  }
  return jsonEncode(frame);
}

void main() {
  final schema = loadSharedSpec('ws_command_schema.json');

  test('frozen constants match shared spec', () {
    expect(wsPort, 50506);
    expect(telemetryIntervalMs, 250);
    expect(maxFrameBytes, 2097152);
    expect(fullRefreshEveryTicks, 20);
    expect(mdnsServiceType, '_potpilot._tcp.local.');
    expect(greetingAction, 'AUTH_OK');
    expect(actionStateDelta, 'STATE_DELTA');
    expect(actionFullState, 'FULL_STATE');
    expect(closeCodeProtocolError, 4400);
    expect(closeCodeUnauthorized, 4401);
    expect(closeCodeHeartbeatTimeout, 4408);
    expect(errorUnknownAction, 4002);
    expect(errorInvalidPayload, 4003);
    expect(errorPotplayerNotRunning, 4004);
    expect(errorMediaNotFound, 4005);
    expect(errorHardwareUnavailable, 4006);
    expect(errorInternalError, 4500);
    expect(schema['ws_port'], wsPort);
    expect(schema['telemetry_interval_ms'], telemetryIntervalMs);
    expect(schema['max_frame_bytes'], maxFrameBytes);
    expect(schema['full_refresh_every_ticks'], fullRefreshEveryTicks);
    expect(schema['mdns_service_type'], mdnsServiceType);
    expect((schema['envelope'] as Map<String, dynamic>).keys.toList(), envelopeKeys);
    final greeting = schema['greeting'] as Map<String, dynamic>;
    expect(greeting['type'], typeCmdSystem);
    expect(greeting['action'], greetingAction);
    expect(greeting['payload'], {'ok': true});
    final replies = schema['replies'] as Map<String, dynamic>;
    expect(replies['result_suffix'], resultSuffix);
    expect(replies['error_suffix'], errorSuffix);
    expect((schema['types'] as Map<String, dynamic>).keys.toSet(), wsTypes.toSet());
  });

  test('action registry equals ws_command_schema.json', () {
    final types = schema['types'] as Map<String, dynamic>;
    expect(types.keys.toSet(), actionsByType.keys.toSet());
    for (final entry in actionsByType.entries) {
      final spec = types[entry.key] as Map<String, dynamic>;
      final jsonActions = (spec['actions'] as Map<String, dynamic>).keys.toSet();
      expect(jsonActions, entry.value, reason: 'registry drift for ${entry.key}');
    }
    expect(Action.authOk, greetingAction);
    expect(telemetryKeys, containsAll(const <String>['position_ms', 'file_title']));
    final telemetry = schema['telemetry'] as Map<String, dynamic>;
    expect((telemetry['keys'] as Map<String, dynamic>).keys.toList(), telemetryKeys);
    final forbidden = schema['forbidden_client_actions'] as Map<String, dynamic>;
    expect(forbidden['actions'], const <String>['TELEMETRY_SYNC', 'AUTH', 'AUTH_FAIL']);
    expect(forbidden['error_code'], errorUnknownAction);
  });

  test('AUTH and AUTH_FAIL never exist in the registry', () {
    for (final forbidden in const <String>['AUTH', 'AUTH_FAIL']) {
      expect(
        actionsByType.values.any((actions) => actions.contains(forbidden)),
        isFalse,
        reason: '$forbidden must yield _ERROR 4002 (no in-band auth path)',
      );
    }
  });

  for (final type in wsTypes) {
    final action = actionsByType[type]!.first;
    test('build stamps fresh uuid4 and unix timestamp [$type]', () {
      final message = buildMessage(type: type, action: action, payload: <String, dynamic>{});
      expect(uuid4Pattern.hasMatch(message.id), isTrue);
      expect(message.id[14], '4');
      expect(const <String>['8', '9', 'a', 'b'], contains(message.id[19]));
      expect(message.timestamp, isA<int>());
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect((message.timestamp - now).abs(), lessThanOrEqualTo(5));
    });

    test('build -> json -> parse round trip [$type]', () {
      final original = buildMessage(
        type: type,
        action: action,
        payload: <String, dynamic>{'k': 'v'},
      );
      final parsed = parseMessage(jsonEncode(original.toJson()));
      expect(parsed.id, original.id);
      expect(parsed.type, original.type);
      expect(parsed.action, original.action);
      expect(parsed.payload, equals(original.payload));
      expect(parsed.timestamp, original.timestamp);
      expect(parsed.toJson().keys.toList(), envelopeKeys);
    });
  }

  test('explicit id is preserved through build and parse', () {
    const fixedId = '00000000-0000-4000-8000-000000000000';
    final message = buildMessage(
      type: typeCmdKey,
      action: Action.sendKey,
      payload: <String, dynamic>{'vk': 13},
      id: fixedId,
    );
    expect(message.id, fixedId);
    expect(parseMessage(jsonEncode(message.toJson())).id, fixedId);
  });

  test('telemetry frames get fresh uuids and are routed by type', () {
    final delta = buildTelemetryDelta(<String, dynamic>{'position_ms': 1234});
    expect(delta.type, typeTelemetrySync);
    expect(delta.action, actionStateDelta);
    expect(delta.payload, {'position_ms': 1234});
    expect(uuid4Pattern.hasMatch(delta.id), isTrue);
    final delta2 = buildTelemetryDelta(<String, dynamic>{'volume': 50});
    expect(delta2.id, isNot(delta.id));
    final full = buildTelemetryFull(<String, dynamic>{'position_ms': 1, 'is_playing': true});
    expect(full.type, typeTelemetrySync);
    expect(full.action, actionFullState);
    expect(full.id, isNot(delta.id));
    expect(uuid4Pattern.hasMatch(full.id), isTrue);
  });

  test('buildAuthOk greeting shape', () {
    final greeting = buildAuthOk();
    expect(greeting.type, typeCmdSystem);
    expect(greeting.action, greetingAction);
    expect(greeting.payload, {'ok': true});
    expect(uuid4Pattern.hasMatch(greeting.id), isTrue);
  });

  test('buildResult echoes id and appends _RESULT', () {
    final request = buildMessage(
      type: typeCmdPotplayer,
      action: Action.playPause,
      payload: <String, dynamic>{},
    );
    final reply = buildResult(request);
    expect(reply.id, request.id);
    expect(reply.type, request.type);
    expect(reply.action, 'PLAY_PAUSE$resultSuffix');
    expect(reply.payload, {'ok': true});
    expect(reply.timestamp, isA<int>());
    final custom = buildResult(request, payload: <String, dynamic>{'total': 3});
    expect(custom.payload, {'total': 3});
  });

  test('buildError echoes id and carries code/message payload', () {
    final request = buildMessage(
      type: typeCmdMedia,
      action: Action.listMedia,
      payload: <String, dynamic>{'path': 'x'},
    );
    final reply = buildError(request, code: errorUnknownAction, message: 'nope');
    expect(reply.id, request.id);
    expect(reply.type, request.type);
    expect(reply.action, 'LIST_MEDIA$errorSuffix');
    expect(reply.payload, {'code': 4002, 'message': 'nope'});
  });

  final invalidFrames = <String, String>{
    'malformed JSON': '{not json',
    'null root': 'null',
    'list root': '[]',
    'string root': '"text"',
    'missing key': jsonEncode(
      buildMessage(
        type: typeCmdPotplayer,
        action: Action.playPause,
        payload: <String, dynamic>{},
      ).toJson()
        ..remove('payload'),
    ),
    'extra key': validFrame(<String, dynamic>{'extra': 1}),
    'bad id': validFrame(<String, dynamic>{'id': 'not-a-uuid'}),
    'uppercase id': validFrame(<String, dynamic>{'id': List<String>.filled(36, 'A').join()}),
    'non-string id': validFrame(<String, dynamic>{'id': 123}),
    'non-string type': validFrame(<String, dynamic>{'type': 42}),
    'lowercase action': validFrame(<String, dynamic>{'action': 'lower_case'}),
    'spaced action': validFrame(<String, dynamic>{'action': 'HAS SPACE'}),
    'list payload': validFrame(<String, dynamic>{'payload': <int>[]}),
    'null payload': validFrame(<String, dynamic>{'payload': null}),
    'string timestamp': validFrame(<String, dynamic>{'timestamp': '1760500000'}),
    'bool timestamp': validFrame(<String, dynamic>{'timestamp': true}),
    'float timestamp': validFrame(<String, dynamic>{'timestamp': 1.5}),
  };
  invalidFrames.forEach((name, raw) {
    test('parse rejects $name', () {
      expect(() => parseMessage(raw), throwsFormatException);
    });
  });

  test('parse rejects oversized frames', () {
    final blob = List<String>.filled(maxFrameBytes + 1, 'x').join();
    final frame = validFrame(<String, dynamic>{'payload': <String, dynamic>{'blob': blob}});
    expect(utf8.encode(frame).length, greaterThan(maxFrameBytes));
    expect(() => parseMessage(frame), throwsFormatException);
  });

  test('parse leaves registry membership to the router (4002, open connection)', () {
    final message = parseMessage(
      validFrame(<String, dynamic>{'type': 'CMD_BOGUS', 'action': 'NOT_A_REAL_ACTION'}),
    );
    expect(message.type, 'CMD_BOGUS');
    expect(actionsByType.containsKey('CMD_BOGUS'), isFalse);
    expect(actionsByType[typeCmdPotplayer]!.contains('NOT_A_REAL_ACTION'), isFalse);
  });

  group('client merge rules (Doc 03 §4.3)', () {
    test('STATE_DELTA replaces present keys, retains absent ones', () {
      var state = <String, dynamic>{'position_ms': 0, 'is_playing': false, 'volume': 50};
      state = mergeTelemetry(state, buildTelemetryDelta(<String, dynamic>{
        'position_ms': 1000,
        'is_playing': true,
      }));
      expect(state['position_ms'], 1000);
      expect(state['is_playing'], isTrue);
      expect(state['volume'], 50);
    });

    test('unknown keys are ignored, never errors', () {
      var state = <String, dynamic>{'volume': 50};
      state = mergeTelemetry(state, buildTelemetryDelta(<String, dynamic>{
        'alien_key': 42,
        'volume': 60,
      }));
      expect(state.containsKey('alien_key'), isFalse);
      expect(state['volume'], 60);
    });

    test('FULL_STATE replaces the whole state', () {
      var state = <String, dynamic>{'position_ms': 1, 'old_key': true};
      state = mergeTelemetry(state, buildTelemetryFull(<String, dynamic>{
        'position_ms': 2000,
        'duration_ms': 9000,
      }));
      expect(state, equals(<String, dynamic>{'position_ms': 2000, 'duration_ms': 9000}));
    });

    test('delta + full sequence reproduces server state', () {
      final serverA = <String, dynamic>{'position_ms': 500, 'speed': 1.0, 'volume': 30};
      var client = mergeTelemetry(<String, dynamic>{}, buildTelemetryFull(serverA));
      expect(client, equals(serverA));
      final serverB = <String, dynamic>{'position_ms': 750, 'speed': 1.5, 'volume': 30};
      client = mergeTelemetry(client, buildTelemetryDelta(<String, dynamic>{
        'position_ms': 750,
        'speed': 1.5,
      }));
      expect(client, equals(serverB));
    });
  });
}
