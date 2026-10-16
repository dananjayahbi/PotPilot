"""Doc 03 conformance suite: envelope round-trip, reply builders, registry equality."""

import json
import re
import time
import uuid
from dataclasses import asdict
from pathlib import Path

import pytest

from pc_agent.network.ws_message_codec import (
    ACTIONS_BY_TYPE,
    ENVELOPE_KEYS,
    FULL_REFRESH_EVERY_TICKS,
    GREETING_ACTION,
    MAX_FRAME_BYTES,
    MDNS_SERVICE_TYPE,
    TELEMETRY_INTERVAL_MS,
    TELEMETRY_KEYS,
    WS_PORT,
    Action,
    CloseCode,
    ErrorCode,
    WsMessage,
    WsSchemaError,
    WsType,
    build_auth_ok,
    build_error,
    build_message,
    build_result,
    build_telemetry_delta,
    build_telemetry_full,
    parse_message,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads(
    (REPO_ROOT / "shared_specs" / "ws_command_schema.json").read_text(encoding="utf-8")
)
UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

ONE_ACTION_PER_TYPE = {
    type_name: sorted(actions)[0] for type_name, actions in ACTIONS_BY_TYPE.items()
}


def _valid_frame(**overrides) -> str:
    frame = {
        "id": str(uuid.uuid4()),
        "type": "CMD_POTPLAYER",
        "action": "PLAY_PAUSE",
        "payload": {},
        "timestamp": int(time.time()),
    }
    frame.update(overrides)
    return json.dumps(frame)


def test_frozen_constants() -> None:
    assert WS_PORT == 50506
    assert TELEMETRY_INTERVAL_MS == 250
    assert MAX_FRAME_BYTES == 2097152
    assert FULL_REFRESH_EVERY_TICKS == 20
    assert GREETING_ACTION == "AUTH_OK"
    assert MDNS_SERVICE_TYPE == "_potpilot._tcp.local."
    assert ENVELOPE_KEYS == ("id", "type", "action", "payload", "timestamp")
    assert {int(code) for code in CloseCode} == {4400, 4401, 4408}
    assert CloseCode.PROTOCOL_ERROR == 4400
    assert CloseCode.UNAUTHORIZED == 4401
    assert CloseCode.HEARTBEAT_TIMEOUT == 4408
    assert {int(code) for code in ErrorCode} == {4002, 4003, 4004, 4005, 4006, 4500}


def test_schema_json_matches_frozen_constants() -> None:
    assert SCHEMA["ws_port"] == WS_PORT
    assert SCHEMA["telemetry_interval_ms"] == TELEMETRY_INTERVAL_MS
    assert SCHEMA["max_frame_bytes"] == MAX_FRAME_BYTES
    assert SCHEMA["full_refresh_every_ticks"] == FULL_REFRESH_EVERY_TICKS
    assert SCHEMA["mdns_service_type"] == MDNS_SERVICE_TYPE
    assert list(SCHEMA["envelope"]) == list(ENVELOPE_KEYS)
    assert SCHEMA["greeting"] == {
        "type": "CMD_SYSTEM",
        "action": "AUTH_OK",
        "payload": {"ok": True},
        "when": SCHEMA["greeting"]["when"],
    }
    assert SCHEMA["replies"]["result_suffix"] == "_RESULT"
    assert SCHEMA["replies"]["error_suffix"] == "_ERROR"
    close_names = {int(code): entry["name"] for code, entry in SCHEMA["close_codes"].items()}
    assert close_names == {int(code): code.name for code in CloseCode}
    error_names = {int(code): entry["name"] for code, entry in SCHEMA["error_codes"].items()}
    assert error_names == {int(code): code.name for code in ErrorCode}


@pytest.mark.parametrize("type_name", sorted(ACTIONS_BY_TYPE))
def test_build_stamps_uuid4_and_timestamp(type_name: str) -> None:
    message = build_message(type_name, ONE_ACTION_PER_TYPE[type_name], {})
    assert UUID4_RE.fullmatch(message.id)
    assert uuid.UUID(message.id).version == 4
    assert isinstance(message.timestamp, int)
    assert abs(int(time.time()) - message.timestamp) <= 5


def test_explicit_id_is_preserved() -> None:
    fixed_id = "00000000-0000-4000-8000-000000000000"
    message = build_message("CMD_KEY", Action.SEND_KEY, {"vk": 13}, id_=fixed_id)
    assert message.id == fixed_id
    assert parse_message(json.dumps(asdict(message))).id == fixed_id


@pytest.mark.parametrize("type_name", sorted(ACTIONS_BY_TYPE))
def test_round_trip_all_five_types(type_name: str) -> None:
    original = build_message(type_name, ONE_ACTION_PER_TYPE[type_name], {"k": "v"})
    parsed = parse_message(json.dumps(asdict(original)))
    assert parsed == original
    assert isinstance(parsed, WsMessage)
    assert list(asdict(parsed)) == list(SCHEMA["envelope"])


def test_parse_accepts_bytes_frame() -> None:
    message = build_message("CMD_SYSTEM", Action.REQUEST_STATE, {})
    parsed = parse_message(json.dumps(asdict(message)).encode("utf-8"))
    assert parsed == message


def test_parse_rejects_malformed_json() -> None:
    with pytest.raises(WsSchemaError) as excinfo:
        parse_message("{not json")
    assert excinfo.value.code == int(CloseCode.PROTOCOL_ERROR)


def test_parse_rejects_non_object_envelope() -> None:
    for raw in ("null", "[]", '"text"', "42"):
        with pytest.raises(WsSchemaError):
            parse_message(raw)


def test_parse_rejects_missing_and_extra_keys() -> None:
    frame = json.loads(_valid_frame())
    del frame["payload"]
    with pytest.raises(WsSchemaError) as excinfo:
        parse_message(json.dumps(frame))
    assert "payload" in excinfo.value.detail

    with pytest.raises(WsSchemaError) as excinfo:
        parse_message(_valid_frame(extra_key="x"))
    assert "extra_key" in excinfo.value.detail


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("id", "not-a-uuid"),
        ("id", "A" * 36),
        ("id", 123),
        ("type", 42),
        ("type", None),
        ("action", "lower_case"),
        ("action", "HAS SPACE"),
        ("action", 7),
        ("payload", []),
        ("payload", None),
        ("payload", "text"),
        ("timestamp", "1760500000"),
        ("timestamp", 1.5),
        ("timestamp", True),
        ("timestamp", None),
    ],
)
def test_parse_rejects_bad_field_values(field: str, value) -> None:
    with pytest.raises(WsSchemaError) as excinfo:
        parse_message(_valid_frame(**{field: value}))
    assert excinfo.value.code == int(CloseCode.PROTOCOL_ERROR)
    assert excinfo.value.detail


