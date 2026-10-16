"""Doc 22: sleep timer & power manager (single-task timer → Windows power action).

Owns the frozen ``CMD_SYSTEM`` wire surface dispatched by Doc 14:
``START_SLEEP_TIMER {mode, target, minutes?, progress_pct?}`` arms (or replaces)
the one shared timer and acks ``{"ok": true}``; ``CANCEL_SLEEP_TIMER {}`` cancels
(and aborts a shutdown still inside its 30 s grace window) and acks
``{"ok": true}``.  Validation failures return ``{"ok": false, "error":
"E_BAD_PAYLOAD", "detail"}`` with **no state change**.  There is no read action —
state reaches the phone through Doc 18's flat telemetry keys produced by
:meth:`SleepTimerManager.snapshot` (exactly ``sleep_timer_active`` /
``sleep_timer_mode`` / ``sleep_timer_remaining_s``).

Engine (§4): one ``asyncio.Task`` per armed timer with IDLE → ARMED →
TRIGGERING → FIRED/ERROR phases (observable via the :attr:`SleepTimerManager.phase`
seam).  COUNTDOWN deadlines use monotonic ``loop.time()`` so NTP jumps cannot
fire early; MOVIE_PROGRESS polls the injected Doc 10 ``progress_provider`` every
``PROGRESS_TICK_S`` and fires on the first sample at/over the threshold.
Power dispatch goes through the injectable :class:`PowerActionRunner` seam —
``powrprof.dll SetSuspendState`` for SLEEP/HIBERNATE (hibernate falls back to
``shutdown.exe /h`` when the call fails) and ``shutdown.exe /s /t 30 /c
"PotPilot sleep timer"`` for SHUTDOWN so a late cancel can still ``/a`` abort.
"""

from __future__ import annotations

import asyncio
import ctypes
import logging
import math
import subprocess
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from pc_agent.network.ws_server_router import WsEnvelope, WsSession

log = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Frozen constants (Doc 22 §3 / §5)
# ------------------------------------------------------------------
MODE_COUNTDOWN: str = "COUNTDOWN"
MODE_MOVIE_PROGRESS: str = "MOVIE_PROGRESS"
POWER_SLEEP: str = "SLEEP"
POWER_HIBERNATE: str = "HIBERNATE"
POWER_SHUTDOWN: str = "SHUTDOWN"
ACT_START_SLEEP_TIMER: str = "START_SLEEP_TIMER"
ACT_CANCEL_SLEEP_TIMER: str = "CANCEL_SLEEP_TIMER"
PROGRESS_TICK_S: float = 1.0
COUNTDOWN_TICK_S: float = 1.0
DEFAULT_PROGRESS_THRESHOLD_PCT: int = 99
MINUTES_MIN: int = 1
MINUTES_MAX: int = 720
SHUTDOWN_GRACE_S: int = 30
WIN_POWRPROF_DLL: str = "powrprof.dll"
WIN_SHUTDOWN_EXE: str = "shutdown.exe"
ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"

SHUTDOWN_MESSAGE: str = "PotPilot sleep timer"
SHUTDOWN_TIMEOUT_S: int = 10

# §4.6 state machine phases (internal; telemetry derives from TimerState).
PHASE_IDLE: str = "IDLE"
PHASE_ARMED: str = "ARMED"
PHASE_TRIGGERING: str = "TRIGGERING"
PHASE_FIRED: str = "FIRED"
PHASE_ERROR: str = "ERROR"

ProgressSample = tuple[int, int, bool]  # (position_ms, duration_ms, is_playing)
ProgressProvider = Callable[[], Awaitable[ProgressSample]]


@dataclass(frozen=True, slots=True)
class TimerState:
    """One snapshot of the shared timer (§3); derived from the phase machine."""

    active: bool  # armed or triggering
    mode: str | None  # "COUNTDOWN" | "MOVIE_PROGRESS" | None when idle
    power_action: str | None  # "SLEEP" | "HIBERNATE" | "SHUTDOWN" | None
    remaining_s: int | None  # seconds until fire; None when idle/progress
    threshold_pct: int | None  # progress mode only


