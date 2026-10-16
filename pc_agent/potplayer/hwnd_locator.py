"""Doc 08: focus-neutral PotPlayer window discovery and process-health service.

Finds the live ``PotPlayer64`` / ``PotPlayer`` main window handle, caches it with its
process id under a short TTL, and validates the cache cheaply on every use. This module
never changes window state: discovery is strictly read-only (no activation, no focus
change, no visibility change), which keeps the WS/UDP hot paths from flashing PotPlayer
to the front while the phone drives playback.
"""

from __future__ import annotations

import ctypes
import logging
import threading
import time
from dataclasses import dataclass

import win32api
import win32con
import win32gui
import win32process

log = logging.getLogger(__name__)

WINDOW_CLASSES: tuple[str, ...] = ("PotPlayer64", "PotPlayer")
"""Window class names probed in order; "PotPlayer64" is the shipping 64-bit build."""

DEFAULT_CACHE_TTL_MS: int = 500
"""Hot-path cache budget: within the TTL a find() costs IsWindow + one class check."""

STILL_ACTIVE: int = 259
"""Win32 process exit code for a still-running process."""

_DWMWA_CLOAKED = 14
_CLASS_PREFIX = "potplayer"


@dataclass(frozen=True)
class WindowInfo:
    """Immutable snapshot of a located window."""

    hwnd: int
    pid: int
    class_name: str
    is_minimized: bool
    found_at: float  # time.time() seconds


def _is_cloaked(hwnd: int) -> bool:
    """Best-effort DWMWA_CLOAKED probe; any failure means 'not cloaked'."""
    try:
        cloaked = ctypes.c_uint(0)
        hr = ctypes.windll.dwmapi.DwmGetWindowAttribute(
            hwnd, _DWMWA_CLOAKED, ctypes.byref(cloaked), ctypes.sizeof(cloaked)
        )
        return bool(hr == 0 and cloaked.value)
    except (AttributeError, OSError):  # pragma: no cover - depends on host DWM
        return False


def _class_name(hwnd: int) -> str:
    try:
        return win32gui.GetClassName(hwnd) or ""
    except win32gui.error:
        return ""


def _matches_potplayer(class_name: str) -> bool:
    return class_name in WINDOW_CLASSES or class_name.lower().startswith(_CLASS_PREFIX)


def _process_pid(hwnd: int) -> int | None:
    try:
        _thread_id, pid = win32process.GetWindowThreadProcessId(hwnd)
        return int(pid) or None
    except (win32process.error, OSError):
        return None