def test_parse_rejects_invalid_utf8_bytes() -> None:
    with pytest.raises(WsSchemaError):
        parse_message(b'{"id": \xff\xfe}')


def test_parse_rejects_oversized_frames() -> None:
    blob = "x" * (MAX_FRAME_BYTES + 1)
    frame = _valid_frame(payload={"blob": blob})
    assert len(frame.encode("utf-8")) > MAX_FRAME_BYTES
    with pytest.raises(WsSchemaError) as excinfo:
        parse_message(frame)
    assert excinfo.value.code == int(CloseCode.PROTOCOL_ERROR)
    with pytest.raises(WsSchemaError):
        parse_message(frame.encode("utf-8"))


def test_parse_rejects_non_frame_input() -> None:
    with pytest.raises(WsSchemaError):
        parse_message(123)  # type: ignore[arg-type]


def test_parse_leaves_registry_membership_to_router() -> None:
    # Well-formed but unknown type/action must parse so the router can reply
    # <ACTION>_ERROR 4002 on the open connection (Doc 03 §7).
    message = parse_message(_valid_frame(type="CMD_BOGUS", action="NOT_A_REAL_ACTION"))
    assert message.type == "CMD_BOGUS"
    assert "CMD_BOGUS" not in ACTIONS_BY_TYPE
    assert "NOT_A_REAL_ACTION" not in ACTIONS_BY_TYPE["CMD_POTPLAYER"]
    for forbidden in ("AUTH", "AUTH_FAIL"):
        assert all(forbidden not in actions for actions in ACTIONS_BY_TYPE.values())


