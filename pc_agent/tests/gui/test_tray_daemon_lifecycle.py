"""Doc 25 §9 — TrayDaemon lifecycle against a stubbed pystray (no real shell icon).

Every test patches ``tray_daemon.pystray`` with fakes *before* ``start()``, so
automated runs never register a real Windows tray icon and never block on a
message pump. Explorer/tray-shell behavior stays MANUAL (doc §9 steps 1–7).
"""

from __future__ import annotations

import threading
import time
from types import SimpleNamespace

from pc_agent.core.config_manager import StartupRegistrationError
from pc_agent.gui import tray_daemon
from pc_agent.gui.tray_daemon import (
    TRAY_ICON_TITLE,
    TrayActions,
    TrayDaemon,
    fallback_icon,
)

_JOIN_TIMEOUT_S = 2.0


# ---------------------------------------------------------------------------
# fakes
# ---------------------------------------------------------------------------


class FakeConfig:
    """ConfigManager stand-in covering only the snapshot reads the tray performs."""

    def __init__(self, run_on_startup: bool = False, minimize_to_tray: bool = True) -> None:
        self.snapshot = SimpleNamespace(
            run_on_startup=run_on_startup,
            minimize_to_tray=minimize_to_tray,
        )

    def get(self) -> SimpleNamespace:
        return self.snapshot


class Recorder:
    """Counting fake for the four injected TrayActions."""

    def __init__(self, config: FakeConfig) -> None:
        self.config = config
        self.show_qr = 0
        self.blackout = 0
        self.startup = 0
        self.exit = 0
        self.blackout_result = True
        self.startup_result = True
        self.startup_error: BaseException | None = None

    def actions(self) -> TrayActions:
        return TrayActions(
            show_qr=self._show_qr,
            toggle_blackout=self._blackout,
            toggle_startup=self._startup,
            exit_app=self._exit,
        )

    def _show_qr(self) -> None:
        self.show_qr += 1

    def _blackout(self) -> bool:
        self.blackout += 1
        return self.blackout_result

    def _startup(self) -> bool:
        self.startup += 1
        if self.startup_error is not None:
            raise self.startup_error
        # mimic Doc 26 persistence so later config re-syncs stay coherent
        self.config.snapshot.run_on_startup = self.startup_result
        return self.startup_result

    def _exit(self) -> None:
        self.exit += 1


class FakeMenuItem:
    """pystray.MenuItem stand-in: lazy checked/enabled callables receive the item."""

    def __init__(
        self,
        text,
        action,
        checked=None,
        radio=False,
        default=False,
        visible=True,
        enabled=True,
    ) -> None:
        self.text = text
        self._action = action
        self._checked = checked
        self.default = default
        self.visible = visible
        self._enabled = enabled

    @property
    def checked(self):
        if self._checked is None:
            return None
        return self._checked(self) if callable(self._checked) else self._checked

    @property
    def enabled(self):
        return self._enabled(self) if callable(self._enabled) else self._enabled

    def activate(self, icon) -> None:
        """Invoke the way pystray does for an active menu click: action(icon, item)."""
        assert self._action is not None, "separators have no action"
        return self._action(icon, self)


class FakeMenu:
    """pystray.Menu stand-in; SEPARATOR identity matches production usage."""

    SEPARATOR = FakeMenuItem("- - - -", None)

    def __init__(self, *items) -> None:
        self.items = items


class FakeIcon:
    """pystray.Icon stand-in: run() blocks on an event, stop() releases it."""

    def __init__(self, name, icon=None, title=None, menu=None, *, fail_run=False) -> None:
        self.name = name
        self.image = icon
        self.title = title
        self.menu = menu
        self.fail_run = fail_run
        self.started = threading.Event()
        self.stop_requested = threading.Event()
        self.stop_calls = 0
        self.update_menu_calls = 0
        self.notify_calls: list[tuple[str | None, str]] = []

    def run(self, setup=None) -> None:
        self.started.set()
        if self.fail_run:
            raise RuntimeError("pystray backend unavailable")
        self.stop_requested.wait(timeout=10.0)

    def stop(self) -> None:
        self.stop_calls += 1
        self.stop_requested.set()

    def notify(self, message, title=None) -> None:
        self.notify_calls.append((title, message))

    def update_menu(self) -> None:
        self.update_menu_calls += 1


def _install_fake_pystray(monkeypatch, *, fail_run: bool = False) -> list[FakeIcon]:
    """Patch tray_daemon.pystray; return the icon-instance recorder."""
    created: list[FakeIcon] = []

    class _Icon(FakeIcon):
        def __init__(self, name, icon=None, title=None, menu=None) -> None:
            super().__init__(name, icon=icon, title=title, menu=menu, fail_run=fail_run)
            created.append(self)

    fake = SimpleNamespace(Icon=_Icon, Menu=FakeMenu, MenuItem=FakeMenuItem)
    monkeypatch.setattr(tray_daemon, "pystray", fake)
    return created


