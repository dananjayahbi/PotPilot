"""Doc 10: drift-free asyncio telemetry poller over PotPlayer WM_USER getters.

Polls position / duration / play state / volume / speed every 250 ms through the getter
table in ``shared_specs/potplayer_wm_codes.json``, normalizes replies into immutable
``TelemetrySnapshot`` values, and hands every snapshot to subscribed listeners (Doc 18's
broadcaster). Each getter query is the module's only blocking Win32 call and is bounded
by a 40 ms ``SendMessageTimeoutW`` budget, so a hung player can never stall the agent's
event loop beyond the documented worst case.
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pc_agent.potplayer.hwnd_locator import PotPlayerLocator

log = logging.getLogger(__name__)

TELEMETRY_INTERVAL_MS: int = 250  # frozen wire cadence (overview §4)
QUERY_TIMEOUT_MS: int = 40  # per-getter SendMessageTimeoutW budget
BACKOFF_INTERVAL_MS: int = 1000  # degraded cadence after repeated failures
BACKOFF_FAILURE_COUNT: int = 4  # consecutive unhealthy ticks before backoff
LAST_GOOD_MAX_AGE_S: float = 2.0  # last-good values expire after this many seconds

SMTO_ABORTIFHUNG = 0x0002

GETTER_ORDER: tuple[str, ...] = (
    "GET_POSITION_MS",
    "GET_DURATION_MS",
    "GET_PLAY_STATE",
    "GET_VOLUME",
    "GET_SPEED",
)

POSITION_SENTINEL = 0xFFFFFFFF  # "no media" reply for position/duration getters
SPEED_MIN_DISPLAY, SPEED_MAX_DISPLAY = 0.2, 4.0
_VALID_REPLIES = {"lparam_u32", "lparam_i32", "wparam_u32"}

POTPILOT_WM_CODES_PATH = Path("shared_specs/potplayer_wm_codes.json")


class QueryError(RuntimeError):
    """One getter failed to deliver (timeout or invalid HWND)."""


@dataclass(frozen=True)
class TelemetrySnapshot:
    """Immutable result of one poll tick."""

    position_ms: int
    duration_ms: int
    is_playing: bool
    volume: int
    speed: float
    healthy: bool  # all five getters delivered this tick
    hwnd: int  # window used (0 when none)
    captured_at: float  # time.time() seconds


def _default_codes_path() -> Path:
    if POTPILOT_WM_CODES_PATH.is_file():
        return POTPILOT_WM_CODES_PATH
    return Path(__file__).resolve().parents[2] / POTPILOT_WM_CODES_PATH


def _send_message_timeout(hwnd: int, msg: int, wparam: int, lparam: int, timeout_ms: int):
    """Blocking getter query seam (tests monkeypatch this); returns (delivered, result)."""
    result = ctypes.c_size_t(0)
    delivered = ctypes.windll.user32.SendMessageTimeoutW(
        hwnd, msg, wparam, lparam, SMTO_ABORTIFHUNG, int(timeout_ms), ctypes.byref(result)
    )
    return int(delivered), int(result.value)


def _load_getters(path: Path) -> tuple[dict[str, int], dict[str, dict]]:
    """Load the getters section; never raises — callers degrade with an empty table."""
    try:
        table = json.loads(path.read_text(encoding="utf-8"))
        base = table.get("base") or table.get("messages")
        if not isinstance(base, dict) or not base:
            raise ValueError("missing base messages object")
        messages = {name: int(value, 0) for name, value in base.items()}
        getters = table.get("getters")
        if not isinstance(getters, dict):
            raise ValueError("missing getters object")
        validated: dict[str, dict] = {}
        for name, entry in getters.items():
            if not isinstance(entry, dict):
                raise ValueError(f"getter {name!r} must be an object")
            if entry.get("message") not in messages:
                raise ValueError(f"getter {name!r}: unknown message")
            int(entry["wparam"], 0)
            int(entry["lparam"], 0)
            if entry.get("reply", "lparam_u32") not in _VALID_REPLIES:
                raise ValueError(f"getter {name!r}: invalid reply packing")
            validated[name] = entry
        return messages, validated
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        log.warning("telemetry getters unavailable from %s: %s", path, exc)
        return {}, {}


def _normalize_position(raw: int) -> int:
    return 0 if raw == POSITION_SENTINEL else max(raw, 0)


def _normalize_volume(raw: int) -> int:
    return min(max(raw, 0), 100)


def _normalize_speed(raw: int) -> float:
    if raw <= 0:
        return 1.0  # neutral / unreported
    tenths = (raw + 50) // 100  # milli-units -> 0.1 steps, half up
    return min(max(tenths / 10.0, SPEED_MIN_DISPLAY), SPEED_MAX_DISPLAY)


class TelemetryPoller:
    """250 ms drift-free WM_USER getter loop publishing immutable snapshots."""

    def __init__(
        self,
        locator: PotPlayerLocator,
        codes_path: Path | None = None,
        interval_ms: int = TELEMETRY_INTERVAL_MS,
        *,
        now_fn: Callable[[], float] | None = None,
        clock: Callable[[], float] | None = None,
    ) -> None:
        """Load getters table; bind locator; no Win32 call until start()/poll_once()."""
        if interval_ms <= 0:
            raise ValueError("interval_ms must be positive")
        self._locator = locator
        self._interval_ms = int(interval_ms)
        path = codes_path if codes_path is not None else _default_codes_path()
        self._messages, self._getters = _load_getters(path)
        if not all(name in self._getters for name in GETTER_ORDER):
            log.warning("getters table incomplete; telemetry will report healthy=False")
        self._now = now_fn if now_fn is not None else time.time
        self._clock = clock  # None -> asyncio loop clock at start()
        self._task: asyncio.Task | None = None
        self._latest: TelemetrySnapshot | None = None
        self._listeners: list[Callable[[TelemetrySnapshot], None]] = []
        self._listeners_lock = threading.Lock()
        self._consecutive_failures = 0
        self._last_good: dict | None = None
        self._last_good_at = 0.0

    # ------------------------------------------------------------- lifecycle

    def start(self) -> None:
        """Spawn the polling task on the running asyncio loop; idempotent."""
        if self._task is not None and not self._task.done():
            log.debug("TelemetryPoller.start() called while already running")
            return
        loop = asyncio.get_running_loop()
        self._task = loop.create_task(self._run())

    async def stop(self) -> None:
        """Cancel the task and await its teardown."""
        task = self._task
        self._task = None
        if task is None:
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

    @property
    def latest(self) -> TelemetrySnapshot | None:
        """Most recent snapshot, or None before the first tick."""
        return self._latest

    @property
    def running(self) -> bool:
        """True while the asyncio task is alive."""
        return self._task is not None and not self._task.done()

    def subscribe(
        self, listener: Callable[[TelemetrySnapshot], None]
    ) -> Callable[[], None]:
        """Register a snapshot listener; returns an unsubscribe callable."""
        with self._listeners_lock:
            self._listeners.append(listener)

        def _unsubscribe() -> None:
            with self._listeners_lock:
                try:
                    self._listeners.remove(listener)
                except ValueError:
                    pass

        return _unsubscribe

    # -------------------------------------------------------------- polling

    def poll_once(self) -> TelemetrySnapshot:
        """Run one synchronous poll tick and publish it; safe to call from tests."""
        try:
            hwnd = self._locator.find()
        except Exception:  # pragma: no cover - defensive locator guard
            log.exception("locator.find() failed")
            hwnd = None

        if not hwnd:
            snapshot = self._degraded(healthy_hwnd=0)
        else:
            values: dict[str, object] = {}
            failure: QueryError | None = None
            for name in GETTER_ORDER:
                entry = self._getters.get(name)
                if entry is None:
                    failure = QueryError(f"{name}: getters unavailable")
                    break
                try:
                    values[name] = self._normalize(name, self._query(int(hwnd), entry))
                except QueryError as exc:
                    failure = exc
                    break
            if failure is not None:
                log.debug("telemetry tick degraded: %s", failure)
                snapshot = self._degraded(healthy_hwnd=int(hwnd), partial=values)
            else:
                self._consecutive_failures = 0
                self._last_good = dict(values)
                self._last_good_at = float(self._now())
                state = str(self._last_good["GET_PLAY_STATE"])
                snapshot = TelemetrySnapshot(
                    position_ms=int(self._last_good["GET_POSITION_MS"]),
                    duration_ms=int(self._last_good["GET_DURATION_MS"]),
                    is_playing=(state == "playing"),
                    volume=int(self._last_good["GET_VOLUME"]),
                    speed=float(self._last_good["GET_SPEED"]),
                    healthy=True,
                    hwnd=int(hwnd),
                    captured_at=float(self._now()),
                )

        self._latest = snapshot
        self._publish(snapshot)
        return snapshot

    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        clock = self._clock if self._clock is not None else loop.time
        deadline = clock() + self._current_interval_s()
        try:
            while True:
                self.poll_once()
                deadline = _advance_deadline(deadline, clock(), self._current_interval_s())
                await asyncio.sleep(max(0.0, deadline - clock()))
        except asyncio.CancelledError:
            raise

    def _current_interval_s(self) -> float:
        if self._consecutive_failures >= BACKOFF_FAILURE_COUNT:
            return BACKOFF_INTERVAL_MS / 1000.0
        return self._interval_ms / 1000.0

    # -------------------------------------------------------------- internals

    def _query(self, hwnd: int, entry: dict) -> int:
        msg = self._messages[entry["message"]]
        wparam, lparam = int(entry["wparam"], 0), int(entry["lparam"], 0)
        delivered, result = _send_message_timeout(hwnd, msg, wparam, lparam, QUERY_TIMEOUT_MS)
        if not delivered:
            raise QueryError(f"{entry.get('name', '?')}: timeout or dead hwnd")
        reply = entry.get("reply", "lparam_u32")
        if reply == "lparam_i32":
            value = result & 0xFFFFFFFF
            return value - 0x100000000 if value >= 0x80000000 else value
        return result & 0xFFFFFFFF

    def _normalize(self, name: str, raw: int) -> object:
        if name in ("GET_POSITION_MS", "GET_DURATION_MS"):
            return _normalize_position(raw)
        if name == "GET_VOLUME":
            return _normalize_volume(raw)
        if name == "GET_SPEED":
            return _normalize_speed(raw)
        if name == "GET_PLAY_STATE":
            entry = self._getters[name]
            state_map = {int(k): v for k, v in entry.get("state_map", {}).items()}
            return state_map.get(raw, "stopped")
        return raw  # pragma: no cover - GETTER_ORDER is closed

    def _degraded(
        self, healthy_hwnd: int, partial: dict[str, object] | None = None
    ) -> TelemetrySnapshot:
        """One failed/missing-window tick: keep this tick's delivered fields, else
        last-good while fresh, else zeroed."""
        self._consecutive_failures += 1
        merged: dict[str, object] = {}
        if self._last_good is not None:
            age = float(self._now()) - self._last_good_at
            if 0 <= age <= LAST_GOOD_MAX_AGE_S:
                merged.update(self._last_good)
        if partial:
            merged.update(partial)
        state = str(merged.get("GET_PLAY_STATE", "stopped"))
        return TelemetrySnapshot(
            position_ms=int(merged.get("GET_POSITION_MS", 0)),
            duration_ms=int(merged.get("GET_DURATION_MS", 0)),
            is_playing=(state == "playing"),
            volume=int(merged.get("GET_VOLUME", 0)),
            speed=float(merged.get("GET_SPEED", 0.0)),
            healthy=False,
            hwnd=healthy_hwnd,
            captured_at=float(self._now()),
        )

    def _publish(self, snapshot: TelemetrySnapshot) -> None:
        with self._listeners_lock:
            listeners = list(self._listeners)
        for listener in listeners:
            try:
                listener(snapshot)
            except Exception:
                log.exception("telemetry listener raised; continuing")


# Static scheduling helper attached after the class body for a clean unit seam.
def _advance_deadline(deadline: float, now: float, interval_s: float) -> float:
    """Advance a drift-free deadline; a stall > one interval skips to now + interval."""
    deadline += interval_s
    if now - deadline > interval_s:
        deadline = now + interval_s
    return deadline
