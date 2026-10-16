"""Doc 46 M4/M5/M6 — WS→WM_COMMAND background dispatch, 250 ms cadence, scrub sync.

Also carries the §8 final wiring-verification checklist reproduction of
overview §7 (automated items asserted, build artifacts reported PASS/PENDING,
manual items clearly marked). Benchmark/integration file: select alone with
``pytest pc_agent/tests/test_ws_dispatch_and_telemetry.py``.

Every harness send goes through ``conftest.build_ws_frame`` which validates the
envelope against ``shared_specs/ws_command_schema.json`` before dispatch (§5).
"""

from __future__ import annotations

import asyncio
import importlib
import json
import re
import time
import warnings
from collections.abc import Callable
from dataclasses import dataclass
from types import SimpleNamespace
from typing import Any

import pytest
import win32gui

from pc_agent.network.telemetry_broadcaster import TelemetryBroadcaster
from pc_agent.network.ws_server_router import WsEnvelope, WsRouter, WsServer, WsSession
from pc_agent.potplayer.hwnd_locator import PotPlayerLocator
from pc_agent.potplayer.telemetry_poller import TelemetryPoller
from pc_agent.potplayer.wm_dispatcher import DispatchResult, WmDispatcher
from pc_agent.tests.conftest import (
    REPO_ROOT,
    TOKEN_HEX,
    build_ws_frame,
    compute_stats,
    evaluate,
    format_stats,
    validate_ws_frame,
    ws_connect,
)

# --- M4 constants (Doc 46 §5: 30 commands = 10 distinct actions × 3) --------
M4_WIRE_ACTIONS: tuple[tuple[str, dict[str, Any]], ...] = (
    ("PLAY_PAUSE", {}),
    ("PLAY", {}),
    ("PAUSE", {}),
    ("TOGGLE_FULLSCREEN", {}),
    ("CYCLE_ASPECT_RATIO", {}),
    ("CYCLE_AUDIO", {}),
    ("CYCLE_SUBS", {}),
    ("SET_SPEED", {"multiplier": 1.5}),
    ("SET_VOLUME", {"percent": 42}),
    ("FRAME_STEP", {"direction": "FORWARD"}),
)
M4_REPETITIONS = 3
WM_USER_ACTIONS = frozenset({"SET_SPEED", "SET_VOLUME", "FRAME_STEP"})
M4_TOTAL = len(M4_WIRE_ACTIONS) * M4_REPETITIONS  # 30
M4_COMMAND_COUNT = (
    sum(1 for action, _ in M4_WIRE_ACTIONS if action not in WM_USER_ACTIONS) * M4_REPETITIONS
)
M4_USER_COUNT = M4_TOTAL - M4_COMMAND_COUNT
# Exact lparams this harness dispatches (speed_milli 1500, percent 42,
# frame_delta 1); lets M4 count dispatcher-origin WM_USERs only, ignoring
# foreign (0,0) getter probes if another suite shares the system-wide
# PotPlayer64 window namespace (Doc 46 §10 assumes an exclusive machine).
M4_DISPATCH_LPARAMS = frozenset({1500, 42, 1})
M4_P95_DISPATCH_MS = 100.0

# --- M5 constants (Doc 46 §5: 60 s of TELEMETRY_SYNC) ----------------------
M5_WINDOW_S = 60.0
M5_MIN_FRAMES = 216
M5_MAX_FRAMES = 264
M5_GAP_MIN_MS = 225.0  # 250 ms ± 10 %
M5_GAP_MAX_MS = 275.0

# --- M6 constants (Doc 46 §5: 20 steps × 250 ms, ±250 ms) ------------------
M6_STEPS = 20
M6_STEP_INTERVAL_S = 0.25
M6_TOLERANCE_MS = 250
M6_FIRST_TARGET_MS = 15_000

UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class _FixedWsAuth:
    """Doc 15 seam: accepts exactly the harness token."""

    def verify_ws_token(self, presented: str) -> bool:
        return isinstance(presented, str) and presented.lower() == TOKEN_HEX


