// Reference/conformance codec for the frozen PotPilot WebSocket JSON envelope
// (Doc 03). Pure dart:convert — the Dart twin of
// pc_agent/network/ws_message_codec.py. Envelope-shape violations throw
// FormatException; registry membership (unknown type/action) is decided by the
// server router, which answers _ERROR 4002 on the open connection.

import 'dart:convert';
import 'dart:math';

const int wsPort = 50506;
const int telemetryIntervalMs = 250;
const int maxFrameBytes = 65536;
const int fullRefreshEveryTicks = 20;
const String mdnsServiceType = '_potpilot._tcp.local.';

const String actionStateDelta = 'STATE_DELTA';
const String actionFullState = 'FULL_STATE';
const String greetingAction = 'AUTH_OK';

const String typeCmdPotplayer = 'CMD_POTPLAYER';
const String typeCmdKey = 'CMD_KEY';
const String typeCmdSystem = 'CMD_SYSTEM';
const String typeCmdMedia = 'CMD_MEDIA';
const String typeTelemetrySync = 'TELEMETRY_SYNC';

const List<String> wsTypes = <String>[
  typeCmdPotplayer,
  typeCmdKey,
  typeCmdSystem,
  typeCmdMedia,
  typeTelemetrySync,
];

const List<String> envelopeKeys = <String>['id', 'type', 'action', 'payload', 'timestamp'];

const int closeCodeProtocolError = 4400;
const int closeCodeUnauthorized = 4401;
const int closeCodeHeartbeatTimeout = 4408;

const int errorUnknownAction = 4002;
const int errorInvalidPayload = 4003;
const int errorPotplayerNotRunning = 4004;
const int errorMediaNotFound = 4005;
const int errorHardwareUnavailable = 4006;
const int errorInternalError = 4500;

const String resultSuffix = '_RESULT';
const String errorSuffix = '_ERROR';

/// Exhaustive action-name constants mirroring Doc 03 §5.3–§5.7 verbatim.
abstract final class Action {
  // CMD_POTPLAYER (§5.3)
  static const String playPause = 'PLAY_PAUSE';
  static const String play = 'PLAY';
  static const String pause = 'PAUSE';
  static const String seek = 'SEEK';
  static const String seekDelta = 'SEEK_DELTA';
  static const String setSpeed = 'SET_SPEED';
  static const String frameStep = 'FRAME_STEP';
  static const String toggleFullscreen = 'TOGGLE_FULLSCREEN';
  static const String cycleAspectRatio = 'CYCLE_ASPECT_RATIO';
  static const String setVolume = 'SET_VOLUME';
  static const String cycleAudio = 'CYCLE_AUDIO';
  static const String cycleSubs = 'CYCLE_SUBS';
  static const String setSubs = 'SET_SUBS';
  static const String subSyncAdjust = 'SUB_SYNC_ADJUST';
  // CMD_KEY (§5.4)
  static const String sendKey = 'SEND_KEY';
  static const String sendCombo = 'SEND_COMBO';
  static const String sendText = 'SEND_TEXT';
  // CMD_SYSTEM / CMD_MEDIA (§5.5)
  static const String snapToPrimaryMonitor = 'SNAP_TO_PRIMARY_MONITOR';
  static const String setBlackout = 'SET_BLACKOUT';
  static const String setBrightness = 'SET_BRIGHTNESS';
  static const String setSystemVolume = 'SET_SYSTEM_VOLUME';
  static const String setSystemMute = 'SET_SYSTEM_MUTE';
  static const String startSleepTimer = 'START_SLEEP_TIMER';
  static const String cancelSleepTimer = 'CANCEL_SLEEP_TIMER';
  static const String requestState = 'REQUEST_STATE';
  static const String listMedia = 'LIST_MEDIA';
  static const String rescanMedia = 'RESCAN_MEDIA';
  static const String launchMedia = 'LAUNCH_MEDIA';
  // TELEMETRY_SYNC (§5.6) / greeting (§5.7)
  static const String stateDelta = actionStateDelta;
  static const String fullState = actionFullState;
  static const String authOk = greetingAction;
}

/// Request-action registry per envelope type (Doc 03 §5.3–§5.6).
const Map<String, Set<String>> actionsByType = <String, Set<String>>{
  typeCmdPotplayer: <String>{
    Action.playPause,
    Action.play,
    Action.pause,
    Action.seek,
    Action.seekDelta,
    Action.setSpeed,
    Action.frameStep,
    Action.toggleFullscreen,
    Action.cycleAspectRatio,
    Action.setVolume,
    Action.cycleAudio,
    Action.cycleSubs,
    Action.setSubs,
    Action.subSyncAdjust,
  },
  typeCmdKey: <String>{Action.sendKey, Action.sendCombo, Action.sendText},
  typeCmdSystem: <String>{
    Action.snapToPrimaryMonitor,
    Action.setBlackout,
    Action.setBrightness,
    Action.setSystemVolume,
    Action.setSystemMute,
    Action.startSleepTimer,
    Action.cancelSleepTimer,
    Action.requestState,
  },
  typeCmdMedia: <String>{Action.listMedia, Action.rescanMedia, Action.launchMedia},
  typeTelemetrySync: <String>{Action.stateDelta, Action.fullState},
};

