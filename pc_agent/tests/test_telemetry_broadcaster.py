"""Unit tests for the Doc 18 telemetry broadcast loop."""

from __future__ import annotations

import asyncio
import json
import re
import time
from types import SimpleNamespace
from typing import Any

from pc_agent.network.telemetry_broadcaster import (
    TYPE_TELEMETRY,
    TelemetryBroadcaster,
    snapshot_to_payload,
    title_from_window,
)

UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
BASE_KEYS = {
    "position_ms",
    "duration_ms",
    "is_playing",
    "speed",
    "volume",
    "file_title",
    "potplayer_found",
}


class FakePoller:
    """Doc 10 seam: exposes a mutable ``latest`` snapshot object."""

    def __init__(self, **overrides: Any) -> None:
        self.latest = SimpleNamespace(
            position_ms=1000,
            duration_ms=100_000,
            is_playing=True,
            speed=1.0,
            volume=50,
            file_title="sample",
            hwnd=42,
            **overrides,
        )


class FakeWs:
    """Fake ``websockets`` connection recording parsed telemetry frames."""

    def __init__(self, *, broken: bool = False) -> None:
        self.frames: list[dict[str, Any]] = []
        self.broken = broken

    async def send(self, text: str) -> None:
        if self.broken:
            raise ConnectionResetError("simulated dead peer")
        self.frames.append(json.loads(text))


async def wait_until(predicate: Any, max_wait: float = 2.0) -> None:
    deadline = time.monotonic() + max_wait
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.005)


def test_diff_sends_only_changed_keys() -> None:
    async def scenario() -> list[dict[str, Any]]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: ws.frames)  # connect push done
        await asyncio.sleep(0.02)  # let tick 1 establish last_sent
        poller.latest.position_ms = 250_123  # exactly one key changes
        await wait_until(
            lambda: any(
                f["action"] == "STATE_DELTA" and f["payload"] == {"position_ms": 250_123}
                for f in ws.frames
            )
        )
        await broadcaster.stop()
        return ws.frames

    frames = asyncio.run(scenario())
    delta = next(
        f
        for f in frames
        if f["action"] == "STATE_DELTA" and f["payload"] == {"position_ms": 250_123}
    )
    assert delta["payload"] == {"position_ms": 250_123}  # single changed key only


def test_unchanged_tick_sends_nothing() -> None:
    async def scenario() -> list[dict[str, Any]]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: ws.frames)  # connect push done
        await asyncio.sleep(0.02)  # let tick 1 establish last_sent
        initial = len(ws.frames)
        await asyncio.sleep(0.15)  # ~9 frozen ticks, below the tick-20 refresh
        captured = ws.frames[initial:]  # capture before stop()'s final flush
        await broadcaster.stop()
        return captured

    assert asyncio.run(scenario()) == []  # zero frames over frozen ticks


def test_full_refresh_every_20_ticks() -> None:
    async def scenario() -> list[dict[str, Any]]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: ws.frames)  # connect push done
        await asyncio.sleep(0.05)  # let tick 1 establish last_sent
        initial = len(ws.frames)
        await asyncio.sleep(0.55)  # frozen state; >= 20 ticks even at 15.6 ms timers
        captured = ws.frames[initial:]  # capture before stop()'s final flush
        await broadcaster.stop()
        return captured

    frames = asyncio.run(scenario())
    assert not [f for f in frames if f["action"] == "STATE_DELTA"]  # frozen state
    refreshes = [f for f in frames if f["action"] == "FULL_STATE"]
    assert refreshes  # tick-20 FULL_STATE still emitted with no changes
    assert set(refreshes[0]["payload"]) == BASE_KEYS


def test_new_client_gets_full_state_immediately() -> None:
    async def scenario() -> tuple[dict[str, Any], list[dict[str, Any]]]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=50)
        await broadcaster.start()
        broadcaster.register_source("brightness", lambda: {"brightness": 80})
        first = FakeWs()
        broadcaster.register_client(first)
        await asyncio.sleep(0.01)
        late = FakeWs()
        broadcaster.register_client(late)
        await wait_until(lambda: late.frames)
        await broadcaster.stop()
        return late.frames

    late_frames = asyncio.run(scenario())
    snapshot_frame = late_frames[0]
    assert snapshot_frame["action"] == "FULL_STATE"
    assert snapshot_frame["type"] == TYPE_TELEMETRY
    # Every available key present (base 7 + registered source) before the next tick.
    assert set(snapshot_frame["payload"]) == BASE_KEYS | {"brightness"}


def test_envelope_shape_matches_ws_schema() -> None:
    async def scenario() -> dict[str, Any]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await asyncio.sleep(0.02)
        await broadcaster.stop()
        return ws.frames[0]

    frame = asyncio.run(scenario())
    assert UUID4_RE.fullmatch(frame["id"])
    assert frame["type"] == "TELEMETRY_SYNC"
    assert frame["action"] in {"STATE_DELTA", "FULL_STATE"}
    assert isinstance(frame["timestamp"], int)
    assert abs(frame["timestamp"] - int(time.time())) < 5
    assert isinstance(frame["payload"], dict)


