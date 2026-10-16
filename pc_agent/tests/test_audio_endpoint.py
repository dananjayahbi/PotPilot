"""Doc 23 unit tests: Windows audio endpoint control (pycaw/comtypes fully mocked)."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from pc_agent.display_power import audio_endpoint as ae
from pc_agent.display_power.audio_endpoint import (
    ACT_SET_SYSTEM_MUTE,
    ACT_SET_SYSTEM_VOLUME,
    ERR_COREAUDIO,
    ERR_NO_ENDPOINT,
    AudioEndpointController,
    AudioEndpointError,
    pct_to_scalar,
    scalar_to_pct,
)
from pc_agent.network.ws_server_router import WsRouter, WsSession, parse_envelope


class FakeEndpoint:
    """pycaw IAudioEndpointVolume stand-in: scalar + mute state, zero hardware."""

    def __init__(self, scalar: float = 0.5, muted: bool = False, delay_s: float = 0.0) -> None:
        self.scalar = scalar
        self.muted = muted
        self.delay_s = delay_s
        self.fail_once = False
        self.fail_always = False
        self.writes: list[float] = []
        self.mute_writes: list[bool] = []
        self.trace: list[str] = []

    def _enter(self, tag: str) -> None:
        self.trace.append(f"start:{tag}")
        if self.delay_s:
            time.sleep(self.delay_s)

    def _exit(self, tag: str) -> None:
        self.trace.append(f"end:{tag}")

    def GetMasterVolumeLevelScalar(self) -> float:
        self._enter("get_volume")
        if self.fail_once:
            self.fail_once = False
            self._exit("get_volume")
            raise RuntimeError("device gone (RPC_E_DISCONNECTED)")
        if self.fail_always:
            self._exit("get_volume")
            raise RuntimeError("device gone (RPC_E_DISCONNECTED)")
        self._exit("get_volume")
        return self.scalar

    def SetMasterVolumeLevelScalar(self, value: float, event: Any = None) -> None:
        del event
        self._enter("set_volume")
        self.scalar = float(value)
        self.writes.append(float(value))
        self._exit("set_volume")

    def GetMute(self) -> bool:
        self._enter("get_mute")
        self._exit("get_mute")
        return bool(self.muted)

    def SetMute(self, state: Any, event: Any = None) -> None:
        del event
        self._enter("set_mute")
        self.muted = bool(state)
        self.mute_writes.append(bool(state))
        self._exit("set_mute")


class FakeSocket:
    """Minimal ``websockets`` connection stand-in for the router-level tests."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


@pytest.fixture(autouse=True)
def audio(monkeypatch: Any) -> SimpleNamespace:
    """Mock pycaw + comtypes at the module seam — no test can touch real audio (§9)."""
    endpoint = FakeEndpoint()
    env = SimpleNamespace(endpoint=endpoint, resolves=0, resolve_error=None)

    def get_speakers() -> Any:
        env.resolves += 1
        if env.resolve_error is not None:
            raise env.resolve_error
        return SimpleNamespace(Activate=lambda *_args: env.endpoint)

    fake_comtypes = SimpleNamespace(
        CoInitializeEx=lambda *_args, **_kwargs: None,
        COINIT_MULTITHREADED=2,
        CLSCTX_ALL=7,
        cast=lambda interface, _interface_class: interface,
    )
    monkeypatch.setattr(ae, "AudioUtilities", SimpleNamespace(GetSpeakers=get_speakers))
    monkeypatch.setattr(ae, "comtypes", fake_comtypes)
    return env


def _envelope(action: str, payload: dict[str, Any]) -> Any:
    return parse_envelope(
        json.dumps(
            {
                "id": str(uuid.uuid4()),
                "type": "CMD_SYSTEM",
                "action": action,
                "payload": payload,
                "timestamp": int(time.time()),
            }
        )
    )


def _router(controller: AudioEndpointController) -> WsRouter:
    router = WsRouter()
    router.register("CMD_SYSTEM", ACT_SET_SYSTEM_VOLUME, controller.handle_set_system_volume)
    router.register("CMD_SYSTEM", ACT_SET_SYSTEM_MUTE, controller.handle_set_system_mute)
    return router