def _make_daemon(config: FakeConfig | None = None, *, icon_factory=fallback_icon):
    cfg = config if config is not None else FakeConfig()
    recorder = Recorder(cfg)
    daemon = TrayDaemon(cfg, recorder.actions(), icon_factory)
    return daemon, recorder


def _wait_until(predicate, timeout: float = _JOIN_TIMEOUT_S) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return bool(predicate())


def _item(icon: FakeIcon, label: str) -> FakeMenuItem:
    for entry in icon.menu.items:
        if entry is FakeMenu.SEPARATOR:
            continue
        if entry.text == label:
            return entry
    raise AssertionError(f"menu item {label!r} not found")


def _active_tray_threads() -> list[threading.Thread]:
    return [t for t in threading.enumerate() if t.name == "potpilot-tray"]


# ---------------------------------------------------------------------------
# lifecycle
# ---------------------------------------------------------------------------


def test_start_spawns_single_daemon_thread(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    try:
        assert daemon.alive is False
        daemon.start()
        daemon.start()  # idempotent while the thread runs
        assert len(icons) == 1
        assert icons[0].started.wait(timeout=_JOIN_TIMEOUT_S)
        assert isinstance(icons[0].menu, FakeMenu)
        assert icons[0].title == TRAY_ICON_TITLE
        assert _item(icons[0], "Show QR").default is True  # left-click path (§4.5)
        assert _item(icons[0], "Run on Startup").checked is False

        threads = _active_tray_threads()
        assert len(threads) == 1
        assert threads[0].daemon is True
        assert daemon.alive is True
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_stop_joins_thread_and_double_stop_is_safe(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    daemon.start()
    assert icons[0].started.wait(timeout=_JOIN_TIMEOUT_S)
    assert daemon.alive is True

    daemon.stop(timeout_s=_JOIN_TIMEOUT_S)
    assert daemon.alive is False
    assert icons[0].stop_calls == 1
    assert _active_tray_threads() == []

    daemon.stop(timeout_s=_JOIN_TIMEOUT_S)  # second stop: idempotent no-op
    assert daemon.alive is False
    assert _active_tray_threads() == []


def test_stop_before_start_is_a_no_op(monkeypatch):
    _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    daemon.stop()
    daemon.stop()
    assert daemon.alive is False


# ---------------------------------------------------------------------------
# menu dispatch
# ---------------------------------------------------------------------------


def test_menu_actions_fire_exactly_once_per_click(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon()
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        _item(icon, "Show QR").activate(icon)
        _item(icon, "Toggle Blackout").activate(icon)
        _item(icon, "Run on Startup").activate(icon)

        assert recorder.show_qr == 1
        assert recorder.blackout == 1
        assert recorder.startup == 1
        # check marks flipped live and the blackout balloon confirmed (§4.4)
        assert _item(icon, "Toggle Blackout").checked is True
        assert _item(icon, "Run on Startup").checked is True
        assert (TRAY_ICON_TITLE, "Blackout on") in icon.notify_calls

        # 300 ms debounce: the rapid second blackout click is dropped (§7)
        _item(icon, "Toggle Blackout").activate(icon)
        assert recorder.blackout == 1
        assert _item(icon, "Toggle Blackout").checked is True
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_blackout_off_balloon_follows_action_result(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon()
    recorder.blackout_result = False
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        _item(icon, "Toggle Blackout").activate(icon)
        assert recorder.blackout == 1
        assert _item(icon, "Toggle Blackout").checked is False
        assert (TRAY_ICON_TITLE, "Blackout off") in icon.notify_calls
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_startup_registration_error_reverts_check_and_balloons(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon()
    recorder.startup_error = StartupRegistrationError(r"HKCU\Run denied")
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        _item(icon, "Run on Startup").activate(icon)  # must not raise on T2
        assert recorder.startup == 1
        assert _item(icon, "Run on Startup").checked is False  # check mark reverted
        assert daemon._state.startup_enabled is False
        assert (TRAY_ICON_TITLE, "Could not update startup entry") in icon.notify_calls
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_exit_freezes_menu_arms_watchdog_and_requests_shutdown(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon()
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        _item(icon, "Exit").activate(icon)
        assert recorder.exit == 1
        assert daemon._state.exiting is True  # phase 1
        for label in ("Show QR", "Toggle Blackout", "Run on Startup", "Exit"):
            assert _item(icon, label).enabled is False
        assert daemon._watchdog is not None  # phase 5: 5 s hard cap armed
        assert daemon._watchdog.is_alive()
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)
    assert daemon._watchdog is None  # clean stop retires the watchdog
    assert daemon.alive is False


# ---------------------------------------------------------------------------
# connection awareness / resilience
# ---------------------------------------------------------------------------


def test_set_connection_rewrites_title_both_ways(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        daemon.set_connection(True, "192.168.1.24")
        assert icon.title == f"{TRAY_ICON_TITLE} · 192.168.1.24"
        daemon.set_connection(False, None)
        assert icon.title == TRAY_ICON_TITLE  # phone gone → base tooltip (§7)
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_dead_icon_thread_probe_restarts_exactly_once(monkeypatch):
    icons = _install_fake_pystray(monkeypatch, fail_run=True)
    daemon, _ = _make_daemon()
    try:
        daemon.start()
        assert icons[0].started.wait(timeout=_JOIN_TIMEOUT_S)
        assert _wait_until(lambda: not daemon.alive)  # backend died (§7)

        daemon.set_connection(True, "192.168.1.24")  # probe restarts the thread
        assert len(icons) == 2
        # fresh icon boots with the already-rewritten tooltip
        assert icons[1].title == f"{TRAY_ICON_TITLE} · 192.168.1.24"
        assert _wait_until(lambda: not daemon.alive)

        daemon.set_connection(False, None)
        assert len(icons) == 2  # one-shot restart: never a third icon
        assert icons[1].title == TRAY_ICON_TITLE
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_run_failure_keeps_agent_alive_windowed_only(monkeypatch):
    _install_fake_pystray(monkeypatch, fail_run=True)
    daemon, _ = _make_daemon()
    try:
        daemon.start()
        assert _wait_until(lambda: not daemon.alive)
        assert daemon.alive is False  # alive probe follows the dead thread
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_icon_factory_failure_falls_back_to_pil_glyph(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)

    def _broken():
        raise FileNotFoundError("tray icon asset missing")

    daemon, _ = _make_daemon(icon_factory=_broken)
    try:
        daemon.start()
        assert icons[0].started.wait(timeout=_JOIN_TIMEOUT_S)
        image = icons[0].image
        assert image is not None
        assert image.size == (32, 32)
        assert image.mode == "RGBA"
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_notify_is_silent_before_start_and_best_effort_after(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    daemon.notify("Ignored", "no icon yet")  # pre-start → silent no-op
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        daemon.notify(TRAY_ICON_TITLE, "hello")
        assert icon.notify_calls == [(TRAY_ICON_TITLE, "hello")]

        def _boom(message, title=None) -> None:
            raise RuntimeError("Focus Assist suppressed it")

        icon.notify = _boom
        daemon.notify(TRAY_ICON_TITLE, "swallowed")  # best-effort: never raises
        assert len(icon.notify_calls) == 1
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_refresh_resyncs_config_and_repaints_menu(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon(config=FakeConfig(run_on_startup=False))
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)
        assert _item(icon, "Run on Startup").checked is False

        recorder.config.snapshot.run_on_startup = True  # dashboard toggled it
        daemon.refresh()
        assert _item(icon, "Run on Startup").checked is True
        assert icon.update_menu_calls == 1
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


# ---------------------------------------------------------------------------
# minimize-to-tray balloon (§4.6)
# ---------------------------------------------------------------------------


def test_first_hide_balloon_fires_once_per_session(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, _ = _make_daemon()
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        assert daemon.note_dashboard_hidden() is True
        assert len(icon.notify_calls) == 1
        title, message = icon.notify_calls[0]
        assert title == TRAY_ICON_TITLE
        assert "still running" in message

        assert daemon.note_dashboard_hidden() is False  # once per session only
        assert len(icon.notify_calls) == 1
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)


def test_hide_balloon_suppressed_without_minimize_to_tray(monkeypatch):
    icons = _install_fake_pystray(monkeypatch)
    daemon, recorder = _make_daemon(config=FakeConfig(minimize_to_tray=False))
    try:
        daemon.start()
        icon = icons[0]
        assert icon.started.wait(timeout=_JOIN_TIMEOUT_S)

        assert daemon.note_dashboard_hidden() is False  # silent-startup guard
        assert icon.notify_calls == []
        # notice not consumed while suppressed: flipping the setting lets it fire
        recorder.config.snapshot.minimize_to_tray = True
        assert daemon.note_dashboard_hidden() is True
        assert len(icon.notify_calls) == 1
    finally:
        daemon.stop(timeout_s=_JOIN_TIMEOUT_S)
