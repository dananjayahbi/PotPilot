"""Doc 46 shared fixtures + result types for the PC QA/benchmark suite.

Provides the pieces §2 promises: echo responder, mock PotPlayer window, WS
test client, an in-process agent stack (real router/server/broadcaster/
poller/dispatcher), the frozen :class:`LatencyStats` result type with
:func:`evaluate`, and the outbound-envelope validator that checks every
harness send against ``shared_specs/ws_command_schema.json`` before dispatch.
"""

from __future__ import annotations

import json
import math
import re
import socket
import time
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from pc_agent.core.auth_middleware import xor_checksum

REPO_ROOT = Path(__file__).resolve().parents[2]
SHARED_SPECS_DIR = REPO_ROOT / "shared_specs"

# Fixed Doc 15 pairing token for tests: deterministic UDP auth byte + WS handshake.
TOKEN_HEX = "0123456789abcdef0123456789abcdef"
AUTH_BYTE = xor_checksum(bytes.fromhex(TOKEN_HEX))  # Doc 15 pure function

PREFERRED_UDP_PORT = 50505  # frozen Doc 02 port; falls back to ephemeral when busy

WS_SCHEMA = json.loads((SHARED_SPECS_DIR / "ws_command_schema.json").read_text(encoding="utf-8"))
UDP_LAYOUT = json.loads((SHARED_SPECS_DIR / "udp_packet_layout.json").read_text(encoding="utf-8"))

_UUID4_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_ACTION_RE = r"^[A-Z][A-Z0-9_]*$"
_ACTION_PATTERN = re.compile(_ACTION_RE)


# ---------------------------------------------------------------------------
# Doc 46 §3 result types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class LatencyStats:
    """Immutable RTT/latency summary in milliseconds."""

    samples_ms: list[float]
    min: float
    mean: float
    p50: float
    p95: float
    p99: float
    max: float


def _percentile(ordered: list[float], percentile: float) -> float:
    """Nearest-rank percentile over an already sorted non-empty list."""
    rank = math.ceil(percentile / 100.0 * len(ordered))
    return ordered[min(max(rank, 1), len(ordered)) - 1]


def compute_stats(samples: Sequence[float]) -> LatencyStats:
    """Summarize raw millisecond samples (raises on an empty sequence)."""
    values = [float(sample) for sample in samples]
    if not values:
        raise ValueError("cannot summarize zero samples")
    ordered = sorted(values)
    return LatencyStats(
        samples_ms=values,
        min=ordered[0],
        mean=sum(values) / len(values),
        p50=_percentile(ordered, 50.0),
        p95=_percentile(ordered, 95.0),
        p99=_percentile(ordered, 99.0),
        max=ordered[-1],
    )


def evaluate(
    stats: LatencyStats, threshold_ms: float = 5.0, *, percentile: str = "p95"
) -> bool:
    """True iff ``stats.<percentile>`` is strictly below ``threshold_ms``."""
    if percentile not in ("p50", "p95", "p99"):
        raise ValueError(f"unsupported percentile: {percentile!r}")
    return float(getattr(stats, percentile)) < float(threshold_ms)


def format_stats(label: str, stats: LatencyStats) -> str:
    """One-line human-readable benchmark report."""
    return (
        f"{label}: n={len(stats.samples_ms)} min={stats.min:.3f} mean={stats.mean:.3f} "
        f"p50={stats.p50:.3f} p95={stats.p95:.3f} p99={stats.p99:.3f} max={stats.max:.3f} ms"
    )


def stats_from_dict(data: dict[str, Any]) -> LatencyStats:
    """Build :class:`LatencyStats` from a Dart ``BENCH_RESULT`` JSON payload."""
    samples = [float(value) for value in data.get("samplesMs", ())]
    if samples:
        return compute_stats(samples)
    return LatencyStats(
        samples_ms=[],
        min=float(data.get("minMs", 0.0)),
        mean=float(data["meanMs"]),
        p50=float(data["p50Ms"]),
        p95=float(data["p95Ms"]),
        p99=float(data["p99Ms"]),
        max=float(data["maxMs"]),
    )


# ---------------------------------------------------------------------------
# Outbound envelope validation (Doc 46 §5: every harness send must conform)
# ---------------------------------------------------------------------------


