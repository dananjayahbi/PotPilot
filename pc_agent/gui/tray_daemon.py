"""PotPilot system-tray background daemon (Doc 25).

Runs the ``pystray`` icon on its own daemon thread (``T2``) so closing the
Doc 24 dashboard never kills the agent: sockets, mDNS and telemetry keep
running while the GUI hides. The four frozen menu actions ("Show QR",
"Toggle Blackout", "Run on Startup", "Exit") cross into other modules only
through the injected :class:`TrayActions` callables — no logic from Docs
12/17/24/26 is duplicated here, and ``dashboard_window.py`` is never
imported: ``TrayActions.show_qr`` is the show/focus seam (``main.py`` wraps
it with ``root.after``), ``note_dashboard_hidden()`` is the one-shot
minimize-to-tray balloon seam. ``main.py`` owns the network/GUI shutdown
phases; this module owns the tray-side phases of the 5-phase exit: the
``exiting`` flag (phase 1), ``icon.stop()`` (phase 4) and the 5 s watchdog
(phase 5).
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import pystray
from PIL import Image, ImageDraw, ImageFont

from pc_agent.core.config_manager import ConfigManager, StartupRegistrationError

logger = logging.getLogger("potpilot.gui.tray_daemon")

TRAY_ICON_TITLE: str = "PotPilot"  # Shell tooltip base (Doc 25 §3)
STARTUP_MENU_LABEL: str = "Run on Startup"  # frozen menu label (Doc 25 §3)
TRAY_ICON_NAME: str = "potpilot"  # pystray Icon id
DEBOUNCE_S: float = 0.3  # rapid double-click window for the two toggles (Doc 25 §7)
HARD_EXIT_S: float = 5.0  # phase-5 watchdog cap (Doc 25 §4)

_SHOW_QR_LABEL = "Show QR"
_TOGGLE_BLACKOUT_LABEL = "Toggle Blackout"
_EXIT_LABEL = "Exit"

_CRIMSON = (220, 20, 60, 255)  # idle accent for the fallback glyph (Doc 25 §5)
_WHITE = (255, 255, 255, 255)

_TOGGLE_ACTION_IDS = frozenset({"blackout", "startup"})


@dataclass(frozen=True)
class TrayActions:
    """Injected menu callbacks; ``main.py`` wraps them with the Tk/asyncio hops (Doc 25 §3)."""

    show_qr: Callable[[], None]  # raise dashboard QR panel (main wraps with root.after)
    toggle_blackout: Callable[[], bool]  # flips Doc 12 overlay; returns new active state
    toggle_startup: Callable[[], bool]  # flips HKCU Run entry via ConfigManager; returns new state
    exit_app: Callable[[], None]  # requests coordinated shutdown (main.py)


@dataclass(frozen=True)
class TrayMenuEntry:
    """One planned menu row; callables are re-queried lazily so check marks stay live."""

    label: str
    action_id: str | None  # "show_qr" | "blackout" | "startup" | "exit"
    checked: Callable[[], bool] | None
    enabled: Callable[[], bool] | None
    is_separator: bool


class TrayState:
    """Mutable tray state guarded by one lock (Doc 25 §4.3).

    Reducers flip booleans atomically from any thread (T2 menu dispatch,
    T1 connection events); pystray's lazy ``checked``/``enabled`` callables
    read the mirrored values on every menu render.
    """

    def __init__(self, startup_enabled: bool = False, blackout_active: bool = False) -> None:
        self._lock = threading.Lock()
        self._startup_enabled = bool(startup_enabled)
        self._blackout_active = bool(blackout_active)
        self._connected = False
        self._device_ip: str | None = None
        self._exiting = False
        self._hide_notified = False
        self._last_toggle: dict[str, float] = {}

    # ------------------------------------------------------------------ readers

    @property
    def startup_enabled(self) -> bool:
        """Mirrored ``config.run_on_startup`` check-mark source."""
        with self._lock:
            return self._startup_enabled

    @property
    def blackout_active(self) -> bool:
        """Mirrored Doc 12 overlay state."""
        with self._lock:
            return self._blackout_active

    @property
    def exiting(self) -> bool:
        """True once Exit was requested; menu items disable themselves."""
        with self._lock:
            return self._exiting

    @property
    def connected(self) -> bool:
        """True while a phone is paired/connected."""
        with self._lock:
            return self._connected

    @property
    def device_ip(self) -> str | None:
        """Connected phone IP, if any."""
        with self._lock:
            return self._device_ip

    @property
    def tooltip(self) -> str:
        """``PotPilot · <ip>`` while paired, base title otherwise (Doc 25 §5)."""
        with self._lock:
            return self._tooltip_locked()

    def _tooltip_locked(self) -> str:
        if self._connected and self._device_ip:
            return f"{TRAY_ICON_TITLE} · {self._device_ip}"
        return TRAY_ICON_TITLE

    # ----------------------------------------------------------------- reducers

    def toggle_blackout(self) -> bool:
        """Flip blackout state atomically; return the new active flag."""
        with self._lock:
            self._blackout_active = not self._blackout_active
            return self._blackout_active

    def set_blackout(self, active: bool) -> bool:
        """Mirror the Doc 12 toggle result; return the stored flag."""
        with self._lock:
            self._blackout_active = bool(active)
            return self._blackout_active

    def toggle_startup(self) -> bool:
        """Flip the startup check mark atomically; return the new flag."""
        with self._lock:
            self._startup_enabled = not self._startup_enabled
            return self._startup_enabled

    def set_startup(self, enabled: bool) -> bool:
        """Mirror ``config.run_on_startup`` (success, revert or external sync)."""
        with self._lock:
            self._startup_enabled = bool(enabled)
            return self._startup_enabled

    def set_connection(self, connected: bool, device_ip: str | None) -> str:
        """Rewrite connection state + tooltip; return the new tooltip text."""
        with self._lock:
            self._connected = bool(connected)
            ip = (device_ip or "").strip() if connected else ""
            self._device_ip = ip or None
            return self._tooltip_locked()

    def mark_exiting(self) -> None:
        """Phase 1 of shutdown: freeze the menu via lazy ``enabled`` callables."""
        with self._lock:
            self._exiting = True

    def allow_action(self, action_id: str, now: float | None = None) -> bool:
        """300 ms debounce for the two toggles; other actions always pass (Doc 25 §7).

        Timestamps are recorded only when a click is allowed, so a dropped
        click never extends the window of the one that was accepted.
        """
        if action_id not in _TOGGLE_ACTION_IDS:
            return True
        stamp = time.monotonic() if now is None else now
        with self._lock:
            last = self._last_toggle.get(action_id)
            if last is not None and stamp - last < DEBOUNCE_S:
                return False
            self._last_toggle[action_id] = stamp
            return True

    def consume_hide_notice(self) -> bool:
        """True exactly once per session — the first-minimize balloon guard (Doc 25 §4.6)."""
        with self._lock:
            if self._hide_notified:
                return False
            self._hide_notified = True
            return True


def _separator() -> TrayMenuEntry:
    """Inert divider row (rendered as ``pystray.Menu.SEPARATOR``)."""
    return TrayMenuEntry(label="", action_id=None, checked=None, enabled=None, is_separator=True)


def build_menu_spec(state: TrayState) -> list[TrayMenuEntry]:
    """Pure planner for the frozen menu tree (Doc 25 §4, exact order):

    ``Show QR · Toggle Blackout · ── · Run on Startup · ── · Exit``

    Every action is enabled unless the daemon is exiting; check marks read
    ``state`` lazily so the shell repaints them after each toggle without
    rebuilding the ``Menu`` object.
    """

    def _enabled() -> bool:
        return not state.exiting

    def _blackout_checked() -> bool:
        return state.blackout_active

    def _startup_checked() -> bool:
        return state.startup_enabled

    return [
        TrayMenuEntry(_SHOW_QR_LABEL, "show_qr", None, _enabled, False),
        TrayMenuEntry(_TOGGLE_BLACKOUT_LABEL, "blackout", _blackout_checked, _enabled, False),
        _separator(),
        TrayMenuEntry(STARTUP_MENU_LABEL, "startup", _startup_checked, _enabled, False),
        _separator(),
        TrayMenuEntry(_EXIT_LABEL, "exit", None, _enabled, False),
    ]


def fallback_icon(size: int = 32) -> Image.Image:
    """PIL-drawn crimson rounded square with a white "P" glyph (Doc 25 §7 asset fallback)."""
    extent = max(1, size)
    image = Image.new("RGBA", (extent, extent), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        (0, 0, extent - 1, extent - 1),
        radius=max(2, extent // 5),
        fill=_CRIMSON,
    )
    try:
        font = ImageFont.load_default(size=max(8, extent // 2))
    except TypeError:  # Pillow < 10.1 has no size parameter
        font = ImageFont.load_default()
    glyph = "P"
    left, top, right, bottom = draw.textbbox((0, 0), glyph, font=font)
    position = ((extent - (right - left)) / 2 - left, (extent - (bottom - top)) / 2 - top)
    draw.text(position, glyph, font=font, fill=_WHITE)
    return image


def _lazy_getter(read: Callable[[], bool]) -> Callable[[Any], bool]:
    """Adapt a zero-arg spec callable to pystray's ``(item)`` callback protocol."""

    def _read(_item: Any) -> bool:
        return bool(read())

    return _read


