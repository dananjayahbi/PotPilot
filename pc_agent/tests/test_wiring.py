"""Session 3 Wave 3.A — ``main.py`` wiring assertions (Doc 04 §4.4, Docs 13–26).

No real sockets, Tk windows, pystray threads, COM, or DDC hardware are touched:
every side-effectful module is monkeypatched with a fake *before* ``run_agent``
runs, and the wiring region's ``from ... import ...`` picks the fake up at call
time.  The region only runs when ``PYTEST_CURRENT_TEST`` is absent, so the
fixture clears that marker for the duration of each run.
"""

from __future__ import annotations

import asyncio
import ctypes
import json
import re
import sys
import time
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

from pc_agent import main as agent_main
from pc_agent.core.auth_middleware import AuthMiddleware
from pc_agent.core.config_manager import ConfigManager
from pc_agent.display_power import (
    audio_endpoint,
    blackout_overlay,
    ddcci_brightness,
    monitor_snapper,
)
from pc_agent.gui import dashboard_window, tray_daemon
from pc_agent.input_engine import win32_keyboard, win32_mouse
from pc_agent.network import (
    mdns_broadcaster,
    telemetry_broadcaster,
    udp_server,
    ws_message_codec,
    ws_server_router,
)
from pc_agent.network.telemetry_broadcaster import (
    SOURCE_AUDIO,
    SOURCE_BLACKOUT,
    SOURCE_BRIGHTNESS,
    SOURCE_SLEEP,
)
from pc_agent.potplayer import telemetry_poller, wm_dispatcher

SERVICE_ORDER = (
    "udp_receiver",
    "ws_server",
    "mdns",
    "telemetry",
    "power_audio",
    "tray",
    "gui",
)

EXPECTED_EVENTS = [
    "udp.start",
    "ws.start",
    "mdns.start",
    "poller.start",
    "telemetry.start",
    "tray.start",
    "tray.stop",
    "brightness.stop",
    "audio.stop",
    "telemetry.stop",
    "poller.stop",
    "mdns.stop",
    "ws.stop",
    "udp.stop",
]


class _Dispatch:
    """Result stand-in for ``WmDispatcher`` outcomes."""

    def __init__(self, ok: bool = True, detail: str = "posted") -> None:
        self.ok = ok
        self.detail = detail


