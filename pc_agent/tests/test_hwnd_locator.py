"""Doc 08 unit tests: focus-neutral PotPlayer HWND locator (fully mocked Win32)."""

from __future__ import annotations

import time
from types import SimpleNamespace

import pytest

from pc_agent.potplayer import hwnd_locator
from pc_agent.potplayer.hwnd_locator import DEFAULT_CACHE_TTL_MS, PotPlayerLocator, WindowInfo

FORBIDDEN_FOCUS_APIS = (
    "SetForegroundWindow",
    "BringWindowToTop",
    "SetFocus",
    "ShowWindow",
    "AttachThreadInput",
)


@pytest.fixture
def win32(monkeypatch):
    """Mock desktop: insertion order == z-order (front-to-back)."""
    desktop = SimpleNamespace(
        windows={},  # hwnd -> {"class", "visible", "iconic", "pid", "title"}
        foreground=0,
        exit_codes={},  # pid -> exit code
        deny_open=False,
        find_calls=0,
        cloak=set(),  # hwnds reported as DWM-cloaked
    )

    def find_window(class_name, _title):
        desktop.find_calls += 1
        for hwnd, win in desktop.windows.items():
            if win["class"] == class_name:
                return hwnd
        return 0

    def enum_windows(callback, param):
        for hwnd in list(desktop.windows):
            if not callback(hwnd, param):
                break

    def is_window(hwnd):
        return hwnd in desktop.windows

    monkeypatch.setattr(hwnd_locator.win32gui, "FindWindow", find_window)
    monkeypatch.setattr(hwnd_locator.win32gui, "EnumWindows", enum_windows)
    monkeypatch.setattr(hwnd_locator.win32gui, "IsWindow", is_window)
    monkeypatch.setattr(
        hwnd_locator.win32gui,
        "IsWindowVisible",
        lambda hwnd: desktop.windows.get(hwnd, {}).get("visible", False),
    )
    monkeypatch.setattr(
        hwnd_locator.win32gui,
        "IsIconic",
        lambda hwnd: desktop.windows.get(hwnd, {}).get("iconic", False),
    )
    monkeypatch.setattr(
        hwnd_locator.win32gui,
        "GetClassName",
        lambda hwnd: desktop.windows.get(hwnd, {}).get("class", ""),
    )
    monkeypatch.setattr(
        hwnd_locator.win32gui,
        "GetWindowText",
        lambda hwnd: desktop.windows.get(hwnd, {}).get("title", ""),
    )
    monkeypatch.setattr(
        hwnd_locator.win32gui, "GetForegroundWindow", lambda: desktop.foreground
    )
    monkeypatch.setattr(
        hwnd_locator.win32process,
        "GetWindowThreadProcessId",
        lambda hwnd: (1000 + hwnd, desktop.windows[hwnd]["pid"]),
    )

    def open_process(_flags, _inherit, pid):
        if desktop.deny_open:
            raise OSError("access denied")
        live_pids = {w["pid"] for w in desktop.windows.values()}
        if pid not in desktop.exit_codes and pid not in live_pids:
            raise OSError("no such process")
        return 0xF00D + pid

    monkeypatch.setattr(hwnd_locator.win32api, "OpenProcess", open_process)
    monkeypatch.setattr(
        hwnd_locator.win32process,
        "GetExitCodeProcess",
        lambda handle: desktop.exit_codes.get(handle - 0xF00D, 259),
    )
    monkeypatch.setattr(hwnd_locator.win32api, "CloseHandle", lambda _handle: None)
    monkeypatch.setattr(hwnd_locator, "_is_cloaked", lambda hwnd: hwnd in desktop.cloak)
    return desktop


def _add(desktop, hwnd, class_name="PotPlayer64", pid=11, visible=True, iconic=False, title=""):
    desktop.windows[hwnd] = {
        "class": class_name,
        "visible": visible,
        "iconic": iconic,
        "pid": pid,
        "title": title,
    }
    return hwnd


def test_find_exact_class_first_hit(win32):
    _add(win32, 100, "PotPlayer64", pid=11)
    _add(win32, 200, "PotPlayer", pid=22)
    locator = PotPlayerLocator()
    assert locator.find() == 100, "PotPlayer64 probe order wins"
    assert locator.get_pid() == 11


def test_find_legacy_class_fallback(win32):
    _add(win32, 200, "PotPlayer", pid=22)
    assert PotPlayerLocator().find() == 200


def test_find_returns_none_when_absent(win32):
    assert PotPlayerLocator().find() is None
    locator = PotPlayerLocator()
    locator.find()
    assert locator.describe() is None
    assert locator.get_pid() is None
    assert locator.is_alive() is False


def test_cache_ttl_and_iswindow_guard(win32):
    _add(win32, 100)
    now = [1000.0]
    fake_time = SimpleNamespace(time=lambda: now[0], sleep=time.sleep)
    locator = PotPlayerLocator(cache_ttl_ms=500)
    import pc_agent.potplayer.hwnd_locator as module

    original = module.time
    try:
        module.time = fake_time
        assert locator.find() == 100
        assert win32.find_calls == 1
        # Fresh cache hit: no re-enumeration (IsWindow + class guard only).
        assert locator.find() == 100
        assert win32.find_calls == 1
        # TTL expiry forces re-location.
        now[0] += 0.6
        assert locator.find() == 100
        assert win32.find_calls == 2
        # Dead-but-fresh handle: IsWindow guard re-locates immediately.
        del win32.windows[100]
        win32.find_calls = 0
        locator.invalidate()
        _add(win32, 300)
        assert locator.find() == 300
    finally:
        module.time = original