@dataclass
class _Stack:
    """One in-process agent: real WS server/router + broadcaster + poller + dispatcher."""

    server: WsServer
    router: WsRouter
    broadcaster: TelemetryBroadcaster
    poller: TelemetryPoller | None
    dispatcher: WmDispatcher
    locator: PotPlayerLocator


def _check_telemetry_shape(frame: dict[str, Any]) -> None:
    """TELEMETRY_SYNC frame structure (Doc 03 §5.6 / Doc 46 §5)."""
    assert frame.get("type") == "TELEMETRY_SYNC", frame
    assert frame.get("action") in ("STATE_DELTA", "FULL_STATE"), frame
    payload = frame.get("payload")
    assert isinstance(payload, dict) and payload, frame
    assert isinstance(frame.get("id"), str) and UUID4_RE.fullmatch(frame["id"]), frame
    assert isinstance(frame.get("timestamp"), int), frame
    assert "position_ms" in payload, f"position advances every tick: {frame}"


class _WsInbox:
    """Test client wrapper: TELEMETRY_SYNC frames are buffered, never dropped.

    A server reply and a telemetry tick can interleave on the wire; discarding
    telemetry while waiting for a reply would race M6's position matching.
    """

    def __init__(self, client: Any) -> None:
        self._client = client
        self._telemetry: list[dict[str, Any]] = []

    async def request(
        self, msg_type: str, action: str, payload: dict[str, Any]
    ) -> dict[str, Any]:
        """Validate against the shared schema, send, await the non-telemetry reply."""
        frame = build_ws_frame(msg_type, action, payload)  # §5: validate BEFORE dispatch
        await self._client.send(json.dumps(frame))
        deadline = time.monotonic() + 5.0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"no reply for {action} within 5 s")
            message = await self._recv(remaining)
            if message.get("type") == "TELEMETRY_SYNC":
                self._telemetry.append(message)
                continue
            return message

    async def wait_telemetry(
        self, *, predicate: Callable[[dict[str, Any]], bool], budget_s: float
    ) -> dict[str, Any]:
        """First buffered-or-live TELEMETRY_SYNC matching ``predicate``."""
        for index, frame in enumerate(self._telemetry):
            _check_telemetry_shape(frame)
            if predicate(frame):
                return self._telemetry.pop(index)
        deadline = time.monotonic() + budget_s
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"no matching TELEMETRY_SYNC within {budget_s:.1f} s")
            frame = await self._recv(remaining)
            if frame.get("type") != "TELEMETRY_SYNC":
                continue
            _check_telemetry_shape(frame)
            if predicate(frame):
                return frame

    async def next_telemetry(self, *, budget_s: float) -> dict[str, Any]:
        """Next live TELEMETRY_SYNC (shape-checked); asserts when cadence stalls."""
        deadline = time.monotonic() + budget_s
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"cadence stalled: no TELEMETRY_SYNC within {budget_s:.0f} s"
                )
            frame = await self._recv(remaining)
            if frame.get("type") == "TELEMETRY_SYNC":
                _check_telemetry_shape(frame)
                return frame

    async def _recv(self, budget_s: float) -> dict[str, Any]:
        try:
            raw = await asyncio.wait_for(self._client.recv(), budget_s)
        except TimeoutError as exc:
            raise AssertionError(f"no WS frame within {budget_s:.1f} s") from exc
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        return json.loads(raw)


