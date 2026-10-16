"""Doc 10 unit tests: drift-free WM_USER telemetry poller (fully mocked Win32)."""

from __future__ import annotations

import asyncio
import json
import pathlib
import time

import pytest

from pc_agent.potplayer import telemetry_poller as poller_module
from pc_agent.potplayer.telemetry_poller import (
    BACKOFF_FAILURE_COUNT,
    BACKOFF_INTERVAL_MS,
    LAST_GOOD_MAX_AGE_S,
    QUERY_TIMEOUT_MS,
    TELEMETRY_INTERVAL_MS,
    QueryError,
    TelemetryPoller,
    TelemetrySnapshot,
    _advance_deadline,
    _normalize_speed,
)


class FakeLocator:
    def __init__(self, hwnd: int | None = 999) -> None:
        self.hwnd = hwnd

    def find(self, *, force: bool = False) -> int | None:
        return self.hwnd


@pytest.fixture
def send(monkeypatch):
    """Replace the blocking getter seam; tests assign `send.impl`."""
    state = {"impl": lambda hwnd, msg, wparam, lparam, timeout_ms: (1, 0), "calls": []}

    def fake_send(hwnd, msg, wparam, lparam, timeout_ms):
        state["calls"].append((hwnd, msg, wparam, lparam, timeout_ms))
        return state["impl"](hwnd, msg, wparam, lparam, timeout_ms)

    monkeypatch.setattr(poller_module, "_send_message_timeout", fake_send)
    return state


def replies(*values):
    """Build an impl answering consecutive getters with the given results."""
    queue = list(values)

    def impl(_hwnd, _msg, _wparam, _lparam, _timeout_ms):
        return (1, queue.pop(0)) if queue else (1, 0)

    return impl


def make_poller(locator=None, interval_ms=TELEMETRY_INTERVAL_MS, **kwargs) -> TelemetryPoller:
    return TelemetryPoller(locator or FakeLocator(), interval_ms=interval_ms, **kwargs)


# ------------------------------------------------------------------ normalization


def test_normalization_table(send):
    send["impl"] = replies(123_456, 789_000, 2, 42, 1450)
    snapshot = make_poller().poll_once()
    assert snapshot.position_ms == 123_456
    assert snapshot.duration_ms == 789_000
    assert snapshot.is_playing is True
    assert snapshot.volume == 42
    assert snapshot.speed == 1.5
    assert snapshot.healthy is True
    assert snapshot.hwnd == 999

    # Sentinels, out-of-range volume, paused state, unreported speed.
    send["impl"] = replies(0xFFFFFFFF, 0xFFFFFFFF, 1, 250, 0)
    snapshot = make_poller().poll_once()
    assert snapshot.position_ms == 0
    assert snapshot.duration_ms == 0
    assert snapshot.is_playing is False
    assert snapshot.volume == 100
    assert snapshot.speed == 1.0

    # Absurd speed clamps to the display range; volume floors/clamps to 0-100.
    send["impl"] = replies(1, 2, 2, 0, 9000)
    snapshot = make_poller().poll_once()
    assert snapshot.volume == 0
    assert snapshot.speed == 4.0


def test_speed_normalization_edge_cases():
    assert _normalize_speed(0) == 1.0
    assert _normalize_speed(1450) == 1.5  # half-up at the 0.05 boundary
    assert _normalize_speed(1449) == 1.4
    assert _normalize_speed(100) == 0.2  # clamped to display minimum
    assert _normalize_speed(2000) == 2.0


