"""PotPilot PC agent entry point and async lifecycle (Doc 04).

Usage: ``python pc_agent/main.py`` or ``python -m pc_agent.main``.
Boots the config (Doc 26), starts registered services in order, idles until a
shutdown trigger (Ctrl+C / GUI exit), then stops services in reverse order
each capped at ``SHUTDOWN_TIMEOUT_S``.
"""

from __future__ import annotations

import asyncio
import logging
import logging.handlers
import os
import re
import signal
import sys
from collections.abc import Callable, Sequence
from pathlib import Path
from types import FrameType
from typing import Protocol

if __package__ in (None, ""):  # direct script execution: make the repo root importable
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pc_agent.core.config_manager import CONFIG_DIR_NAME, ConfigManager  # noqa: E402

SHUTDOWN_TIMEOUT_S = 5.0
AGENT_DISPLAY_NAME = "PotPilot Agent"

_LOG_FORMAT = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"
_SECRET_PATTERNS = (
    re.compile(r"(auth_token(?:_hex)?\s*[=:]\s*)\S+", re.IGNORECASE),
    re.compile(r"\b[0-9a-f]{32}\b"),
)


class LifecycleService(Protocol):
    """Any long-lived PotPilot component (UDP server, WS server, mDNS, telemetry, tray…)."""

    name: str

    async def start(self) -> None:
        """Acquire resources and begin operating; must be idempotent-safe on failure rollback."""
        ...

    async def stop(self) -> None:
        """Release resources within SHUTDOWN_TIMEOUT_S; must be safe to call after partial start."""
        ...


class ServiceRegistry:
    """Ordered startup plan plus the shared shutdown signal (Docs 24/25 request exit here)."""

    def __init__(self) -> None:
        self._services: list[LifecycleService] = []
        self._shutdown_event: asyncio.Event | None = None

    @property
    def services(self) -> tuple[LifecycleService, ...]:
        return tuple(self._services)

    @property
    def shutdown_event(self) -> asyncio.Event:
        if self._shutdown_event is None:
            self._shutdown_event = asyncio.Event()
        return self._shutdown_event

    def register(self, service: LifecycleService) -> None:
        """Registration order == start order."""
        self._services.append(service)

    def request_shutdown(self) -> None:
        """Begin the stop phase (call via ``loop.call_soon_threadsafe`` from other threads)."""
        self.shutdown_event.set()

    def reset(self) -> None:
        """Drop all services and the shutdown signal (test isolation / repeated runs)."""
        self._services.clear()
        self._shutdown_event = None


service_registry = ServiceRegistry()


def register_service(service: LifecycleService) -> None:
    """Add a service to the startup plan (registration order == start order)."""
    service_registry.register(service)


def _redact(text: str) -> str:
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("***", text)
    return text