def _validate_payload_value(field: str, value: Any, spec: dict[str, Any]) -> None:
    expected = spec.get("type")
    if expected == "integer":
        valid = isinstance(value, int) and not isinstance(value, bool)
    elif expected == "number":
        valid = isinstance(value, int | float) and not isinstance(value, bool)
    elif expected == "string":
        valid = isinstance(value, str)
    elif expected == "boolean":
        valid = isinstance(value, bool)
    elif expected == "object":
        valid = isinstance(value, dict)
    elif expected == "array":
        valid = isinstance(value, list)
    else:
        valid = True
    assert valid, f"payload field {field!r}: expected {expected}, got {type(value).__name__}"

    if isinstance(value, int | float) and not isinstance(value, bool):
        if "minimum" in spec:
            assert value >= spec["minimum"], f"payload field {field!r}: {value} < minimum"
        if "maximum" in spec:
            assert value <= spec["maximum"], f"payload field {field!r}: {value} > maximum"
        if "multiple_of" in spec and isinstance(value, int):
            assert value % int(spec["multiple_of"]) == 0, (
                f"payload field {field!r}: {value} not a multiple of {spec['multiple_of']}"
            )
    if isinstance(value, str):
        if "min_length" in spec:
            assert len(value) >= spec["min_length"], f"payload field {field!r} too short"
        if "max_length" in spec:
            assert len(value) <= spec["max_length"], f"payload field {field!r} too long"
    if "enum" in spec:
        assert value in spec["enum"], f"payload field {field!r}: {value!r} not in {spec['enum']}"
    if isinstance(value, list):
        if "max_items" in spec:
            assert len(value) <= spec["max_items"], f"payload field {field!r}: too many items"
        if spec.get("unique_items"):
            assert len(set(map(str, value))) == len(value), (
                f"payload field {field!r}: items must be unique"
            )
        item_spec = spec.get("items")
        if isinstance(item_spec, dict):
            for item in value:
                _validate_payload_value(field, item, item_spec)


def validate_ws_frame(frame: dict[str, Any]) -> None:
    """Assert one outbound harness frame conforms to ws_command_schema.json.

    Checks the frozen envelope (keys/uuid4/type enum/action pattern), that the
    action is registered for its type, and per-field payload constraints
    (type, range, enum, required-vs-optional). Raises ``AssertionError`` with
    a precise reason on any violation.
    """
    envelope_keys = set(WS_SCHEMA["envelope"])
    frame_keys = set(frame)
    assert frame_keys == envelope_keys, (
        f"envelope keys {sorted(frame_keys)} != {sorted(envelope_keys)}"
    )
    assert isinstance(frame["id"], str) and _UUID4_RE.fullmatch(frame["id"]), (
        f"envelope id must be a lowercase uuid4: {frame['id']!r}"
    )
    msg_type = frame["type"]
    assert msg_type in WS_SCHEMA["types"], f"unknown message type: {msg_type!r}"
    assert msg_type != "TELEMETRY_SYNC", (
        "TELEMETRY_SYNC is server->client only (schema forbidden_client_actions)"
    )
    action = frame["action"]
    assert isinstance(action, str) and _ACTION_PATTERN.fullmatch(action), (
        f"action must be UPPER_SNAKE_CASE: {action!r}"
    )
    actions = WS_SCHEMA["types"][msg_type]["actions"]
    assert action in actions, f"action {action!r} not registered under {msg_type}"
    timestamp = frame["timestamp"]
    assert isinstance(timestamp, int) and not isinstance(timestamp, bool), (
        f"timestamp must be integer unix seconds: {timestamp!r}"
    )

    payload = frame["payload"]
    assert isinstance(payload, dict), f"payload must be an object: {payload!r}"
    payload_spec = actions[action].get("payload", {})
    for key, value in payload.items():
        assert key in payload_spec, f"payload field {key!r} not in schema for {action}"
        _validate_payload_value(key, value, payload_spec[key])
    for key, spec in payload_spec.items():
        if key in payload:
            continue
        assert spec.get("optional", False) or "required_when" in spec, (
            f"payload field {key!r} is required for {action}"
        )


def build_ws_frame(
    msg_type: str, action: str, payload: dict[str, Any] | None = None
) -> dict[str, Any]:
    """Compose an outbound envelope and validate it before any test send."""
    frame = {
        "id": str(uuid.uuid4()),
        "type": msg_type,
        "action": action,
        "payload": dict(payload or {}),
        "timestamp": int(time.time()),
    }
    validate_ws_frame(frame)
    return frame


# ---------------------------------------------------------------------------
# WS test client (Doc 46 §4.4.4)
# ---------------------------------------------------------------------------


async def ws_connect(port: int, *, token: str = TOKEN_HEX) -> Any:
    """Connect to a started WsServer on 127.0.0.1:<port>; consume AUTH_OK."""
    from websockets.asyncio.client import connect

    connection = await connect(f"ws://127.0.0.1:{port}/?auth={token}")
    greeting = json.loads(await connection.recv())
    assert greeting.get("type") == "CMD_SYSTEM" and greeting.get("action") == "AUTH_OK", (
        f"expected AUTH_OK greeting, got {greeting}"
    )
    return connection


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


def _pick_udp_port(host: str, preferred: int) -> int:
    """Use the frozen port when free, else fall back to an ephemeral one."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.bind((host, preferred))
        except OSError:
            return 0
    return preferred


@pytest.fixture
def echo_responder():
    """Doc 46 §4.2 echo responder: frozen 50505 when free, else ephemeral."""
    from pc_agent.tests.harness.udp_echo_responder import UdpEchoResponder

    responder = UdpEchoResponder(
        "127.0.0.1", _pick_udp_port("127.0.0.1", PREFERRED_UDP_PORT), AUTH_BYTE
    )
    responder.start()
    try:
        yield responder
    finally:
        responder.stop()


@pytest.fixture
def mock_potplayer():
    """Doc 46 §4.3 mock PotPlayer64 window; created and destroyed in-test."""
    from pc_agent.tests.harness.mock_potplayer_window import MockPotPlayerWindow

    window = MockPotPlayerWindow()
    window.start()
    try:
        yield window
    finally:
        window.stop()