def test_query_budget_and_timeout(send):
    # 5 delivered queries x 40 ms mock stay within the 200 ms tick budget.
    def slow_ok(_hwnd, _msg, _wparam, _lparam, timeout_ms):
        assert timeout_ms == QUERY_TIMEOUT_MS
        time.sleep(QUERY_TIMEOUT_MS / 1000.0)
        return (1, 1)

    send["impl"] = slow_ok
    started = time.perf_counter()
    snapshot = make_poller().poll_once()
    elapsed = time.perf_counter() - started
    assert snapshot.healthy is True
    assert elapsed <= (5 * QUERY_TIMEOUT_MS) / 1000.0 + 0.02

    # An undelivered query is a QueryError; the tick aborts and reports unhealthy.
    calls = {"n": 0}

    def timeout_third(_hwnd, _msg, _wparam, _lparam, _timeout_ms):
        calls["n"] += 1
        return (0, 0) if calls["n"] == 3 else (1, 5)

    send["impl"] = timeout_third
    snapshot = make_poller().poll_once()
    assert snapshot.healthy is False
    assert calls["n"] == 3, "remaining getters must be skipped after a failure"

    send["impl"] = lambda *_a: (0, 0)
    poller = make_poller()
    with pytest.raises(QueryError):
        poller._query(999, poller._getters["GET_POSITION_MS"])


# ------------------------------------------------------------------ degraded modes


def test_missing_window_zero_snapshot(send):
    snapshot = make_poller(locator=FakeLocator(hwnd=None)).poll_once()
    assert snapshot.healthy is False
    assert snapshot.hwnd == 0
    assert (
        snapshot.position_ms,
        snapshot.duration_ms,
        snapshot.is_playing,
        snapshot.volume,
        snapshot.speed,
    ) == (0, 0, False, 0, 0.0)
    assert send["calls"] == [], "no queries must be attempted without a window"


def test_partial_failure_last_good_values(send):
    clock = {"now": 1000.0}
    poller = make_poller(now_fn=lambda: clock["now"])
    send["impl"] = replies(100, 200, 2, 50, 1000)
    good = poller.poll_once()
    assert good.healthy is True and good.position_ms == 100

    # 3rd getter fails: fields 1-2 from this tick, rest from last good, unhealthy.
    calls_before = len(send["calls"])
    attempts = {"n": 0}

    def flaky(_hwnd, _msg, _wparam, _lparam, _timeout_ms):
        attempts["n"] += 1
        if attempts["n"] == 3:
            return (0, 0)
        return (1, 111)

    send["impl"] = flaky
    degraded = poller.poll_once()
    assert degraded.healthy is False
    assert degraded.hwnd == 999
    assert degraded.position_ms == 111 and degraded.duration_ms == 111
    assert degraded.volume == 50 and degraded.speed == 1.0, "last-good fallback values"
    assert len(send["calls"]) - calls_before == 3, "remaining getters skipped"

    # After the last-good window ages out, the snapshot zeroes.
    clock["now"] += LAST_GOOD_MAX_AGE_S + 0.01
    send["impl"] = lambda *_a: (0, 0)
    aged = poller.poll_once()
    assert aged.healthy is False
    assert (aged.position_ms, aged.speed) == (0, 0.0)


def test_backoff_and_recovery(send):
    send["impl"] = lambda *_a: (0, 0)  # every query times out
    poller = make_poller()
    for _ in range(BACKOFF_FAILURE_COUNT):
        assert poller.poll_once().healthy is False
    assert poller._consecutive_failures == BACKOFF_FAILURE_COUNT
    assert poller._current_interval_s() == BACKOFF_INTERVAL_MS / 1000.0
    # First healthy tick restores the frozen 250 ms cadence.
    send["impl"] = replies(1, 2, 2, 3, 1000)
    assert poller.poll_once().healthy is True
    assert poller._consecutive_failures == 0
    assert poller._current_interval_s() == TELEMETRY_INTERVAL_MS / 1000.0


def test_getters_unavailable(tmp_path):
    empty = tmp_path / "codes.json"
    empty.write_text(json.dumps({"base": {"WM_USER": "0x400"}, "getters": {}}), encoding="utf-8")
    poller = TelemetryPoller(FakeLocator(), codes_path=empty)
    snapshot = poller.poll_once()
    assert snapshot.healthy is False
    assert (snapshot.position_ms, snapshot.speed) == (0, 0.0)


# ------------------------------------------------------------------ scheduling


