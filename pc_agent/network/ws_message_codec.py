"""Reference/conformance codec for the frozen PotPilot WebSocket JSON envelope (Doc 03).

Pure functions, no I/O beyond stdlib json/uuid/time — the executable spec for the
conformance suites. Validation split (Doc 03 §7): *envelope shape* violations raise
WsSchemaError (server closes 4400); *registry membership* (unknown type/action,
client-sent TELEMETRY_SYNC/AUTH/AUTH_FAIL) is checked by the router (Doc 14) and
answered with _ERROR 4002 on an open connection.
"""

import json
import re
import time
import uuid
from dataclasses import dataclass
from enum import IntEnum, StrEnum

WS_PORT = 50506
TELEMETRY_INTERVAL_MS = 250
MAX_FRAME_BYTES = 65536
ACTION_STATE_DELTA = "STATE_DELTA"
ACTION_FULL_STATE = "FULL_STATE"
FULL_REFRESH_EVERY_TICKS = 20
GREETING_ACTION = "AUTH_OK"
MDNS_SERVICE_TYPE = "_potpilot._tcp.local."

ENVELOPE_KEYS = ("id", "type", "action", "payload", "timestamp")

_UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
_ACTION_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


class WsType(StrEnum):
    CMD_POTPLAYER = "CMD_POTPLAYER"
    CMD_KEY = "CMD_KEY"
    CMD_SYSTEM = "CMD_SYSTEM"
    CMD_MEDIA = "CMD_MEDIA"
    TELEMETRY_SYNC = "TELEMETRY_SYNC"


class CloseCode(IntEnum):
    PROTOCOL_ERROR = 4400
    UNAUTHORIZED = 4401
    HEARTBEAT_TIMEOUT = 4408


class ErrorCode(IntEnum):
    UNKNOWN_ACTION = 4002
    INVALID_PAYLOAD = 4003
    POTPLAYER_NOT_RUNNING = 4004
    MEDIA_NOT_FOUND = 4005
    HARDWARE_UNAVAILABLE = 4006
    INTERNAL_ERROR = 4500


class Action:
    """Exhaustive action-name constants mirroring Doc 03 §5.3–§5.7 verbatim."""

    # CMD_POTPLAYER (§5.3)
    PLAY_PAUSE = "PLAY_PAUSE"
    PLAY = "PLAY"
    PAUSE = "PAUSE"
    SEEK = "SEEK"
    SEEK_DELTA = "SEEK_DELTA"
    SET_SPEED = "SET_SPEED"
    FRAME_STEP = "FRAME_STEP"
    TOGGLE_FULLSCREEN = "TOGGLE_FULLSCREEN"
    CYCLE_ASPECT_RATIO = "CYCLE_ASPECT_RATIO"
    SET_VOLUME = "SET_VOLUME"
    CYCLE_AUDIO = "CYCLE_AUDIO"
    CYCLE_SUBS = "CYCLE_SUBS"
    SET_SUBS = "SET_SUBS"
    SUB_SYNC_ADJUST = "SUB_SYNC_ADJUST"
    # CMD_KEY (§5.4)
    SEND_KEY = "SEND_KEY"
    SEND_COMBO = "SEND_COMBO"
    SEND_TEXT = "SEND_TEXT"
    # CMD_SYSTEM / CMD_MEDIA (§5.5)
    SNAP_TO_PRIMARY_MONITOR = "SNAP_TO_PRIMARY_MONITOR"
    SET_BLACKOUT = "SET_BLACKOUT"
    SET_BRIGHTNESS = "SET_BRIGHTNESS"
    SET_SYSTEM_VOLUME = "SET_SYSTEM_VOLUME"
    SET_SYSTEM_MUTE = "SET_SYSTEM_MUTE"
    START_SLEEP_TIMER = "START_SLEEP_TIMER"
    CANCEL_SLEEP_TIMER = "CANCEL_SLEEP_TIMER"
    REQUEST_STATE = "REQUEST_STATE"
    LIST_MEDIA = "LIST_MEDIA"
    RESCAN_MEDIA = "RESCAN_MEDIA"
    LAUNCH_MEDIA = "LAUNCH_MEDIA"
    # TELEMETRY_SYNC (§5.6) / greeting (§5.7)
    STATE_DELTA = ACTION_STATE_DELTA
    FULL_STATE = ACTION_FULL_STATE
    AUTH_OK = GREETING_ACTION


ACTIONS_BY_TYPE: dict[str, frozenset[str]] = {
    WsType.CMD_POTPLAYER: frozenset(
        {
            Action.PLAY_PAUSE,
            Action.PLAY,
            Action.PAUSE,
            Action.SEEK,
            Action.SEEK_DELTA,
            Action.SET_SPEED,
            Action.FRAME_STEP,
            Action.TOGGLE_FULLSCREEN,
            Action.CYCLE_ASPECT_RATIO,
            Action.SET_VOLUME,
            Action.CYCLE_AUDIO,
            Action.CYCLE_SUBS,
            Action.SET_SUBS,
            Action.SUB_SYNC_ADJUST,
        }
    ),
    WsType.CMD_KEY: frozenset({Action.SEND_KEY, Action.SEND_COMBO, Action.SEND_TEXT}),
    WsType.CMD_SYSTEM: frozenset(
        {
            Action.SNAP_TO_PRIMARY_MONITOR,
            Action.SET_BLACKOUT,
            Action.SET_BRIGHTNESS,
            Action.SET_SYSTEM_VOLUME,
            Action.SET_SYSTEM_MUTE,
            Action.START_SLEEP_TIMER,
            Action.CANCEL_SLEEP_TIMER,
            Action.REQUEST_STATE,
        }
    ),
    WsType.CMD_MEDIA: frozenset({Action.LIST_MEDIA, Action.RESCAN_MEDIA, Action.LAUNCH_MEDIA}),
    WsType.TELEMETRY_SYNC: frozenset({Action.STATE_DELTA, Action.FULL_STATE}),
}