def _process_is_active(pid: int) -> bool:
    """True unless the process is provably gone; probe failures count as alive."""
    try:
        handle = win32api.OpenProcess(win32con.PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    except OSError:
        # Access denied / transient probe failure: the window exists, so treat as alive.
        return True
    try:
        return win32process.GetExitCodeProcess(handle) == STILL_ACTIVE
    except OSError:
        return True
    finally:
        try:
            win32api.CloseHandle(handle)
        except OSError:  # pragma: no cover - defensive close
            pass


class PotPlayerLocator:
    """Thread-safe, TTL-cached, focus-neutral PotPlayer window locator."""

    def __init__(self, cache_ttl_ms: int = DEFAULT_CACHE_TTL_MS) -> None:
        """Configure cache TTL; performs no Win32 call at construction."""
        self._ttl_s = max(0, int(cache_ttl_ms)) / 1000.0
        self._lock = threading.Lock()
        self._info: WindowInfo | None = None

    # ---------------------------------------------------------------- cache

    def find(self, *, force: bool = False) -> int | None:
        """Return live HWND (cached, validated) or None; never activates the window."""
        with self._lock:
            cached = self._info
            if cached is not None and not force:
                fresh = (time.time() - cached.found_at) <= self._ttl_s
                if fresh and win32gui.IsWindow(cached.hwnd):
                    if _matches_potplayer(_class_name(cached.hwnd)):
                        return cached.hwnd
            info = self._locate()
            self._info = info
            return info.hwnd if info is not None else None

    def describe(self) -> WindowInfo | None:
        """Return the cached WindowInfo snapshot, refreshing if stale."""
        with self._lock:
            cached = self._info
            if (
                cached is not None
                and (time.time() - cached.found_at) <= self._ttl_s
                and win32gui.IsWindow(cached.hwnd)
            ):
                return cached
        hwnd = self.find()
        if hwnd is None:
            return None
        with self._lock:
            return self._info

    def get_pid(self) -> int | None:
        """Return cached PID for the located window, else None."""
        with self._lock:
            return self._info.pid if self._info is not None else None

    def is_alive(self) -> bool:
        """True if cached HWND passes IsWindow and its process is still active."""
        with self._lock:
            info = self._info
        if info is None:
            return False
        if not win32gui.IsWindow(info.hwnd):
            return False
        if info.pid <= 0:
            return True  # window exists; PID probe previously failed open
        return _process_is_active(info.pid)

    def invalidate(self) -> None:
        """Drop the cache; next find() re-enumerates (call after a failed message send)."""
        with self._lock:
            self._info = None

    def wait_for_window(self, timeout_ms: int, poll_ms: int = 100) -> int | None:
        """Poll find() until a window appears or timeout elapses (blocking; worker threads only)."""
        deadline = time.time() + max(0, timeout_ms) / 1000.0
        interval = max(1, poll_ms) / 1000.0
        while True:
            hwnd = self.find()
            if hwnd is not None:
                return hwnd
            if time.time() >= deadline:
                return None
            time.sleep(interval)

    # ------------------------------------------------------------- discovery

    def _locate(self) -> WindowInfo | None:
        candidates = self._find_by_class()
        if not candidates:
            candidates = self._enum_fallback()
        if not candidates:
            return None
        chosen = self._prefer_foreground(candidates)
        pid = _process_pid(chosen)
        info = WindowInfo(
            hwnd=chosen,
            pid=pid if pid is not None else 0,
            class_name=_class_name(chosen),
            is_minimized=bool(win32gui.IsIconic(chosen)),
            found_at=time.time(),
        )
        log.debug(
            "PotPlayer window located: hwnd=%s pid=%s class=%s",
            info.hwnd,
            info.pid,
            info.class_name,
        )
        return info

    def _find_by_class(self) -> list[int]:
        """Primary discovery: exact class names, first valid hit wins, probe order kept."""
        for class_name in WINDOW_CLASSES:
            try:
                hwnd = win32gui.FindWindow(class_name, None)
            except win32gui.error:
                hwnd = 0
            if hwnd and win32gui.IsWindowVisible(hwnd) and not _is_cloaked(hwnd):
                return [hwnd]
        return []

    def _enum_fallback(self) -> list[int]:
        """Z-order fallback: visible, non-cloaked, PotPlayer-prefixed top-level windows."""
        candidates: list[int] = []

        def _callback(hwnd: int, _param: object) -> bool:
            try:
                if not win32gui.IsWindowVisible(hwnd):
                    return True
            except win32gui.error:
                return True
            if _is_cloaked(hwnd):
                return True
            if _matches_potplayer(_class_name(hwnd)):
                candidates.append(hwnd)
            return True

        try:
            win32gui.EnumWindows(_callback, None)
        except win32gui.error:  # pragma: no cover - defensive enumeration guard
            pass
        return candidates

    def _prefer_foreground(self, candidates: list[int]) -> int:
        """Multi-instance tie-break: the foreground-owned instance wins (read-only check)."""
        try:
            foreground = win32gui.GetForegroundWindow()
        except win32gui.error:  # pragma: no cover - defensive
            foreground = 0
        if foreground:
            if foreground in candidates:
                candidates = [foreground] + [h for h in candidates if h != foreground]
            elif _matches_potplayer(_class_name(foreground)):
                candidates.insert(0, foreground)
        return candidates[0]


locator = PotPlayerLocator()
"""Module singleton shared by all potplayer/ and display_power/ consumers."""