class PowerActionRunner:
    """Windows power seam (injectable for tests): powrprof.dll + shutdown.exe (§4.4)."""

    async def sleep(self) -> None:
        """Suspend to RAM: ``SetSuspendState(FALSE, FALSE, FALSE)``."""
        await self._set_suspend_state(hibernate=False)

    async def hibernate(self) -> None:
        """Suspend to disk: ``SetSuspendState(TRUE, FALSE, FALSE)``."""
        await self._set_suspend_state(hibernate=True)

    async def _set_suspend_state(self, *, hibernate: bool) -> None:
        def call() -> bool:
            dll = getattr(ctypes.windll, WIN_POWRPROF_DLL)
            return bool(dll.SetSuspendState(hibernate, False, False))

        if not await asyncio.to_thread(call):
            state = "TRUE" if hibernate else "FALSE"
            raise RuntimeError(f"SetSuspendState({state}, FALSE, FALSE) failed")

    async def shutdown(self, grace_s: int) -> None:
        """Schedule ``shutdown.exe /s /t <grace_s> /c "PotPilot sleep timer"`` (§4.4)."""
        argv = [WIN_SHUTDOWN_EXE, "/s", "/t", str(grace_s), "/c", SHUTDOWN_MESSAGE]
        await self._run_shutdown(argv)

    async def abort_shutdown(self) -> None:
        """Best-effort ``shutdown.exe /a`` — exit code and errors ignored (§7)."""
        try:
            await asyncio.to_thread(self._run, [WIN_SHUTDOWN_EXE, "/a"])
        except Exception:
            log.warning("shutdown.exe /a failed; system may still shut down", exc_info=True)

    async def _run_shutdown(self, argv: list[str]) -> None:
        def call() -> Any:
            return self._run(argv)

        result = await asyncio.to_thread(call)
        if result.returncode != 0:
            joined = " ".join(argv)
            raise RuntimeError(f"{WIN_SHUTDOWN_EXE} exited with {result.returncode}: {joined}")

    @staticmethod
    def _run(argv: list[str]) -> Any:
        return subprocess.run(argv, timeout=SHUTDOWN_TIMEOUT_S, capture_output=True)


