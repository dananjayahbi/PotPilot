"""Doc 19: DDC/CI hardware luminance control for external monitors.

Wraps ``monitorcontrol`` (VCP code ``0x10``) behind an async controller: physical
monitor enumeration runs in a worker thread, hardware reads are cached for Doc
18's ``brightness`` telemetry provider, and slider writes are **coalesced** —
the latest target per monitor wins and the DDC/I2C bus sees at most one physical
write per ``WRITE_COALESCE_MS`` no matter how fast the phone drags (120 Hz).

Wire surface (frozen Doc 03 §5.5): the router dispatches ``CMD_SYSTEM`` /
``SET_BRIGHTNESS`` with ``{"percent": int 0–100}`` to
:meth:`DdcciBrightnessController.set_brightness`; there is no relative or read
command — clients compute deltas from telemetry/cache. Errors surface as
:class:`DdcciError` whose ``code`` is one of the frozen ``E_*`` tokens; the
Doc 14 handler maps them to ``{"ok": false, "error", "detail"}`` payloads so no
exception ever reaches the WS loop.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import math
import time
from dataclasses import dataclass, replace
from typing import Any

import monitorcontrol

log = logging.getLogger(__name__)

BRIGHTNESS_MIN: int = 0
BRIGHTNESS_MAX: int = 100
WRITE_COALESCE_MS: int = 100
ACT_SET_BRIGHTNESS: str = "SET_BRIGHTNESS"

ERR_DDCI_UNSUPPORTED: str = "E_DDCI_UNSUPPORTED"
ERR_MONITOR_NOT_FOUND: str = "E_MONITOR_NOT_FOUND"
ERR_DDCI_IO: str = "E_DDCI_IO"
ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"

_STOP_FLUSH_DEADLINE_S: float = 2.0


class DdcciError(Exception):
    """Structured DDC/CI failure carrying the frozen Doc 19 §5 wire error code."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail


@dataclass(frozen=True, slots=True)
class MonitorInfo:
    """Immutable snapshot of one monitorcontrol monitor."""

    index: int  # 0-based position in monitorcontrol enumeration order
    name: str  # human-readable model/description, "" if unavailable
    supported: bool  # DDC/CI probe succeeded
    value: int | None  # last known luminance 0-100; None if unknown/unsupported


def _clamp(value: int) -> int:
    return max(BRIGHTNESS_MIN, min(BRIGHTNESS_MAX, int(value)))


def _coerce_percent(value: Any) -> int:
    """Clamp safe values; structurally invalid input becomes E_BAD_PAYLOAD."""
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise DdcciError(ERR_BAD_PAYLOAD, f"percent must be a number, got {type(value).__name__}")
    number = float(value)
    if not math.isfinite(number):
        raise DdcciError(ERR_BAD_PAYLOAD, "percent must be finite")
    return _clamp(int(round(number)))


def _classify(exc: BaseException) -> DdcciError:
    """Map monitorcontrol/OS exceptions onto the frozen error-code set (§7)."""
    if isinstance(exc, DdcciError):
        return exc
    detail = f"{type(exc).__name__}: {exc}"
    if isinstance(exc, PermissionError) or isinstance(exc, monitorcontrol.VCPPermissionError):
        # Permission denied on DDC access → same UX as unsupported (§7).
        return DdcciError(ERR_DDCI_UNSUPPORTED, detail)
    if isinstance(exc, monitorcontrol.VCPIOError | OSError | TimeoutError):
        # Transient I2C/timeout failures keep the cache and retry next command.
        return DdcciError(ERR_DDCI_IO, detail)
    if isinstance(exc, monitorcontrol.VCPError | ValueError | NotImplementedError):
        # VCP-level refusal: monitor lacks DDC/CI or rejects the request.
        return DdcciError(ERR_DDCI_UNSUPPORTED, detail)
    return DdcciError(ERR_DDCI_IO, detail)


