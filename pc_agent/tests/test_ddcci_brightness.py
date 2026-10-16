"""Doc 19 unit tests: DDC/CI brightness controller (monitorcontrol fully mocked, no hardware)."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from pc_agent.display_power import ddcci_brightness as ddcci
from pc_agent.display_power.ddcci_brightness import (
    ACT_SET_BRIGHTNESS,
    BRIGHTNESS_MAX,
    BRIGHTNESS_MIN,
    DdcciBrightnessController,
    DdcciError,
)
from pc_agent.network.telemetry_broadcaster import TelemetryBroadcaster
from pc_agent.network.ws_server_router import WsRouter, WsSession, parse_envelope


class FakeMonitor:
    """monitorcontrol Monitor stand-in: luminance probe + write, zero hardware."""

    def __init__(
        self,
        luminance: int = 75,
        *,
        probe_exc: Exception | None = None,
        writes: list[int] | None = None,
    ) -> None:
        self.luminance = luminance
        self.probe_exc = probe_exc
        self.writes: list[int] = writes if writes is not None else []

    def get_luminance(self) -> int:
        if self.probe_exc is not None:
            raise self.probe_exc
        return self.luminance

    def set_luminance(self, value: int) -> None:
        self.writes.append(value)
        self.luminance = value


class FakeSocket:
    """Minimal ``websockets`` connection stand-in for the router-level test."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


class FakeWs:
    """Telemetry client stand-in recording parsed broadcast frames."""

    def __init__(self) -> None:
        self.frames: list[dict[str, Any]] = []

    async def send(self, text: str) -> None:
        self.frames.append(json.loads(text))


@pytest.fixture
def ddc(monkeypatch) -> SimpleNamespace:
    """Fake ``monitorcontrol.get_monitors`` source of FakeMonitor instances."""
    env = SimpleNamespace(monitors=[])

    def get_monitors() -> list[FakeMonitor]:
        return list(env.monitors)

    monkeypatch.setattr(ddcci.monitorcontrol, "get_monitors", get_monitors)
    return env


async def wait_until(predicate: Any, max_wait: float = 2.0) -> None:
    deadline = time.monotonic() + max_wait
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.005)


def test_set_brightness_clamps_to_bounds(ddc: SimpleNamespace) -> None:
    monitor = FakeMonitor()
    ddc.monitors = [monitor]

    async def scenario() -> tuple[int, int, int]:
        controller = DdcciBrightnessController()
        below = await controller.set_brightness(0, -10)
        above = await controller.set_brightness(0, 150)
        normal = await controller.set_brightness(0, 40)
        await controller.stop()
        return below, above, normal

    below, above, normal = asyncio.run(scenario())
    assert (below, above, normal) == (BRIGHTNESS_MIN, BRIGHTNESS_MAX, 40)
    assert monitor.writes[-1] == 40  # stop() flushed the final coalesced target


def test_unsupported_monitor_maps_to_error_code(ddc: SimpleNamespace) -> None:
    monitor = FakeMonitor(probe_exc=RuntimeError("firmware blocks DDC/CI"))
    ddc.monitors = [monitor]

    async def scenario() -> tuple[str, dict[str, Any]]:
        controller = DdcciBrightnessController()
        with pytest.raises(DdcciError) as excinfo:
            await controller.set_brightness(0, 50)
        snapshot = controller.snapshot()
        await controller.stop()
        return excinfo.value.code, snapshot

    code, snapshot = asyncio.run(scenario())
    assert code == "E_DDCI_UNSUPPORTED"
    assert snapshot == {"brightness": None}  # unsupported -> telemetry null


def test_unknown_monitor_index_error(ddc: SimpleNamespace) -> None:
    ddc.monitors = [FakeMonitor()]

    async def scenario() -> tuple[str, str]:
        controller = DdcciBrightnessController()
        with pytest.raises(DdcciError) as set_exc:
            await controller.set_brightness(1, 50)
        with pytest.raises(DdcciError) as get_exc:
            await controller.get_brightness(1)
        await controller.stop()
        return set_exc.value.code, get_exc.value.code

    set_code, get_code = asyncio.run(scenario())
    assert set_code == "E_MONITOR_NOT_FOUND"
    assert get_code == "E_MONITOR_NOT_FOUND"


def test_write_coalescing_keeps_latest_value(ddc: SimpleNamespace) -> None:
    writes: list[int] = []
    monitor = FakeMonitor(luminance=10, writes=writes)
    ddc.monitors = [monitor]

    async def scenario() -> int:
        controller = DdcciBrightnessController()  # default 100 ms coalescing
        await controller.list_monitors()
        for value in range(10):  # a 10-command burst (slider spam)
            await controller.set_brightness(0, value)
        await asyncio.sleep(0.05)  # writer flushes the coalesced target
        final = await controller.get_brightness(0)
        await controller.stop()
        return final

    final = asyncio.run(scenario())
    assert len(writes) <= 2  # latest wins; intermediates legitimately skipped
    assert writes[-1] == 9  # ends at the final requested value
    assert final == 9