class TrayDaemon:
    """``pystray`` icon on its own daemon thread — the process-lifetime anchor (Doc 25).

    Threading: ``start()`` spawns daemon thread ``T2`` which blocks inside
    ``Icon.run()`` (Windows message pump owned by T2, never the Tk thread).
    T2 only calls the injected :class:`TrayActions` and :class:`TrayState`;
    Tk hops and asyncio submits happen inside ``main.py``'s wrappers (Doc 25 §4).
    """

    def __init__(
        self,
        config: ConfigManager,
        actions: TrayActions,
        icon_factory: Callable[[], Image.Image],
    ) -> None:
        """``config``: ConfigManager (26); ``icon_factory``: 32×32 tray icon."""
        self._config = config
        self._actions = actions
        self._icon_factory = icon_factory
        self._state = TrayState(startup_enabled=self._read_startup())
        self._lock = threading.Lock()
        self._icon: Any | None = None
        self._thread: threading.Thread | None = None
        self._started = False
        self._stopped = False
        self._restarted = False
        self._watchdog: threading.Timer | None = None

    # ----------------------------------------------------------------- lifecycle

    def start(self) -> None:
        """Spawn the daemon thread running ``icon.run()``; idempotent while alive."""
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._started = True
            self._stopped = False
            self._icon = self._create_icon()
            thread = threading.Thread(
                target=self._run_icon,
                args=(self._icon,),
                name="potpilot-tray",
                daemon=True,
            )
            self._thread = thread
            thread.start()

    def stop(self, timeout_s: float = 3.0) -> None:
        """``icon.stop()`` + bounded join; safe twice and before ``start()`` (Doc 25 §3)."""
        with self._lock:
            icon = self._icon
            thread = self._thread
            self._stopped = True
        self._cancel_watchdog()  # clean stop retires the phase-5 watchdog
        if icon is not None:
            try:
                icon.stop()
            except Exception:
                logger.debug("icon.stop() raised", exc_info=True)
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout_s)
            if thread.is_alive():
                logger.warning("tray icon thread still alive after %.1fs join", timeout_s)

    @property
    def alive(self) -> bool:
        """True while the icon thread runs (Doc 24 uses it for the close decision)."""
        thread = self._thread
        return thread is not None and thread.is_alive()

    # ------------------------------------------------------------------ updates

    def set_connection(self, connected: bool, device_ip: str | None) -> None:
        """Update tooltip/title (thread-safe); probe-restart a dead icon thread once."""
        tooltip = self._state.set_connection(connected, device_ip)
        icon = self._icon
        if icon is not None:
            try:
                icon.title = tooltip
            except Exception:
                logger.debug("cannot update tray tooltip", exc_info=True)
        exiting = self._state.exiting
        with self._lock:
            restart = (
                self._started
                and not self._stopped
                and not self._restarted
                and not exiting
                and (self._thread is None or not self._thread.is_alive())
            )
            if restart:
                self._restarted = True
        if restart:
            logger.warning("tray icon thread not running; restarting it once")
            self.start()

    def notify(self, title: str, message: str) -> None:
        """Balloon notification, best-effort; swallows Focus-Assist/backend failures."""
        icon = self._icon
        if icon is None:
            return
        try:
            icon.notify(message, title)
        except Exception:
            logger.debug("balloon notification failed", exc_info=True)

    def refresh(self) -> None:
        """Re-mirror ``config.run_on_startup`` and repaint the menu (Doc 25 §7 seam)."""
        self._state.set_startup(self._read_startup())
        icon = self._icon
        if icon is not None:
            try:
                icon.update_menu()
            except Exception:
                logger.debug("menu repaint failed", exc_info=True)

    def note_dashboard_hidden(self) -> bool:
        """Fire the once-per-session "still running" balloon after a minimize-to-tray.

        Called by the Doc 24 dashboard (through ``main.py``) right after
        ``hide()``. Guarded by ``minimize_to_tray`` so silent-startup users
        are never nagged; returns True only when a balloon was requested
        (Doc 25 §4.6).
        """
        if not self._read_minimize_to_tray():
            return False
        if not self._state.consume_hide_notice():
            return False
        self.notify(TRAY_ICON_TITLE, "PotPilot is still running — use the tray icon")
        return True

    # ------------------------------------------------------------------ internals

    def _create_icon(self) -> Any:
        """Build the pystray Icon; a failing factory falls back to the PIL glyph."""
        try:
            image = self._icon_factory()
        except Exception:
            logger.warning("icon factory failed; using fallback glyph", exc_info=True)
            image = fallback_icon()
        return pystray.Icon(
            TRAY_ICON_NAME,
            image,
            title=self._state.tooltip,
            menu=self._build_menu(),
        )

    def _build_menu(self) -> Any:
        """Convert the pure menu spec into pystray objects with lazy callables."""
        items: list[Any] = []
        for entry in build_menu_spec(self._state):
            if entry.is_separator:
                items.append(pystray.Menu.SEPARATOR)
                continue
            action_id = entry.action_id or ""
            items.append(
                pystray.MenuItem(
                    entry.label,
                    self._menu_handler(action_id),
                    checked=_lazy_getter(entry.checked) if entry.checked else None,
                    enabled=_lazy_getter(entry.enabled) if entry.enabled else True,
                    # left/double-click on the icon activates Show QR (Doc 25 §4.5)
                    default=action_id == "show_qr",
                )
            )
        return pystray.Menu(*items)

    def _menu_handler(self, action_id: str) -> Callable[[Any, Any], None]:
        """Two-arg handler matching pystray's ``action(icon, item)`` protocol."""

        def _handler(_icon: Any, _item: Any) -> None:
            self._dispatch(action_id)

        return _handler

    def _run_icon(self, icon: Any) -> None:
        """T2 body: block in the pystray message pump until ``stop()``."""
        try:
            icon.run()
        except Exception:
            # Backend unavailable → alive goes False with this thread; the
            # agent keeps running windowed-only (Doc 25 §7).
            logger.warning("tray icon loop failed; continuing without a tray icon", exc_info=True)

    def _dispatch(self, action_id: str) -> None:
        """Run one menu action (arrives on T2); re-mirror config first (Doc 25 §7)."""
        self._state.set_startup(self._read_startup())
        if action_id == "show_qr":
            try:
                self._actions.show_qr()
            except Exception:
                logger.exception("Show QR action failed")
        elif action_id == "blackout":
            self._dispatch_toggle_blackout()
        elif action_id == "startup":
            self._dispatch_toggle_startup()
        elif action_id == "exit":
            self._dispatch_exit()

    def _dispatch_toggle_blackout(self) -> None:
        """Doc 12 internal toggle; mirror state and confirm with a balloon."""
        if not self._state.allow_action("blackout"):
            return
        try:
            active = bool(self._actions.toggle_blackout())
        except Exception:
            logger.exception("Toggle Blackout action failed")
            return
        self._state.set_blackout(active)
        self.notify(TRAY_ICON_TITLE, "Blackout on" if active else "Blackout off")

    def _dispatch_toggle_startup(self) -> None:
        """Doc 26 HKCU Run sync; revert the check mark and balloon on denial."""
        if not self._state.allow_action("startup"):
            return
        try:
            enabled = bool(self._actions.toggle_startup())
        except StartupRegistrationError as exc:
            logger.warning("could not update startup entry: %s", exc)
            self._state.set_startup(self._read_startup())
            self.notify(TRAY_ICON_TITLE, "Could not update startup entry")
        except Exception:
            logger.exception("Run on Startup action failed")
            self._state.set_startup(self._read_startup())
            self.notify(TRAY_ICON_TITLE, "Could not update startup entry")
        else:
            self._state.set_startup(enabled)

    def _dispatch_exit(self) -> None:
        """Phase 1: freeze the menu, arm the phase-5 watchdog, request shutdown."""
        self._state.mark_exiting()
        # Arm before exit_app() so even a hung coordinator dies within HARD_EXIT_S.
        self._arm_watchdog()
        try:
            self._actions.exit_app()
        except Exception:
            logger.exception("Exit action failed")

    def _arm_watchdog(self) -> None:
        """Phase 5: ``os._exit(0)`` at t=5 s if the process is still alive (Doc 25 §4)."""
        with self._lock:
            if self._watchdog is not None and self._watchdog.is_alive():
                return
            timer = threading.Timer(HARD_EXIT_S, self._hard_exit)
            timer.daemon = True
            self._watchdog = timer
            timer.start()

    def _cancel_watchdog(self) -> None:
        with self._lock:
            timer, self._watchdog = self._watchdog, None
        if timer is not None:
            timer.cancel()

    @staticmethod
    def _hard_exit() -> None:
        logger.error("shutdown watchdog fired after %.0fs; forcing process exit", HARD_EXIT_S)
        os._exit(0)

    def _read_startup(self) -> bool:
        try:
            return bool(self._config.get().run_on_startup)
        except Exception:
            logger.warning("cannot read run_on_startup from config", exc_info=True)
            return False

    def _read_minimize_to_tray(self) -> bool:
        try:
            return bool(self._config.get().minimize_to_tray)
        except Exception:
            logger.warning("cannot read minimize_to_tray from config", exc_info=True)
            return True  # Doc 26 default