class SleepTimerManager:
    """Single-timer engine: arm/cancel/state/snapshot plus the Doc 14 wire seam."""

    def __init__(
        self,
        progress_provider: ProgressProvider,
        runner: PowerActionRunner | None = None,
    ) -> None:
        """Own the single timer task and the power action runner (§3)."""
        self._progress_provider = progress_provider
        self._runner = runner if runner is not None else PowerActionRunner()
        self._phase: str = PHASE_IDLE
        self._mode: str | None = None
        self._power_action: str | None = None
        self._threshold_pct: int | None = None
        self._end_at: float | None = None
        self._countdown_s: int | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._task: asyncio.Task[None] | None = None
        self._shutdown_pending = False  # SHUTDOWN accepted; inside /t 30 grace
        self._last_error: str | None = None

    # ---------------------------------------------------------- observations

    @property
    def phase(self) -> str:
        """Current state-machine phase: IDLE/ARMED/TRIGGERING/FIRED/ERROR (§4.6)."""
        return self._phase

    @property
    def last_error(self) -> str | None:
        """Detail of the most recent failed power action (None unless ERROR)."""
        return self._last_error

    def _remaining_s(self) -> int | None:
        if self._mode != MODE_COUNTDOWN or self._end_at is None or self._loop is None:
            return None
        raw = math.ceil(self._end_at - self._loop.time())
        return max(0, min(self._countdown_s, raw)) if self._countdown_s else max(0, raw)

    def state(self) -> TimerState:
        """Synchronous current state (§3); FIRED/ERROR/IDLE read back as idle."""
        if self._phase not in (PHASE_ARMED, PHASE_TRIGGERING):
            return TimerState(False, None, None, None, None)
        remaining = self._remaining_s()
        threshold = self._threshold_pct if self._mode == MODE_MOVIE_PROGRESS else None
        return TimerState(True, self._mode, self._power_action, remaining, threshold)

    def snapshot(self) -> dict[str, Any]:
        """Flat dict for Doc 18: exactly the 3 ``sleep_timer_*`` keys (§5)."""
        current = self.state()
        return {
            "sleep_timer_active": current.active,
            "sleep_timer_mode": current.mode,
            "sleep_timer_remaining_s": current.remaining_s,
        }

    # ------------------------------------------------------------- arming

    @staticmethod
    def _validate(
        mode: str,
        power_action: str,
        minutes: int | None,
        threshold_pct: int | None,
    ) -> tuple[str, int | None, int | None]:
        """Resolve wire fields to ``(mode, threshold_pct, minutes)``; bad → ValueError (§5)."""
        if mode == MODE_COUNTDOWN:
            if power_action not in (POWER_SLEEP, POWER_HIBERNATE, POWER_SHUTDOWN):
                raise ValueError(f"unknown target: {power_action!r}")
            valid = (
                isinstance(minutes, int)
                and not isinstance(minutes, bool)
                and MINUTES_MIN <= minutes <= MINUTES_MAX
            )
            if not valid:
                raise ValueError(f"minutes must be an int in {MINUTES_MIN}-{MINUTES_MAX}")
            return mode, None, minutes
        if mode == MODE_MOVIE_PROGRESS:
            if power_action not in (POWER_SLEEP, POWER_HIBERNATE, POWER_SHUTDOWN):
                raise ValueError(f"unknown target: {power_action!r}")
            if minutes is not None:
                raise ValueError("MOVIE_PROGRESS does not accept minutes")
            threshold = DEFAULT_PROGRESS_THRESHOLD_PCT if threshold_pct is None else threshold_pct
            valid = (
                isinstance(threshold, int)
                and not isinstance(threshold, bool)
                and 1 <= threshold <= 100
            )
            if not valid:
                raise ValueError("progress_pct must be an int in 1-100")
            return mode, threshold, None
        raise ValueError(f"unknown mode: {mode!r}")

    async def arm(
        self,
        mode: str,
        power_action: str,
        *,
        minutes: int | None = None,
        threshold_pct: int | None = None,
    ) -> TimerState:
        """Validate and (re)arm a timer; replaces any existing one atomically (§3)."""
        resolved_mode, resolved_threshold, resolved_minutes = self._validate(
            mode, power_action, minutes, threshold_pct
        )
        await self._stop_task()
        if self._shutdown_pending:  # replaced timer must not still fire (§4.1)
            self._shutdown_pending = False
            try:
                await self._runner.abort_shutdown()
            except Exception:
                log.warning("aborting replaced shutdown failed", exc_info=True)
        loop = asyncio.get_running_loop()
        self._loop = loop
        self._mode = resolved_mode
        self._power_action = power_action
        self._threshold_pct = resolved_threshold
        self._last_error = None
        if resolved_mode == MODE_COUNTDOWN and resolved_minutes is not None:
            self._countdown_s = resolved_minutes * 60
            self._end_at = loop.time() + self._countdown_s
        else:
            self._countdown_s = None
            self._end_at = None
        self._phase = PHASE_ARMED
        self._task = asyncio.create_task(self._run_timer())
        log.info("sleep timer armed: mode=%s target=%s", resolved_mode, power_action)
        return self.state()

    async def cancel(self) -> TimerState:
        """Cancel the active timer (and abort a pending shutdown.exe if in grace) (§3)."""
        await self._stop_task()
        pending = self._shutdown_pending
        self._shutdown_pending = False
        if pending:
            try:
                await self._runner.abort_shutdown()
            except Exception:
                log.warning("shutdown abort failed", exc_info=True)
        self._phase = PHASE_IDLE  # ERROR → IDLE too (§4.6 diagram)
        self._mode = None
        self._power_action = None
        self._threshold_pct = None
        self._end_at = None
        self._countdown_s = None
        self._last_error = None
        return self.state()

    async def _stop_task(self) -> None:
        task, self._task = self._task, None
        if task is None or task.done():
            return
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)

    # ------------------------------------------------------------ tick loop

    async def _run_timer(self) -> None:
        try:
            if self._mode == MODE_COUNTDOWN:
                await self._tick_countdown()
            else:
                await self._tick_progress()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self._phase = PHASE_ERROR
            self._last_error = str(exc) or type(exc).__name__
            log.warning("sleep timer task failed: %s", self._last_error)

    async def _tick_countdown(self) -> None:
        while True:
            await asyncio.sleep(COUNTDOWN_TICK_S)
            if self._remaining_s() == 0:  # monotonic deadline reached (§4.2)
                await self._fire()
                return

    async def _tick_progress(self) -> None:
        while True:
            await asyncio.sleep(PROGRESS_TICK_S)
            try:
                position_ms, duration_ms, _is_playing = await self._progress_provider()
            except Exception:
                log.warning("progress provider failed; timer stays armed", exc_info=True)
                continue
            if duration_ms <= 0:
                continue  # no movie / unknown duration — never divide by zero (§7)
            if position_ms / duration_ms * 100 >= self._threshold_pct:
                await self._fire()
                return

    # -------------------------------------------------------- power dispatch

    async def _fire(self) -> None:
        self._phase = PHASE_TRIGGERING
        try:
            if self._power_action == POWER_SLEEP:
                await self._runner.sleep()
            elif self._power_action == POWER_HIBERNATE:
                await self._hibernate_with_fallback()
            else:  # POWER_SHUTDOWN — keep the 30 s grace window abortable (§4.4)
                await self._runner.shutdown(SHUTDOWN_GRACE_S)
                self._shutdown_pending = True
        except Exception as exc:
            self._phase = PHASE_ERROR
            self._last_error = str(exc) or type(exc).__name__
            log.warning(
                "sleep timer power action %s failed: %s",
                self._power_action,
                self._last_error,
            )
            return
        self._phase = PHASE_FIRED
        log.info("sleep timer fired: target=%s", self._power_action)

    async def _hibernate_with_fallback(self) -> None:
        try:
            await self._runner.hibernate()
        except Exception:
            log.warning("hibernate failed; falling back to shutdown.exe /h", exc_info=True)
            await self._hibernate_fallback()

    async def _hibernate_fallback(self) -> None:
        """§4.4/§7: hibernation disabled → ``shutdown.exe /h``; failure → ERROR."""

        def call() -> Any:
            return subprocess.run(
                [WIN_SHUTDOWN_EXE, "/h"], timeout=SHUTDOWN_TIMEOUT_S, capture_output=True
            )

        result = await asyncio.to_thread(call)
        if result.returncode != 0:
            raise RuntimeError(f"{WIN_SHUTDOWN_EXE} /h exited with {result.returncode}")

    # ------------------------------------------------------ Doc 14 wire seam

    async def handle_start_sleep_timer(
        self, session: WsSession, envelope: WsEnvelope
    ) -> dict[str, Any]:
        """``START_SLEEP_TIMER``: ``{"ok": true}`` or the E_BAD_PAYLOAD error payload (§5)."""
        del session
        payload = envelope.payload
        try:
            await self.arm(
                payload.get("mode"),
                payload.get("target"),
                minutes=payload.get("minutes"),
                threshold_pct=payload.get("progress_pct"),
            )
        except ValueError as exc:
            return {"ok": False, "error": ERR_BAD_PAYLOAD, "detail": str(exc)}
        return {}  # build_ack supplies ok:true

    async def handle_cancel_sleep_timer(
        self, session: WsSession, envelope: WsEnvelope
    ) -> dict[str, Any]:
        """``CANCEL_SLEEP_TIMER``: ``{"ok": true}`` (no-op when already idle) (§5)."""
        del session, envelope
        await self.cancel()
        return {}
