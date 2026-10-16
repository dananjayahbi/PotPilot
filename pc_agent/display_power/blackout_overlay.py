"""Doc 12: secondary-monitor blackout overlay manager.

Spawns borderless, pure-black (``#000000``), always-on-top Tkinter windows across
**all non-primary monitors** to kill ambient room glare during night viewing.
Overlays are driven by the WebSocket ``SET_BLACKOUT`` command (Doc 14 routes
:func:`handle_blackout_command`) and by the system-tray quick action (Doc 25
calls :meth:`toggle` directly).

Threading model: ``toggle`` / ``set_enabled`` / ``refresh_monitors`` / ``shutdown``
may be called from the asyncio thread (WS) or the pystray thread — they only flip
the coalesced ``_desired`` flag and enqueue an intent. Tk objects are **never**
touched outside :meth:`_pump`, which runs on the Tk thread via ``root.after`` at
``PUMP_INTERVAL_MS``. The pump drains the queue, diffs the monitor topology
signature, and converges windows to ``_desired`` — so rapid toggles coalesce to
the last intent and never spawn duplicate overlays.

Monitor enumeration is Doc 11's job: the manager receives a
``monitor_provider`` callable (normally ``MonitorSnapper.list_monitors``) and
keeps its notion of "primary" identical to the snapper's by construction.
"""

from __future__ import annotations

import logging
import queue
import threading
import tkinter as tk
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from enum import StrEnum
from typing import NamedTuple

from pc_agent.display_power.monitor_snapper import MonitorInfo

log = logging.getLogger(__name__)

OVERLAY_BG: str = "#000000"  # pure-black fill, fully opaque (Doc 12 §5)
PUMP_INTERVAL_MS: int = 33  # command-pump tick (~30 Hz)

ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"
ERR_UNAVAILABLE: str = "E_UNAVAILABLE"


class _Command(StrEnum):
    """Thread-safe intents queued by foreign threads for the Tk pump."""

    SHOW_ALL = "show_all"
    HIDE_ALL = "hide_all"
    REFRESH = "refresh"
    SHUTDOWN = "shutdown"


class _State(StrEnum):
    """Manager lifecycle: NEW → RUNNING → STOPPED (FAILED skips RUNNING)."""

    NEW = "new"
    RUNNING = "running"
    FAILED = "failed"
    STOPPED = "stopped"


class MonitorSnapshot(NamedTuple):
    """One display's topology tuple used for cheap pump-time diffing."""

    device: str
    rect: tuple[int, int, int, int]
    is_primary: bool


@dataclass(frozen=True, slots=True)
class _Target:
    """Overlay geometry captured at spawn time for rect-change detection."""

    rect: tuple[int, int, int, int]


_active_manager: BlackoutOverlayManager | None = None
"""Process-wide manager surfaced to Doc 14 via :func:`handle_blackout_command`."""


def _create_root() -> tk.Misc:
    """Owned hidden Tk root; monkeypatched in tests (stub Tk factory seam)."""
    return tk.Tk()


def _create_overlay(root: tk.Misc) -> tk.Toplevel:
    """One overlay Toplevel; monkeypatched in tests (stub Tk factory seam)."""
    return tk.Toplevel(root)


def _geometry(rect: tuple[int, int, int, int]) -> str:
    """Build a Tk geometry string; handles negative virtual-desktop origins."""
    left, top, right, bottom = rect
    width = max(1, right - left)
    height = max(1, bottom - top)
    x = f"{'+' if left >= 0 else '-'}{abs(left)}"
    y = f"{'+' if top >= 0 else '-'}{abs(top)}"
    return f"{width}x{height}{x}{y}"


