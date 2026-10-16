"""Doc 25 §9 — build_menu_spec() pure menu planner: labels, order, checkable flags.

No shell/pystray involved: only the frozen menu tree from §4 and the lazy
``checked``/``enabled`` callables that keep check marks live.
"""

from pc_agent.gui.tray_daemon import (
    STARTUP_MENU_LABEL,
    TrayState,
    build_menu_spec,
)

# Doc 25 §4 exact tree: Show QR · Toggle Blackout · ── · Run on Startup · ── · Exit
_SEPARATOR_PATTERN = [False, False, True, False, True, False]


def test_menu_tree_yields_four_actions_in_exact_order():
    state = TrayState()
    spec = build_menu_spec(state)
    actions = [entry for entry in spec if not entry.is_separator]

    assert [entry.label for entry in actions] == [
        "Show QR",
        "Toggle Blackout",
        STARTUP_MENU_LABEL,
        "Exit",
    ]
    assert [entry.action_id for entry in actions] == [
        "show_qr",
        "blackout",
        "startup",
        "exit",
    ]


def test_menu_tree_separator_placement_matches_doc_tree():
    spec = build_menu_spec(TrayState())

    # Doc 25 §9 summarizes "four actions + one separator", but the normative §4
    # tree (and AC §8 "exact order of the tree") shows a rule after Toggle
    # Blackout AND after Run on Startup — the tree wins.
    separators = [entry for entry in spec if entry.is_separator]
    assert len([entry for entry in spec if not entry.is_separator]) == 4
    assert len(separators) == 2
    assert [entry.is_separator for entry in spec] == _SEPARATOR_PATTERN


def test_separator_entries_are_inert():
    for entry in build_menu_spec(TrayState()):
        if not entry.is_separator:
            continue
        assert entry.label == ""
        assert entry.action_id is None
        assert entry.checked is None
        assert entry.enabled is None


def test_run_on_startup_is_checkable_and_mirrors_state():
    checked_on = build_menu_spec(TrayState(startup_enabled=True))
    checked_off = build_menu_spec(TrayState(startup_enabled=False))
    startup_on = next(e for e in checked_on if e.action_id == "startup")
    startup_off = next(e for e in checked_off if e.action_id == "startup")

    assert startup_on.label == STARTUP_MENU_LABEL
    assert startup_on.checked is not None
    assert startup_on.checked() is True
    assert startup_off.checked is not None
    assert startup_off.checked() is False


def test_blackout_check_mark_mirrors_tray_state():
    on = build_menu_spec(TrayState(blackout_active=True))
    off = build_menu_spec(TrayState(blackout_active=False))
    item_on = next(e for e in on if e.action_id == "blackout")
    item_off = next(e for e in off if e.action_id == "blackout")

    assert item_on.checked is not None and item_on.checked() is True
    assert item_off.checked is not None and item_off.checked() is False


def test_show_qr_and_exit_are_uncheckable():
    spec = build_menu_spec(TrayState())
    for action_id in ("show_qr", "exit"):
        entry = next(e for e in spec if e.action_id == action_id)
        assert entry.checked is None
        assert entry.enabled is not None


def test_actions_enable_while_running_and_disable_while_exiting():
    state = TrayState()
    running = [e for e in build_menu_spec(state) if not e.is_separator]
    assert all(e.enabled is not None and e.enabled() for e in running)

    state.mark_exiting()
    exiting = [e for e in build_menu_spec(state) if not e.is_separator]
    assert all(e.enabled is not None and not e.enabled() for e in exiting)
