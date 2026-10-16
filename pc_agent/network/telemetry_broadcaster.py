"""Telemetry broadcast loop — Doc 18.

Owns the drift-corrected 250 ms diff loop: each tick merges the latest
PotPlayer playback snapshot (Doc 10 poller, constructor-injected) with any
registered named providers (Docs 12/19/22/23), diffs the merged flat dict
against the last state actually relevant, and pushes compact
``TELEMETRY_SYNC`` JSON frames (``STATE_DELTA`` / ``FULL_STATE``) to every
registered WebSocket client.

Provider registry seam: Session-2 modules call ``register_source(name, provider)``
with a sync or async callable returning a flat ``dict[str, Any]``; their keys
never appear in any frame until registered and vanish again after
``unregister_source``. No module from Docs 12/19/22/23 is ever imported here.

Client seam: Doc 14's ``WsServer`` (wired by ``main.py``) calls
``register_client`` / ``unregister_client`` with the raw ``websockets``
connection object; each authenticated client immediately receives a
``FULL_STATE`` snapshot.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import math
import time
from collections.abc import Awaitable, Callable
from dataclasses import asdict
from typing import Any, Protocol

from pc_agent.network.ws_message_codec import (
    ACTION_FULL_STATE,
    ACTION_STATE_DELTA,
    FULL_REFRESH_EVERY_TICKS,
    TELEMETRY_INTERVAL_MS,
    WsType,
    build_telemetry_delta,
    build_telemetry_full,
)

log = logging.getLogger(__name__)

TYPE_TELEMETRY: str = str(WsType.TELEMETRY_SYNC)
SOURCE_BLACKOUT: str = "blackout"
SOURCE_BRIGHTNESS: str = "brightness"
SOURCE_SLEEP: str = "sleep_timer"
SOURCE_AUDIO: str = "audio"

PROVIDER_TIMEOUT_S: float = 0.100  # per-provider budget per tick (Doc 18 §4.2)
SEND_TIMEOUT_S: float = 2.0  # per-client send budget (Doc 18 §4.5)
_PROVIDER_WARN_INTERVAL_S: float = 60.0

_MISSING = object()

SnapshotProvider = Callable[[], "dict[str, Any] | Awaitable[dict[str, Any]]"]


class TelemetryPollerLike(Protocol):
    """Structural subset of the Doc 10 poller: cached snapshot via ``latest``."""

    @property
    def latest(self) -> Any | None: ...


def snapshot_to_payload(snapshot: Any) -> dict[str, Any]:
    """Map a Doc 10 ``TelemetrySnapshot`` (or dict/None) to the 7 base wire keys."""
    if snapshot is None:
        return {
            "position_ms": 0,
            "duration_ms": 0,
            "is_playing": False,
            "speed": 1.0,
            "volume": 0,
            "file_title": None,
            "potplayer_found": False,
        }

    def field(name: str, default: Any) -> Any:
        if isinstance(snapshot, dict):
            return snapshot.get(name, default)
        return getattr(snapshot, name, default)

    found = field("potplayer_found", None)
    if found is None:
        found = bool(field("hwnd", 0))
    return {
        "position_ms": int(field("position_ms", 0)),
        "duration_ms": int(field("duration_ms", 0)),
        "is_playing": bool(field("is_playing", False)),
        "speed": float(field("speed", 1.0)),
        "volume": int(field("volume", 0)),
        "file_title": field("file_title", None),
        "potplayer_found": bool(found),
    }


class TelemetryBroadcaster:
    """250 ms drift-corrected diff loop over the merged provider snapshot."""

    def __init__(
        self,
        poller: TelemetryPollerLike,
        *,
        interval_ms: int = TELEMETRY_INTERVAL_MS,
    ) -> None:
        self._poller = poller
        self._interval_s = interval_ms / 1000.0
        self._clients: set[Any] = set()
        self._sources: dict[str, SnapshotProvider] = {}
        self._source_values: dict[str, dict[str, Any]] = {}
        self._last_sent: dict[str, Any] = {}
        self._last_merged: dict[str, Any] = {}
        self._tick = 0
        self._task: asyncio.Task[None] | None = None
        self._warned_at: dict[str, float] = {}

    # -- Client registry (Doc 14 seam) --------------------------------------
    def register_client(self, ws: Any) -> None:
        """Add an authenticated WS client and immediately push it a FULL_STATE frame."""
        self._clients.add(ws)
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:  # pragma: no cover - only outside a running loop
            log.warning("register_client called with no running loop; snapshot deferred")
            return
        loop.create_task(self._push_full_state(ws))

    def unregister_client(self, ws: Any) -> None:
        """Remove a client; silently tolerant of unknown or dead sockets."""
        self._clients.discard(ws)

    @property
    def client_count(self) -> int:
        return len(self._clients)

    # -- Provider registry (Docs 12/19/22/23 seam) --------------------------
    def register_source(self, name: str, provider: SnapshotProvider) -> None:
        """Register a named flat-dict snapshot provider merged into every tick."""
        self._sources[name] = provider

    def unregister_source(self, name: str) -> None:
        """Drop a provider; its keys are omitted from subsequent frames."""
        self._sources.pop(name, None)
        self._source_values.pop(name, None)

    # -- Lifecycle ----------------------------------------------------------
    async def start(self) -> None:
        """Spawn the drift-corrected 250 ms loop as a background asyncio task."""
        if self._task is not None and not self._task.done():
            return
        self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        """Cancel the loop, flush one final FULL_STATE, and clear clients."""
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        if self._clients and self._last_merged:
            frame = self.build_frame(dict(self._last_merged), action=ACTION_FULL_STATE)
            await self._fanout(frame)
        self._clients.clear()

    # -- State accessors ----------------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        """Return the last known full flat state dict (absent sources = absent keys)."""
        return dict(self._last_merged)

    def build_frame(self, payload: dict[str, Any], *, action: str) -> str:
        """Serialize one TELEMETRY_SYNC envelope as compact JSON text."""
        if action == ACTION_STATE_DELTA:
            msg = build_telemetry_delta(payload)
        elif action == ACTION_FULL_STATE:
            msg = build_telemetry_full(payload)
        else:
            raise ValueError(f"unsupported telemetry action: {action!r}")
        return json.dumps(asdict(msg), separators=(",", ":"), allow_nan=False)

    # -- Loop internals -----------------------------------------------------
    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        interval = self._interval_s
        deadline = loop.time() + interval
        while True:
            delay = deadline - loop.time()
            if delay > 0:
                await asyncio.sleep(delay)
            now = loop.time()
            while deadline <= now:  # skip missed deadlines; never burst catch-up
                deadline += interval
            self._tick += 1
            await self._tick_once()

    async def _tick_once(self) -> None:
        merged = await self._collect_state()
        self._last_merged = merged
        changed = {
            key: value
            for key, value in merged.items()
            if value != self._last_sent.get(key, _MISSING)
        }
        if changed:
            action = ACTION_STATE_DELTA
            payload = changed
        elif self._tick % FULL_REFRESH_EVERY_TICKS == 0:
            action = ACTION_FULL_STATE
            payload = dict(merged)
        else:
            self._last_sent = merged  # keep warm; nothing worth sending
            return
        self._last_sent = merged
        if not self._clients:
            return  # diff still ran; serialization/fan-out skipped (Doc 18 §7)
        await self._fanout(self.build_frame(payload, action=action))

    async def _collect_state(self) -> dict[str, Any]:
        state = snapshot_to_payload(getattr(self._poller, "latest", None))
        for name, provider in list(self._sources.items()):
            try:
                value = provider()
                if inspect.isawaitable(value):
                    value = await asyncio.wait_for(value, timeout=PROVIDER_TIMEOUT_S)
                if not isinstance(value, dict):
                    raise TypeError(f"provider returned {type(value).__name__}, expected dict")
            except Exception:
                self._warn_provider(name)
                last_good = self._source_values.get(name)
                if last_good is not None:
                    state.update(last_good)  # keep last-good values for that source
                continue
            clean = {key: _json_safe(val) for key, val in value.items()}
            self._source_values[name] = clean
            state.update(clean)
        return state

    async def _fanout(self, frame: str) -> None:
        await asyncio.gather(*(self._send_to(ws, frame) for ws in list(self._clients)))

    async def _send_to(self, ws: Any, frame: str) -> None:
        try:
            await asyncio.wait_for(ws.send(frame), timeout=SEND_TIMEOUT_S)
        except Exception:
            self._clients.discard(ws)  # dead socket; loop survives (Doc 18 §7)
            log.warning("telemetry client failed mid-send; unregistered", exc_info=True)

    async def _push_full_state(self, ws: Any) -> None:
        state = dict(self._last_merged)
        if not state:
            state = await self._collect_state()
        frame = self.build_frame(state, action=ACTION_FULL_STATE)
        try:
            await asyncio.wait_for(ws.send(frame), timeout=SEND_TIMEOUT_S)
        except Exception:
            self._clients.discard(ws)
            log.warning("initial FULL_STATE push failed; client unregistered", exc_info=True)

    def _warn_provider(self, name: str) -> None:
        """Log at most one warning per source per minute (Doc 18 §7)."""
        now = time.monotonic()
        last = self._warned_at.get(name)
        if last is None or now - last >= _PROVIDER_WARN_INTERVAL_S:
            self._warned_at[name] = now
            log.warning("telemetry provider %r raised or timed out; keeping last-good values", name)


def _json_safe(value: Any) -> Any:
    """Coerce non-finite floats to 0 defensively (Doc 18 §7)."""
    if isinstance(value, float) and not math.isfinite(value):
        return 0
    return value


__all__ = [
    "ACTION_FULL_STATE",
    "ACTION_STATE_DELTA",
    "FULL_REFRESH_EVERY_TICKS",
    "SOURCE_AUDIO",
    "SOURCE_BLACKOUT",
    "SOURCE_BRIGHTNESS",
    "SOURCE_SLEEP",
    "TELEMETRY_INTERVAL_MS",
    "TYPE_TELEMETRY",
    "SnapshotProvider",
    "TelemetryBroadcaster",
    "TelemetryPollerLike",
    "snapshot_to_payload",
]