/// Wire keys of the TELEMETRY_SYNC payload dictionary (Doc 03 §5.6), in table order.
const List<String> telemetryKeys = <String>[
  'position_ms',
  'duration_ms',
  'is_playing',
  'speed',
  'volume',
  'file_title',
  'potplayer_found',
  'blackout_active',
  'brightness',
  'sys_volume',
  'sys_muted',
  'sleep_timer_active',
  'sleep_timer_mode',
  'sleep_timer_remaining_s',
];

final RegExp _uuid4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp _actionPattern = RegExp(r'^[A-Z][A-Z0-9_]*$');

/// One frozen WS envelope (Doc 03 §5.1).
class WsMessage {
  const WsMessage({
    required this.id,
    required this.type,
    required this.action,
    required this.payload,
    required this.timestamp,
  });

  final String id;
  final String type;
  final String action;
  final Map<String, dynamic> payload;
  final int timestamp;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type,
        'action': action,
        'payload': payload,
        'timestamp': timestamp,
      };
}

String _newUuid4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

int _unixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Composes an envelope; [id] defaults to a fresh uuid4, timestamp to unix seconds.
WsMessage buildMessage({
  required String type,
  required String action,
  required Map<String, dynamic> payload,
  String? id,
}) {
  return WsMessage(
    id: id ?? _newUuid4(),
    type: type,
    action: action,
    payload: payload,
    timestamp: _unixSeconds(),
  );
}

/// Parses + validates an inbound frame; throws [FormatException] on violation.
WsMessage parseMessage(String raw) {
  if (utf8.encode(raw).length > maxFrameBytes) {
    throw const FormatException('frame exceeds $maxFrameBytes bytes');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (exc) {
    throw FormatException('malformed JSON: ${exc.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('envelope must be a JSON object');
  }
  final data = decoded;
  final missing = envelopeKeys.where((key) => !data.containsKey(key)).toList();
  if (missing.isNotEmpty) {
    throw FormatException('missing envelope key(s): ${missing.join(', ')}');
  }
  final extra = data.keys.where((key) => !envelopeKeys.contains(key)).toList();
  if (extra.isNotEmpty) {
    throw FormatException('unexpected envelope key(s): ${extra.join(', ')}');
  }
  final id = data['id'];
  if (id is! String || !_uuid4Pattern.hasMatch(id)) {
    throw const FormatException('id must be a lowercase hyphenated uuid4 (36 chars)');
  }
  if (data['type'] is! String) {
    throw const FormatException('type must be a string');
  }
  final action = data['action'];
  if (action is! String || !_actionPattern.hasMatch(action)) {
    throw const FormatException('action must be UPPER_SNAKE_CASE');
  }
  final payload = data['payload'];
  if (payload is! Map<String, dynamic>) {
    throw const FormatException('payload must be an object');
  }
  final timestamp = data['timestamp'];
  if (timestamp is! int) {
    throw const FormatException('timestamp must be an integer (unix seconds)');
  }
  return WsMessage(
    id: id,
    type: data['type'] as String,
    action: action,
    payload: payload,
    timestamp: timestamp,
  );
}

/// Success reply: echoes request id, action = request.action + '_RESULT'.
WsMessage buildResult(WsMessage request, {Map<String, dynamic>? payload}) {
  return buildMessage(
    type: request.type,
    action: '${request.action}$resultSuffix',
    payload: payload ?? <String, dynamic>{'ok': true},
    id: request.id,
  );
}

/// Error reply: echoes request id, action = request.action + '_ERROR'.
WsMessage buildError(WsMessage request, {required int code, required String message}) {
  return buildMessage(
    type: request.type,
    action: '${request.action}$errorSuffix',
    payload: <String, dynamic>{'code': code, 'message': message},
    id: request.id,
  );
}

/// Telemetry frame carrying only the keys changed this tick (§4.3).
WsMessage buildTelemetryDelta(Map<String, dynamic> changed) {
  return buildMessage(
    type: typeTelemetrySync,
    action: actionStateDelta,
    payload: Map<String, dynamic>.of(changed),
  );
}

/// Telemetry frame carrying every §5.6 key (connect / REQUEST_STATE / keepalive).
WsMessage buildTelemetryFull(Map<String, dynamic> state) {
  return buildMessage(
    type: typeTelemetrySync,
    action: actionFullState,
    payload: Map<String, dynamic>.of(state),
  );
}

/// Post-upgrade greeting frame (CMD_SYSTEM/AUTH_OK, payload {"ok": true}).
WsMessage buildAuthOk() {
  return buildMessage(
    type: typeCmdSystem,
    action: greetingAction,
    payload: <String, dynamic>{'ok': true},
  );
}
