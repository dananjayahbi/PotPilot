"""Doc 12 unit tests: secondary-monitor blackout overlay manager (stub Tk, no real windows)."""

from __future__ import annotations

import threading
from collections.abc import Callable, Sequence
from typing import Any

import pytest

from pc_agent.display_power import blackout_overlay
from pc_agent.display_power.blackout_overlay import (
    OVERLAY_BG,
    PUMP_INTERVAL_MS,
    BlackoutOverlayManager,
)
from pc_agent.display_power.monitor_snapper import MonitorInfo

PRIMARY = MonitorInfo(
    index=0,
    rect=(0, 0, 1920, 1080),
    work_rect=(0, 0, 1920, 1040),
    is_primary=True,
    device="\\\\.\\DISPLAY1",
)
SECONDARY_A = MonitorInfo(
    index=1,
    rect=(1920, 0, 3840, 1080),
    work_rect=(1920, 0, 3840, 1040),
    is_primary=False,
    device="\\\\.\\DISPLAY2",
)
SECONDARY_B = MonitorInfo(
    index=2,
    rect=(-1920, 0, 0, 1080),
    work_rect=(-1920, 0, 0, 1040),
    is_primary=False,
    device="\\\\.\\DISPLAY3",
)


class FakeRoot:
    """Tk root stand-in: withdraw/after/destroy recorded, callbacks manual."""

    def __init__(self) -> None:
        self.withdrawn = False
        self.destroyed = 0
        self.scheduled: list[tuple[int, Callable[[], None]]] = []

    def withdraw(self) -> None:
        self.withdrawn = True

    def after(self, ms: int, callback: Callable[[], None]) -> str:
        self.scheduled.append((ms, callback))
        return f"after-{len(self.scheduled)}"

    def destroy(self) -> None:
        self.destroyed += 1


class FakeToplevel:
    """Overlay window stand-in: every mutation recorded, never touches a screen."""

    def __init__(self, parent: Any) -> None:
        self.parent = parent
        self.overrode: bool | None = None
        self.geometry_str: str | None = None
        self.bg: str | None = None
        self.topmost: bool | None = None
        self.destroyed = False

    def overrideredirect(self, value: bool) -> None:
        self.overrode = value

    def geometry(self, value: str) -> None:
        self.geometry_str = value

    def configure(self, **kwargs: Any) -> None:
        self.bg = kwargs.get("bg")

    def attributes(self, name: str, value: Any) -> None:
        assert name == "-topmost"
        self.topmost = value

    def destroy(self) -> None:
        self.destroyed = True


@pytest.fixture
def tk_env(monkeypatch) -> dict[str, Any]:
    """Stub Tk factory: manager-created roots and overlays land in this env."""
    env: dict[str, Any] = {"roots": [], "windows": []}

    def create_root() -> FakeRoot:
        root = FakeRoot()
        env["roots"].append(root)
        return root

    def create_overlay(parent: Any) -> FakeToplevel:
        window = FakeToplevel(parent)
        env["windows"].append(window)
        return window

    monkeypatch.setattr(blackout_overlay, "_create_root", create_root)
    monkeypatch.setattr(blackout_overlay, "_create_overlay", create_overlay)
    return env


def make_provider(
    monitors: Sequence[MonitorInfo],
) -> tuple[Callable[[], list[MonitorInfo]], dict[str, Any]]:
    """Mutable-topology monitor provider (Doc 11 list_monitors seam)."""
    state = {"monitors": list(monitors)}

    def provider() -> list[MonitorInfo]:
        return list(state["monitors"])

    return provider, state


def pump(root: FakeRoot) -> None:
    """Run exactly one scheduled pump tick (deterministic, no sleeping)."""
    if root.scheduled:
        _ms, callback = root.scheduled.pop(0)
        callback()


def alive(env: dict[str, Any]) -> list[FakeToplevel]:
    return [window for window in env["windows"] if not window.destroyed]


def test_toggle_state_machine(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    assert root.withdrawn
    pump(root)
    assert manager.is_active is False
    assert alive(tk_env) == []

    assert manager.toggle() is True  # Hidden -> Showing
    assert manager.is_active is True
    pump(root)
    assert len(alive(tk_env)) == 1

    assert manager.toggle() is False  # Showing -> Hidden
    assert manager.is_active is False
    pump(root)
    assert alive(tk_env) == []
    assert all(window.destroyed for window in tk_env["windows"])
    manager.shutdown()


def test_set_enabled_idempotent(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A, SECONDARY_B])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    pump(root)

    assert manager.set_enabled(True) is True
    pump(root)
    assert len(alive(tk_env)) == 2

    # Idempotent: a second identical command must not spawn duplicates.
    assert manager.set_enabled(True) is True
    pump(root)
    assert len(tk_env["windows"]) == 2  # exactly one window per target monitor
    assert len(alive(tk_env)) == 2
    manager.shutdown()


