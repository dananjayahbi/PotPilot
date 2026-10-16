"""Doc 11 unit tests: focus-neutral multi-monitor window snapper (fully mocked Win32)."""

from __future__ import annotations

from pathlib import Path

import pytest

from pc_agent.display_power import monitor_snapper
from pc_agent.display_power.monitor_snapper import (
    SC_MAXIMIZE,
    SC_RESTORE,
    SWP_NOACTIVATE,
    SWP_NOZORDER,
    WM_SYSCOMMAND,
    MonitorSnapper,
)

PRIMARY_RECT = (0, 0, 2560, 1440)
PRIMARY_WORK = (0, 0, 2560, 1400)
SECONDARY_RECT = (-2560, 0, 0, 1440)  # left of primary: negative virtual-desktop origin
SECONDARY_WORK = (-2560, 0, 0, 1400)

# The forbidden focus-stealing APIs (Doc 11 §8 source guard).
FORBIDDEN_FOCUS_APIS = ("SetForegroundWindow", "SetFocus", "BringWindowToTop")


class Desktop:
    """Mock desktop: monitors + windows with an ordered syscall recorder."""

    def __init__(self) -> None:
        self.monitors = [
            {
                "rect": SECONDARY_RECT,
                "work": SECONDARY_WORK,
                "flags": 0,
                "device": "\\\\.\\DISPLAY2",
            },
            {
                "rect": PRIMARY_RECT,
                "work": PRIMARY_WORK,
                "flags": 1,  # MONITORINFOF_PRIMARY — selection must be flag-based
                "device": "\\\\.\\DISPLAY1",
            },
        ]
        self.windows: dict[int, dict] = {}
        self.dead: set[int] = set()
        self.refuse_move = False
        self.calls: list[tuple] = []

    # -- helpers ------------------------------------------------------------

    def add_window(
        self,
        hwnd: int,
        rect: tuple[int, int, int, int],
        *,
        iconic: bool = False,
        zoomed: bool = False,
        visible: bool = True,
    ) -> None:
        self.windows[hwnd] = {
            "rect": rect,
            "iconic": iconic,
            "zoomed": zoomed,
            "visible": visible,
        }

    def move_calls(self) -> list[tuple]:
        return [call for call in self.calls if call[0] == "SetWindowPos"]

    def post_calls(self) -> list[tuple]:
        return [call for call in self.calls if call[0] == "PostMessage"]

    def _window(self, hwnd: int) -> dict:
        if hwnd in self.dead:
            raise monitor_snapper.win32gui.error(1400, "Invalid window handle")
        return self.windows[hwnd]

    # -- win32api -----------------------------------------------------------

    def enum_display_monitors(self):
        return [(index + 1, 0, entry["rect"]) for index, entry in enumerate(self.monitors)]

    def get_monitor_info(self, hmon: int) -> dict:
        entry = self.monitors[hmon - 1]
        return {
            "Monitor": entry["rect"],
            "Work": entry["work"],
            "Flags": entry["flags"],
            "Device": entry["device"],
        }

    # -- win32gui -----------------------------------------------------------

    def get_window_rect(self, hwnd: int) -> tuple[int, int, int, int]:
        return self._window(hwnd)["rect"]

    def is_iconic(self, hwnd: int) -> bool:
        return self._window(hwnd)["iconic"]

    def is_zoomed(self, hwnd: int) -> bool:
        return self._window(hwnd)["zoomed"]

    def is_window_visible(self, hwnd: int) -> bool:
        return self._window(hwnd)["visible"]

    def set_window_pos(self, hwnd, insert_after, x, y, cx, cy, flags) -> None:
        self.calls.append(("SetWindowPos", hwnd, x, y, cx, cy, flags))
        self._window(hwnd)  # dead hwnd raises like the real API
        if not self.refuse_move:
            self.windows[hwnd]["rect"] = (x, y, x + cx, y + cy)

    def post_message(self, hwnd, msg, wparam, lparam) -> None:
        self.calls.append(("PostMessage", hwnd, msg, wparam, lparam))
        window = self._window(hwnd)
        if msg == WM_SYSCOMMAND and wparam == SC_RESTORE:
            window["iconic"] = False
            window["zoomed"] = False
        elif msg == WM_SYSCOMMAND and wparam == SC_MAXIMIZE:
            window["zoomed"] = True


class FakeLocator:
    """Doc 08 seam: fixed hwnd + invalidation recorder."""

    def __init__(self, hwnd: int | None) -> None:
        self.hwnd = hwnd
        self.invalidations = 0

    def find(self) -> int | None:
        return self.hwnd

    def invalidate(self) -> None:
        self.invalidations += 1


