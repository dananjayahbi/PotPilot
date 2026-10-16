"""Doc 01 Test Plan: shared_specs/*.json existence, UTF-8 parse, and frozen constants."""

import json
import struct
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SHARED_SPECS = REPO_ROOT / "shared_specs"
SPEC_FILES = ("udp_packet_layout.json", "ws_command_schema.json", "potplayer_wm_codes.json")

# Doc 01 §5.1 frozen constants
UDP_PORT = 50505
WS_PORT = 50506
TELEMETRY_INTERVAL_MS = 250
MDNS_SERVICE_TYPE = "_potpilot._tcp.local."
UDP_STRUCT_FORMAT = "<BBhhH>"
UDP_PACKET_SIZE = 8
WS_ENVELOPE_KEYS = ["id", "type", "action", "payload", "timestamp"]

# Doc 01 §5.2 container constants
WM_BASE = {"WM_COMMAND": "0x0111", "WM_USER": "0x0400"}


def _load(spec_file: str) -> dict:
    path = SHARED_SPECS / spec_file
    assert path.is_file(), f"missing spec file: {path}"
    raw = path.read_bytes()
    assert raw, f"spec file is empty: {path}"
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        pytest.fail(f"{path} is not valid UTF-8: {exc}")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        pytest.fail(f"{path} is not valid JSON: {exc}")
    assert isinstance(data, dict) and data, f"{path} must be a non-empty JSON object"
    return data


def _all_keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from _all_keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from _all_keys(item)


@pytest.mark.parametrize("spec_file", SPEC_FILES)
def test_spec_files_parse_as_utf8_json_objects(spec_file: str) -> None:
    _load(spec_file)


def test_udp_layout_frozen_constants() -> None:
    layout = _load("udp_packet_layout.json")
    assert layout["udp_port"] == UDP_PORT, (layout["udp_port"], UDP_PORT)
    assert layout["format"] == UDP_STRUCT_FORMAT, (layout["format"], UDP_STRUCT_FORMAT)
    assert layout["size"] == UDP_PACKET_SIZE, (layout["size"], UDP_PACKET_SIZE)
    assert layout["endian"] == "little"
    # Doc 02 §3 executable spelling (no trailing '>' — struct rejects it) must
    # agree with the frozen size.
    assert struct.calcsize(layout["struct_format"]) == UDP_PACKET_SIZE


def test_udp_layout_required_top_level_keys() -> None:
    layout = _load("udp_packet_layout.json")
    for key in ("format", "size", "endian", "packet_types", "golden_vectors"):
        assert key in layout, f"missing required top-level key: {key}"


def test_ws_schema_frozen_constants() -> None:
    schema = _load("ws_command_schema.json")
    assert schema["ws_port"] == WS_PORT, (schema["ws_port"], WS_PORT)
    assert schema["telemetry_interval_ms"] == TELEMETRY_INTERVAL_MS, (
        schema["telemetry_interval_ms"],
        TELEMETRY_INTERVAL_MS,
    )
    assert schema["mdns_service_type"] == MDNS_SERVICE_TYPE, (
        schema["mdns_service_type"],
        MDNS_SERVICE_TYPE,
    )
    assert list(schema["envelope"]) == WS_ENVELOPE_KEYS, list(schema["envelope"])
    assert schema["max_frame_bytes"] == 65536
    assert schema["full_refresh_every_ticks"] == 20


def test_ws_schema_required_top_level_keys() -> None:
    schema = _load("ws_command_schema.json")
    for key in ("envelope", "types", "close_codes", "error_codes"):
        assert key in schema, f"missing required top-level key: {key}"
        assert isinstance(schema[key], dict) and schema[key], f"{key} must be a non-empty object"


def test_wm_codes_container_shape() -> None:
    codes = _load("potplayer_wm_codes.json")
    for key in ("base", "commands", "getters"):
        assert key in codes, f"missing required top-level key: {key}"
        assert isinstance(codes[key], dict), f"{key} must be an object"
    assert codes["base"] == WM_BASE, (codes["base"], WM_BASE)
    # Doc 09 fills commands and Doc 09/10 fill getters once the container exists.
    assert codes["commands"], "commands must be filled per Doc 09"
    assert codes["getters"], "getters must be filled per Doc 09/10"


def test_wm_codes_commands_match_doc09_schema() -> None:
    """Doc 09 §4.1 entry schema + full coverage of the frozen CMD_POTPLAYER actions."""
    codes = _load("potplayer_wm_codes.json")
    params = {None, "wparam", "lparam", "lparam_loword", "lparam_hiword"}
    for name, entry in codes["commands"].items():
        assert entry["message"] in codes["base"], f"{name}: unknown message"
        for field in ("wparam", "lparam"):
            assert isinstance(entry[field], str), f"{name}: {field} must be a hex string"
            int(entry[field], 0)  # parseable
        assert entry["param"] in params, f"{name}: invalid param {entry['param']!r}"
        assert entry["mode"] in {"direct", "steps"}, f"{name}: invalid mode"
        assert isinstance(entry["needs_ack"], bool), f"{name}: needs_ack must be bool"
        assert entry["status"] in {"verified", "capture_required"}, f"{name}: bad status"
        if entry["mode"] == "steps":
            for key in ("step_up", "step_down"):
                assert entry[key] in codes["commands"], f"{name}: steps mode needs {key}"
    # Every Doc 03 §5.3 wire action resolves to exactly one entry (alias or typed path).
    wire_actions = [
        "PLAY_PAUSE",
        "PLAY",
        "PAUSE",
        "SEEK",
        "SEEK_DELTA",
        "SET_SPEED",
        "FRAME_STEP",
        "TOGGLE_FULLSCREEN",
        "CYCLE_ASPECT_RATIO",
        "SET_VOLUME",
        "CYCLE_AUDIO",
        "CYCLE_SUBS",
        "SET_SUBS",
        "SUB_SYNC_ADJUST",
    ]
    aliases = {"SEEK_DELTA": "SEEK", "SUB_SYNC_ADJUST": "SUB_DELAY_DELTA"}
    for action in wire_actions:
        key = aliases.get(action, action)
        assert key in codes["commands"], f"missing command entry for action {action}"


def test_wm_codes_getters_match_doc10_schema() -> None:
    """Doc 10 §5: the five telemetry getters exist with valid reply packing."""
    codes = _load("potplayer_wm_codes.json")
    required = {
        "GET_POSITION_MS",
        "GET_DURATION_MS",
        "GET_PLAY_STATE",
        "GET_VOLUME",
        "GET_SPEED",
    }
    assert required <= set(codes["getters"]), sorted(required - set(codes["getters"]))
    for name, entry in codes["getters"].items():
        assert entry["message"] in codes["base"], f"{name}: unknown message"
        int(entry["wparam"], 0)
        int(entry["lparam"], 0)
        assert entry.get("reply", "lparam_u32") in {"lparam_u32", "lparam_i32", "wparam_u32"}
        assert entry["status"] in {"verified", "capture_required"}, f"{name}: bad status"


def test_pairing_token_never_written_to_shared_specs() -> None:
    for spec_file in SPEC_FILES:
        keys = list(_all_keys(_load(spec_file)))
        leaked = [key for key in keys if "token" in key.lower() or "secret" in key.lower()]
        assert not leaked, f"{spec_file} leaks secret-like key(s): {leaked}"