def test_skips_primary_monitor(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A, SECONDARY_B])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    pump(root)
    manager.set_enabled(True)
    pump(root)

    windows = alive(tk_env)
    assert len(windows) == 2  # 3 monitors, 1 primary -> 2 overlay targets
    geometries = {window.geometry_str for window in windows}
    assert geometries == {"1920x1080+1920+0", "1920x1080-1920+0"}
    assert OVERLAY_BG == "#000000"  # exact pure black, fully opaque
    assert all(window.bg == OVERLAY_BG for window in windows)
    assert all(window.overrode is True for window in windows)
    assert all(window.topmost is True for window in windows)
    assert PUMP_INTERVAL_MS == 33
    manager.shutdown()


def test_topology_diff_destroys_stale(tk_env: dict[str, Any]) -> None:
    provider, state = make_provider([PRIMARY, SECONDARY_A, SECONDARY_B])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    pump(root)
    manager.set_enabled(True)
    pump(root)
    window_a = next(w for w in tk_env["windows"] if w.geometry_str == "1920x1080+1920+0")
    window_b = next(w for w in tk_env["windows"] if w.geometry_str == "1920x1080-1920+0")

    # Secondary B unplugged while active: orphan destroyed, survivor kept.
    state["monitors"] = [PRIMARY, SECONDARY_A]
    manager.refresh_monitors()
    pump(root)

    assert window_b.destroyed is True
    assert window_a.destroyed is False
    assert alive(tk_env) == [window_a]
    assert manager.is_active is True  # blackout remains active for survivors

    # Replug + refresh: the overlay reappears at the correct rect.
    state["monitors"] = [PRIMARY, SECONDARY_A, SECONDARY_B]
    manager.refresh_monitors()
    pump(root)
    respawns = [w for w in alive(tk_env) if w.geometry_str == "1920x1080-1920+0"]
    assert len(respawns) == 1 and respawns[0] is not window_b
    assert len(alive(tk_env)) == 2
    manager.shutdown()


def test_thread_enqueue(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    # Deliberately do not pump: the foreign thread must not touch Tk.

    worker = threading.Thread(target=manager.toggle)
    worker.start()
    worker.join(timeout=5)

    assert tk_env["windows"] == []  # no Tk mutation happened off the pump
    assert manager.is_active is True  # intent recorded (coalesced target state)

    pump(root)  # pump performs the Tk mutation on the Tk "thread"
    assert len(alive(tk_env)) == 1
    manager.shutdown()


def test_desired_state_coalescing(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]

    manager.toggle()  # SHOW queued
    manager.toggle()  # HIDE queued before one pump tick
    pump(root)

    assert alive(tk_env) == []  # zero transient windows
    assert tk_env["windows"] == []  # never spawned at all
    assert manager.is_active is False
    manager.shutdown()


def test_root_adoption(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A])

    # Injected (shared dashboard) root: adopted, never destroyed.
    injected = FakeRoot()
    manager = BlackoutOverlayManager(provider, root=injected)
    manager.start()
    pump(injected)
    manager.set_enabled(True)
    pump(injected)
    assert len(alive(tk_env)) == 1
    manager.shutdown()
    assert injected.destroyed == 0
    assert alive(tk_env) == []

    # Owned root: created here, destroyed exactly once across two shutdowns.
    owned_manager = BlackoutOverlayManager(provider)
    owned_manager.start()
    owned_root = tk_env["roots"][-1]
    assert owned_root is not injected and owned_root.withdrawn
    owned_manager.shutdown()
    owned_manager.shutdown()
    assert owned_root.destroyed == 1


def test_signature_includes_rect(tk_env: dict[str, Any]) -> None:
    provider, state = make_provider([PRIMARY, SECONDARY_A])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    pump(root)
    manager.set_enabled(True)
    pump(root)
    old_window = alive(tk_env)[0]
    assert old_window.geometry_str == "1920x1080+1920+0"

    # Same device name, changed rect (orientation/resolution change) -> rebuild.
    rotated = MonitorInfo(
        index=1,
        rect=(1920, 0, 2880, 720),
        work_rect=(1920, 0, 2880, 680),
        is_primary=False,
        device=SECONDARY_A.device,
    )
    state["monitors"] = [PRIMARY, rotated]
    manager.refresh_monitors()
    pump(root)

    assert old_window.destroyed is True
    survivors = alive(tk_env)
    assert len(survivors) == 1
    assert survivors[0].geometry_str == "960x720+1920+0"
    manager.shutdown()


def test_shutdown_twice_safe(tk_env: dict[str, Any]) -> None:
    provider, _state = make_provider([PRIMARY, SECONDARY_A])
    manager = BlackoutOverlayManager(provider)
    manager.start()
    root = tk_env["roots"][0]
    pump(root)
    manager.set_enabled(True)
    pump(root)
    assert len(alive(tk_env)) == 1

    manager.shutdown()
    manager.shutdown()  # must raise nothing
    assert manager.is_active is False
    assert alive(tk_env) == []
    assert all(window.destroyed for window in tk_env["windows"])

    # Any stale scheduled pump callbacks must also be harmless.
    while root.scheduled:
        pump(root)
    assert manager.is_active is False