def test_build_result_echoes_id_and_suffix() -> None:
    request = build_message("CMD_POTPLAYER", Action.PLAY_PAUSE, {})
    reply = build_result(request)
    assert reply.id == request.id
    assert reply.type == request.type
    assert reply.action == "PLAY_PAUSE_RESULT"
    assert reply.payload == {"ok": True}
    assert isinstance(reply.timestamp, int)
    custom = build_result(request, {"total": 3})
    assert custom.payload == {"total": 3}


def test_build_error_echoes_id_and_payload() -> None:
    request = build_message("CMD_MEDIA", Action.LIST_MEDIA, {"path": "x"})
    reply = build_error(request, ErrorCode.UNKNOWN_ACTION, "nope")
    assert reply.id == request.id
    assert reply.type == request.type
    assert reply.action == "LIST_MEDIA_ERROR"
    assert reply.payload == {"code": 4002, "message": "nope"}
    assert reply.payload["code"] == int(ErrorCode.UNKNOWN_ACTION)


def test_telemetry_builders_stamp_actions_and_fresh_ids() -> None:
    changed = {"position_ms": 1234, "is_playing": True}
    delta = build_telemetry_delta(changed)
    assert delta.type == WsType.TELEMETRY_SYNC
    assert delta.action == "STATE_DELTA"
    assert delta.payload == changed
    assert UUID4_RE.fullmatch(delta.id)

    delta2 = build_telemetry_delta({"volume": 50})
    assert delta2.id != delta.id
    assert UUID4_RE.fullmatch(delta2.id)

    full = build_telemetry_full({key: None for key in TELEMETRY_KEYS})
    assert full.type == WsType.TELEMETRY_SYNC
    assert full.action == "FULL_STATE"
    assert set(full.payload) == set(TELEMETRY_KEYS)
    assert full.id != delta.id
    assert isinstance(full.timestamp, int)

    # Telemetry frames are server-push; clients route by type, never correlate ids.
    parsed = parse_message(json.dumps(asdict(delta)))
    assert parsed.action == "STATE_DELTA"


def test_build_auth_ok_greeting() -> None:
    greeting = build_auth_ok()
    assert greeting.type == WsType.CMD_SYSTEM
    assert greeting.action == "AUTH_OK"
    assert greeting.payload == {"ok": True}
    assert UUID4_RE.fullmatch(greeting.id)


def test_action_registry_matches_schema_json() -> None:
    assert set(SCHEMA["types"]) == set(ACTIONS_BY_TYPE)
    for type_name, spec in SCHEMA["types"].items():
        json_actions = set(spec["actions"])
        codec_actions = set(ACTIONS_BY_TYPE[type_name])
        assert json_actions == codec_actions, (
            type_name,
            sorted(json_actions ^ codec_actions),
        )


def test_action_class_exactly_covers_registry_plus_greeting() -> None:
    action_names = {
        value
        for name, value in vars(Action).items()
        if not name.startswith("_") and isinstance(value, str)
    }
    union = frozenset().union(*ACTIONS_BY_TYPE.values()) | {GREETING_ACTION}
    assert action_names == set(union)


def test_telemetry_keys_match_schema_json() -> None:
    assert set(TELEMETRY_KEYS) == set(SCHEMA["telemetry"]["keys"])
    assert len(TELEMETRY_KEYS) == 14


def test_telemetry_key_order_matches_doc_table() -> None:
    assert tuple(SCHEMA["telemetry"]["keys"]) == TELEMETRY_KEYS
