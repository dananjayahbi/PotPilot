"""Doc 11: focus-neutral multi-monitor window snapper for PotPlayer.

Enumerates every active display with ``win32api.EnumDisplayMonitors``, identifies
the display Windows flags as primary (A1: that is the bedroom screen), and moves /
maximizes the PotPlayer window onto it using only no-activate positioning and
posted ``WM_SYSCOMMAND`` messages — the phone's foreground app keeps focus
throughout. Every operation re-enumerates displays (hot-plug and "make this my
main display" changes apply on the next command), and a snap that finds the
window already in the desired state short-circuits without a single window move.

Out of scope here: blackout overlays on the non-primary displays (Doc 12),
DDC/CI brightness (Doc 19), HWND discovery (Doc 08 owns the locator this module
is handed), and launch-time auto-snap (Doc 21 calls :meth:`snap_to_primary`).
"""

from __future__ import annotations

import ctypes
import logging
import time
from dataclasses import dataclass

import win32api
import win32gui

from pc_agent.potplayer.hwnd_locator import PotPlayerLocator

log = logging.getLogger(__name__)

MONITOR_TARGET_PRIMARY: str = "primary"
"""Reserved ``display.target`` config value (Doc 26); the v1 default and only mode."""

SWP_FLAGS_NO_ACTIVATE: int = 0x0010 | 0x0004 | 0x0040  # SWP_NOACTIVATE|SWP_NOZORDER|SWP_SHOWWINDOW

# Win32 constants (Doc 11 §5) — declared locally so this module's dependency
# surface stays win32api + win32gui only.
MONITORINFOF_PRIMARY: int = 0x1
WM_SYSCOMMAND: int = 0x0112
SC_MAXIMIZE: int = 0xF030
SC_RESTORE: int = 0xF120
SWP_NOACTIVATE: int = 0x0010
SWP_NOZORDER: int = 0x0004

_INVALID_WINDOW_HANDLE: int = 1400  # WinError 1400 — hwnd died mid-operation
_RESTORE_TIMEOUT_S: float = 0.100  # post-SC_RESTORE settle budget (Doc 11 §4.3)
_RESTORE_POLL_S: float = 0.010
_VERIFY_TIMEOUT_S: float = 0.100  # post-move verification budget (Doc 11 §4.7)
_VERIFY_POLL_S: float = 0.010

# The only flags ever passed to SetWindowPos: never activate, never restack.
_MOVE_FLAGS: int = SWP_NOACTIVATE | SWP_NOZORDER


@dataclass(frozen=True, slots=True)
class MonitorInfo:
    """Immutable snapshot of one display in virtual-desktop coordinates."""

    index: int
    rect: tuple[int, int, int, int]  # (left, top, right, bottom)
    work_rect: tuple[int, int, int, int]  # excludes taskbar
    is_primary: bool
    device: str = ""  # e.g. \\.\DISPLAY1 — Doc 12 keys overlays by this


@dataclass(frozen=True, slots=True)
class SnapResult:
    """Immutable outcome of one snap operation."""

    ok: bool
    hwnd: int | None
    monitor: MonitorInfo | None
    detail: str  # "snapped" | "already_snapped" | "no_window" | "monitor_lost" | "verify_failed"


def _as_rect(value: object) -> tuple[int, int, int, int]:
    left, top, right, bottom = value  # type: ignore[misc]
    return int(left), int(top), int(right), int(bottom)


def _is_zoomed(hwnd: int) -> bool:
    """user32!IsZoomed via ctypes — pywin32 exposes no IsZoomed wrapper."""
    try:
        return bool(ctypes.windll.user32.IsZoomed(ctypes.c_void_p(hwnd)))
    except (AttributeError, OSError):  # pragma: no cover - depends on host DLLs
        return False


