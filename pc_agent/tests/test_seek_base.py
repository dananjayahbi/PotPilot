"""Unit tests: rapid-tap SEEK_DELTA base coalescing (Doc 09 router arithmetic)."""

from __future__ import annotations

from pc_agent.potplayer.seek_base import COALESCE_WINDOW_S, SeekBaseTracker


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_fresh_record_wins_over_stale_snapshot():
    clock = FakeClock()
    tracker = SeekBaseTracker(clock=clock)
    assert tracker.next_base(1_000) == 1_000  # no record yet -> snapshot base
    tracker.record(6_000)
    # Snapshot still says 1_000 (stale poller): chaining uses our target.
    assert tracker.next_base(1_000) == 6_000


def test_window_expiry_falls_back_to_snapshot():
    clock = FakeClock()
    tracker = SeekBaseTracker(window_s=0.8, clock=clock)
    tracker.record(6_000)
    clock.now += 0.79
    assert tracker.next_base(5_800) == 6_000  # still inside the window
    clock.now += 0.81
    assert tracker.next_base(5_900) == 5_900  # expired -> trust the snapshot


def test_burst_chains_every_step():
    clock = FakeClock()
    tracker = SeekBaseTracker(clock=clock)
    base = tracker.next_base(10_000)
    for expected in (15_000, 20_000, 25_000):
        target = max(0, base + 5_000)
        assert target == expected
        tracker.record(target)
        clock.now += 0.1  # taps 100 ms apart, snapshot never moves
        base = tracker.next_base(10_000)
    assert base == 25_000


def test_backward_burst_chains_down():
    clock = FakeClock()
    tracker = SeekBaseTracker(clock=clock)
    tracker.record(10_000)
    base = tracker.next_base(10_000)
    target = max(0, base - 4_000)
    assert target == 6_000
    tracker.record(target)
    assert tracker.next_base(10_000) == 6_000


def test_record_never_negative_target_guard_is_router_side():
    # The tracker stores what it is told; clamping belongs to the router.
    tracker = SeekBaseTracker()
    tracker.record(-5)
    assert tracker.next_base(0) == -5


def test_default_window_is_sub_second():
    assert COALESCE_WINDOW_S == 0.8