def test_snapshot_null_until_probed(ddc: SimpleNamespace) -> None:
    ddc.monitors = [FakeMonitor(luminance=75)]

    async def scenario() -> dict[str, Any]:
        controller = DdcciBrightnessController()
        # Doc 18 seam: brightness provider registered on the broadcaster.
        broadcaster = TelemetryBroadcaster(SimpleNamespace(latest=None), interval_ms=10)
        broadcaster.register_source("brightness", controller.snapshot)
        before = dict(controller.snapshot())
        ws = FakeWs()
        broadcaster.register_client(ws)
        await broadcaster.start()
        await wait_until(lambda: ws.frames)
        null_frames = [f for f in ws.frames if "brightness" in f.get("payload", {})]
        assert null_frames, "FULL_STATE push must carry brightness before any probe"
        assert null_frames[0]["payload"]["brightness"] is None

        await controller.list_monitors()  # hardware probe -> 75
        assert controller.snapshot() == {"brightness": 75}
        await wait_until(
            lambda: any(
                f.get("action") == "STATE_DELTA" and f["payload"].get("brightness") == 75
                for f in ws.frames
            )
        )
        await broadcaster.stop()
        await controller.stop()
        return before

    before = asyncio.run(scenario())
    assert before == {"brightness": None}  # null until probed, int after


def test_get_during_pending_returns_target(ddc: SimpleNamespace) -> None:
    writes: list[int] = []
    ddc.monitors = [FakeMonitor(luminance=40, writes=writes)]

    async def scenario() -> tuple[int, list[int]]:
        # 60 s spacing keeps the second write pending for the whole test.
        controller = DdcciBrightnessController(write_min_interval_ms=60_000)
        await controller.list_monitors()
        await controller.set_brightness(0, 40)
        await asyncio.sleep(0.05)  # first physical write lands immediately
        assert writes == [40]
        await controller.set_brightness(0, 61)  # pending; writer must wait ≥60 s
        await asyncio.sleep(0.02)  # writer enters its coalesce wait
        during = await controller.get_brightness(0)
        await controller.stop()  # stop() flushes the last target at once
        return during, list(writes)

    during, writes_after = asyncio.run(scenario())
    assert during == 61  # pending target, not the stale cache value (40)
    assert writes_after[-1] == 61  # flush-on-stop wrote the final target


def test_response_envelope_echoes_id_and_action(ddc: SimpleNamespace) -> None:
    ddc.monitors = [FakeMonitor()]
    assert ACT_SET_BRIGHTNESS == "SET_BRIGHTNESS"  # frozen Doc 03 §5.5 token
    assert ddcci.ERR_DDCI_UNSUPPORTED == "E_DDCI_UNSUPPORTED"
    assert ddcci.ERR_MONITOR_NOT_FOUND == "E_MONITOR_NOT_FOUND"
    assert ddcci.ERR_DDCI_IO == "E_DDCI_IO"
    assert ddcci.ERR_BAD_PAYLOAD == "E_BAD_PAYLOAD"

    async def scenario() -> tuple[dict[str, Any], dict[str, Any]]:
        controller = DdcciBrightnessController()
        router = WsRouter()

        async def handler(session: WsSession, envelope: Any) -> dict[str, Any]:
            # The Doc 14 wiring shape for CMD_SYSTEM/SET_BRIGHTNESS (Doc 19 §5):
            # success -> payload {"ok": true}; DdcciError -> ok:false payload,
            # never an exception reaching the WS router.
            del session
            try:
                await controller.set_brightness(0, envelope.payload["percent"])
            except DdcciError as exc:
                return {"ok": False, "error": exc.code, "detail": str(exc)}
            return {}

        router.register("CMD_SYSTEM", ACT_SET_BRIGHTNESS, handler)
        request = {
            "id": str(uuid.uuid4()),
            "type": "CMD_SYSTEM",
            "action": ACT_SET_BRIGHTNESS,
            "payload": {"percent": 40},
            "timestamp": int(time.time()),
        }
        envelope = parse_envelope(json.dumps(request))
        session = WsSession(FakeSocket())
        reply = await router.dispatch(session, envelope)
        await controller.stop()
        return request, reply

    request, reply = asyncio.run(scenario())
    assert reply["id"] == request["id"]  # id echoed
    assert reply["type"] == "CMD_SYSTEM"
    assert reply["action"] == "SET_BRIGHTNESS_RESULT"  # action echoed + _RESULT
    assert reply["payload"] == {"ok": True}
    assert isinstance(reply["timestamp"], int)