def test_provider_exception_keeps_last_good_values() -> None:
    async def scenario() -> tuple[dict[str, Any], bool]:
        poller = FakePoller()
        state = {"brightness": 80}

        def flaky() -> dict[str, Any]:
            if state.get("boom"):
                raise RuntimeError("DDC bus hiccup")
            return dict(state)

        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        broadcaster.register_source("brightness", flaky)
        ws = FakeWs()
        broadcaster.register_client(ws)
        await asyncio.sleep(0.06)  # at least one tick runs before the provider breaks
        state["boom"] = True
        await asyncio.sleep(0.05)  # several ticks with the provider raising
        alive = broadcaster.client_count == 1  # loop survived, client retained
        merged = broadcaster.snapshot()
        await broadcaster.stop()
        return merged, alive

    merged, alive = asyncio.run(scenario())
    assert alive  # loop survived the raising provider
    assert merged["brightness"] == 80  # last-good value retained
    assert merged["position_ms"] == 1000  # other sources unaffected


def test_missing_provider_keys_omitted() -> None:
    async def scenario() -> dict[str, Any]:
        broadcaster = TelemetryBroadcaster(FakePoller(), interval_ms=50)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: ws.frames)
        await broadcaster.stop()
        return ws.frames[0]["payload"]

    payload = asyncio.run(scenario())
    assert set(payload) == BASE_KEYS  # Session-1 registry: 7 keys, no system keys
    assert "blackout_active" not in payload
    assert "brightness" not in payload
    assert "sys_volume" not in payload
    assert "sleep_timer_active" not in payload


def test_unregister_source_omits_keys() -> None:
    async def scenario() -> tuple[dict[str, Any], dict[str, Any]]:
        broadcaster = TelemetryBroadcaster(FakePoller(), interval_ms=10)
        await broadcaster.start()
        broadcaster.register_source("audio", lambda: {"sys_volume": 40, "sys_muted": False})
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: broadcaster.snapshot())  # first tick has run
        before = broadcaster.snapshot()
        broadcaster.unregister_source("audio")
        await asyncio.sleep(0.05)  # several ticks re-collect without the source
        after = broadcaster.snapshot()
        await broadcaster.stop()
        return before, after

    before, after = asyncio.run(scenario())
    assert "sys_volume" in before
    assert "sys_volume" not in after  # keys omitted from subsequent frames
    assert "sys_muted" not in after


def test_unregister_on_send_failure() -> None:
    async def scenario() -> tuple[int, bool]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=10)
        await broadcaster.start()
        healthy = FakeWs()
        dead = FakeWs()
        broadcaster.register_client(healthy)
        broadcaster.register_client(dead)
        await wait_until(lambda: healthy.frames and dead.frames)
        dead.broken = True  # peer dies after the connect snapshot
        poller.latest.position_ms = 777  # force a delta fan-out
        await wait_until(lambda: broadcaster.client_count == 1)
        await asyncio.sleep(0.03)  # loop still alive afterwards
        still_ticking = not broadcaster._task.done()
        delivered = len(healthy.frames)
        await broadcaster.stop()
        return delivered, still_ticking

    delivered, still_ticking = asyncio.run(scenario())
    assert delivered >= 2  # healthy client kept receiving after the failure
    assert still_ticking  # dead client unregistered; loop survived


def test_cadence_250ms() -> None:
    async def scenario() -> list[float]:
        poller = FakePoller()
        broadcaster = TelemetryBroadcaster(poller, interval_ms=250)
        await broadcaster.start()
        sent_at: list[float] = []
        loop = asyncio.get_running_loop()

        class StampWs:
            async def send(self, text: str) -> None:
                sent_at.append(loop.time())

        broadcaster.register_client(StampWs())
        await wait_until(lambda: len(sent_at) >= 1, max_wait=2.0)  # connect snapshot
        for target in range(2, 6):  # mutate right after each frame -> every tick sends
            poller.latest.position_ms += 1
            await wait_until(lambda t=target: len(sent_at) >= t, max_wait=2.0)
        recorded = list(sent_at)  # exclude stop()'s final flush from the gaps
        await broadcaster.stop()
        return [b - a for a, b in zip(recorded[2:], recorded[3:], strict=False)]

    gaps = asyncio.run(scenario())
    assert gaps
    assert abs(sum(gaps) / len(gaps) - 0.250) < 0.025  # mean within ±10 %
    assert all(0.20 < gap < 0.35 for gap in gaps)  # no gross stalls