class MonitorSnapper:
    """Move/maximize PotPlayer onto the primary display without focus theft."""

    def __init__(self, locator: PotPlayerLocator) -> None:
        """Bind the shared PotPlayer locator; no Win32 call at construction."""
        self._locator = locator

    # ---------------------------------------------------------- enumeration

    def list_monitors(self) -> list[MonitorInfo]:
        """Fresh enumeration of all active displays (never cached across calls)."""
        monitors: list[MonitorInfo] = []
        for index, entry in enumerate(win32api.EnumDisplayMonitors()):
            hmon = entry[0]
            info = win32api.GetMonitorInfo(hmon)
            monitors.append(
                MonitorInfo(
                    index=index,
                    rect=_as_rect(info["Monitor"]),
                    work_rect=_as_rect(info["Work"]),
                    is_primary=bool(info.get("Flags", 0) & MONITORINFOF_PRIMARY),
                    device=str(info.get("Device", "")),
                )
            )
        return monitors

    def primary_monitor(self) -> MonitorInfo | None:
        """The display flagged MONITORINFOF_PRIMARY (the bedroom screen), else None."""
        return next((m for m in self.list_monitors() if m.is_primary), None)

    def is_on_primary(self, hwnd: int, *, tol_px: int = 8) -> bool:
        """True if the window's center lies inside the primary monitor rect (±tol)."""
        primary = self.primary_monitor()
        if primary is None:
            return False
        left, top, right, bottom = win32gui.GetWindowRect(hwnd)
        cx = (left + right) // 2
        cy = (top + bottom) // 2
        p_left, p_top, p_right, p_bottom = primary.rect
        return (
            p_left - tol_px <= cx <= p_right + tol_px
            and p_top - tol_px <= cy <= p_bottom + tol_px
        )

    # ------------------------------------------------------------- snapping

    def snap_to_primary(self, *, maximize: bool = True) -> SnapResult:
        """Move (and optionally maximize) PotPlayer onto the primary display.

        Focus-neutral by construction: only SWP_NOACTIVATE moves and posted
        WM_SYSCOMMAND messages are used, so the foreground window never changes.
        """
        hwnd = self._locator.find()
        if hwnd is None:
            return SnapResult(ok=False, hwnd=None, monitor=None, detail="no_window")
        primary = self.primary_monitor()
        if primary is None:
            # Doc 11 A2: no primary flag is an OS misconfiguration — do not guess.
            return SnapResult(ok=False, hwnd=hwnd, monitor=None, detail="monitor_lost")
        try:
            if win32gui.IsIconic(hwnd):
                # Restore lands on the window's current monitor; the move below
                # then brings it to the primary — never left stranded on a dark
                # secondary display.
                self._post_syscommand(hwnd, SC_RESTORE)
                self._wait_restored(hwnd)

            on_primary = self.is_on_primary(hwnd)
            zoomed = _is_zoomed(hwnd)
            if on_primary and zoomed == maximize:
                # Idempotent short-circuit (Doc 11 §4.4): no moves, no posts.
                return SnapResult(ok=True, hwnd=hwnd, monitor=primary, detail="already_snapped")

            if zoomed and (not on_primary or not maximize):
                # Un-maximize before SetWindowPos: a zoomed window's restored-rect
                # bookkeeping makes direct moves unreliable (Doc 11 §4.3/§4.6).
                self._post_syscommand(hwnd, SC_RESTORE)
                self._wait_restored(hwnd)

            left, top, right, bottom = primary.rect if maximize else primary.work_rect
            win32gui.SetWindowPos(
                hwnd, 0, left, top, right - left, bottom - top, _MOVE_FLAGS
            )
            if maximize:
                # Background/async: PotPlayer applies it to its own queue.
                self._post_syscommand(hwnd, SC_MAXIMIZE)

            if self._verify(hwnd):
                return SnapResult(ok=True, hwnd=hwnd, monitor=primary, detail="snapped")
            # Window manager overrode us (e.g. re-placed a fullscreen window).
            return SnapResult(ok=False, hwnd=hwnd, monitor=primary, detail="verify_failed")
        except win32gui.error as exc:
            return self._dead_window_result(hwnd, exc, getattr(exc, "winerror", None))
        except OSError as exc:
            code = getattr(exc, "winerror", None)
            if code is None:
                code = exc.errno
            if code != _INVALID_WINDOW_HANDLE:
                raise
            return self._dead_window_result(hwnd, exc, code)

    # ------------------------------------------------------------ internals

    def _dead_window_result(
        self, hwnd: int, exc: BaseException, code: int | None
    ) -> SnapResult:
        """hwnd died mid-operation (WinError 1400): structured no_window, no raise."""
        log.debug("PotPlayer hwnd %s vanished mid-snap (WinError %s): %s", hwnd, code, exc)
        self._locator.invalidate()
        return SnapResult(ok=False, hwnd=hwnd, monitor=None, detail="no_window")

    @staticmethod
    def _post_syscommand(hwnd: int, command: int) -> None:
        """Queue a system command without activating or waiting on the target."""
        win32gui.PostMessage(hwnd, WM_SYSCOMMAND, command, 0)

    @staticmethod
    def _wait_restored(hwnd: int) -> None:
        """Poll IsIconic ≤100 ms in 10 ms steps after SC_RESTORE (Doc 11 §4.3)."""
        deadline = time.monotonic() + _RESTORE_TIMEOUT_S
        while win32gui.IsIconic(hwnd):
            if time.monotonic() >= deadline:
                log.debug("hwnd %s still minimized after restore window; continuing", hwnd)
                return
            time.sleep(_RESTORE_POLL_S)

    def _verify(self, hwnd: int) -> bool:
        """Within ≤100 ms: visible and centered on the primary display (±8 px)."""
        deadline = time.monotonic() + _VERIFY_TIMEOUT_S
        while True:
            if win32gui.IsWindowVisible(hwnd) and self.is_on_primary(hwnd):
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(_VERIFY_POLL_S)
