"""Unit tests: PC-side seek request queue (round 7 burst coalescing).

Deterministic: fake monotonic clock + fake scheduler, no asyncio, no player.
Contract under test (Doc 09 / user round-7 fix "rapid forward/backward goes
here and there"):

* leading edge dispatches immediately (zero added latency for a single tap),
* trailing coalescing collapses a burst into ONE final seek,
* chained base comes from the *pending* target — never the stale snapshot
  mid-chain,
* absolute seeks flush pending deltas first (request order preserved), then
  dispatch immediately and rebase the chain,
* external moves (frame step) invalidate the chain,
* failed dispatches are not recorded as chain truth,
* targets clamp at zero.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from pc_agent.potplayer.seek_queue import BURST_COALESCE_MS, SeekQueue
from pc_agent.potplayer.wm_dispatcher import DispatchResult

_COALESCE_S = BURST_COALESCE_MS / 1000.0


@dataclass
class FakeClock:
    """Monotonic clock the tests drive by hand."""

    now: float = 0.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@dataclass
class _Timer:
    fire_at: float
    callback: Callable[[], None]
    cancelled: bool = False

    def cancel(self) -> None:
        self.cancelled = True


class FakeScheduler:
    """Asyncio-loop stand-in: records timers, fires due ones on demand."""

    def __init__(self, clock: FakeClock) -> None:
        self.clock = clock
        self.timers: list[_Timer] = []

    def schedule(self, delay_s: float, callback: Callable[[], None]) -> _Timer:
        timer = _Timer(self.clock.now + delay_s, callback)
        self.timers.append(timer)
        return timer

    @property
    def armed(self) -> int:
        return sum(1 for t in self.timers if not t.cancelled)

    def run_due(self) -> int:
        fired = 0
        for timer in list(self.timers):
            if not timer.cancelled and timer.fire_at <= self.clock.now + 1e-9:
                timer.cancelled = True
                timer.callback()
                fired += 1
        self.timers = [t for t in self.timers if not t.cancelled]
        return fired


class FakeDispatcher:
    """Dispatch recorder; optionally fails with a dispatcher-style detail."""

    def __init__(self, fail_detail: str | None = None) -> None:
        self.calls: list[int] = []
        self.fail_detail = fail_detail

    def __call__(self, target_ms: int) -> DispatchResult:
        self.calls.append(int(target_ms))
        if self.fail_detail is not None:
            return DispatchResult(False, "SEEK", None, self.fail_detail)
        return DispatchResult(True, "SEEK", 0x1234, "posted")


def _make(
    *, observed: int = 1_000, fail_detail: str | None = None
) -> tuple[SeekQueue, FakeDispatcher, FakeClock, FakeScheduler]:
    clock = FakeClock()
    scheduler = FakeScheduler(clock)
    dispatcher = FakeDispatcher(fail_detail=fail_detail)
    observed_box = {"position_ms": observed}
    queue = SeekQueue(
        dispatcher,
        observed=lambda: observed_box["position_ms"],
        schedule=scheduler.schedule,
        clock=clock,
    )
    queue.observed_box = observed_box  # type: ignore[attr-defined]  # test handle
    return queue, dispatcher, clock, scheduler


# --- leading edge / trailing coalescing -------------------------------------


def test_single_delta_dispatches_immediately_on_leading_edge() -> None:
    queue, dispatcher, _clock, _scheduler = _make(observed=1_000)
    result = queue.delta(500)
    assert result.ok is True
    assert dispatcher.calls == [1_500]  # no waiting for a timer


def test_back_to_back_deltas_coalesce_into_one_trailing_dispatch() -> None:
    queue, dispatcher, clock, scheduler = _make(observed=1_000)
    queue.delta(500)  # leading edge → 1_500
    queue.delta(500)  # within window → held
    queue.delta(500)  # still within window → held
    assert dispatcher.calls == [1_500]  # nothing interleaved
    assert scheduler.armed == 1  # re-arm keeps a single live timer

    clock.advance(_COALESCE_S)
    assert scheduler.run_due() == 1
    # ONE final seek for the whole burst: 1_000 + 500×3, chained through the
    # pending target (2_500), never the stale snapshot.
    assert dispatcher.calls == [1_500, 2_500]


def test_burst_base_never_falls_back_to_stale_snapshot_mid_chain() -> None:
    queue, dispatcher, _clock, scheduler = _make(observed=1_000)
    queue.delta(500)  # leading → 1_500, chain recorded
    # Snapshot goes wild (external garbage / polling gap) mid-burst:
    queue.observed_box["position_ms"] = 999_999  # type: ignore[attr-defined]
    queue.delta(500)  # held; base must be pending/chain, not the snapshot
    queue.flush()
    assert dispatcher.calls == [1_500, 2_000]  # chain, NOT 999_999 + 500


def test_delta_after_quiet_window_dispatches_immediately() -> None:
    queue, dispatcher, clock, _scheduler = _make(observed=1_000)
    queue.delta(500)
    clock.advance(_COALESCE_S + 0.05)  # human re-taps after a pause
    queue.delta(500)
    assert dispatcher.calls == [1_500, 2_000]  # burst window expired → leading


def test_flush_with_nothing_pending_is_a_no_op() -> None:
    queue, dispatcher, _clock, _scheduler = _make(observed=1_000)
    assert queue.flush() is None
    assert dispatcher.calls == []


# --- absolute (ruler scrub / UDP scrub) -------------------------------------


def test_absolute_flushes_pending_then_dispatches_then_rebases() -> None:
    queue, dispatcher, clock, _scheduler = _make(observed=1_000)
    queue.delta(500)  # leading → 1_500
    queue.delta(500)  # held pending (2_000)
    result = queue.absolute(50_000)
    assert result.ok is True
    # Order preserved: queued delta first, absolute last (it is newest truth).
    assert dispatcher.calls == [1_500, 2_000, 50_000]

    # Chain rebased: next delta chains off the absolute target, not pre-scrub.
    clock.advance(_COALESCE_S + 0.05)
    queue.delta(100)
    assert dispatcher.calls[-1] == 50_100


def test_absolute_without_pending_dispatches_immediately() -> None:
    queue, dispatcher, _clock, _scheduler = _make(observed=1_000)
    queue.absolute(12_345)
    assert dispatcher.calls == [12_345]


# --- external move (frame step) ---------------------------------------------


def test_note_external_move_invalidates_chain_so_next_delta_uses_fresh_telemetry() -> None:
    queue, dispatcher, clock, _scheduler = _make(observed=1_000)
    queue.delta(500)  # chain → 1_500
    queue.note_external_move()  # frame step moved the video elsewhere
    queue.observed_box["position_ms"] = 7_000  # type: ignore[attr-defined]
    clock.advance(0.05)
    queue.delta(500)
    assert dispatcher.calls[-1] == 7_500  # fresh telemetry, not 1_500 + 500


def test_note_external_move_delivers_pending_deltas_first() -> None:
    queue, dispatcher, _clock, _scheduler = _make(observed=1_000)
    queue.delta(500)  # leading → 1_500
    queue.delta(500)  # held → 2_000
    queue.note_external_move()
    assert dispatcher.calls == [1_500, 2_000]  # never drops a request


# --- failure handling / clamping --------------------------------------------


def test_failed_dispatch_is_not_recorded_as_chain_truth() -> None:
    queue, dispatcher, clock, _scheduler = _make(observed=1_000, fail_detail="no_window")
    result = queue.delta(500)
    assert result.ok is False
    assert result.detail == "no_window"

    # Window expired is irrelevant: nothing was recorded, so the base stays
    # the observed snapshot instead of the failed target.
    clock.advance(_COALESCE_S + 0.05)
    dispatcher.fail_detail = None
    queue.delta(500)
    assert dispatcher.calls == [1_500, 1_500]


def test_targets_clamp_at_zero() -> None:
    queue, dispatcher, _clock, _scheduler = _make(observed=100)
    queue.delta(-500)
    queue.absolute(-1)
    assert dispatcher.calls == [0, 0]


# --- scheduler fallback ------------------------------------------------------


def test_missing_scheduler_delivers_synchronously_never_holds_a_request() -> None:
    clock = FakeClock()
    dispatcher = FakeDispatcher()
    queue = SeekQueue(dispatcher, observed=lambda: 1_000, schedule=None, clock=clock)
    queue.delta(500)  # leading → 1_500
    result = queue.delta(500)  # no scheduler → synchronous delivery
    assert result.ok is True
    assert dispatcher.calls == [1_500, 2_000]