def test_build_frame_and_stop_flush() -> None:
    async def scenario() -> list[dict[str, Any]]:
        broadcaster = TelemetryBroadcaster(FakePoller(), interval_ms=10)
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await asyncio.sleep(0.02)
        await broadcaster.stop()  # final FULL_STATE flush, then clears clients
        return ws.frames

    frames = asyncio.run(scenario())
    assert frames[-1]["action"] == "FULL_STATE"
    assert set(frames[-1]["payload"]) == BASE_KEYS


def test_snapshot_to_payload_shapes() -> None:
    assert set(snapshot_to_payload(None)) == BASE_KEYS
    snap = snapshot_to_payload(
        SimpleNamespace(
            position_ms=5, duration_ms=9, is_playing=False, speed=2.0, volume=1, hwnd=7
        ),
        title_reader=lambda _hwnd: "",  # deterministic idle title (no live Win32 read)
    )
    assert snap["potplayer_found"] is True  # derived from hwnd when not explicit
    assert snap["file_title"] is None  # idle window → no media title
    as_dict = snapshot_to_payload({"position_ms": 3, "potplayer_found": True})
    assert as_dict["position_ms"] == 3
    assert as_dict["potplayer_found"] is True
    assert as_dict["duration_ms"] == 0


def test_file_title_derived_from_live_window_title() -> None:
    """Doc 33's confirmation key is populated from the media-carrying PotPlayer
    window title (the poller snapshot itself carries no title source)."""
    snapshot = SimpleNamespace(
        position_ms=1,
        duration_ms=100,
        is_playing=True,
        speed=1.0,
        volume=50,
        hwnd=42,
        healthy=True,
    )
    calls: list[int] = []

    def reader(hwnd: int) -> str:
        calls.append(hwnd)
        return "Inception (2010).mkv - PotPlayer"

    payload = snapshot_to_payload(snapshot, title_reader=reader)
    assert payload["file_title"] == "Inception (2010)"  # scanner-style stem
    assert calls == [42]  # exactly one cheap GetWindowText per payload build

    # Degraded (a slow WM getter) still reads the live title: one flaky getter
    # must not blank playback detection for the tick (2026-10-17).
    degraded = SimpleNamespace(**{**vars(snapshot), "healthy": False})
    assert snapshot_to_payload(degraded, title_reader=reader)["file_title"] == (
        "Inception (2010)"
    )
    assert calls == [42, 42]

    # Explicit snapshot value (a title-carrying poller) always wins.
    explicit = SimpleNamespace(**{**vars(snapshot), "file_title": "explicit"})
    assert snapshot_to_payload(explicit, title_reader=reader)["file_title"] == "explicit"

    # potplayer_found:false / no hwnd → nothing to read.
    missing = SimpleNamespace(**{**vars(snapshot), "hwnd": 0, "potplayer_found": False})
    assert snapshot_to_payload(missing, title_reader=reader)["file_title"] is None
    assert calls == [42, 42]


def test_title_from_window_parsing() -> None:
    assert title_from_window("Inception (2010).mkv - PotPlayer") == "Inception (2010)"
    assert title_from_window("Movie.2010.1080p.mkv - PotPlayer64") == "Movie.2010.1080p"
    assert title_from_window("D:\\Movies\\Film.webm - PotPlayer") == "Film"
    assert title_from_window("Movie.2010 - PotPlayer") == "Movie.2010"  # no known ext → keep
    # Context-prefixed window titles keep their prefix (the client anchors the
    # stem): "folder, Film.mkv - PotPlayer" → "folder, Film".
    assert title_from_window("Some Folder, Film.mp4 - PotPlayer") == "Some Folder, Film"
    assert title_from_window("PotPlayer") is None  # bare empty instance
    assert title_from_window("potplayer64") is None
    assert title_from_window(" - PotPlayer") is None
    assert title_from_window("") is None
    assert title_from_window("   ") is None


def test_broadcaster_broadcasts_derived_file_title() -> None:
    async def scenario() -> list[dict[str, Any]]:
        poller = FakePoller()
        poller.latest.file_title = None  # poller has no title source of its own
        broadcaster = TelemetryBroadcaster(
            poller, interval_ms=10, title_reader=lambda _hwnd: "New Film.mkv - PotPlayer"
        )
        await broadcaster.start()
        ws = FakeWs()
        broadcaster.register_client(ws)
        await wait_until(lambda: ws.frames)
        state = await broadcaster._collect_state()  # noqa: SLF001 - direct seam check
        await broadcaster.stop()
        return [state]

    state = asyncio.run(scenario())[0]
    assert state["file_title"] == "New Film"  # end-to-end: snapshot → reader → wire key


def test_frame_ids_are_fresh_uuid4() -> None:
    broadcaster = TelemetryBroadcaster(FakePoller(), interval_ms=250)
    first = json.loads(broadcaster.build_frame({"a": 1}, action="STATE_DELTA"))
    second = json.loads(broadcaster.build_frame({"a": 1}, action="STATE_DELTA"))
    assert UUID4_RE.fullmatch(first["id"])
    assert first["id"] != second["id"]  # fresh uuid4 per frame