@pytest.fixture
def desktop(monkeypatch) -> Desktop:
    desk = Desktop()
    monkeypatch.setattr(
        monitor_snapper.win32api, "EnumDisplayMonitors", desk.enum_display_monitors
    )
    monkeypatch.setattr(monitor_snapper.win32api, "GetMonitorInfo", desk.get_monitor_info)
    monkeypatch.setattr(monitor_snapper.win32gui, "GetWindowRect", desk.get_window_rect)
    monkeypatch.setattr(monitor_snapper.win32gui, "IsIconic", desk.is_iconic)
    monkeypatch.setattr(monitor_snapper, "_is_zoomed", desk.is_zoomed)
    monkeypatch.setattr(monitor_snapper.win32gui, "IsWindowVisible", desk.is_window_visible)
    monkeypatch.setattr(monitor_snapper.win32gui, "SetWindowPos", desk.set_window_pos)
    monkeypatch.setattr(monitor_snapper.win32gui, "PostMessage", desk.post_message)
    return desk


def make_snapper(desktop: Desktop, hwnd: int | None = 100) -> MonitorSnapper:
    return MonitorSnapper(FakeLocator(hwnd))


def test_enumeration_and_primary_selection(desktop: Desktop) -> None:
    snapper = make_snapper(desktop)
    monitors = snapper.list_monitors()
    assert len(monitors) == 2  # one MonitorInfo per active display
    assert monitors[0].rect == SECONDARY_RECT  # negative origin preserved
    assert [m.is_primary for m in monitors] == [False, True]
    assert [m.device for m in monitors] == ["\\\\.\\DISPLAY2", "\\\\.\\DISPLAY1"]
    # Primary is chosen by MONITORINFOF_PRIMARY, not by index.
    # (primary_monitor() re-enumerates, so compare values — never cached.)
    assert snapper.primary_monitor() == monitors[1]
    assert snapper.primary_monitor().index == 1

    # Never cached across calls: topology change is visible immediately.
    desktop.monitors.append(
        {
            "rect": (2560, 0, 5120, 1440),
            "work": (2560, 0, 5120, 1400),
            "flags": 1,  # user re-assigned primary in Windows Settings
            "device": "\\\\.\\DISPLAY3",
        }
    )
    desktop.monitors[1]["flags"] = 0
    fresh = snapper.list_monitors()
    assert len(fresh) == 3
    assert snapper.primary_monitor().index == 2


def test_snap_moves_with_noactivate_flags(desktop: Desktop) -> None:
    desktop.add_window(100, (-2000, 100, -800, 900))  # on the secondary
    snapper = make_snapper(desktop)
    result = snapper.snap_to_primary(maximize=True)
    assert result.ok and result.detail == "snapped"
    assert result.hwnd == 100 and result.monitor.index == 1

    moves = desktop.move_calls()
    assert len(moves) == 1
    _, hwnd, x, y, cx, cy, flags = moves[0]
    assert hwnd == 100
    assert flags & SWP_NOACTIVATE, "move must be SWP_NOACTIVATE (no focus steal)"
    assert flags & SWP_NOZORDER, "move must be SWP_NOZORDER (never restack)"
    assert (x, y, cx, cy) == PRIMARY_RECT  # maximize targets the full primary rect

    posts = [
        (call[2], call[3]) for call in desktop.post_calls()
    ]  # (msg, wparam)
    assert (WM_SYSCOMMAND, SC_MAXIMIZE) in posts


def test_idempotent_already_snapped(desktop: Desktop) -> None:
    desktop.add_window(100, PRIMARY_RECT, zoomed=True)  # fullscreen on primary
    snapper = make_snapper(desktop)
    result = snapper.snap_to_primary(maximize=True)
    assert result.ok and result.detail == "already_snapped"
    assert desktop.move_calls() == []  # zero SetWindowPos calls
    assert desktop.post_calls() == []  # nothing to restore/maximize either


