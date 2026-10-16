"""Doc 23: Windows system volume/mute control via CoreAudio (pycaw on a COM worker).

Owns the frozen ``CMD_SYSTEM`` wire surface dispatched by Doc 14:
``SET_SYSTEM_VOLUME {"percent": int}`` and ``SET_SYSTEM_MUTE {"muted": bool}``,
each acking ``{"ok": true}`` (deltas are client-computed; internal
``adjust_volume``/``toggle_mute`` helpers stay local).  Failures map to
``{"ok": false, "error": E_NO_ENDPOINT|E_COREAUDIO|E_BAD_PAYLOAD, "detail"}`` —
raw ``COMError`` never reaches the router.

Engine (§4): every pycaw/comtypes call runs on one dedicated
``ThreadPoolExecutor(max_workers=1)`` worker that performs
``comtypes.CoInitializeEx(COINIT_MULTITHREADED)`` exactly once before first use
(COM apartment correctness off the asyncio thread, serialized slider writes).
The default render endpoint resolves lazily
(``GetSpeakers().Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)`` →
``cast``) and is cached until an operation fails: one re-resolve + one retry
covers HDMI/BT device changes; resolution failure maps to ``E_NO_ENDPOINT``,
a still-failing operation to ``E_COREAUDIO``.  ``snapshot()`` serves Doc 18's
``sys_volume``/``sys_muted`` keys from a plain cache (no COM call); a 2 s
read-only refresh loop reconciles external mixer changes so the broadcaster
only ever sees real diffs.
"""

from __future__ import annotations

import asyncio
import logging
import math
from concurrent.futures import ThreadPoolExecutor
from typing import TYPE_CHECKING, Any

import comtypes
from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume

if TYPE_CHECKING:
    from pc_agent.network.ws_server_router import WsEnvelope, WsSession

log = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Frozen constants (Doc 23 §3 / §5)
# ------------------------------------------------------------------
VOLUME_MIN_PCT: int = 0
VOLUME_MAX_PCT: int = 100
ACT_SET_SYSTEM_VOLUME: str = "SET_SYSTEM_VOLUME"
ACT_SET_SYSTEM_MUTE: str = "SET_SYSTEM_MUTE"
ERR_NO_ENDPOINT: str = "E_NO_ENDPOINT"
ERR_COREAUDIO: str = "E_COREAUDIO"
ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"
REFRESH_INTERVAL_S: float = 2.0