def test_percentage_to_scalar_mapping() -> None:
    assert ACT_SET_SYSTEM_VOLUME == "SET_SYSTEM_VOLUME"  # frozen Doc 03 §5.5 tokens
    assert ACT_SET_SYSTEM_MUTE == "SET_SYSTEM_MUTE"
    assert pct_to_scalar(0) == 0.0
    assert pct_to_scalar(50) == 0.5
    assert pct_to_scalar(99) == 0.99
    assert pct_to_scalar(100) == 1.0
    assert scalar_to_pct(0.0) == 0
    assert scalar_to_pct(0.5) == 50
    assert scalar_to_pct(0.99) == 99  # round-half-up, no ±1 drift (§4.2)
    assert scalar_to_pct(1.0) == 100
    # Acceptance: pct → scalar → pct preserves every 0-100 input.
    assert [scalar_to_pct(pct_to_scalar(pct)) for pct in range(101)] == list(range(101))


def test_set_volume_clamps(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[int, int, int, dict[str, Any]]:
        controller = AudioEndpointController()
        router = _router(controller)
        session = WsSession(FakeSocket())
        below = await controller.set_volume(-5)
        above = await controller.set_volume(137)
        normal = await controller.set_volume(40)
        reply = await router.dispatch(
            session,
            _envelope(ACT_SET_SYSTEM_VOLUME, {"percent": 137}),
        )
        await controller.stop()
        return below, above, normal, reply["payload"]

    below, above, normal, payload = asyncio.run(scenario())
    assert (below, above, normal) == (0, 100, 40)  # clamped bounds, plain pass-through
    assert audio.endpoint.writes == [0.0, 1.0, 0.4, 1.0]
    assert payload == {"ok": True}  # out-of-range ints clamp, never error (§7)


def test_adjust_volume_relative_bounds(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[int, int, int]:
        controller = AudioEndpointController()
        audio.endpoint.scalar = 0.90
        upper = await controller.adjust_volume(20)  # 90 + 20 → clamp 100
        audio.endpoint.scalar = 0.10
        lower = await controller.adjust_volume(-30)  # 10 - 30 → clamp 0
        audio.endpoint.scalar = 0.30  # external change the cache never saw
        fresh = await controller.adjust_volume(5)  # fresh read 30 + 5 (§4.3)
        await controller.stop()
        return upper, lower, fresh

    upper, lower, fresh = asyncio.run(scenario())
    assert (upper, lower, fresh) == (100, 0, 35)


def test_set_mute_idempotent_and_toggle_flips(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[bool, bool, bool, bool, dict[str, Any]]:
        controller = AudioEndpointController()
        router = _router(controller)
        session = WsSession(FakeSocket())
        first = await controller.set_mute(True)
        again = await controller.set_mute(True)  # idempotent explicit set
        flipped_off = await controller.toggle_mute()
        flipped_on = await controller.toggle_mute()
        reply = await router.dispatch(
            session,
            _envelope(ACT_SET_SYSTEM_MUTE, {"muted": True}),
        )
        await controller.stop()
        return first, again, flipped_off, flipped_on, reply["payload"]

    first, again, off, on, payload = asyncio.run(scenario())
    assert first is True and again is True
    assert off is False and on is True
    assert audio.endpoint.mute_writes == [True, True, False, True, True]
    # four helper writes (set, set, toggle-off, toggle-on) + the wire dispatch's set
    assert payload == {"ok": True}  # wire exposes only SET_SYSTEM_MUTE (§5)


def test_snapshot_keys_sys_volume_sys_muted(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[list[dict[str, Any]], int]:
        controller = AudioEndpointController()
        snapshots = [controller.snapshot()]
        await controller.set_volume(40)
        snapshots.extend(controller.snapshot() for _ in range(3))
        resolves_after_use = audio.resolves
        await controller.stop()
        return snapshots, resolves_after_use

    snapshots, resolves = asyncio.run(scenario())
    assert resolves >= 1  # the write did resolve an endpoint...
    for snapshot in snapshots:
        assert set(snapshot) == {"sys_volume", "sys_muted"}
        assert isinstance(snapshot["sys_volume"], int)
        assert isinstance(snapshot["sys_muted"], bool)
    assert snapshots[0] == {"sys_volume": 0, "sys_muted": False}  # cache before any COM
    assert snapshots[-1] == {"sys_volume": 40, "sys_muted": False}
    # snapshot() itself never resolves or calls COM (§4.5) — the resolve count is
    # stable across the three post-write reads taken after set_volume completed.
    assert audio.resolves == resolves


def test_endpoint_reresolve_after_error(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[int, int, str | None]:
        controller = AudioEndpointController()
        audio.endpoint.fail_once = True  # first op: device-gone → re-resolve + retry
        value = await controller.get_volume()
        resolves_after_retry = audio.resolves
        audio.endpoint.fail_always = True  # re-resolve works, retry still fails
        code = None
        try:
            await controller.get_volume()
        except AudioEndpointError as exc:
            code = exc.code
        await controller.stop()
        return value, resolves_after_retry, code

    value, resolves, code = asyncio.run(scenario())
    assert value == 50  # retry succeeded transparently (§4.1)
    assert resolves == 2  # initial resolve + one re-resolve
    assert code == ERR_COREAUDIO  # failing op after one retry maps here (§4.4)


def test_no_endpoint_maps_to_error_code(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[str, dict[str, Any]]:
        audio.resolve_error = RuntimeError("no render devices installed")
        controller = AudioEndpointController()
        router = _router(controller)
        session = WsSession(FakeSocket())
        code = None
        try:
            await controller.get_volume()
        except AudioEndpointError as exc:
            code = exc.code  # never a raw COMError (§4.4)
        reply = await router.dispatch(
            session,
            _envelope(ACT_SET_SYSTEM_VOLUME, {"percent": 40}),
        )
        await controller.stop()
        assert code is not None
        return code, reply["payload"]

    code, payload = asyncio.run(scenario())
    assert code == ERR_NO_ENDPOINT
    assert payload["ok"] is False
    assert payload["error"] == ERR_NO_ENDPOINT  # agent/WS router stay up (§8)
    assert isinstance(payload["detail"], str) and payload["detail"]


def test_worker_serializes_calls(audio: SimpleNamespace) -> None:
    audio.endpoint.delay_s = 0.01  # widen the window so overlap would be visible

    async def scenario() -> tuple[list[str], float]:
        controller = AudioEndpointController()
        await asyncio.gather(
            controller.set_volume(10),
            controller.set_volume(20),
            controller.get_volume(),
        )
        trace = list(audio.endpoint.trace)
        await controller.stop()
        return trace, audio.endpoint.scalar

    trace, scalar = asyncio.run(scenario())
    in_call = False
    for event in trace:
        if event.startswith("start:"):
            assert not in_call, f"overlapping COM call observed: {event}"
            in_call = True
        else:
            assert in_call, f"end without start: {event}"
            in_call = False
    assert trace == [
        "start:set_volume",
        "end:set_volume",
        "start:set_volume",
        "end:set_volume",
        "start:get_volume",
        "end:get_volume",
    ]  # single worker serializes; last write wins (§7)
    assert scalar == 0.2


def test_refresh_updates_cache_only_on_change(audio: SimpleNamespace) -> None:
    async def scenario() -> tuple[bool, bool, dict[str, Any], dict[str, Any], dict[str, Any]]:
        controller = AudioEndpointController()
        await controller.set_volume(40)
        audio.endpoint.scalar = 0.70  # user drags the taskbar slider (external)
        picked_up = await controller.refresh()
        after_change = controller.snapshot()
        unchanged = await controller.refresh()
        before = controller.snapshot()
        await controller.refresh()
        after = controller.snapshot()
        await controller.stop()
        return picked_up, unchanged, after_change, before, after

    picked_up, unchanged, after_change, before, after = asyncio.run(scenario())
    assert picked_up is True
    assert after_change["sys_volume"] == 70  # external change reconciled (§4.5)
    assert unchanged is False
    assert before == after == {"sys_volume": 70, "sys_muted": False}
    # unchanged reads produce no diff for Doc 18 to emit (§9)