class BlackoutOverlayManager:
    """Show/hide black overlays on every non-primary display, thread-safe."""

    def __init__(
        self,
        monitor_provider: Callable[[], Sequence[MonitorInfo]],
        root: tk.Misc | None = None,
    ) -> None:
        """Bind the Doc-11 monitor source; optionally adopt a shared Tk root."""
        self._monitor_provider = monitor_provider
        self._injected_root = root
        self._root: tk.Misc | None = root
        self._owns_root = False
        self._root_destroyed = False
        self._state = _State.NEW
        self._tk_thread_id: int | None = None
        self._desired = False
        self._shutdown_requested = False
        self._lock = threading.Lock()
        self._commands: queue.Queue[_Command] = queue.Queue()
        self._built: dict[str, tk.Toplevel] = {}
        self._built_targets: dict[str, _Target] = {}
        self._signature: tuple[MonitorSnapshot, ...] = ()

    # ------------------------------------------------------------ lifecycle

    def start(self) -> None:
        """Create/adopt the Tk root and start the pump loop; idempotent."""
        with self._lock:
            if self._state is not _State.NEW:
                return
            try:
                root = self._root if self._root is not None else _create_root()
                if self._injected_root is None:
                    root.withdraw()  # owned root stays hidden; the shared
                    # dashboard root keeps its own visibility state (Doc 24 §4)
                root.after(PUMP_INTERVAL_MS, self._pump)
            except Exception as exc:  # Tk init failure (non-interactive session)
                log.warning("blackout overlay Tk init failed; degrading to no-op: %s", exc)
                self._state = _State.FAILED
                return
            self._root = root
            self._owns_root = self._injected_root is None
            self._tk_thread_id = threading.get_ident()
            self._state = _State.RUNNING
        global _active_manager
        _active_manager = self
        log.debug("blackout overlay manager started (pump every %d ms)", PUMP_INTERVAL_MS)

    def shutdown(self) -> None:
        """Destroy all overlays (+ owned root); safe to call twice."""
        with self._lock:
            self._desired = False
            if self._state is _State.NEW:
                self._state = _State.STOPPED
        self._commands.put(_Command.SHUTDOWN)
        running = self._state is _State.RUNNING
        on_tk_thread = (
            self._tk_thread_id is not None and threading.get_ident() == self._tk_thread_id
        )
        if running and on_tk_thread:
            # On the Tk thread the teardown is immediate so process exit can
            # rely on it; foreign threads converge via the next pump tick.
            self._drain_commands()
            self._teardown()

    @property
    def is_active(self) -> bool:
        """True while overlays are (or are converging to be) shown."""
        if self._state is not _State.RUNNING:
            return False
        with self._lock:
            desired = self._desired
        return desired and self._target_count() > 0

    # ------------------------------------------------------------- commands

    def toggle(self) -> bool:
        """Flip blackout state; return the new enabled flag (False if no targets)."""
        if self._state is not _State.RUNNING:
            return False
        if self._target_count() == 0:
            # Doc 12 §7: no non-primary monitors — no-op, creates zero windows.
            log.info("blackout toggle ignored: no non-primary monitors connected")
            return False
        with self._lock:
            self._desired = not self._desired
            enabled = self._desired
            self._commands.put(_Command.SHOW_ALL if enabled else _Command.HIDE_ALL)
        return enabled

    def set_enabled(self, enabled: bool) -> bool:
        """Idempotently show/hide all non-primary overlays; return actual state."""
        if self._state is not _State.RUNNING:
            return False
        with self._lock:
            self._desired = bool(enabled)
            self._commands.put(_Command.SHOW_ALL if enabled else _Command.HIDE_ALL)
        return bool(enabled) and self._target_count() > 0

    def refresh_monitors(self) -> None:
        """Rebuild overlays if the display topology changed (requeues a diff)."""
        if self._state is not _State.RUNNING:
            return
        self._commands.put(_Command.REFRESH)

    # --------------------------------------------------------------- pump

    def _pump(self) -> None:
        """Tk-thread tick: drain intents, diff topology, converge to _desired."""
        if self._state is not _State.RUNNING:
            return
        try:
            self._drain_commands()
            if self._shutdown_requested:
                self._teardown()
                return
            try:
                monitors = tuple(self._monitor_provider())
            except Exception:
                log.debug("monitor provider failed during pump", exc_info=True)
                monitors = None
            if monitors is not None:
                signature = tuple(
                    MonitorSnapshot(m.device, m.rect, m.is_primary) for m in monitors
                )
                if signature != self._signature:
                    log.debug("blackout monitor topology changed: %d display(s)", len(monitors))
                    self._signature = signature
                self._converge(monitors)
        except tk.TclError:
            # Root/window torn down externally (GUI exit); swallow per Doc 12 §7.
            log.debug("TclError inside blackout pump tick", exc_info=True)
        except Exception:
            log.exception("blackout pump tick failed")
        finally:
            self._reschedule()

    def _reschedule(self) -> None:
        if self._state is not _State.RUNNING or self._root is None:
            return
        try:
            self._root.after(PUMP_INTERVAL_MS, self._pump)
        except Exception:
            log.debug("cannot reschedule blackout pump; stopping", exc_info=True)
            self._state = _State.STOPPED

    def _drain_commands(self) -> None:
        """Consume queued intents; SHOW/HIDE are wake-ups only (see below)."""
        while True:
            try:
                command = self._commands.get_nowait()
            except queue.Empty:
                return
            if command is _Command.SHUTDOWN:
                self._shutdown_requested = True

    def _converge(self, monitors: Sequence[MonitorInfo]) -> None:
        """Diff targets against windows; the queue never decides — _desired does.

        Because intents are drained *before* convergence, a SHOW followed by a
        HIDE before one tick ends hidden with zero transient windows (Doc 12 §9).
        """
        targets: dict[str, MonitorInfo] = {}
        for info in monitors:
            if info.is_primary:
                continue  # primary monitor stays untouched (Doc 12 §4.1)
            targets[self._key(info)] = info

        with self._lock:
            desired = self._desired

        if not desired:
            for key in list(self._built):
                self._destroy(key)
            return

        for key, target in list(self._built_targets.items()):
            current = targets.get(key)
            if current is None or current.rect != target.rect:
                self._destroy(key)  # unplug / orientation / primary-flag change
        for key, info in targets.items():
            if key not in self._built:
                self._spawn(key, info)

    # ------------------------------------------------------------- windows

    @staticmethod
    def _key(info: MonitorInfo) -> str:
        return info.device or f"monitor-{info.index}"

    def _spawn(self, key: str, info: MonitorInfo) -> None:
        root = self._root
        if root is None:  # pragma: no cover - defensive
            return
        window = _create_overlay(root)
        try:
            window.overrideredirect(True)  # no border, no title bar
            window.geometry(_geometry(info.rect))
            window.configure(bg=OVERLAY_BG)
            window.attributes("-topmost", True)  # above normal topmost windows
        except Exception:
            try:
                window.destroy()
            except Exception:  # pragma: no cover - best-effort cleanup
                pass
            raise
        self._built[key] = window
        self._built_targets[key] = _Target(rect=info.rect)
        log.debug("blackout overlay spawned on %s (%s)", key, info.rect)

    def _destroy(self, key: str) -> None:
        window = self._built.pop(key, None)
        self._built_targets.pop(key, None)
        if window is None:
            return
        try:
            window.destroy()
        except Exception:
            log.debug("overlay %s already gone at destroy time", key, exc_info=True)

    def _teardown(self) -> None:
        """Destroy overlays, stop the pump, destroy the root only if owned."""
        with self._lock:
            if self._state is _State.STOPPED:
                return
            self._state = _State.STOPPED
            self._desired = False
            self._shutdown_requested = False
        while True:  # drop any intents queued between shutdown() and here
            try:
                self._commands.get_nowait()
            except queue.Empty:
                break
        for key in list(self._built):
            self._destroy(key)
        global _active_manager
        if _active_manager is self:
            _active_manager = None
        if self._owns_root and self._root is not None and not self._root_destroyed:
            self._root_destroyed = True
            try:
                self._root.destroy()
            except Exception:
                log.debug("owned Tk root already destroyed", exc_info=True)
        log.debug("blackout overlay manager shut down")

    def _target_count(self) -> int:
        try:
            return sum(1 for info in self._monitor_provider() if not info.is_primary)
        except Exception:
            log.debug("monitor provider failed while counting targets", exc_info=True)
            return 0


def handle_blackout_command(payload: dict) -> dict:
    """WS action adapter for ``CMD_SYSTEM``/``SET_BLACKOUT`` (registered by Doc 14).

    Payload shape is the frozen Doc 03 §5.5 registry: ``{"enabled": bool}``.
    Returns Doc 14 handler results merged into the ``SET_BLACKOUT_RESULT`` ack;
    failures come back as ``ok: false`` payloads instead of raising (Doc 14 §7).
    """
    if not isinstance(payload, dict) or type(payload.get("enabled")) is not bool:
        return {
            "ok": False,
            "error": ERR_BAD_PAYLOAD,
            "detail": 'SET_BLACKOUT payload must be {"enabled": bool}',
        }
    manager = _active_manager
    if manager is None:
        return {
            "ok": False,
            "error": ERR_UNAVAILABLE,
            "detail": "blackout overlay manager is not running",
        }
    enabled = manager.set_enabled(bool(payload["enabled"]))
    return {"ok": True, "enabled": enabled}