def test_restore_sequences(desktop: Desktop) -> None:
    # (a) minimized on the secondary: restore -> move -> re-maximize.
    desktop.add_window(100, SECONDARY_RECT, iconic=True)
    snapper = make_snapper(desktop)
    result = snapper.snap_to_primary(maximize=True)
    assert result.ok and result.detail == "snapped"
    window = desktop.windows[100]
    assert window["iconic"] is False and window["zoomed"] is True
    assert window["rect"] == PRIMARY_RECT

    restore = desktop.calls.index(("PostMessage", 100, WM_SYSCOMMAND, SC_RESTORE, 0))
    move = next(i for i, call in enumerate(desktop.calls) if call[0] == "SetWindowPos")
    maximize = desktop.calls.index(("PostMessage", 100, WM_SYSCOMMAND, SC_MAXIMIZE, 0))
    assert restore < move < maximize, desktop.calls

    # (b) zoomed fullscreen on the wrong display: restore -> move -> re-maximize.
    desktop.windows.clear()
    desktop.calls.clear()
    desktop.add_window(200, SECONDARY_RECT, zoomed=True)
    snapper_b = make_snapper(desktop, hwnd=200)
    result_b = snapper_b.snap_to_primary(maximize=True)
    assert result_b.ok and result_b.detail == "snapped"
    assert desktop.windows[200]["zoomed"] is True
    restore_b = desktop.calls.index(("PostMessage", 200, WM_SYSCOMMAND, SC_RESTORE, 0))
    move_b = next(i for i, call in enumerate(desktop.calls) if call[0] == "SetWindowPos")
    maximize_b = desktop.calls.index(("PostMessage", 200, WM_SYSCOMMAND, SC_MAXIMIZE, 0))
    assert restore_b < move_b < maximize_b, desktop.calls


def test_windowed_mode_work_rect(desktop: Desktop) -> None:
    desktop.add_window(100, SECONDARY_RECT)
    snapper = make_snapper(desktop)
    result = snapper.snap_to_primary(maximize=False)
    assert result.ok and result.detail == "snapped"

    moves = desktop.move_calls()
    assert len(moves) == 1
    _, _, x, y, cx, cy, _flags = moves[0]
    assert (x, y, cx, cy) == PRIMARY_WORK  # windowed frame respects the taskbar
    assert desktop.windows[100]["rect"] == PRIMARY_WORK
    posts = [(call[2], call[3]) for call in desktop.post_calls()]
    assert (WM_SYSCOMMAND, SC_MAXIMIZE) not in posts  # stays windowed


def test_no_window_and_verify_failure(desktop: Desktop) -> None:
    # (a) PotPlayer not running -> structured no_window, nothing raised.
    snapper = make_snapper(desktop, hwnd=None)
    result = snapper.snap_to_primary()
    assert result.ok is False and result.detail == "no_window"
    assert result.hwnd is None and result.monitor is None
    assert desktop.calls == []

    # (b) hwnd dies mid-operation (WinError 1400) -> invalidate + no_window.
    desktop.dead.add(100)
    locator = FakeLocator(100)
    dead_snapper = MonitorSnapper(locator)
    result = dead_snapper.snap_to_primary()
    assert result.ok is False and result.detail == "no_window"
    assert locator.invalidations == 1

    # (c) window manager refuses the move -> verify_failed after the settle window.
    desktop.dead.clear()
    desktop.add_window(200, SECONDARY_RECT)
    desktop.refuse_move = True
    verify_snapper = MonitorSnapper(FakeLocator(200))
    result = verify_snapper.snap_to_primary()
    assert result.ok is False and result.detail == "verify_failed"
    assert result.monitor.index == 1
    assert desktop.move_calls()  # the move was attempted with correct flags

    # (d) no monitor flagged primary (OS misconfiguration) -> monitor_lost,
    # structured and raising nothing (Doc 11 A2/§8).
    desktop.monitors[1]["flags"] = 0
    result = verify_snapper.snap_to_primary()
    assert result.ok is False and result.detail == "monitor_lost"
    assert result.monitor is None


def test_center_predicate_and_tolerance(desktop: Desktop) -> None:
    snapper = make_snapper(desktop)

    desktop.add_window(1, (100, 100, 500, 500))  # center (300, 300): inside
    assert snapper.is_on_primary(1) is True

    desktop.add_window(2, (2540, 500, 2596, 580))  # center x=2568 = right+8
    assert snapper.is_on_primary(2) is True  # exactly at the tolerance edge

    desktop.add_window(3, (2568, 500, 2616, 580))  # center x=2592 = right+32
    assert snapper.is_on_primary(3) is False  # beyond the 8 px tolerance

    desktop.add_window(4, (-20, 500, 12, 580))  # center x=-4 = left-4
    assert snapper.is_on_primary(4) is True  # inside tolerance on the left

    desktop.add_window(5, (900, 1432, 1020, 1512))  # center y=1472 = bottom+32
    assert snapper.is_on_primary(5) is False

    desktop.add_window(6, (900, 500, 1020, 580))
    assert snapper.is_on_primary(6, tol_px=0) is True


def test_no_focus_apis_source_guard() -> None:
    source = Path(monitor_snapper.__file__).read_text(encoding="utf-8")
    for token in FORBIDDEN_FOCUS_APIS:
        assert token not in source, f"forbidden focus API {token!r} found in module source"