TELEMETRY_KEYS: tuple[str, ...] = (
    "position_ms",
    "duration_ms",
    "is_playing",
    "speed",
    "volume",
    "file_title",
    "potplayer_found",
    "blackout_active",
    "brightness",
    "sys_volume",
    "sys_muted",
    "sleep_timer_active",
    "sleep_timer_mode",
    "sleep_timer_remaining_s",
)


class WsSchemaError(Exception):
    """Envelope-level protocol violation (Doc 03 §7 → server closes 4400)."""

    def __init__(self, detail: str, code: int = CloseCode.PROTOCOL_ERROR) -> None:
        super().__init__(detail)
        self.detail = detail
        self.code = int(code)


@dataclass(frozen=True, slots=True)
class WsMessage:
    id: str
    type: str
    action: str
    payload: dict
    timestamp: int


def build_message(type_: str, action: str, payload: dict, id_: str | None = None) -> WsMessage:
    """Compose an envelope; id_ defaults to uuid4(); timestamp = unix seconds."""
    return WsMessage(
        id=str(uuid.uuid4()) if id_ is None else id_,
        type=type_,
        action=action,
        payload=payload,
        timestamp=int(time.time()),
    )


def _fail(detail: str) -> WsSchemaError:
    return WsSchemaError(detail, CloseCode.PROTOCOL_ERROR)


def parse_message(raw: str | bytes) -> WsMessage:
    """Parse + validate an inbound frame; raises WsSchemaError on any violation."""
    if isinstance(raw, bytes):
        if len(raw) > MAX_FRAME_BYTES:
            raise _fail(f"frame exceeds {MAX_FRAME_BYTES} bytes")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise _fail("frame is not valid UTF-8") from exc
    elif isinstance(raw, str):
        if len(raw.encode("utf-8")) > MAX_FRAME_BYTES:
            raise _fail(f"frame exceeds {MAX_FRAME_BYTES} bytes")
        text = raw
    else:
        raise _fail(f"frame must be str or bytes, got {type(raw).__name__}")

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise _fail(f"malformed JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise _fail("envelope must be a JSON object")

    missing = [key for key in ENVELOPE_KEYS if key not in data]
    if missing:
        raise _fail(f"missing envelope key(s): {', '.join(missing)}")
    extra = [key for key in data if key not in ENVELOPE_KEYS]
    if extra:
        raise _fail(f"unexpected envelope key(s): {', '.join(sorted(extra))}")

    msg_id = data["id"]
    if not isinstance(msg_id, str) or not _UUID4_RE.fullmatch(msg_id):
        raise _fail("id must be a lowercase hyphenated uuid4 (36 chars)")
    if not isinstance(data["type"], str):
        raise _fail("type must be a string")
    action = data["action"]
    if not isinstance(action, str) or not _ACTION_RE.fullmatch(action):
        raise _fail("action must be UPPER_SNAKE_CASE")
    if not isinstance(data["payload"], dict):
        raise _fail("payload must be an object")
    timestamp = data["timestamp"]
    if isinstance(timestamp, bool) or not isinstance(timestamp, int):
        raise _fail("timestamp must be an integer (unix seconds)")

    return WsMessage(
        id=msg_id,
        type=data["type"],
        action=action,
        payload=data["payload"],
        timestamp=timestamp,
    )


def build_result(request: WsMessage, payload: dict | None = None) -> WsMessage:
    """Success reply: echoes request id, action = request.action + '_RESULT'."""
    return build_message(
        request.type,
        f"{request.action}_RESULT",
        {"ok": True} if payload is None else payload,
        id_=request.id,
    )


def build_error(request: WsMessage, code: int, message: str) -> WsMessage:
    """Error reply: echoes request id, action = request.action + '_ERROR'."""
    return build_message(
        request.type,
        f"{request.action}_ERROR",
        {"code": int(code), "message": message},
        id_=request.id,
    )


def build_telemetry_delta(changed: dict) -> WsMessage:
    """Telemetry frame, action STATE_DELTA, payload = keys changed this tick (§4.3)."""
    return build_message(WsType.TELEMETRY_SYNC, ACTION_STATE_DELTA, dict(changed))


def build_telemetry_full(state: dict) -> WsMessage:
    """Telemetry frame, action FULL_STATE, payload = every §5.6 key."""
    return build_message(WsType.TELEMETRY_SYNC, ACTION_FULL_STATE, dict(state))


def build_auth_ok() -> WsMessage:
    """Post-upgrade greeting frame (CMD_SYSTEM/AUTH_OK, payload {"ok": true})."""
    return build_message(WsType.CMD_SYSTEM, GREETING_ACTION, {"ok": True})