def test_default_cache_ttl_is_500ms():
    assert DEFAULT_CACHE_TTL_MS == 500


def test_describe_snapshot_fields(win32):
    _add(win32, 100, "PotPlayer64", pid=4242, iconic=True)
    locator = PotPlayerLocator()
    info = locator.describe()
    assert isinstance(info, WindowInfo)
    assert (info.hwnd, info.pid, info.class_name, info.is_minimized) == (
        100,
        4242,
        "PotPlayer64",
        True,
    )
    assert info.found_at <= time.time()


def test_enum_fallback_zorder_and_visibility(win32):
    _add(win32, 301, "PotPlayer64", visible=False)  # invisible: skipped
    _add(win32, 302, "PotPlayer64")  # cloaked: skipped
    win32.cloak.add(302)
    _add(win32, 303, "PotplayerDerivative", pid=33)  # prefix match, visible: kept
    locator = PotPlayerLocator()
    assert locator.find() == 303
    assert locator.get_pid() == 33


def test_pid_cache_and_process_health(win32):
    _add(win32, 100, pid=77)
    locator = PotPlayerLocator()
    assert locator.find() == 100
    assert locator.get_pid() == 77
    win32.exit_codes[77] = 259  # STILL_ACTIVE
    assert locator.is_alive() is True
    win32.exit_codes[77] = 1  # process exited
    assert locator.is_alive() is False
    # Probe failure (access denied) must never false-negative.
    win32.exit_codes.pop(77)
    win32.deny_open = True
    assert locator.is_alive() is True
    # Dead window short-circuits to False.
    win32.deny_open = False
    del win32.windows[100]
    assert locator.is_alive() is False


def test_invalidate_forces_refresh(win32):
    _add(win32, 100, pid=11)
    locator = PotPlayerLocator()
    assert locator.find() == 100
    calls = win32.find_calls
    locator.invalidate()
    assert locator.get_pid() is None
    # Same window re-discovered with a fresh snapshot (e.g. recycled PID data).
    win32.windows[100]["pid"] = 99
    assert locator.find() == 100
    assert win32.find_calls == calls + 1
    assert locator.get_pid() == 99


def test_multiple_instances_prefers_foreground_pid(win32):
    _add(win32, 100, pid=11)
    _add(win32, 200, pid=22)
    win32.foreground = 200
    locator = PotPlayerLocator()
    assert locator.find() == 200
    assert locator.get_pid() == 22


def test_media_titled_instance_beats_topmost_empty(win32):
    # Real-world multi-instance: empty window topmost in z-order, movie below it.
    _add(win32, 100, pid=11, title="PotPlayer")
    _add(win32, 200, pid=22, title="movie.mkv - PotPlayer")
    locator = PotPlayerLocator()
    assert locator.find() == 200
    assert locator.get_pid() == 22


def test_media_titled_instance_beats_foreground_empty(win32):
    # Media preference outranks the foreground tie-break: controls must target
    # playback, even when the user has the empty instance focused.
    _add(win32, 100, pid=11, title="PotPlayer")
    _add(win32, 200, pid=22, title="Interstellar.2014.mkv - PotPlayer")
    win32.foreground = 100
    locator = PotPlayerLocator()
    assert locator.find() == 200
    assert locator.get_pid() == 22


def test_minimized_window_is_still_valid(win32):
    _add(win32, 100, iconic=True)
    locator = PotPlayerLocator()
    assert locator.find() == 100
    assert locator.describe().is_minimized is True


def test_wait_for_window_polls_until_present(win32):
    locator = PotPlayerLocator()

    ticks = {"n": 0}

    def fake_sleep(_seconds):
        ticks["n"] += 1
        if ticks["n"] == 2:
            _add(win32, 555)

    fake_time = SimpleNamespace(time=time.time, sleep=fake_sleep)
    import pc_agent.potplayer.hwnd_locator as module

    original = module.time
    try:
        module.time = fake_time
        assert locator.wait_for_window(timeout_ms=5000, poll_ms=1) == 555
        assert ticks["n"] == 2
    finally:
        module.time = original


def test_wait_for_window_times_out(win32):
    import pc_agent.potplayer.hwnd_locator as module

    fake_time = SimpleNamespace(time=time.time, sleep=lambda _s: None)
    original = module.time
    try:
        module.time = fake_time
        assert PotPlayerLocator().wait_for_window(timeout_ms=0, poll_ms=1) is None
    finally:
        module.time = original


def test_no_focus_stealing_source_guard():
    """Forbidden focus APIs must be structurally absent (Doc 08 §7 discipline)."""
    import pathlib

    source_path = pathlib.Path(hwnd_locator.__file__)
    if source_path.suffix == "c":  # running against a compiled cache
        source_path = source_path.with_suffix("")
    text = source_path.read_text(encoding="utf-8")
    for api in FORBIDDEN_FOCUS_APIS:
        assert api not in text, f"forbidden focus API referenced: {api}"


def test_module_singleton_exists():
    assert isinstance(hwnd_locator.locator, PotPlayerLocator)