def _install_fakes(monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    """Swap every side-effectful service module for a recording fake."""
    record = SimpleNamespace(events=[])

    # --- Doc 13 UDP receiver -------------------------------------------------
    async def fake_start_udp(**kwargs: object) -> SimpleNamespace:
        record.events.append("udp.start")
        record.udp_kwargs = kwargs
        handle = SimpleNamespace(stopped=False)

        async def _stop() -> None:
            handle.stopped = True
            record.events.append("udp.stop")

        handle.stop = _stop
        record.udp_handle = handle
        return handle

    monkeypatch.setattr(udp_server, "start_udp_server", fake_start_udp)

    # --- Doc 14 WS server (router stays REAL so registrations are inspectable)
    class FakeWsServer:
        def __init__(self, **kwargs: object) -> None:
            record.ws_kwargs = kwargs
            record.ws = self
            self.client_count = 0

        async def start(self, *, host: str = "0.0.0.0", port: int = 0) -> None:
            record.events.append("ws.start")
            record.ws_port = port

        async def stop(self) -> None:
            record.events.append("ws.stop")

    monkeypatch.setattr(ws_server_router, "WsServer", FakeWsServer)

    # --- Doc 16 mDNS ---------------------------------------------------------
    class FakeMdns:
        def __init__(self, **kwargs: object) -> None:
            record.mdns_kwargs = kwargs

        async def start(self) -> None:
            record.events.append("mdns.start")

        async def stop(self) -> None:
            record.events.append("mdns.stop")

    monkeypatch.setattr(mdns_broadcaster, "MdnsBroadcaster", FakeMdns)

    # --- Doc 18 telemetry ----------------------------------------------------
    class FakeBroadcaster:
        def __init__(self, poller: object, **kwargs: object) -> None:
            record.broadcaster = self
            self.poller = poller
            self.sources: dict[str, object] = {}
            self.clients: list[object] = []

        def register_source(self, name: str, provider: object) -> None:
            self.sources[name] = provider

        def register_client(self, ws: object) -> None:
            self.clients.append(ws)

        def unregister_client(self, ws: object) -> None:
            self.clients.remove(ws)

        def snapshot(self) -> dict[str, object]:
            return {"sys_volume": 42}

        def build_frame(self, payload: dict[str, object], *, action: str) -> str:
            record.built_frame = {"payload": payload, "action": action}
            return json.dumps({"action": action, "payload": payload}, separators=(",", ":"))

        async def start(self) -> None:
            record.events.append("telemetry.start")

        async def stop(self) -> None:
            record.events.append("telemetry.stop")

    monkeypatch.setattr(telemetry_broadcaster, "TelemetryBroadcaster", FakeBroadcaster)

    # --- Doc 10 poller -------------------------------------------------------
    class FakePoller:
        def __init__(self, locator: object, *args: object, **kwargs: object) -> None:
            record.poller = self
            self.locator = locator
            self.latest = None
            self.started = False

        def start(self) -> None:
            self.started = True
            record.events.append("poller.start")

        async def stop(self) -> None:
            self.started = False
            record.events.append("poller.stop")

    monkeypatch.setattr(telemetry_poller, "TelemetryPoller", FakePoller)

    # --- Doc 09 dispatcher ---------------------------------------------------
    class FakeDispatcher:
        def __init__(
            self,
            locator: object,
            codes_path: object = None,
            speed_provider: object = None,
        ) -> None:
            record.dispatcher = self
            self.locator = locator
            self.speed_provider = speed_provider
            self.calls: list[tuple[object, ...]] = []
            self.fail_detail: str | None = None

        def _result(self) -> _Dispatch:
            if self.fail_detail is not None:
                return _Dispatch(ok=False, detail=self.fail_detail)
            return _Dispatch()

        def dispatch(self, command: str, *, value: int | None = None) -> _Dispatch:
            self.calls.append(("dispatch", command, value))
            return self._result()

        def seek_ms(self, position_ms: int) -> _Dispatch:
            self.calls.append(("seek_ms", position_ms))
            return self._result()

        def set_speed(self, multiplier: float) -> _Dispatch:
            self.calls.append(("set_speed", multiplier))
            return self._result()

        def frame_step(self, direction: str = "FORWARD") -> _Dispatch:
            self.calls.append(("frame_step", direction))
            return self._result()

        def adjust_subtitle_delay(self, delta_ms: int = 500) -> _Dispatch:
            self.calls.append(("adjust_subtitle_delay", delta_ms))
            return self._result()

    monkeypatch.setattr(wm_dispatcher, "WmDispatcher", FakeDispatcher)

    # --- Doc 23 audio --------------------------------------------------------
    class FakeAudio:
        def __init__(self) -> None:
            record.audio = self
            self.volume_payloads: list[object] = []

        async def handle_set_system_volume(self, session: object, envelope: object) -> dict:
            self.volume_payloads.append(envelope.payload)
            return {}

        async def handle_set_system_mute(self, session: object, envelope: object) -> dict:
            return {}

        def snapshot(self) -> dict[str, object]:
            return {"sys_volume": 50, "sys_muted": False}

        async def stop(self) -> None:
            record.events.append("audio.stop")

    monkeypatch.setattr(audio_endpoint, "AudioEndpointController", FakeAudio)

    # --- Doc 19 brightness ---------------------------------------------------
    class FakeBrightness:
        def __init__(self) -> None:
            record.brightness = self
            self.probed = False

        async def list_monitors(self, *, refresh: bool = False) -> list[object]:
            self.probed = True
            return []

        def snapshot(self) -> dict[str, object]:
            return {"brightness": None}

        async def set_brightness(self, monitor: int, value: int) -> int:
            record.brightness_set = (monitor, value)
            return value

        async def stop(self) -> None:
            record.events.append("brightness.stop")

    monkeypatch.setattr(ddcci_brightness, "DdcciBrightnessController", FakeBrightness)

    # --- Doc 11 snapper ------------------------------------------------------
    class FakeSnapper:
        def __init__(self, locator: object) -> None:
            record.snapper = self
            self.locator = locator

        def list_monitors(self) -> list[object]:
            return []

        def snap_to_primary(self, *, maximize: bool = True) -> SimpleNamespace:
            return SimpleNamespace(ok=True, detail="snapped")

    monkeypatch.setattr(monitor_snapper, "MonitorSnapper", FakeSnapper)

    # --- Doc 12 blackout overlay ---------------------------------------------
    class FakeBlackout:
        def __init__(self, monitor_provider: object = None, root: object = None) -> None:
            record.blackout = self
            self.monitor_provider = monitor_provider
            self.root = root
            self.started = False
            self.shutdown_called = False
            self._active = False

        def start(self) -> None:
            self.started = True

        def toggle(self) -> bool:
            self._active = not self._active
            return self._active

        @property
        def is_active(self) -> bool:
            return self._active

        def shutdown(self) -> None:
            self.shutdown_called = True
            self.started = False

    monkeypatch.setattr(blackout_overlay, "BlackoutOverlayManager", FakeBlackout)

    # --- Doc 24 dashboard ----------------------------------------------------
    class FakeDashboard:
        def __init__(
            self,
            config: object,
            qr_image_factory: object,
            submit: object,
            *,
            rescan_factory: object = None,
            shutdown_callback: object = None,
            tray_alive: object = None,
            hide_callback: object = None,
        ) -> None:
            record.dashboard = self
            record.dashboard_kwargs = {
                "rescan_factory": rescan_factory,
                "shutdown_callback": shutdown_callback,
                "tray_alive": tray_alive,
                "hide_callback": hide_callback,
            }
            self.events: list[object] = []
            self.hidden = False
            self.closed = False
            self.focus_count = 0
            self._root = object()  # Doc 12 §4.2 shared-root seam

        def post(self, event: object) -> None:
            self.events.append(event)

        def focus_qr(self) -> None:
            self.focus_count += 1

        def hide(self) -> None:
            self.hidden = True

        def run(self) -> None:
            return None

        def close(self) -> None:
            self.closed = True

    monkeypatch.setattr(dashboard_window, "DashboardWindow", FakeDashboard)

    # --- Doc 25 tray ---------------------------------------------------------
    class FakeTray:
        def __init__(self, config: object, actions: object, icon_factory: object) -> None:
            record.tray = self
            record.tray_actions = actions
            record.tray_icon_factory = icon_factory
            self.started = False
            self.stopped = False
            self.connection: tuple[bool, object] | None = None

        def start(self) -> None:
            self.started = True
            record.events.append("tray.start")
            record.tray_actions.exit_app()  # the real tray fires this on Exit

        def stop(self, timeout_s: float = 3.0) -> None:
            self.stopped = True
            record.events.append("tray.stop")

        @property
        def alive(self) -> bool:
            return self.started and not self.stopped

        def set_connection(self, connected: bool, device_ip: object) -> None:
            self.connection = (connected, device_ip)

        def note_dashboard_hidden(self) -> bool:
            return False

    monkeypatch.setattr(tray_daemon, "TrayDaemon", FakeTray)
    return record


@pytest.fixture()
def wired(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    """Run the full wiring region with fakes; yields the recorder + registry."""
    monkeypatch.setenv("APPDATA", str(tmp_path / "AppData"))
    monkeypatch.setattr(ConfigManager, "_instance", None)
    agent_main.service_registry.reset()
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    record = _install_fakes(monkeypatch)

    code = asyncio.run(agent_main.run_agent([]))

    yield SimpleNamespace(
        record=record,
        code=code,
        registry=agent_main.service_registry,
        config=ConfigManager.instance(),
    )
    agent_main.service_registry.reset()


def _envelope(msg_type: str, action: str, payload: dict | None = None) -> object:
    return ws_server_router.parse_envelope(
        json.dumps(
            {
                "id": str(uuid.uuid4()),
                "type": msg_type,
                "action": action,
                "payload": payload if payload is not None else {},
                "timestamp": int(time.time()),
            }
        )
    )


class _FakeSocket:
    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


def _dispatch(router: object, msg_type: str, action: str, payload: dict | None = None) -> dict:
    session = ws_server_router.WsSession(_FakeSocket())
    envelope = _envelope(msg_type, action, payload)
    return asyncio.run(router.dispatch(session, envelope))


# --- lifecycle / registration ------------------------------------------------


def test_service_registration_order_and_start_stop_sequence(wired) -> None:
    assert wired.code == 0
    assert tuple(service.name for service in wired.registry.services) == SERVICE_ORDER
    assert wired.record.events == EXPECTED_EVENTS
    assert wired.record.udp_handle.stopped is True


def test_region_is_skipped_under_pytest_marker(monkeypatch, tmp_path) -> None:
    """Without clearing PYTEST_CURRENT_TEST the region must not wire anything."""
    monkeypatch.setenv("APPDATA", str(tmp_path / "AppData"))
    monkeypatch.setattr(ConfigManager, "_instance", None)
    agent_main.service_registry.reset()
    agent_main.service_registry.request_shutdown()

    assert asyncio.run(agent_main.run_agent([])) == 0
    assert agent_main.service_registry.services == ()
    agent_main.service_registry.reset()


# --- Docs 13/15: UDP + auth --------------------------------------------------


def test_udp_receiver_wired_with_auth_mouse_and_scrub_sink(wired) -> None:
    kwargs = wired.record.udp_kwargs
    auth = kwargs["auth"]
    assert isinstance(auth, AuthMiddleware)
    assert auth.verify_udp_auth_byte(auth.udp_auth_byte) is True
    assert re.fullmatch(r"[0-9a-f]{32}", wired.config.get().auth_token)
    assert kwargs["mouse"] is win32_mouse.engine
    assert kwargs["port"] == 50505  # fresh config default (frozen wire contract)

    wired.record.dispatcher.calls.clear()
    kwargs["scrub_sink"](90)  # UDP 0x04 target in seconds
    assert wired.record.dispatcher.calls == [("seek_ms", 90_000)]


# --- Docs 14/15/03: WS router ------------------------------------------------


def test_ws_server_wired_with_real_router_and_full_route_table(wired) -> None:
    kwargs = wired.record.ws_kwargs
    auth = kwargs["auth"]
    assert isinstance(auth, AuthMiddleware)
    assert auth.verify_ws_token(auth.token_hex) is True
    assert auth.verify_ws_token(auth.token_hex.upper()) is True
    assert auth.verify_ws_token(auth.token_hex[:-1]) is False
    assert kwargs["on_client_connected"] is not None
    assert kwargs["on_client_disconnected"] is not None
    assert wired.record.ws_port == 50506

    router = kwargs["router"]
    assert isinstance(router, ws_server_router.WsRouter)
    for msg_type, actions in ws_message_codec.ACTIONS_BY_TYPE.items():
        if msg_type == ws_message_codec.WsType.TELEMETRY_SYNC:
            continue
        for action in actions:
            assert router.lookup(str(msg_type), action) is not None, (msg_type, action)

    reply = _dispatch(router, "CMD_POTPLAYER", "PLAY_PAUSE")
    assert reply["payload"] == {"ok": True}
    assert reply["action"] == "PLAY_PAUSE_RESULT"
    assert str(uuid.UUID(reply["id"])) == reply["id"]  # uuid echoed


def test_potplayer_adapter_payloads_and_failures(wired) -> None:
    router = wired.record.ws_kwargs["router"]
    dispatcher = wired.record.dispatcher

    reply = _dispatch(router, "CMD_POTPLAYER", "SET_SPEED", {"multiplier": 1.5})
    assert dispatcher.calls[-1] == ("set_speed", 1.5)
    assert reply["payload"] == {"ok": True}

    reply = _dispatch(router, "CMD_POTPLAYER", "SEEK", {"position_ms": 12_345})
    assert dispatcher.calls[-1] == ("seek_ms", 12_345)

    reply = _dispatch(router, "CMD_POTPLAYER", "SEEK_DELTA", {})  # missing delta_ms
    assert reply["payload"]["ok"] is False
    assert reply["payload"]["error"] == "E_BAD_PAYLOAD"

    dispatcher.fail_detail = "no_window"
    reply = _dispatch(router, "CMD_POTPLAYER", "PLAY_PAUSE")
    assert reply["payload"] == {
        "ok": False,
        "error": "E_POTPLAYER_NOT_RUNNING",
        "detail": "no_window",
    }
    dispatcher.fail_detail = None

    # SEEK_DELTA adds the Doc 10 snapshot position to the delta.
    wired.record.poller.latest = SimpleNamespace(
        position_ms=1_000, duration_ms=10_000, is_playing=True, speed=1.25
    )
    reply = _dispatch(router, "CMD_POTPLAYER", "SEEK_DELTA", {"delta_ms": 500})
    assert dispatcher.calls[-1] == ("seek_ms", 1_500)
    assert dispatcher.speed_provider() == 1.25


def test_cmd_key_adapter_validates_payloads(wired, monkeypatch) -> None:
    router = wired.record.ws_kwargs["router"]
    monkeypatch.setattr(win32_keyboard.engine, "_send_input", lambda *_args: 1)

    reply = _dispatch(router, "CMD_KEY", "SEND_KEY", {"vk": 13})
    assert reply["payload"] == {"ok": True}

    reply = _dispatch(router, "CMD_KEY", "SEND_KEY", {"vk": 999})
    assert reply["payload"]["ok"] is False
    assert reply["payload"]["error"] == "E_BAD_PAYLOAD"

    reply = _dispatch(router, "CMD_KEY", "SEND_TEXT", {"text": ""})
    assert reply["payload"]["ok"] is False


def test_system_and_media_handlers_dispatch(wired, monkeypatch) -> None:
    router = wired.record.ws_kwargs["router"]

    reply = _dispatch(router, "CMD_SYSTEM", "SNAP_TO_PRIMARY_MONITOR")
    assert reply["payload"] == {"ok": True}

    reply = _dispatch(router, "CMD_SYSTEM", "SET_SYSTEM_VOLUME", {"percent": 70})
    assert wired.record.audio.volume_payloads[-1] == {"percent": 70}
    assert reply["payload"] == {"ok": True}

    reply = _dispatch(router, "CMD_SYSTEM", "START_SLEEP_TIMER", {"bogus": True})
    assert reply["payload"]["ok"] is False
    assert reply["payload"]["error"] == "E_BAD_PAYLOAD"

    # SET_BLACKOUT routes through Doc 12's module adapter + active manager.
    monkeypatch.setattr(
        blackout_overlay, "_active_manager", SimpleNamespace(set_enabled=lambda flag: flag)
    )
    reply = _dispatch(router, "CMD_SYSTEM", "SET_BLACKOUT", {"enabled": True})
    assert reply["payload"] == {"ok": True, "enabled": True}

    session = ws_server_router.WsSession(_FakeSocket())
    envelope = _envelope("CMD_SYSTEM", "REQUEST_STATE")
    reply = asyncio.run(router.dispatch(session, envelope))
    assert reply["payload"] == {"ok": True}
    assert session.ws.sent  # one unicast FULL_STATE frame went out first
    assert json.loads(session.ws.sent[0])["action"] == "FULL_STATE"

    reply = _dispatch(router, "CMD_MEDIA", "LIST_MEDIA", {})
    assert reply["payload"]["ok"] is True
    assert reply["payload"]["total"] == 0


# --- Docs 16/17/24/25: mDNS, QR, dashboard, tray -----------------------------


def test_telemetry_providers_are_registered_and_shape_correct(wired) -> None:
    sources = wired.record.broadcaster.sources
    assert set(sources) == {SOURCE_BLACKOUT, SOURCE_BRIGHTNESS, SOURCE_SLEEP, SOURCE_AUDIO}
    # Doc 12's is_active is a property — the provider must not call it.
    assert sources[SOURCE_BLACKOUT]() == {"blackout_active": False}
    assert sources[SOURCE_BRIGHTNESS]() == {"brightness": None}
    assert sources[SOURCE_AUDIO]() == {"sys_volume": 50, "sys_muted": False}
    sleep_state = sources[SOURCE_SLEEP]()
    assert set(sleep_state) == {
        "sleep_timer_active",
        "sleep_timer_mode",
        "sleep_timer_remaining_s",
    }
    assert sleep_state["sleep_timer_active"] is False


def test_mdns_ip_change_refreshes_dashboard_qr(wired) -> None:
    kwargs = wired.record.mdns_kwargs
    assert kwargs["udp_port"] == 50505
    assert kwargs["ws_port"] == 50506
    assert callable(kwargs["on_ips_changed"])

    dashboard = wired.record.dashboard
    dashboard.events.clear()
    kwargs["on_ips_changed"](["192.168.1.50"])
    assert [event.kind for event in dashboard.events] == [dashboard_window.EVENT_QR_REFRESH]


def test_dashboard_thread_wiring_and_initial_badge(wired) -> None:
    dashboard = wired.record.dashboard
    assert dashboard.closed is True  # GUI stop closed the window
    kinds = [event.kind for event in dashboard.events]
    assert dashboard_window.EVENT_CONNECTION in kinds
    first_connection = next(
        event for event in dashboard.events if event.kind == dashboard_window.EVENT_CONNECTION
    )
    assert first_connection.connection.state is dashboard_window.BadgeState.IDLE

    kwargs = wired.record.dashboard_kwargs
    assert callable(kwargs["shutdown_callback"])
    assert callable(kwargs["tray_alive"])
    assert callable(kwargs["hide_callback"])
    assert kwargs["tray_alive"]() is False  # tray stopped by then
    assert kwargs["hide_callback"]() is False

    overlay = wired.record.blackout
    assert overlay.started is False  # shut down during the stop phase
    assert overlay.shutdown_called is True
    assert overlay.root is dashboard._root  # shared dashboard root injected


def test_tray_actions_are_wired_to_seams(wired, monkeypatch) -> None:
    actions = wired.record.tray_actions
    dashboard = wired.record.dashboard

    actions.show_qr()
    assert dashboard.focus_count == 1

    assert actions.toggle_blackout() is True  # Doc 12 overlay slot (started on T0)

    recorded: list[tuple[bool, Path]] = []
    monkeypatch.setattr(
        ConfigManager,
        "set_startup_enabled",
        lambda self, enabled, exe_path: recorded.append((enabled, exe_path)),
    )
    assert actions.toggle_startup() is True
    assert recorded == [(True, Path(sys.executable))]

    assert callable(actions.exit_app)


def test_tray_icon_factory_falls_back_when_asset_missing(wired) -> None:
    with pytest.raises(FileNotFoundError):
        wired.record.tray_icon_factory()


def test_minimized_flag_starts_dashboard_hidden(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("APPDATA", str(tmp_path / "AppData"))
    monkeypatch.setattr(ConfigManager, "_instance", None)
    agent_main.service_registry.reset()
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    record = _install_fakes(monkeypatch)

    assert asyncio.run(agent_main.run_agent(["--minimized"])) == 0
    assert record.dashboard.hidden is True
    agent_main.service_registry.reset()


# --- Doc 25 §10: single-instance guard ---------------------------------------


def test_single_instance_guard_rejects_second_frozen_instance(monkeypatch) -> None:
    name = f"Local\\PotPilotTest-{uuid.uuid4().hex}"
    monkeypatch.setattr(agent_main, "_INSTANCE_MUTEX_NAME", name)
    monkeypatch.setattr(sys, "frozen", True, raising=False)

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.restype = ctypes.c_void_p
    held = kernel32.CreateMutexW(None, False, name)
    assert held
    try:
        code = asyncio.run(agent_main.run_agent([]))
    finally:
        kernel32.CloseHandle(held)
    assert code == 0
    assert agent_main.service_registry.services == ()


def test_single_instance_guard_allows_first_frozen_instance(monkeypatch) -> None:
    name = f"Local\\PotPilotTest-{uuid.uuid4().hex}"
    monkeypatch.setattr(agent_main, "_INSTANCE_MUTEX_NAME", name)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    agent_main.service_registry.reset()
    agent_main.service_registry.request_shutdown()

    assert asyncio.run(agent_main.run_agent([])) == 0
    agent_main.service_registry.reset()