class RedactSecretsFilter(logging.Filter):
    """Scrub pairing tokens (``auth_token*`` / bare 32-hex) from every record."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:
            return True
        redacted = _redact(message)
        if redacted != message:
            record.msg = redacted
            record.args = None
        return True


def _log_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    base = Path(appdata) if appdata else Path.home() / "AppData" / "Roaming"
    return base / CONFIG_DIR_NAME / "logs"


def _configure_logging(verbose: bool) -> None:
    """Rotating file handler (1 MB x 5) + stderr when a console exists; secrets redacted."""
    level = logging.DEBUG if verbose else logging.INFO
    agent_logger = logging.getLogger("potpilot")
    agent_logger.setLevel(level)
    for stale in agent_logger.handlers[:]:
        stale.close()
    agent_logger.handlers.clear()
    formatter = logging.Formatter(_LOG_FORMAT)
    try:
        log_dir = _log_dir()
        log_dir.mkdir(parents=True, exist_ok=True)
        file_handler = logging.handlers.RotatingFileHandler(
            log_dir / "agent.log", maxBytes=1_000_000, backupCount=5, encoding="utf-8"
        )
        file_handler.setFormatter(formatter)
        file_handler.addFilter(RedactSecretsFilter())
        agent_logger.addHandler(file_handler)
    except OSError as exc:
        sys.stderr.write(f"{AGENT_DISPLAY_NAME}: cannot open log file ({exc})\n")
    if sys.stderr is not None:
        stream_handler = logging.StreamHandler(sys.stderr)
        stream_handler.setFormatter(formatter)
        stream_handler.addFilter(RedactSecretsFilter())
        agent_logger.addHandler(stream_handler)


async def _stop_services(services: Sequence[LifecycleService]) -> None:
    """Stop in reverse order, each capped at SHUTDOWN_TIMEOUT_S; never abort the loop."""
    logger = logging.getLogger("potpilot.main")
    for service in reversed(services):
        try:
            await asyncio.wait_for(service.stop(), timeout=SHUTDOWN_TIMEOUT_S)
        except TimeoutError:
            logger.error(
                "Service %s did not stop within %.1fs; force-cancelling",
                service.name,
                SHUTDOWN_TIMEOUT_S,
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Service %s failed to stop", service.name)


def _install_sigint_handler(registry: ServiceRegistry) -> Callable[[], None]:
    """First Ctrl+C → graceful shutdown; repeat → hard-cancel. Returns a restore hook."""
    logger = logging.getLogger("potpilot.main")
    try:
        previous = signal.getsignal(signal.SIGINT)
        loop = asyncio.get_running_loop()
        current = asyncio.current_task()
        hits = 0

        def _on_sigint(signum: int, frame: FrameType | None) -> None:
            nonlocal hits
            hits += 1
            if hits == 1:
                logger.info("Interrupt received; shutting down (Ctrl+C again to force)")
                loop.call_soon_threadsafe(registry.request_shutdown)
            elif current is not None:
                loop.call_soon_threadsafe(current.cancel)

        signal.signal(signal.SIGINT, _on_sigint)
    except (ValueError, OSError):
        return lambda: None

    def _restore() -> None:
        try:
            signal.signal(signal.SIGINT, previous)
        except (ValueError, OSError):
            pass

    return _restore


_INSTANCE_MUTEX_NAME = "Local\\PotPilotAgentSingleInstance"
_ERROR_ALREADY_EXISTS = 183


def _acquire_single_instance_guard() -> bool:
    """Doc 25 §10 single-instance guard for frozen builds (named mutex).

    Returns ``False`` when another instance already owns the mutex.  The
    winning handle is intentionally left open for the process lifetime so the
    guard stays held; dev (non-frozen) runs rely on the port-bind rollback
    instead, so ``python main.py`` and the test suite are unaffected.
    """
    if not getattr(sys, "frozen", False):
        return True
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    handle = kernel32.CreateMutexW(None, False, _INSTANCE_MUTEX_NAME)
    if handle and ctypes.get_last_error() == _ERROR_ALREADY_EXISTS:
        kernel32.CloseHandle(handle)
        return False
    return True


async def run_agent(argv: list[str] | None = None) -> int:
    """Boot config, start services in order, idle until shutdown; return exit code."""
    args = list(sys.argv[1:] if argv is None else argv)
    _configure_logging("--verbose" in args)
    logger = logging.getLogger("potpilot.main")

    config = ConfigManager.instance().load()
    registry = service_registry

    # WIRING (Session 3) -------------------------------------------------------
    # Session 3 Wave 3.A constructs every service here (feature imports stay
    # inside this region per Doc 04 §7) and registers them in Doc 04 §4.4
    # order: UDP receiver (13), WS server (14), mDNS (16), telemetry loop (18),
    # power/audio (22/23), tray (25), GUI (24).
    # Under pytest the region is skipped — unit tests register their own fakes
    # through register_service(); the wiring tests opt in by clearing the
    # PYTEST_CURRENT_TEST marker before calling run_agent().
    if not _acquire_single_instance_guard():
        logger.info("%s: another instance is already running; exiting", AGENT_DISPLAY_NAME)
        return 0

    if not registry.services and os.environ.get("PYTEST_CURRENT_TEST") is None:
        import ctypes
        import inspect
        import threading
        from typing import Any

        import customtkinter as ctk
        from PIL import Image

        from pc_agent.core.auth_middleware import AuthMiddleware
        from pc_agent.core.qr_payload_gen import render_pairing_qr
        from pc_agent.display_power.audio_endpoint import AudioEndpointController
        from pc_agent.display_power.blackout_overlay import (
            BlackoutOverlayManager,
            handle_blackout_command,
        )
        from pc_agent.display_power.ddcci_brightness import (
            DdcciBrightnessController,
            DdcciError,
        )
        from pc_agent.display_power.monitor_snapper import MonitorSnapper
        from pc_agent.display_power.sleep_power_mgr import SleepTimerManager
        from pc_agent.gui.dashboard_window import (
            EVENT_CONNECTION,
            EVENT_QR_REFRESH,
            QR_IMAGE_PX,
            BadgeState,
            ConnectionInfo,
            DashboardWindow,
            UiEvent,
        )
        from pc_agent.gui.tray_daemon import TrayActions, TrayDaemon
        from pc_agent.input_engine import win32_keyboard, win32_mouse
        from pc_agent.media.file_launcher import FileLauncher
        from pc_agent.media.library_scanner import LibraryScanner
        from pc_agent.network.mdns_broadcaster import MdnsBroadcaster
        from pc_agent.network.telemetry_broadcaster import (
            SOURCE_AUDIO,
            SOURCE_BLACKOUT,
            SOURCE_BRIGHTNESS,
            SOURCE_SLEEP,
            TelemetryBroadcaster,
        )
        from pc_agent.network.udp_server import start_udp_server
        from pc_agent.network.ws_message_codec import (
            ACTION_FULL_STATE,
            ACTIONS_BY_TYPE,
            Action,
            WsType,
        )
        from pc_agent.network.ws_server_router import WsRouter, WsServer
        from pc_agent.potplayer.hwnd_locator import PotPlayerLocator
        from pc_agent.potplayer.telemetry_poller import TelemetryPoller
        from pc_agent.potplayer.wm_dispatcher import WmDispatcher

        # -- Doc 04 §4.4 service identities ------------------------------------
        SERVICE_UDP_RECEIVER = "udp_receiver"
        SERVICE_WS_SERVER = "ws_server"
        SERVICE_MDNS = "mdns"
        SERVICE_TELEMETRY = "telemetry"
        SERVICE_POWER_AUDIO = "power_audio"
        SERVICE_TRAY = "tray"
        SERVICE_GUI = "gui"

        def _enable_dpi_awareness() -> None:
            """Per-Monitor-V2 via user32, shcore fallback (Doc 24 §6 / Doc 12 §6)."""
            try:
                user32 = ctypes.WinDLL("user32", use_last_error=True)
                if user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
                    return
            except (AttributeError, OSError):
                pass
            try:
                shcore = ctypes.WinDLL("shcore", use_last_error=True)
                shcore.SetProcessDpiAwareness(2)  # PROCESS_PER_MONITOR_DPI_AWARE
            except (AttributeError, OSError):
                pass

        class _WiredService:
            """LifecycleService adapter (Doc 04 §3) over sync/async start/stop callables."""

            def __init__(
                self, name: str, start: Callable[[], Any], stop: Callable[[], Any]
            ) -> None:
                self.name = name
                self._start = start
                self._stop = stop

            async def start(self) -> None:
                result = self._start()
                if inspect.isawaitable(result):
                    await result

            async def stop(self) -> None:
                result = self._stop()
                if inspect.isawaitable(result):
                    await result

        _enable_dpi_awareness()

        # Doc 04 §4.5: modules log via getLogger(__name__) under ``pc_agent.*``;
        # mirror those records onto the configured ``potpilot`` handlers (the
        # rotating file + stderr with token redaction), keeping one destination.
        _agent_logger = logging.getLogger("potpilot")
        _module_logger = logging.getLogger("pc_agent")
        _module_logger.setLevel(_agent_logger.level)
        for _handler in _agent_logger.handlers:
            if _handler not in _module_logger.handlers:
                _module_logger.addHandler(_handler)

        # -- Bootstrap (Doc 26 §4.8: config -> token -> servers) ---------------
        config_manager = ConfigManager.instance()
        auth = AuthMiddleware(config_manager)
        auth.load_or_create()
        try:
            config_manager.resync_startup()  # best-effort HKCU Run heal (Doc 26 §10)
        except Exception:
            logger.debug("startup registry resync failed", exc_info=True)

        class _BlackoutSlot:
            """Doc 12 overlay manager created on T0 once the dashboard root exists."""

            manager: Any = None

            def toggle(self) -> bool:
                return bool(self.manager.toggle()) if self.manager is not None else False

        class _UiBridge:
            """Fan-out for connection/QR events from T1/T2 to the tray and dashboard."""

            def __init__(self) -> None:
                self._dashboard: Any = None
                self._tray: Any = None
                self._ws: Any = None
                self._last_ip: str | None = None

            def attach_ws(self, ws: Any) -> None:
                self._ws = ws

            def attach_tray(self, tray: Any) -> None:
                self._tray = tray

            def attach_dashboard(self, dashboard: Any) -> None:
                self._dashboard = dashboard

            @property
            def dashboard(self) -> Any:
                return self._dashboard

            def focus_qr(self) -> None:
                """Tray "Show QR": schedules root.after(0, focus_qr) on T0 (Doc 24)."""
                if self._dashboard is not None:
                    self._dashboard.focus_qr()

            def publish_connection(self, ip: str | None = None) -> None:
                if ip:
                    self._last_ip = ip
                count = int(self._ws.client_count) if self._ws is not None else 0
                connected = count > 0
                device_ip = self._last_ip if connected else None
                if self._tray is not None:
                    self._tray.set_connection(connected, device_ip)
                if self._dashboard is None:
                    return
                if connected:
                    info = ConnectionInfo(BadgeState.CONNECTED, device_ip, count, "")
                else:
                    info = ConnectionInfo(BadgeState.IDLE, None, 0, "")
                self._dashboard.post(UiEvent(EVENT_CONNECTION, connection=info))

            def publish_qr_refresh(self) -> None:
                if self._dashboard is not None:
                    self._dashboard.post(UiEvent(EVENT_QR_REFRESH))

        bridge = _UiBridge()
        blackout_slot = _BlackoutSlot()
        loop = asyncio.get_running_loop()
        start_minimized = "--minimized" in args
        udp_state: dict[str, Any] = {}
        power_state: dict[str, Any] = {}
        gui_state: dict[str, Any] = {}

        def _request_shutdown() -> None:
            """Thread-safe (T0/T2) exit request → registry shutdown event on T1."""
            loop.call_soon_threadsafe(registry.request_shutdown)

        def _toggle_startup() -> bool:
            desired = not config_manager.get().run_on_startup
            config_manager.set_startup_enabled(desired, Path(sys.executable))
            return desired

        # -- PotPlayer engine layer (Docs 08/09/10) -----------------------------
        locator = PotPlayerLocator()
        poller = TelemetryPoller(locator)

        def _speed_provider() -> float:
            snapshot = poller.latest
            return float(snapshot.speed) if snapshot is not None else 1.0

        dispatcher = WmDispatcher(locator, speed_provider=_speed_provider)

        def _scrub_sink(target_seconds: int) -> None:
            """UDP 0x04 scrub target (seconds) → Doc 09 absolute seek (ms)."""
            dispatcher.seek_ms(int(target_seconds) * 1000)

        async def _progress_provider() -> tuple[int, int, bool]:
            snapshot = poller.latest
            if snapshot is None:
                return (0, 0, False)
            return (int(snapshot.position_ms), int(snapshot.duration_ms), bool(snapshot.is_playing))

        # -- Display / audio / media controllers --------------------------------
        snapper = MonitorSnapper(locator)
        brightness = DdcciBrightnessController()
        audio = AudioEndpointController()
        sleep_mgr = SleepTimerManager(_progress_provider)
        scanner = LibraryScanner(config_manager)
        launcher = FileLauncher(locator, snapper, config_manager)

        # -- Doc 14 router (Docs 09/07/11/12/19/22/23/20/21 handlers) -----------
        router = WsRouter()
        broadcaster = TelemetryBroadcaster(poller)

        def _on_ws_connected(connection: Any) -> None:
            ip = None
            remote = getattr(connection, "remote_address", None)
            if isinstance(remote, (tuple, list)) and remote:
                ip = str(remote[0])
            broadcaster.register_client(connection)
            bridge.publish_connection(ip)

        def _on_ws_disconnected(connection: Any) -> None:
            broadcaster.unregister_client(connection)
            win32_keyboard.engine.release_all()
            win32_mouse.engine.release_all()
            bridge.publish_connection()

        ws_server = WsServer(
            router=router,
            auth=auth,
            on_client_connected=_on_ws_connected,
            on_client_disconnected=_on_ws_disconnected,
        )

        _DISPATCH_ERRORS = {
            "no_window": "E_POTPLAYER_NOT_RUNNING",
            "bad_value": "E_BAD_PAYLOAD",
            "unknown_command": "E_UNKNOWN_ACTION",
            "monitor_lost": "E_SNAP_FAILED",
            "verify_failed": "E_SNAP_FAILED",
        }

        def _dispatch_failure(detail: str) -> dict[str, Any]:
            return {
                "ok": False,
                "error": _DISPATCH_ERRORS.get(detail, "E_HANDLER"),
                "detail": detail,
            }

        async def _handle_potplayer(_session: Any, envelope: Any) -> dict[str, Any]:
            payload = envelope.payload if isinstance(envelope.payload, dict) else {}
            action = str(envelope.action)
            try:
                if action == Action.SEEK:
                    result = dispatcher.seek_ms(int(payload["position_ms"]))
                elif action == Action.SEEK_DELTA:
                    snapshot = poller.latest
                    current = int(snapshot.position_ms) if snapshot is not None else 0
                    result = dispatcher.seek_ms(current + int(payload["delta_ms"]))
                elif action == Action.SET_SPEED:
                    result = dispatcher.set_speed(float(payload["multiplier"]))
                elif action == Action.FRAME_STEP:
                    result = dispatcher.frame_step(str(payload.get("direction", "FORWARD")))
                elif action == Action.SET_VOLUME:
                    result = dispatcher.dispatch(action, value=int(payload["percent"]))
                elif action == Action.SET_SUBS:
                    enabled = payload.get("enabled")
                    if type(enabled) is not bool:
                        return {
                            "ok": False,
                            "error": "E_BAD_PAYLOAD",
                            "detail": "enabled must be a boolean",
                        }
                    result = dispatcher.dispatch(action, value=1 if enabled else 0)
                elif action == Action.SUB_SYNC_ADJUST:
                    result = dispatcher.adjust_subtitle_delay(int(payload["delta_ms"]))
                else:
                    result = dispatcher.dispatch(action)
            except (KeyError, TypeError, ValueError):
                return {
                    "ok": False,
                    "error": "E_BAD_PAYLOAD",
                    "detail": f"invalid payload for {action}",
                }
            if result.ok:
                return {}
            return _dispatch_failure(str(result.detail))

        async def _handle_cmd_key(_session: Any, envelope: Any) -> dict[str, Any]:
            payload = envelope.payload if isinstance(envelope.payload, dict) else {}
            injected = win32_keyboard.engine.handle_cmd_key(str(envelope.action), payload)
            if injected <= 0:
                return {
                    "ok": False,
                    "error": "E_BAD_PAYLOAD",
                    "detail": "no input injected (invalid key, empty text, or blocked)",
                }
            return {}

        async def _handle_snap(_session: Any, envelope: Any) -> dict[str, Any]:
            del envelope
            result = snapper.snap_to_primary()
            if result.ok:
                return {}
            return _dispatch_failure(str(result.detail))

        async def _handle_blackout(_session: Any, envelope: Any) -> dict[str, Any]:
            payload = envelope.payload if isinstance(envelope.payload, dict) else {}
            return handle_blackout_command(dict(payload))

        async def _handle_brightness(_session: Any, envelope: Any) -> dict[str, Any]:
            payload = envelope.payload if isinstance(envelope.payload, dict) else {}
            try:
                percent = payload["percent"]
            except KeyError:
                return {
                    "ok": False,
                    "error": "E_BAD_PAYLOAD",
                    "detail": "SET_BRIGHTNESS requires percent",
                }
            try:
                await brightness.set_brightness(0, percent)
            except DdcciError as exc:
                return {"ok": False, "error": exc.code, "detail": str(exc)}
            return {}

        async def _handle_request_state(session: Any, envelope: Any) -> dict[str, Any]:
            try:
                frame = broadcaster.build_frame(broadcaster.snapshot(), action=ACTION_FULL_STATE)
                await session.send_text(frame)
            except Exception:
                logger.debug("unicast FULL_STATE failed (envelope %s)", envelope.id, exc_info=True)
            return {}

        for _action in ACTIONS_BY_TYPE[WsType.CMD_POTPLAYER]:
            router.register(str(WsType.CMD_POTPLAYER), _action, _handle_potplayer)
        for _action in ACTIONS_BY_TYPE[WsType.CMD_KEY]:
            router.register(str(WsType.CMD_KEY), _action, _handle_cmd_key)
        router.register(str(WsType.CMD_SYSTEM), Action.SNAP_TO_PRIMARY_MONITOR, _handle_snap)
        router.register(str(WsType.CMD_SYSTEM), Action.SET_BLACKOUT, _handle_blackout)
        router.register(str(WsType.CMD_SYSTEM), Action.SET_BRIGHTNESS, _handle_brightness)
        router.register(
            str(WsType.CMD_SYSTEM), Action.SET_SYSTEM_VOLUME, audio.handle_set_system_volume
        )
        router.register(
            str(WsType.CMD_SYSTEM), Action.SET_SYSTEM_MUTE, audio.handle_set_system_mute
        )
        router.register(
            str(WsType.CMD_SYSTEM), Action.START_SLEEP_TIMER, sleep_mgr.handle_start_sleep_timer
        )
        router.register(
            str(WsType.CMD_SYSTEM), Action.CANCEL_SLEEP_TIMER, sleep_mgr.handle_cancel_sleep_timer
        )
        router.register(str(WsType.CMD_SYSTEM), Action.REQUEST_STATE, _handle_request_state)
        router.register(str(WsType.CMD_MEDIA), Action.LIST_MEDIA, scanner.handle_list_media)
        router.register(str(WsType.CMD_MEDIA), Action.RESCAN_MEDIA, scanner.handle_rescan_media)
        router.register(str(WsType.CMD_MEDIA), Action.LAUNCH_MEDIA, launcher.handle_launch_media)

        # -- Doc 18 telemetry sources (Docs 12/19/22/23 providers) --------------
        def _blackout_snapshot() -> dict[str, Any]:
            manager = blackout_slot.manager
            active = bool(manager.is_active) if manager is not None else False
            return {"blackout_active": active}

        broadcaster.register_source(SOURCE_BLACKOUT, _blackout_snapshot)
        broadcaster.register_source(SOURCE_BRIGHTNESS, brightness.snapshot)
        broadcaster.register_source(SOURCE_SLEEP, sleep_mgr.snapshot)
        broadcaster.register_source(SOURCE_AUDIO, audio.snapshot)

        def _qr_image_factory() -> Any:
            image = render_pairing_qr(
                auth=auth, udp_port=config.udp_port, ws_port=config.ws_port
            )
            return ctk.CTkImage(
                light_image=image, dark_image=image, size=(QR_IMAGE_PX, QR_IMAGE_PX)
            )

        def _tray_icon_factory() -> Any:
            frozen_base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).parent))
            for candidate in (
                Path(sys.executable).parent / "potpilot_icon.ico",
                frozen_base / "potpilot_icon.ico",
                frozen_base / "assets" / "potpilot_icon.ico",
                Path(__file__).resolve().parent / "assets" / "potpilot_icon.ico",
            ):
                if candidate.is_file():
                    with Image.open(candidate) as source:
                        image = source.convert("RGBA")
                    if image.size != (32, 32):
                        image = image.resize((32, 32), Image.Resampling.LANCZOS)
                    return image
            raise FileNotFoundError("potpilot_icon.ico not found; tray uses its fallback glyph")

        actions = TrayActions(
            show_qr=bridge.focus_qr,
            toggle_blackout=blackout_slot.toggle,
            toggle_startup=_toggle_startup,
            exit_app=_request_shutdown,
        )
        tray_daemon = TrayDaemon(config_manager, actions, _tray_icon_factory)
        bridge.attach_tray(tray_daemon)

        def _run_dashboard() -> None:
            """T0 body: build the dashboard + shared-root overlays, run the mainloop."""
            try:
                dashboard = DashboardWindow(
                    config=config_manager,
                    qr_image_factory=_qr_image_factory,
                    submit=lambda awaitable: asyncio.run_coroutine_threadsafe(awaitable, loop),
                    rescan_factory=scanner.rescan,
                    shutdown_callback=_request_shutdown,
                    tray_alive=lambda: tray_daemon.alive,
                    hide_callback=tray_daemon.note_dashboard_hidden,
                )
                root = getattr(dashboard, "_root", None)  # Doc 12 §4.2 shared-root seam
                overlay = BlackoutOverlayManager(
                    monitor_provider=snapper.list_monitors, root=root
                )
                overlay.start()  # on T0: adopts the dashboard root, starts the pump
                blackout_slot.manager = overlay
                bridge.attach_dashboard(dashboard)
                bridge.publish_connection()  # sockets are bound → STARTING → IDLE
                if start_minimized:
                    dashboard.hide()
                dashboard.run()
            except Exception:
                logger.exception("dashboard thread failed; continuing without a window")

        def _start_gui() -> None:
            thread = threading.Thread(target=_run_dashboard, name="potpilot-tk", daemon=True)
            gui_state["thread"] = thread
            thread.start()

        def _stop_gui() -> None:
            dashboard = bridge.dashboard
            if dashboard is not None:
                dashboard.close()
            thread = gui_state.get("thread")
            if thread is not None:
                thread.join(timeout=3.0)
                if thread.is_alive():
                    logger.error("dashboard thread did not stop within 3.0s")

        # -- Service plan (Doc 04 §4.4 registration order) ----------------------
        async def _start_udp() -> None:
            udp_state["handle"] = await start_udp_server(
                auth=auth,
                mouse=win32_mouse.engine,
                scrub_sink=_scrub_sink,
                port=config.udp_port,
            )

        async def _stop_udp() -> None:
            handle = udp_state.get("handle")
            if handle is not None:
                await handle.stop()

        async def _start_telemetry() -> None:
            poller.start()
            await broadcaster.start()

        async def _stop_telemetry() -> None:
            await broadcaster.stop()
            await poller.stop()

        async def _probe_brightness() -> None:
            try:
                await brightness.list_monitors()  # warm the Doc 19 snapshot cache
            except Exception:
                logger.debug("DDC/CI warm-up probe failed", exc_info=True)

        def _start_power() -> None:
            power_state["probe"] = asyncio.create_task(_probe_brightness())

        async def _stop_power() -> None:
            probe = power_state.pop("probe", None)
            if probe is not None:
                probe.cancel()
                try:
                    await probe
                except asyncio.CancelledError:
                    pass
            if sleep_mgr.state().active:
                await sleep_mgr.cancel()
            if blackout_slot.manager is not None:
                blackout_slot.manager.shutdown()
            await brightness.stop()
            await audio.stop()

        # -- Doc 16 mDNS broadcaster (QR refresh on IP change, Docs 16/17/24) ---
        mdns = MdnsBroadcaster(
            udp_port=config.udp_port,
            ws_port=config.ws_port,
            on_ips_changed=lambda _ips: bridge.publish_qr_refresh(),
        )

        bridge.attach_ws(ws_server)
        register_service(_WiredService(SERVICE_UDP_RECEIVER, _start_udp, _stop_udp))
        register_service(
            _WiredService(
                SERVICE_WS_SERVER,
                lambda: ws_server.start(port=config.ws_port),
                ws_server.stop,
            )
        )
        register_service(_WiredService(SERVICE_MDNS, mdns.start, mdns.stop))
        register_service(_WiredService(SERVICE_TELEMETRY, _start_telemetry, _stop_telemetry))
        register_service(_WiredService(SERVICE_POWER_AUDIO, _start_power, _stop_power))
        register_service(
            _WiredService(SERVICE_TRAY, tray_daemon.start, tray_daemon.stop)
        )
        register_service(_WiredService(SERVICE_GUI, _start_gui, _stop_gui))
    # --------------------------------------------------------------------------

    if not registry.services:
        logger.info("%s up (no services registered)", AGENT_DISPLAY_NAME)
    else:
        logger.info(
            "%s up (%d services; udp=%d ws=%d)",
            AGENT_DISPLAY_NAME,
            len(registry.services),
            config.udp_port,
            config.ws_port,
        )

    started: list[LifecycleService] = []
    for service in registry.services:
        try:
            await service.start()
        except Exception:
            logger.exception("Service %s failed to start; rolling back", service.name)
            await _stop_services(started)
            return 1
        started.append(service)

    restore_sigint = _install_sigint_handler(registry)
    try:
        try:
            async with asyncio.TaskGroup() as group:
                group.create_task(registry.shutdown_event.wait(), name="shutdown-wait")
        except asyncio.CancelledError:
            logger.warning("Hard shutdown requested; skipping graceful wait")
        except ExceptionGroup as exc_group:
            logger.error("idle wait failed: %s", exc_group)
        await _stop_services(started)
    finally:
        restore_sigint()
    logger.info("%s stopped", AGENT_DISPLAY_NAME)
    return 0


def main() -> None:
    """Console/script entry: configure Windows event policy, run run_agent(), map exit code."""
    if sys.version_info < (3, 11):  # noqa: UP036 — deliberate guard for older interpreters
        print(
            f"{AGENT_DISPLAY_NAME} requires Python 3.11+ (running {sys.version.split()[0]})",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if sys.platform != "win32":
        print(f"{AGENT_DISPLAY_NAME} requires Windows (running {sys.platform})", file=sys.stderr)
        raise SystemExit(2)
    if sys.version_info < (3, 14):
        # Proactor is required for subprocess/UDP; on 3.14+ the policy API is
        # deprecated and Proactor is already the Windows default.
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())
    try:
        code = asyncio.run(run_agent())
    except KeyboardInterrupt:
        code = 130
    raise SystemExit(code)


if __name__ == "__main__":
    main()