def test_cadence_drift_free_math():
    interval = 0.25
    # On-time tick: next deadline steps by exactly one interval.
    assert _advance_deadline(0.0, 0.20, interval) == pytest.approx(0.25)
    # Small overrun: still anchored to the boundary (no drift accumulation).
    assert _advance_deadline(0.25, 0.30, interval) == pytest.approx(0.50)
    # Stall past one full interval: skip to now + interval (no burst catch-up).
    assert _advance_deadline(0.50, 1.30, interval) == pytest.approx(1.55)
    # Never schedules ticks back-to-back faster than one interval.
    assert _advance_deadline(0.50, 0.50, interval) == pytest.approx(0.75)


@pytest.mark.asyncio
async def test_async_cadence_and_stop(send):
    send["impl"] = replies(*([100, 200, 2, 50, 1000] * 40))
    poller = make_poller(interval_ms=40, now_fn=time.monotonic)
    seen: list[float] = []
    poller.subscribe(lambda snap: seen.append(snap.captured_at))
    poller.start()
    assert poller.running is True
    poller.start()  # idempotent: no second task
    await asyncio.sleep(0.35)
    started = time.perf_counter()
    await poller.stop()
    assert (time.perf_counter() - started) < 0.1, "stop() must return within 100 ms"
    assert poller.running is False
    assert poller.latest is not None

    # Drift-free: consecutive ticks never bunch up nor oversleep wildly.
    gaps = [b - a for a, b in zip(seen, seen[1:], strict=False)]
    assert gaps, "expected several ticks"
    assert all(gap >= 0.02 for gap in gaps), gaps
    assert all(gap <= 0.25 for gap in gaps), gaps


@pytest.mark.asyncio
async def test_task_survives_raising_listener(send):
    send["impl"] = replies(*([1, 2, 2, 3, 1000] * 10))
    poller = make_poller(interval_ms=20)

    def bad_listener(_snap):
        raise RuntimeError("boom")

    poller.subscribe(bad_listener)
    poller.start()
    await asyncio.sleep(0.1)
    await poller.stop()
    assert poller.latest is not None


@pytest.mark.asyncio
async def test_stop_cancellation_without_start(send):
    poller = make_poller()
    await poller.stop()  # no-op, never started
    assert poller.running is False


def test_start_without_running_loop_raises():
    poller = make_poller()
    with pytest.raises(RuntimeError):
        poller.start()


# ------------------------------------------------------------------ listeners


def test_subscribe_unsubscribe_and_listener_exception(send):
    send["impl"] = replies(*([10, 20, 2, 30, 1000] * 5))
    poller = make_poller()
    order: list[str] = []

    def first(_snap):
        order.append("first")
        raise RuntimeError("listener bug")

    def second(_snap):
        order.append("second")

    unsubscribe_first = poller.subscribe(first)
    poller.subscribe(second)
    snapshot = poller.poll_once()
    assert order == ["first", "second"], "a raising listener must not stop the others"
    assert poller.latest is snapshot

    unsubscribe_first()
    order.clear()
    poller.poll_once()
    assert order == ["second"], "unsubscribed listeners stop receiving snapshots"


def test_latest_none_before_first_tick():
    poller = make_poller()
    assert poller.latest is None
    assert poller.running is False


def test_snapshot_is_immutable():
    snapshot = TelemetrySnapshot(0, 0, False, 0, 1.0, False, 0, 0.0)
    with pytest.raises(AttributeError):
        snapshot.position_ms = 5  # type: ignore[misc]


def test_interval_must_be_positive():
    with pytest.raises(ValueError):
        TelemetryPoller(FakeLocator(), interval_ms=0)


def test_module_source_has_no_hardcoded_ids():
    """Doc 10 A1: no hard-coded Win32/PotPlayer message IDs — the table is the source."""
    source_path = pathlib.Path(poller_module.__file__)
    if source_path.suffix == "c":
        source_path = source_path.with_suffix("")
    text = source_path.read_text(encoding="utf-8")
    assert "0x0400" not in text, "WM_USER must be resolved from the shared JSON table"
    assert "0x0111" not in text, "WM_COMMAND must be resolved from the shared JSON table"