class DdcciBrightnessController:
    """Cached monitor list + coalescing DDC writer + Doc 18 snapshot provider."""

    def __init__(self, *, write_min_interval_ms: int = WRITE_COALESCE_MS) -> None:
        """Own the monitor cache and the coalescing DDC writer task."""
        self._interval_s = max(0, int(write_min_interval_ms)) / 1000.0
        self._cache: dict[int, MonitorInfo] = {}
        self._raw: dict[int, Any] = {}
        self._enumerated = False
        self._pending: dict[int, int] = {}
        self._last_write_at: dict[int, float] = {}
        self._deferred: DdcciError | None = None
        self._writer_task: asyncio.Task[None] | None = None
        self._writing = False
        self._wake = asyncio.Event()
        self._stop = asyncio.Event()
        self._idle = asyncio.Event()  # writer drained (or dead) — stop() waits on this
        self._enum_lock = asyncio.Lock()

    # ---------------------------------------------------------- enumeration

    async def list_monitors(self, *, refresh: bool = False) -> list[MonitorInfo]:
        """Return cached monitor info, re-probing hardware when refresh=True."""
        async with self._enum_lock:
            if self._enumerated and not refresh:
                return sorted(self._cache.values(), key=lambda info: info.index)
            infos, raw = await asyncio.to_thread(self._enumerate_blocking)
            self._cache = infos
            self._raw = raw
            self._enumerated = True
            return sorted(infos.values(), key=lambda info: info.index)

    def _enumerate_blocking(self) -> tuple[dict[int, MonitorInfo], dict[int, Any]]:
        """Worker thread: enumerate hardware and probe each monitor's luminance."""
        try:
            monitors = list(monitorcontrol.get_monitors())
        except Exception as exc:
            raise _classify(exc) from exc
        infos: dict[int, MonitorInfo] = {}
        raw: dict[int, Any] = {}
        for index, monitor in enumerate(monitors):
            name = str(getattr(monitor, "name", "") or "")
            raw[index] = monitor
            try:
                value = _clamp(int(monitor.get_luminance()))
            except Exception:
                # Probe failure (firmware-blocked panel, asleep, no DDC/CI):
                # report unsupported; snapshot stays null (Doc 19 §7/Q1).
                infos[index] = MonitorInfo(index=index, name=name, supported=False, value=None)
            else:
                infos[index] = MonitorInfo(index=index, name=name, supported=True, value=value)
        return infos, raw

    # -------------------------------------------------------------- reads

    async def get_brightness(self, monitor: int = 0, *, refresh: bool = False) -> int:
        """Return luminance 0-100 for one monitor; refresh=True forces a hardware read."""
        await self.list_monitors(refresh=refresh)
        info = self._cache.get(monitor)
        if info is None:
            raise DdcciError(ERR_MONITOR_NOT_FOUND, f"monitor {monitor} is not enumerated")
        pending = self._pending.get(monitor)
        if pending is not None:
            return pending  # a pending write is what the monitor will show (§7)
        if not info.supported or info.value is None:
            raise DdcciError(ERR_DDCI_UNSUPPORTED, f"monitor {monitor} rejected the DDC/CI probe")
        return info.value

    def snapshot(self) -> dict[str, Any]:
        """Flat dict for Doc 18: ``{'brightness': int | None}`` (first capable monitor)."""
        for index in sorted(self._cache):
            info = self._cache[index]
            if info.supported:
                return {"brightness": self._pending.get(index, info.value)}
        return {"brightness": None}

    # ------------------------------------------------------------- writes

    async def set_brightness(self, monitor: int, value: int) -> int:
        """Clamp value to 0-100, schedule a coalesced write, return the target."""
        target = _coerce_percent(value)
        deferred = self._deferred
        if deferred is not None:
            # One automatic re-enumeration on the command following a failed
            # write (Doc 19 §7); then surface the original failure once.
            self._deferred = None
            await self.list_monitors(refresh=True)
            if monitor not in self._cache:
                raise DdcciError(ERR_MONITOR_NOT_FOUND, f"monitor {monitor} disappeared")
            raise deferred
        await self.list_monitors()
        info = self._cache.get(monitor)
        if info is None:
            raise DdcciError(ERR_MONITOR_NOT_FOUND, f"monitor {monitor} is not enumerated")
        if not info.supported:
            raise DdcciError(
                ERR_DDCI_UNSUPPORTED, f"monitor {monitor} does not support DDC/CI writes"
            )
        self._pending[monitor] = target  # latest wins; intermediate values skipped
        self._ensure_writer()
        self._wake.set()
        return target

    # ------------------------------------------------------ writer task

    def _ensure_writer(self) -> None:
        if self._writer_task is None or self._writer_task.done():
            self._writer_task = asyncio.create_task(self._writer_loop())

    async def _writer_loop(self) -> None:
        """Single writer: wait, coalesce to latest per monitor, flush, repeat."""
        try:
            while True:
                await self._wake.wait()
                self._wake.clear()
                while self._pending:
                    monitor = next(iter(self._pending))
                    await self._coalesce_wait(monitor)
                    value = self._pending.pop(monitor, None)
                    if value is None:
                        continue
                    await self._flush(monitor, value)
                self._idle.set()  # fully drained — stop() may proceed
        except asyncio.CancelledError:
            raise
        except Exception:  # pragma: no cover - defensive: never kill the loop silently
            log.exception("DDC coalescing writer task died unexpectedly")
        finally:
            self._idle.set()

    async def _coalesce_wait(self, monitor: int) -> None:
        """Wait out the per-monitor write spacing; stop() short-circuits it."""
        last = self._last_write_at.get(monitor)
        if last is None:
            return
        delay = last + self._interval_s - time.monotonic()
        if delay <= 0 or self._stop.is_set():
            return
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._stop.wait(), timeout=delay)

    async def _flush(self, monitor: int, value: int) -> None:
        """Perform one physical write with a single unplug-race retry (§7)."""
        self._writing = True
        try:
            try:
                await asyncio.to_thread(self._write_blocking, monitor, value)
            except DdcciError as exc:
                if exc.code != ERR_DDCI_IO:
                    raise
                # Unplug race: re-enumerate once, then retry the write once.
                await self.list_monitors(refresh=True)
                if monitor not in self._cache:
                    raise DdcciError(
                        ERR_MONITOR_NOT_FOUND, f"monitor {monitor} vanished mid-write"
                    ) from exc
                await asyncio.to_thread(self._write_blocking, monitor, value)
        except DdcciError as exc:
            self._pending.pop(monitor, None)  # drop the stale target too (§4.3)
            self._deferred = exc
            log.warning(
                "DDC write for monitor %s failed (%s): %s", monitor, exc.code, exc.detail
            )
        else:
            info = self._cache.get(monitor)
            if info is not None:
                self._cache[monitor] = replace(info, supported=True, value=value)
            self._last_write_at[monitor] = time.monotonic()
        finally:
            self._writing = False

    def _write_blocking(self, monitor: int, value: int) -> None:
        """Worker thread: one physical DDC write, mapped onto frozen error codes."""
        raw = self._raw.get(monitor)
        if raw is None:
            raise DdcciError(ERR_MONITOR_NOT_FOUND, f"monitor {monitor} is not enumerated")
        try:
            raw.set_luminance(value)
        except Exception as exc:
            raise _classify(exc) from exc

    # ---------------------------------------------------------- lifecycle

    async def stop(self) -> None:
        """Flush any pending coalesced write and cancel the writer task."""
        task = self._writer_task
        if task is None:
            return
        self._idle.clear()
        self._stop.set()
        self._wake.set()
        if not task.done():
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(self._idle.wait(), timeout=_STOP_FLUSH_DEADLINE_S)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        self._writer_task = None
        self._stop.clear()
        self._wake.clear()