def _dispatch_handler(
    dispatcher: WmDispatcher, invoker: Callable[[WsEnvelope], DispatchResult]
) -> Any:
    async def handler(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        del session
        result = invoker(envelope)
        return {"delivered": bool(result.ok), "detail": str(result.detail)}

    return handler


def _register_routes(
    router: WsRouter, dispatcher: WmDispatcher, broadcaster: TelemetryBroadcaster
) -> None:
    """Wire the frozen action names to the REAL WmDispatcher (Docs 09/14 seam)."""
    potplayer_routes: dict[str, Callable[[WsEnvelope], DispatchResult]] = {
        "PLAY_PAUSE": lambda envelope: dispatcher.play_pause(),
        "PLAY": lambda envelope: dispatcher.dispatch("PLAY"),
        "PAUSE": lambda envelope: dispatcher.dispatch("PAUSE"),
        "TOGGLE_FULLSCREEN": lambda envelope: dispatcher.dispatch("TOGGLE_FULLSCREEN"),
        "CYCLE_ASPECT_RATIO": lambda envelope: dispatcher.dispatch("CYCLE_ASPECT_RATIO"),
        "CYCLE_AUDIO": lambda envelope: dispatcher.cycle_audio_track(),
        "CYCLE_SUBS": lambda envelope: dispatcher.cycle_subtitle_track(),
        "SET_SPEED": lambda envelope: dispatcher.set_speed(float(envelope.payload["multiplier"])),
        "SET_VOLUME": lambda envelope: dispatcher.dispatch(
            "SET_VOLUME", value=int(envelope.payload["percent"])
        ),
        "FRAME_STEP": lambda envelope: dispatcher.frame_step(str(envelope.payload["direction"])),
        "SEEK": lambda envelope: dispatcher.seek_ms(int(envelope.payload["position_ms"])),
    }
    for action, invoker in potplayer_routes.items():
        router.register("CMD_POTPLAYER", action, _dispatch_handler(dispatcher, invoker))

    async def request_state(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        del session, envelope
        return {"state": broadcaster.snapshot()}

    # Doc 46 §5 "exercises" LIST_MEDIA/LAUNCH_MEDIA for envelope+registry
    # conformance; the real scanner/launcher paths are gated by Docs 20/21.
    async def list_media(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        del session
        payload = envelope.payload
        return {
            "folders": [],
            "items": [],
            "total": 0,
            "offset": int(payload.get("offset", 0)),
            "limit": int(payload.get("limit", 50)),
        }

    async def launch_media(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        del session, envelope
        return {"started": False}

    router.register("CMD_SYSTEM", "REQUEST_STATE", request_state)
    router.register("CMD_MEDIA", "LIST_MEDIA", list_media)
    router.register("CMD_MEDIA", "LAUNCH_MEDIA", launch_media)


async def _start_stack(mock: Any, *, with_poller: bool) -> _Stack:
    """Real locator → finds the mock window; real dispatcher/poller/broadcaster/WS."""
    locator = PotPlayerLocator()
    dispatcher = WmDispatcher(locator)
    poller = TelemetryPoller(locator) if with_poller else None
    poller_seam = poller if poller is not None else SimpleNamespace(latest=None)
    broadcaster = TelemetryBroadcaster(poller_seam)
    router = WsRouter()
    _register_routes(router, dispatcher, broadcaster)
    server = WsServer(
        router=router,
        auth=_FixedWsAuth(),
        on_client_connected=broadcaster.register_client,
        on_client_disconnected=broadcaster.unregister_client,
    )
    await server.start(host="127.0.0.1", port=0)
    found = locator.find()
    assert found == mock.hwnd, (
        f"real Doc 08 locator must resolve the mock window (found {found}, "
        f"expected {mock.hwnd}) — a foreign PotPlayer64 window from a "
        "concurrent test run may be ahead in z-order"
    )
    if poller is not None:
        poller.start()
    await broadcaster.start()
    return _Stack(server, router, broadcaster, poller, dispatcher, locator)


async def _stop_stack(stack: _Stack) -> None:
    await stack.broadcaster.stop()
    if stack.poller is not None:
        await stack.poller.stop()
    await stack.server.stop()


async def _wait_for_commands(mock: Any, count: int, budget_s: float = 3.0) -> None:
    deadline = time.monotonic() + budget_s
    while time.monotonic() < deadline:
        if len(mock.received_commands) >= count:
            return
        await asyncio.sleep(0.01)
    raise AssertionError(f"mock logged {len(mock.received_commands)} < {count} WM_COMMANDs")


# ---------------------------------------------------------------------------
# M4 — background WM_COMMAND dispatch (Blocking)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_m4_background_wm_command_dispatch(mock_potplayer: Any) -> None:
    """M4: 30 commands hit the mock via the REAL dispatcher; foreground stable; p95 < 100 ms."""
    foreground_before = win32gui.GetForegroundWindow()
    stack = await _start_stack(mock_potplayer, with_poller=False)
    client: Any = None
    try:
        client = await ws_connect(stack.server.port)
        inbox = _WsInbox(client)
        send_log: list[tuple[str, float]] = []
        for _ in range(M4_REPETITIONS):
            for action, payload in M4_WIRE_ACTIONS:
                foreground = win32gui.GetForegroundWindow()
                sent_at = time.monotonic()
                reply = await inbox.request("CMD_POTPLAYER", action, payload)
                assert reply.get("action") == f"{action}_RESULT", reply
                assert reply.get("payload", {}).get("delivered") is True, (
                    f"M4: {action} not delivered: {reply}"
                )
                assert win32gui.GetForegroundWindow() == foreground, (
                    f"M4: foreground window changed during dispatch of {action}"
                )
                kind = "WM_USER" if action in WM_USER_ACTIONS else "WM_COMMAND"
                send_log.append((kind, sent_at))

        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            logged = len(mock_potplayer.received_commands) + len(
                mock_potplayer.received_user_msgs
            )
            if logged >= M4_TOTAL:
                break
            await asyncio.sleep(0.01)

        command_times = mock_potplayer.received_command_times
        details = mock_potplayer.received_user_details
        user_times = [
            stamp
            for stamp, (_msg, _wparam, lparam) in zip(
                mock_potplayer.received_user_times, details, strict=True
            )
            if lparam in M4_DISPATCH_LPARAMS
        ]
        assert len(mock_potplayer.received_commands) == M4_COMMAND_COUNT, (
            f"expected {M4_COMMAND_COUNT} WM_COMMANDs, "
            f"got {len(mock_potplayer.received_commands)}"
        )
        assert len(user_times) == M4_USER_COUNT, (
            f"expected {M4_USER_COUNT} dispatcher WM_USERs, got {len(user_times)}: "
            f"{details}"
        )
        assert win32gui.GetForegroundWindow() == foreground_before, (
            "M4: foreground window changed across the dispatch suite"
        )

        command_sends = [stamp for kind, stamp in send_log if kind == "WM_COMMAND"]
        user_sends = [stamp for kind, stamp in send_log if kind == "WM_USER"]
        latencies = [
            (received - sent) * 1000.0
            for sent, received in zip(command_sends, command_times, strict=True)
        ]
        latencies += [
            (received - sent) * 1000.0
            for sent, received in zip(user_sends, user_times, strict=True)
        ]
        assert all(value >= 0 for value in latencies)
        stats = compute_stats(latencies)
        print(format_stats("M4 WS->WM dispatch-to-log", stats))
        assert evaluate(stats, M4_P95_DISPATCH_MS, percentile="p95"), (
            f"M4 FAIL: p95 dispatch-to-log {stats.p95:.3f} ms >= {M4_P95_DISPATCH_MS} ms"
        )
        for counter in ("no_window", "timeout", "unknown_command", "bad_value"):
            assert stack.dispatcher.stats.get(counter, 0) == 0, (
                f"M4: dispatcher counter {counter} fired: {dict(stack.dispatcher.stats)}"
            )
    finally:
        if client is not None:
            await client.close()
        await _stop_stack(stack)


@pytest.mark.asyncio
async def test_media_actions_real_router_round_trip(mock_potplayer: Any) -> None:
    """Doc 46 §5: LIST_MEDIA / LAUNCH_MEDIA exercised through the real registry."""
    stack = await _start_stack(mock_potplayer, with_poller=False)
    client: Any = None
    try:
        client = await ws_connect(stack.server.port)
        inbox = _WsInbox(client)
        list_reply = await inbox.request("CMD_MEDIA", "LIST_MEDIA", {})
        assert list_reply.get("action") == "LIST_MEDIA_RESULT", list_reply
        assert list_reply.get("payload", {}).get("total") == 0, list_reply
        launch_reply = await inbox.request(
            "CMD_MEDIA", "LAUNCH_MEDIA", {"path": r"C:\Movies\demo.mkv"}
        )
        assert launch_reply.get("action") == "LAUNCH_MEDIA_RESULT", launch_reply
    finally:
        if client is not None:
            await client.close()
        await _stop_stack(stack)


# ---------------------------------------------------------------------------
# M5 — 250 ms telemetry cadence (Blocking; 60 s measurement window)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_m5_telemetry_cadence_250ms(mock_potplayer: Any) -> None:
    """M5: 60 s of TELEMETRY_SYNC — 216..264 frames, inter-arrival p95 within 225–275 ms."""
    stack = await _start_stack(mock_potplayer, with_poller=True)
    client: Any = None
    try:
        client = await ws_connect(stack.server.port)
        inbox = _WsInbox(client)
        reply = await inbox.request("CMD_POTPLAYER", "PLAY", {})
        assert reply.get("payload", {}).get("delivered") is True, reply
        await _wait_for_commands(mock_potplayer, 1)
        assert mock_potplayer.playing is True, "PLAY must toggle the mock play-state bit"

        # Cadence marker: the first delta proves position is advancing each tick.
        await inbox.wait_telemetry(
            predicate=lambda frame: frame["action"] == "STATE_DELTA", budget_s=5.0
        )
        window_start = time.monotonic()
        arrivals = [window_start]
        while time.monotonic() - window_start < M5_WINDOW_S:
            await inbox.next_telemetry(budget_s=10.0)
            arrivals.append(time.monotonic())

        count = len(arrivals)
        gaps_ms = [
            (later - earlier) * 1000.0
            for earlier, later in zip(arrivals, arrivals[1:], strict=False)
        ]
        gap_stats = compute_stats(gaps_ms)
        print(
            f"M5 TELEMETRY_SYNC frames in {M5_WINDOW_S:.0f} s: {count} "
            f"(expected ~240, band {M5_MIN_FRAMES}-{M5_MAX_FRAMES})"
        )
        print(format_stats("M5 inter-arrival gaps", gap_stats))
        assert M5_MIN_FRAMES <= count <= M5_MAX_FRAMES, (
            f"M5 FAIL: {count} frames outside band [{M5_MIN_FRAMES}, {M5_MAX_FRAMES}]"
        )
        assert M5_GAP_MIN_MS <= gap_stats.p95 <= M5_GAP_MAX_MS, (
            f"M5 FAIL: inter-arrival p95 {gap_stats.p95:.1f} ms outside "
            f"[{M5_GAP_MIN_MS}, {M5_GAP_MAX_MS}] ms"
        )
    finally:
        if client is not None:
            await client.close()
        await _stop_stack(stack)


# ---------------------------------------------------------------------------
# M6 — scrub-bar sync (Blocking; PC-side mirror of the phone check)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_m6_scrub_bar_sync_live_position(mock_potplayer: Any) -> None:
    """M6: 20 seek steps × 250 ms — telemetry position within ±250 ms of the mock."""
    # The frozen placeholder table gives every WM_USER setter the identical
    # (WM_USER, 0, value) query, so the mock cannot disambiguate SEEK from
    # SET_VOLUME/SET_SPEED; this test only dispatches SEEK, and the value is
    # applied to the position model through the mock's documented hook
    # (a captured real-PotPlayer table would route it internally).
    mock_potplayer.on_wm_user_value = mock_potplayer.set_position_ms
    stack = await _start_stack(mock_potplayer, with_poller=True)
    client: Any = None
    try:
        client = await ws_connect(stack.server.port)
        inbox = _WsInbox(client)
        for step in range(M6_STEPS):
            target_ms = M6_FIRST_TARGET_MS + step * 1_000
            sent_at = time.monotonic()
            reply = await inbox.request("CMD_POTPLAYER", "SEEK", {"position_ms": target_ms})
            assert reply.get("action") == "SEEK_RESULT", reply
            assert reply.get("payload", {}).get("delivered") is True, reply
            frame = await inbox.wait_telemetry(
                # bind target_ms now: B023-safe closure over the loop variable
                predicate=lambda message, target=target_ms: (
                    message["payload"].get("position_ms") == target
                ),
                budget_s=2.0,
            )
            received_ms = int(frame["payload"]["position_ms"])
            mock_ms = mock_potplayer.position_ms  # paused model: static at the target
            drift = abs(received_ms - mock_ms)
            assert drift <= M6_TOLERANCE_MS, (
                f"M6 step {step}: phone {received_ms} ms vs mock {mock_ms} ms "
                f"(drift {drift} ms > ±{M6_TOLERANCE_MS} ms)"
            )
            elapsed = time.monotonic() - sent_at
            await asyncio.sleep(max(0.0, M6_STEP_INTERVAL_S - elapsed))

        assert mock_potplayer.playing is False, "M6 must not disturb the play state"
        seek_values = [
            lparam
            for _msg, _wparam, lparam in mock_potplayer.received_user_details
            if lparam != 0  # getter queries are (WM_USER, 0, 0)
        ]
        expected = [M6_FIRST_TARGET_MS + step * 1_000 for step in range(M6_STEPS)]
        assert seek_values == expected, (
            f"M6: seeks delivered out of order or missing: {seek_values} != {expected}"
        )
        print(
            f"M6: {M6_STEPS} scrub steps reflected within ±{M6_TOLERANCE_MS} ms "
            f"at {M6_STEP_INTERVAL_S * 1000:.0f} ms cadence"
        )
    finally:
        mock_potplayer.on_wm_user_value = None
        if client is not None:
            await client.close()
        await _stop_stack(stack)


# ---------------------------------------------------------------------------
# §5 — envelope conformance of every harness send
# ---------------------------------------------------------------------------


def test_harness_ws_actions_validate_against_shared_schema() -> None:
    """Every WS action the harness sends validates against ws_command_schema.json."""
    harness_sends: tuple[tuple[str, str, dict[str, Any]], ...] = (
        *(("CMD_POTPLAYER", action, payload) for action, payload in M4_WIRE_ACTIONS),
        ("CMD_POTPLAYER", "SEEK", {"position_ms": M6_FIRST_TARGET_MS}),
        ("CMD_MEDIA", "LIST_MEDIA", {}),
        ("CMD_MEDIA", "LAUNCH_MEDIA", {"path": r"C:\Movies\demo.mkv"}),
        ("CMD_SYSTEM", "REQUEST_STATE", {}),
    )
    for msg_type, action, payload in harness_sends:
        frame = build_ws_frame(msg_type, action, payload)
        validate_ws_frame(frame)  # double-tap: explicit API proof, not just builder
        assert frame["type"] == msg_type and frame["action"] == action

    # Negative controls — the validator must bite on out-of-schema sends.
    with pytest.raises(AssertionError):
        build_ws_frame("CMD_POTPLAYER", "SET_SPEED", {"multiplier": 9.0})  # > max 4.0
    with pytest.raises(AssertionError):
        build_ws_frame("CMD_POTPLAYER", "NOT_A_REGISTERED_ACTION", {})
    with pytest.raises(AssertionError):
        build_ws_frame("CMD_POTPLAYER", "SET_VOLUME", {"percent": "50"})  # wrong type
    with pytest.raises(AssertionError):
        build_ws_frame("TELEMETRY_SYNC", "STATE_DELTA", {})  # server->client only
    with pytest.raises(AssertionError):
        build_ws_frame("CMD_MEDIA", "LIST_MEDIA", {"bogus_field": 1})  # unknown field


# ---------------------------------------------------------------------------
# §8 — final wiring verification checklist (overview §7 reproduction)
# ---------------------------------------------------------------------------

MANUAL_CHECKS: tuple[str, ...] = (
    "Phase 1 milestone: move trackpad on phone, time cursor response on PC (< 2 ms, manual)",
    "Real-PotPlayer smoke: Play/Pause + 5 s seek from deck, background, window unfocused",
    "Ergonomics spot checks Docs 42-45: haptics, volume hijack, call auto-pause, tap-launch",
    "Installer smoke: PotPilot_Setup.exe on a clean VM, firewall rules, agent starts at boot",
    "Phone off Wi-Fi 30 s -> Doc 31 reconnect restores control without app restart",
)

_PHASE1_PC_MODULES = (
    "pc_agent.input_engine.win32_mouse",
    "pc_agent.input_engine.win32_keyboard",
    "pc_agent.potplayer.hwnd_locator",
    "pc_agent.potplayer.wm_dispatcher",
    "pc_agent.potplayer.telemetry_poller",
    "pc_agent.network.udp_server",
    "pc_agent.network.ws_server_router",
    "pc_agent.core.auth_middleware",
    "pc_agent.network.mdns_broadcaster",
    "pc_agent.core.qr_payload_gen",
)
_PHASE1_MOBILE = (
    "mobile_app/lib/network/udp_sender.dart",
    "mobile_app/lib/network/ws_client.dart",
    "mobile_app/lib/network/pairing_scanner.dart",
    "mobile_app/lib/network/telemetry_provider.dart",
)
_PHASE2_FILES = (
    # Wave 2.A
    "pc_agent/display_power/monitor_snapper.py",
    "pc_agent/display_power/blackout_overlay.py",
    "pc_agent/display_power/ddcci_brightness.py",
    "pc_agent/media/library_scanner.py",
    "pc_agent/media/file_launcher.py",
    "pc_agent/display_power/sleep_power_mgr.py",
    "pc_agent/display_power/audio_endpoint.py",
    "mobile_app/lib/features/trackpad/virtual_trackpad.dart",
    "mobile_app/lib/features/deck/potplayer_deck.dart",
    "mobile_app/lib/features/hud/scrub_speed_hud.dart",
    "mobile_app/lib/features/keyboard/full_keyboard.dart",
    "mobile_app/lib/features/display/monitor_power_sheet.dart",
    # Wave 2.B
    "mobile_app/lib/features/bed_mode/blind_gesture_pad.dart",
    "mobile_app/lib/core/haptics/haptic_engine.dart",
    "mobile_app/lib/hardware_hooks/volume_button_hijack.dart",
    "mobile_app/lib/hardware_hooks/call_autopause_hook.dart",
    "mobile_app/lib/features/library/movie_browser.dart",
    "pc_agent/gui/dashboard_window.py",
    "pc_agent/gui/tray_daemon.py",
)
_SPEC_FILES = (
    "shared_specs/udp_packet_layout.json",
    "shared_specs/ws_command_schema.json",
    "shared_specs/potplayer_wm_codes.json",
)


def _existing(paths: tuple[str, ...]) -> list[str]:
    return [path for path in paths if not (REPO_ROOT / path).exists()]


def test_checklist_phase0_all_46_micro_docs_exist() -> None:
    """Phase 0: plan-series contains micro-docs 01..46 (read-only check)."""
    numbered = {
        int(path.name.split("_", 1)[0])
        for path in (REPO_ROOT / "plan-series").glob("[0-9][0-9]_*.md")
    }
    missing = sorted(set(range(1, 47)) - numbered)
    assert not missing, f"plan-series micro-docs missing: {missing}"
    print(f"CHECKLIST Phase 0 [automated]: all {len(numbered)} micro-docs present")


def test_checklist_phase1_foundation_and_wave1b() -> None:
    """Phase 1: 3 shared specs, Wave 1.B PC modules importable, mobile sources present."""
    missing_specs = _existing(_SPEC_FILES)
    assert missing_specs == [], f"missing shared specs: {missing_specs}"
    for module in _PHASE1_PC_MODULES:
        importlib.import_module(module)
    missing_mobile = _existing(_PHASE1_MOBILE)
    assert missing_mobile == [], f"missing mobile files: {missing_mobile}"
    # pytest --collect-only cleanliness is proven by this suite's own collection;
    # flutter analyze cleanliness is owned by the mobile CI lane (external).
    print(
        f"CHECKLIST Phase 1 [automated]: {len(_PHASE1_PC_MODULES)} PC modules import, "
        f"{len(_PHASE1_MOBILE)} mobile sources present"
    )


def test_checklist_phase2_session2_surface_present() -> None:
    """Phase 2: Wave 2.A/2.B surfaces present (pytest/analyze gates run in their suites)."""
    missing = _existing(_PHASE2_FILES)
    assert not missing, f"Session-2 surfaces missing: {missing}"
    print(f"CHECKLIST Phase 2 [automated]: {len(_PHASE2_FILES)} Session-2 surfaces present")


def test_checklist_phase3_packaging_and_e2e() -> None:
    """Phase 3: packaging sources hard-gated; built artifacts reported PASS/PENDING."""
    assert (REPO_ROOT / "pc_agent" / "installer" / "setup.iss").is_file(), (
        "InnoSetup script missing (Doc 28)"
    )
    print("CHECKLIST Phase 3 [automated]: pc_agent/installer/setup.iss present")

    pending: list[str] = []
    spec_candidates = (
        REPO_ROOT / "pc_agent" / "installer" / "potpilot_agent.spec",  # blueprint path
        REPO_ROOT / "pc_agent" / "potpilot_agent.spec",
        REPO_ROOT / "potpilot_agent.spec",
    )
    if any(candidate.is_file() for candidate in spec_candidates):
        print("CHECKLIST Phase 3 [PASS]: pyinstaller spec present")
    else:
        pending.append("potpilot_agent.spec (Doc 27 packaging lane)")

    agent_bundles = (
        REPO_ROOT / "pc_agent" / "dist" / "PotPilotAgent",  # Doc 27 spec distpath
        REPO_ROOT / "dist" / "PotPilotAgent",  # legacy/alternate distpath
    )
    if any(d.is_dir() and any(d.iterdir()) for d in agent_bundles):
        print("CHECKLIST Phase 3 [PASS]: dist/PotPilotAgent/ built")
    else:
        pending.append("dist/PotPilotAgent/ (Wave 3.A build lane)")

    setup_exe = next(
        (
            path
            for base in (
                REPO_ROOT / "pc_agent" / "installer",
                REPO_ROOT / "pc_agent" / "installer" / "Output",
                REPO_ROOT / "dist",
                REPO_ROOT,
            )
            for path in base.glob("PotPilot_Setup*.exe")
        ),
        None,
    )
    if setup_exe is not None:
        print(f"CHECKLIST Phase 3 [PASS]: {setup_exe.name} built")
    else:
        pending.append("PotPilot_Setup.exe (Wave 3.A build lane)")

    apk = (
        REPO_ROOT
        / "mobile_app"
        / "build"
        / "app"
        / "outputs"
        / "flutter-apk"
        / "app-release.apk"
    )
    if apk.is_file():
        print("CHECKLIST Phase 3 [PASS]: release APK built")
    else:
        pending.append("app-release.apk (Wave 3.A build lane)")

    for item in pending:
        warnings.warn(
            f"CHECKLIST Phase 3 [PENDING]: {item} not built yet — "
            "automated once the owning lane lands",
            stacklevel=1,
        )

    # E2E milestone (M2 < 5 ms, M4 background dispatch, M5/M6 telemetry+scrub)
    # is gated by the tests above in this file + test_udp_latency_benchmark.py.
    print("CHECKLIST Phase 3 [automated]: E2E milestone gated by M2/M4/M5/M6 tests")


def test_checklist_manual_items_documented() -> None:
    """Manual items (Doc 46 §9) — automation impractical; clearly marked."""
    assert len(MANUAL_CHECKS) == 5, "the §9 manual list must reproduce exactly 5 items"
    for item in MANUAL_CHECKS:
        print(f"MANUAL: {item}")
