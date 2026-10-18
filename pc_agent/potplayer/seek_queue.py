"""PC-side seek request queue (round 7, Doc 09).

Rapid forward/backward bursts used to compute every relative SEEK from a
lagging telemetry snapshot (250 ms poll + ~500 ms position chunks), so chained
targets regressed against the moving video and the player "wandered" in short
strides. This queue fixes that class of bug on the PC side:

* **Chained pending base** — while a burst is open, deltas chain from the last
  *pending* target, never from the stale snapshot (tracker-backed).
* **Burst coalescing** — the first delta of a burst dispatches immediately
  (leading edge, zero added latency); further deltas inside
  ``BURST_COALESCE_MS`` accumulate and a trailing timer dispatches ONE final
  seek instead of N interleaved ones. Signals cannot mix.
* **Absolute requests** (ruler scrub / UDP scrub) flush pending deltas first,
  dispatch immediately, and rebase the chain — order is always preserved.
* **External moves** (frame stepping) invalidate the chain so the next delta
  trusts fresh telemetry instead of snapping over the stepped frames.

Everything is constructor-injected (``dispatch``/``observed``/``schedule``/
``clock``) so unit tests run deterministically without asyncio or a player.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from typing import Protocol

from pc_agent.potplayer.seek_base import SeekBaseTracker
from pc_agent.potplayer.wm_dispatcher import DispatchResult

BURST_COALESCE_MS = 150
"""Quiet time before a burst's accumulated deltas are dispatched.

Must exceed the phone's per-action debounce (80 ms) plus round-trip time so a
sustained press burst actually coalesces, yet stay below a human's deliberate
tap spacing (~250 ms) so single taps keep dispatching on the leading edge.
"""

DispatchFn = Callable[[int], "DispatchResult"]
ObservedFn = Callable[[], int]
ClockFn = Callable[[], float]


class _CancelHandle(Protocol):
    def cancel(self) -> None: ...


ScheduleFn = Callable[[float, Callable[[], None]], _CancelHandle]


class SeekQueue:
    """Serialized, coalescing seek queue (the router-side successor of the
    bare :class:`SeekBaseTracker` chain)."""

    def __init__(
        self,
        dispatch: DispatchFn,
        *,
        observed: ObservedFn,
        schedule: ScheduleFn | None = None,
        clock: ClockFn = time.monotonic,
        coalesce_ms: float = BURST_COALESCE_MS,
    ) -> None:
        self._dispatch = dispatch
        self._observed = observed
        self._schedule = schedule
        self._clock = clock
        self._coalesce_s = float(coalesce_ms) / 1000.0
        self._lock = threading.Lock()
        self._tracker = SeekBaseTracker(clock=clock)
        self._pending_ms: int | None = None
        self._timer: _CancelHandle | None = None
        self._last_delta_at: float | None = None

    # -- public API ---------------------------------------------------------

    def delta(self, delta_ms: int) -> DispatchResult:
        """Relative seek. Chains from the pending target while a burst is open;
        dispatches immediately on the burst's leading edge, coalesces the rest."""
        with self._lock:
            base = (
                self._pending_ms
                if self._pending_ms is not None
                else self._tracker.next_base(self._observed())
            )
            target = max(0, int(base) + int(delta_ms))
            now = self._clock()
            burst_open = (
                self._pending_ms is not None
                or (
                    self._last_delta_at is not None
                    and (now - self._last_delta_at) < self._coalesce_s
                )
            )
            if not burst_open:
                result = self._dispatch_locked(target)
                if result.ok:
                    self._tracker.record(target)
                    self._last_delta_at = now
                return result
            self._pending_ms = target
            synced = self._arm_trailing_locked()
            if synced is not None:
                # No scheduler (or loop gone): delivered synchronously — report
                # the real dispatch outcome instead of a synthetic "coalesced".
                return synced
            return DispatchResult(True, "SEEK", None, "coalesced")

    def absolute(self, position_ms: int) -> DispatchResult:
        """Absolute seek (ruler scrub / UDP scrub): flush pending deltas first
        (request order preserved), dispatch immediately, rebase the chain."""
        with self._lock:
            self._flush_locked()
            target = max(0, int(position_ms))
            immediate = self._dispatch_locked(target)
            if immediate.ok:
                self._tracker.record(target)
                self._last_delta_at = None
            return immediate

    def note_external_move(self) -> None:
        """Video moved outside this queue (frame step): flush queued deltas,
        then invalidate the chain so the next delta trusts fresh telemetry."""
        with self._lock:
            self._flush_locked()
            self._tracker.invalidate()
            self._last_delta_at = None

    def flush(self) -> DispatchResult | None:
        """Dispatch accumulated burst deltas now (shutdown / test seam)."""
        with self._lock:
            return self._flush_locked()

    # -- internals ----------------------------------------------------------

    def _arm_trailing_locked(self) -> DispatchResult | None:
        """Arm the trailing coalescing timer. Returns a result only when the
        burst was delivered synchronously (no scheduler / loop unavailable)."""
        if self._schedule is None:
            # No scheduler injected: deliver synchronously so a request can
            # never be held indefinitely (never lose a signal).
            return self._flush_locked()
        if self._timer is not None:
            self._timer.cancel()
        try:
            self._timer = self._schedule(self._coalesce_s, self._on_trailing)
        except RuntimeError:
            # No event loop available (loop closed between dispatches): fall
            # back to synchronous delivery so a request is never lost.
            self._timer = None
            return self._flush_locked()
        return None

    def _on_trailing(self) -> None:
        with self._lock:
            self._timer = None
            self._flush_locked()

    def _flush_locked(self) -> DispatchResult | None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        if self._pending_ms is None:
            return None
        target = self._pending_ms
        self._pending_ms = None
        result = self._dispatch_locked(target)
        if result.ok:
            self._tracker.record(target)
            self._last_delta_at = self._clock()
        return result

    def _dispatch_locked(self, target_ms: int) -> DispatchResult:
        try:
            return self._dispatch(int(target_ms))
        except Exception as exc:  # dispatcher should not raise, but never hang a queue
            return DispatchResult(False, "SEEK", None, f"queue_dispatch_error:{exc}")
