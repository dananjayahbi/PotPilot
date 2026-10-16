"""Doc 09 SEEK_DELTA rapid-tap coalescing.

The poller snapshot advances on a 250 ms cadence and the position getter itself
moves in ~500 ms chunks, so back-to-back SEEK_DELTA taps (human bursts arrive
well under 250 ms apart) would each re-read the same stale base and land on
nearly the same target — the user's "it starts again where we started tapping".
This tracker keeps a short-lived truth for "where we just seeked to" so each
new delta chains from the previous target instead of the stale snapshot.

Scope: used ONLY by the router's SEEK_DELTA arithmetic; absolute SEEK leaves
the base untouched (scrub taps stay snapshot-driven).
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable

COALESCE_WINDOW_S = 0.8
"""Chaining horizon: taps further apart than this trust the fresh snapshot again."""


class SeekBaseTracker:
    """Thread-safe short-lived seek target memory (monotonic clock)."""

    def __init__(
        self,
        *,
        window_s: float = COALESCE_WINDOW_S,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._window_s = float(window_s)
        self._clock = clock
        self._lock = threading.Lock()
        self._target_ms: int | None = None
        self._recorded_at: float = 0.0

    def next_base(self, observed_ms: int) -> int:
        """Base for the next delta: our recent target when still fresh, else the
        observed snapshot position."""
        with self._lock:
            if (
                self._target_ms is not None
                and (self._clock() - self._recorded_at) <= self._window_s
            ):
                return self._target_ms
            return int(observed_ms)

    def record(self, target_ms: int) -> None:
        """Remember a delta-driven seek target (call only after dispatch ok)."""
        with self._lock:
            self._target_ms = int(target_ms)
            self._recorded_at = self._clock()
