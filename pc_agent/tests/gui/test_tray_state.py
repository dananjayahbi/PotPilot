"""Doc 25 §9 — TrayState: atomic toggle reducers, 300 ms debounce, tooltip rewrites."""

import threading

from pc_agent.gui.tray_daemon import TRAY_ICON_TITLE, TrayState


def test_toggle_reducers_flip_and_round_trip():
    state = TrayState(startup_enabled=False, blackout_active=False)

    assert state.toggle_blackout() is True
    assert state.toggle_blackout() is False
    assert state.toggle_startup() is True
    assert state.toggle_startup() is False

    assert state.set_blackout(True) is True
    assert state.blackout_active is True
    assert state.set_startup(True) is True
    assert state.startup_enabled is True
    # idempotent re-sets
    assert state.set_blackout(True) is True
    assert state.set_startup(False) is False


def test_toggle_reducers_are_atomic_under_concurrency():
    """Lost updates would break the flip parity and the returned-value tally."""
    state = TrayState()
    workers, flips_per_worker = 8, 25
    results: list[bool] = []
    barrier = threading.Barrier(workers)

    def _toggler() -> None:
        barrier.wait()
        local = [state.toggle_blackout() for _ in range(flips_per_worker)]
        results.extend(local)

    threads = [threading.Thread(target=_toggler) for _ in range(workers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=5.0)
        assert not thread.is_alive()

    total = workers * flips_per_worker
    assert len(results) == total
    assert results.count(True) == total // 2  # every flip alternates exactly
    assert state.blackout_active is (total % 2 != 0)  # even total → back to False
    assert state.startup_enabled is False  # untouched by blackout toggles


def test_debounce_drops_clicks_inside_300ms_window():
    state = TrayState()

    assert state.allow_action("blackout", now=0.0) is True
    assert state.allow_action("blackout", now=0.1) is False  # inside the window
    assert state.allow_action("blackout", now=0.299) is False  # still inside
    assert state.allow_action("blackout", now=0.3) is True  # window elapsed
    assert state.allow_action("blackout", now=0.45) is False  # window restarts
    assert state.allow_action("blackout", now=0.61) is True


def test_debounce_is_per_action_and_skips_non_toggle_actions():
    state = TrayState()

    assert state.allow_action("startup", now=10.0) is True
    assert state.allow_action("blackout", now=10.0) is True  # independent key
    assert state.allow_action("startup", now=10.05) is False
    # show_qr / exit are never debounced (Doc 25 §7 only covers the toggles)
    assert state.allow_action("show_qr", now=10.0) is True
    assert state.allow_action("show_qr", now=10.0) is True
    assert state.allow_action("exit", now=10.0) is True
    assert state.allow_action("exit", now=10.0) is True


def test_connection_updates_rewrite_tooltip_text():
    state = TrayState()
    assert state.tooltip == TRAY_ICON_TITLE
    assert state.connected is False
    assert state.device_ip is None

    tooltip = state.set_connection(True, "192.168.1.24")
    assert tooltip == f"{TRAY_ICON_TITLE} · 192.168.1.24"
    assert state.tooltip == f"{TRAY_ICON_TITLE} · 192.168.1.24"
    assert state.connected is True
    assert state.device_ip == "192.168.1.24"

    # IP-less or disconnected updates fall back to the base title (Doc 25 §7)
    assert state.set_connection(True, None) == TRAY_ICON_TITLE
    assert state.set_connection(True, "   ") == TRAY_ICON_TITLE
    assert state.set_connection(False, "10.0.0.5") == TRAY_ICON_TITLE
    assert state.tooltip == TRAY_ICON_TITLE
    assert state.device_ip is None


def test_exiting_flag_and_one_shot_hide_notice():
    state = TrayState()
    assert state.exiting is False
    state.mark_exiting()
    assert state.exiting is True

    assert state.consume_hide_notice() is True  # first minimize-to-tray only
    assert state.consume_hide_notice() is False  # never again this session