class AudioEndpointError(Exception):
    """Domain error carrying a frozen wire error code (§3)."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail or code


def pct_to_scalar(pct: int) -> float:
    """0–100 int → CoreAudio 0.0–1.0 master scalar, clamped (§4.2)."""
    clamped = max(VOLUME_MIN_PCT, min(VOLUME_MAX_PCT, int(pct)))
    return clamped / 100.0


def scalar_to_pct(scalar: float) -> int:
    """CoreAudio scalar → 0–100 with round-half-up, clamped (§4.2)."""
    raw = math.floor(float(scalar) * 100 + 0.5)
    return max(VOLUME_MIN_PCT, min(VOLUME_MAX_PCT, int(raw)))


class AudioEndpointController:
    """Master endpoint volume/mute with a single COM worker and cached snapshot."""

    def __init__(self) -> None:
        """Own the single COM worker thread and the cached endpoint handle (§3)."""
        self._endpoint: Any | None = None
        self._cache_volume: int = VOLUME_MIN_PCT
        self._cache_muted: bool = False
        self._executor = ThreadPoolExecutor(max_workers=1, initializer=self._init_com)
        self._refresh_task: asyncio.Task[None] | None = None
        self._ensure_refresh()  # start the 2 s loop when constructed in a loop

    # ---------------------------------------------------------- COM worker

    @staticmethod
    def _init_com() -> None:
        """Worker-thread first use: MTA init; RPC_E_CHANGED_MODE tolerated (§7)."""
        try:
            comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        except Exception:
            log.debug("CoInitializeEx returned an error; continuing (tolerated)", exc_info=True)

    @staticmethod
    def _resolve() -> Any:
        """Lazy default-render-endpoint resolve (§4.1); raises when none exists."""
        device = AudioUtilities.GetSpeakers()
        interface = device.Activate(IAudioEndpointVolume._iid_, comtypes.CLSCTX_ALL, None)
        return comtypes.cast(interface, IAudioEndpointVolume)

    def _work(self, operation: Any) -> Any:
        """Run ``operation(endpoint)`` with cache/re-resolve/retry semantics (§4.1/§4.4)."""
        if self._endpoint is None:
            try:
                self._endpoint = self._resolve()
            except Exception as exc:
                raise AudioEndpointError(ERR_NO_ENDPOINT, f"no audio endpoint: {exc}") from exc
        try:
            return operation(self._endpoint)
        except Exception:
            log.debug("CoreAudio call failed; re-resolving endpoint", exc_info=True)
            try:
                self._endpoint = self._resolve()
            except Exception as exc:
                raise AudioEndpointError(ERR_NO_ENDPOINT, f"audio endpoint lost: {exc}") from exc
            try:
                return operation(self._endpoint)
            except Exception as retry_exc:
                detail = f"CoreAudio operation failed after re-resolve: {retry_exc}"
                raise AudioEndpointError(ERR_COREAUDIO, detail) from retry_exc

    async def _call(self, operation: Any) -> Any:
        """Submit an endpoint operation to the single worker and await its result."""
        future = self._executor.submit(self._work, operation)
        return await asyncio.wrap_future(future)

    # ------------------------------------------------------------- volume

    async def get_volume(self) -> int:
        """Fresh master endpoint volume, rounded 0-100 (§3)."""
        percent = await self._call(
            lambda endpoint: scalar_to_pct(endpoint.GetMasterVolumeLevelScalar())
        )
        self._cache_volume = percent
        return percent

    async def set_volume(self, value: int) -> int:
        """Clamp to 0-100, write master scalar, return the applied value (§3)."""
        percent = max(VOLUME_MIN_PCT, min(VOLUME_MAX_PCT, int(value)))
        scalar = pct_to_scalar(percent)
        await self._call(lambda endpoint: endpoint.SetMasterVolumeLevelScalar(scalar, None))
        self._cache_volume = percent
        return percent

    async def adjust_volume(self, delta: int) -> int:
        """Relative change on a fresh read, clamped; returns the applied value (§3)."""
        current = await self.get_volume()  # fresh read — no cache drift (§4.3)
        return await self.set_volume(current + int(delta))

    # -------------------------------------------------------------- mute

    async def get_mute(self) -> bool:
        """Fresh master mute state (§3)."""
        muted = await self._call(lambda endpoint: bool(endpoint.GetMute()))
        self._cache_muted = muted
        return muted

    async def set_mute(self, muted: bool) -> bool:
        """Set master mute explicitly, return the applied state (§3)."""
        state = bool(muted)
        await self._call(lambda endpoint: endpoint.SetMute(state, None))
        self._cache_muted = state
        return state

    async def toggle_mute(self) -> bool:
        """Invert current mute state, return the new state (§3; local callers only)."""
        current = await self.get_mute()
        return await self.set_mute(not current)

    # -------------------------------------------------- telemetry / refresh

    def snapshot(self) -> dict[str, Any]:
        """Flat Doc 18 dict: ``{'sys_volume': int, 'sys_muted': bool}`` — no COM (§4.5)."""
        return {"sys_volume": self._cache_volume, "sys_muted": self._cache_muted}

    async def refresh(self) -> bool:
        """Read-only reconciliation of external mixer changes; True when the cache changed."""
        volume, muted = await self._call(
            lambda endpoint: (
                scalar_to_pct(endpoint.GetMasterVolumeLevelScalar()),
                bool(endpoint.GetMute()),
            )
        )
        changed = volume != self._cache_volume or muted != self._cache_muted
        self._cache_volume, self._cache_muted = volume, muted
        return changed

    def _ensure_refresh(self) -> None:
        """Start the background refresh loop once a running loop is available."""
        if self._refresh_task is not None and not self._refresh_task.done():
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return  # constructed outside a loop — first async call starts it
        self._refresh_task = loop.create_task(self._refresh_loop())

    async def _refresh_loop(self) -> None:
        while True:
            await asyncio.sleep(REFRESH_INTERVAL_S)
            try:
                if await self.refresh():
                    log.debug("audio cache changed: %s", self.snapshot())
            except asyncio.CancelledError:
                raise
            except Exception:
                log.debug("audio refresh skipped", exc_info=True)  # agent stays up (§7)

    async def stop(self) -> None:
        """Shut the COM worker (and refresh loop) down cleanly (§3/§7)."""
        task, self._refresh_task = self._refresh_task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        await asyncio.to_thread(self._executor.shutdown, True)

    # ------------------------------------------------------ Doc 14 wire seam

    async def handle_set_system_volume(
        self, session: WsSession, envelope: WsEnvelope
    ) -> dict[str, Any]:
        """``SET_SYSTEM_VOLUME``: clamped write acked ``{"ok": true}`` or error payload (§5)."""
        del session
        raw = envelope.payload.get("percent")
        valid = (
            isinstance(raw, (int, float))
            and not isinstance(raw, bool)
            and (not isinstance(raw, float) or math.isfinite(raw))
        )
        if not valid:
            return {
                "ok": False,
                "error": ERR_BAD_PAYLOAD,
                "detail": "percent must be a finite number",
            }
        try:
            await self.set_volume(int(raw))  # floats coerce; out-of-range clamps (§7)
        except AudioEndpointError as exc:
            return {"ok": False, "error": exc.code, "detail": exc.detail}
        return {}  # build_ack supplies ok:true

    async def handle_set_system_mute(
        self, session: WsSession, envelope: WsEnvelope
    ) -> dict[str, Any]:
        """``SET_SYSTEM_MUTE``: explicit state acked ``{"ok": true}`` or error payload (§5)."""
        del session
        raw = envelope.payload.get("muted")
        if isinstance(raw, bool):
            state = raw
        elif isinstance(raw, (int, float)) and raw in (0, 1) and math.isfinite(raw):
            state = bool(raw)  # JSON 0/1 coerce safely (§7)
        else:
            return {"ok": False, "error": ERR_BAD_PAYLOAD, "detail": "muted must be a boolean"}
        try:
            await self.set_mute(state)
        except AudioEndpointError as exc:
            return {"ok": False, "error": exc.code, "detail": exc.detail}
        return {}
