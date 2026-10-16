"""Doc 07 conformance suite: non-invasive SendInput recorder tests (no real input)."""

import ctypes

import pytest

from pc_agent.input_engine.win32_keyboard import (
    CMD_KEY_HANDLERS,
    INPUT,
    INPUT_KEYBOARD,
    KEY_MAP,
    KEYEVENTF_EXTENDEDKEY,
    KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE,
    MODIFIERS,
    KeyboardEngine,
    KeyboardEngineConfig,
)


class KeyboardInputRecorder:
    """Snapshots each INPUT at call time (the engine reuses one buffer)."""

    def __init__(self, return_value: int = 1) -> None:
        self.return_value = return_value
        self.events: list[dict[str, int]] = []
        self.call_sizes: list[int] = []

    def __call__(self, c_inputs: int, p_inputs: object, cb_size: int) -> int:
        assert c_inputs == 1
        self.call_sizes.append(cb_size)
        inp = ctypes.cast(p_inputs, ctypes.POINTER(INPUT)).contents  # type: ignore[arg-type]
        keybd = inp.union.ki
        self.events.append(
            {
                "type": inp.type,
                "wVk": keybd.wVk,
                "wScan": keybd.wScan,
                "dwFlags": keybd.dwFlags,
            }
        )
        return self.return_value


@pytest.fixture()
def recorder(monkeypatch: pytest.MonkeyPatch) -> KeyboardInputRecorder:
    """Doc 07 §9 seam: replace user32.SendInput with an INPUT recorder returning 1."""
    rec = KeyboardInputRecorder()
    monkeypatch.setattr(ctypes.windll.user32, "SendInput", rec)
    return rec


def test_send_text_unicode_and_surrogates(recorder: KeyboardInputRecorder) -> None:
    eng = KeyboardEngine()
    # "Hi \U0001F3AC" -> UTF-16 units 0x0048 0x0069 0x0020 0xD83C 0xDFAC.
    units = [0x0048, 0x0069, 0x0020, 0xD83C, 0xDFAC]
    assert eng.send_text("Hi \U0001F3AC") == 2 * len(units)
    assert len(recorder.events) == 10
    for index, unit in enumerate(units):
        down = recorder.events[index * 2]
        up = recorder.events[index * 2 + 1]
        assert down["wScan"] == unit
        assert up["wScan"] == unit
        assert down["dwFlags"] == KEYEVENTF_UNICODE
        assert up["dwFlags"] == KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
    assert all(event["wVk"] == 0 for event in recorder.events)
    assert all(event["type"] == INPUT_KEYBOARD for event in recorder.events)
    assert recorder.call_sizes == [40] * 10  # sizeof(INPUT) on x64

    recorder.events.clear()
    assert eng.send_text("") == 0  # empty string: no syscall
    assert recorder.events == []
    # Doc 07 §7: raw \n / \t are injected as Unicode LF/HT.
    assert eng.send_text("\n\t") == 4
    assert [event["wScan"] for event in recorder.events][::2] == [0x000A, 0x0009]


def test_tap_sequence_and_extended_flags(recorder: KeyboardInputRecorder) -> None:
    eng = KeyboardEngine()
    assert eng.tap("ENTER") == 2
    assert [(event["wVk"], event["dwFlags"]) for event in recorder.events] == [
        (0x0D, 0),
        (0x0D, KEYEVENTF_KEYUP),
    ]

    recorder.events.clear()
    assert eng.tap("LEFT") == 2
    assert eng.tap("RCTRL") == 2
    assert eng.tap("A") == 2
    assert eng.tap("7") == 2
    assert [(event["wVk"], event["dwFlags"]) for event in recorder.events] == [
        (0x25, KEYEVENTF_EXTENDEDKEY),  # arrows are extended
        (0x25, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP),
        (0xA3, KEYEVENTF_EXTENDEDKEY),  # RCTRL is extended
        (0xA3, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP),
        (0x41, 0),  # letters are not
        (0x41, KEYEVENTF_KEYUP),
        (0x37, 0),  # digits are not
        (0x37, KEYEVENTF_KEYUP),
    ]


def test_hotkey_modifier_order_and_preheld(recorder: KeyboardInputRecorder) -> None:
    eng = KeyboardEngine()
    # hotkey("ALT", "F4") -> ALT down, F4 down, F4 up, ALT up; no EXTENDEDKEY on F4.
    assert eng.hotkey("ALT", "F4") == 4
    assert [(event["wVk"], event["dwFlags"]) for event in recorder.events] == [
        (0x12, 0),
        (0x73, 0),
        (0x73, KEYEVENTF_KEYUP),
        (0x12, KEYEVENTF_KEYUP),
    ]

    # Modifier press order is CTRL -> ALT -> SHIFT -> WIN regardless of argument
    # order; releases are the final key first, then modifiers in reverse.
    recorder.events.clear()
    assert eng.hotkey("WIN", "SHIFT", "CTRL", "A") == 8
    presses = [e["wVk"] for e in recorder.events if not (e["dwFlags"] & KEYEVENTF_KEYUP)]
    releases = [e["wVk"] for e in recorder.events if e["dwFlags"] & KEYEVENTF_KEYUP]
    assert presses == [0x11, 0x10, 0x5B, 0x41]
    assert releases == [0x41, 0x5B, 0x10, 0x11]

    # Pre-held CTRL is not re-pressed and not released afterwards (Doc 07 §4.4).
    recorder.events.clear()
    assert eng.key_down("CTRL") is True
    recorder.events.clear()
    assert eng.hotkey("CTRL", "C") == 2
    assert [event["wVk"] for event in recorder.events] == [0x43, 0x43]
    assert eng.held_keys == frozenset({"CTRL"})
    assert eng.release_all() == 1
    assert eng.held_keys == frozenset()

    # All-or-nothing: an unknown member aborts before any injection.
    recorder.events.clear()
    assert eng.hotkey("CTRL", "NOT_A_KEY") == 0
    assert recorder.events == []
    assert eng.unknown_key_hits == 1
    # A non-modifier before the final key also aborts without injecting.
    assert eng.hotkey("A", "B") == 0
    assert recorder.events == []


def test_key_map_coverage_for_flutter_sheet() -> None:
    reverse: dict[int, str] = {}
    for name, (vk, _extended) in KEY_MAP.items():
        reverse.setdefault(vk, name)
    # Every VK the Doc 37 sheet dispatches resolves to a KEY_MAP name.
    doc37_vks = [
        27,  # Esc
        9,  # Tab
        13,  # Enter
        8,  # Backspace
        91,  # Win
        *range(112, 124),  # F1-F12
        38,
        40,
        37,
        39,  # arrows
        36,
        35,
        33,
        34,  # Home / End / PgUp / PgDn
        115,  # Alt+F4 combo key
    ]
    for vk in doc37_vks:
        assert vk in reverse, f"missing KEY_MAP name for Doc 37 vk={vk}"
    # Letters and digits (latched-modifier combos) resolve too.
    for code in range(0x41, 0x5B):
        assert code in reverse
    for code in range(0x30, 0x3A):
        assert code in reverse
    # Doc 07 §5 guaranteed subset: names and VK values.
    guaranteed = {
        "A": 0x41,
        "Z": 0x5A,
        "0": 0x30,
        "9": 0x39,
        "F1": 0x70,
        "F12": 0x7B,
        "ENTER": 0x0D,
        "ESCAPE": 0x1B,
        "BACKSPACE": 0x08,
        "TAB": 0x09,
        "SPACE": 0x20,
        "SHIFT": 0x10,
        "CTRL": 0x11,
        "ALT": 0x12,
        "LWIN": 0x5B,
        "RWIN": 0x5C,
        "DELETE": 0x2E,
        "HOME": 0x24,
        "END": 0x23,
        "PGUP": 0x21,
        "PGDN": 0x22,
        "INSERT": 0x2D,
        "UP": 0x26,
        "DOWN": 0x28,
        "LEFT": 0x25,
        "RIGHT": 0x27,
        "RCTRL": 0xA3,
        "SEMICOLON": 0xBA,
        "EQUAL": 0xBB,
        "COMMA": 0xBC,
        "MINUS": 0xBD,
        "PERIOD": 0xBE,
        "SLASH": 0xBF,
        "BACKTICK": 0xC0,
        "LBRACKET": 0xDB,
        "BACKSLASH": 0xDC,
        "RBRACKET": 0xDD,
        "QUOTE": 0xDE,
    }
    for name, vk in guaranteed.items():
        assert name in KEY_MAP
        assert KEY_MAP[name][0] == vk
    # The wire modifier enum resolves exactly.
    assert MODIFIERS == frozenset({"CTRL", "ALT", "SHIFT", "WIN"})
    assert set(MODIFIERS) <= set(KEY_MAP)


def test_release_all_clears_state(recorder: KeyboardInputRecorder) -> None:
    eng = KeyboardEngine()
    assert eng.key_down("CTRL") is True
    assert eng.key_down("A") is True
    assert eng.key_down("SHIFT") is True
    recorder.events.clear()
    # Modifiers released first (reverse insertion), then other keys (reverse order).
    assert eng.release_all() == 3
    ups = [event["wVk"] for event in recorder.events if event["dwFlags"] & KEYEVENTF_KEYUP]
    assert ups == [0x10, 0x11, 0x41]
    assert eng.held_keys == frozenset()
    # Idempotent: second call injects nothing.
    recorder.events.clear()
    assert eng.release_all() == 0
    assert recorder.events == []


def test_unknown_key_counted_not_raised(recorder: KeyboardInputRecorder) -> None:
    eng = KeyboardEngine()
    assert eng.key_down("GIBBERISH") is False
    assert eng.key_up("GIBBERISH") is False
    assert eng.tap("GIBBERISH") == 0
    assert eng.unknown_key_hits == 3
    assert recorder.events == []
    # Aliases resolve: ESC->ESCAPE, CONTROL->CTRL, single space->SPACE.
    assert eng.tap("esc") == 2
    assert eng.tap("Control") == 2
    assert eng.tap(" ") == 2
    assert [event["wVk"] for event in recorder.events][::2] == [0x1B, 0x11, 0x20]


def test_partial_send_failures() -> None:
    rec = KeyboardInputRecorder(return_value=0)
    eng = KeyboardEngine(send_input=rec)  # injection seam (Doc 07 §9 mock)
    assert eng.tap("A") == 0
    assert eng.send_failures == 2
    assert eng.held_keys == frozenset()  # nothing was actually sent, nothing tracked
    assert eng.send_text("x") == 0
    assert eng.send_failures == 4
    assert eng.key_down("CTRL") is False
    assert eng.held_keys == frozenset()
    # release_all stays safe and idempotent on a dead desktop.
    assert eng.release_all() == 0


def test_cmd_key_handler_table(recorder: KeyboardInputRecorder) -> None:
    assert set(CMD_KEY_HANDLERS) == {"SEND_KEY", "SEND_COMBO", "SEND_TEXT"}
    eng = KeyboardEngine()
    # SEND_KEY: {"vk": 13} resolves through KEY_MAP to ENTER.
    assert eng.handle_cmd_key("SEND_KEY", {"vk": 13}) == 2
    assert [(event["wVk"], event["dwFlags"]) for event in recorder.events] == [
        (0x0D, 0),
        (0x0D, KEYEVENTF_KEYUP),
    ]
    # SEND_COMBO: {"vk": 115, "modifiers": ["ALT"]} -> Alt+F4.
    recorder.events.clear()
    assert eng.handle_cmd_key("SEND_COMBO", {"vk": 115, "modifiers": ["ALT"]}) == 4
    assert [event["wVk"] for event in recorder.events] == [0x12, 0x73, 0x73, 0x12]
    # SEND_TEXT: {"text": "a"}.
    recorder.events.clear()
    assert eng.handle_cmd_key("SEND_TEXT", {"text": "a"}) == 2
    assert recorder.events[0]["dwFlags"] == KEYEVENTF_UNICODE
    # Unknown action and malformed payloads drop without raising.
    assert eng.handle_cmd_key("SEND_BOGUS", {}) == 0
    assert eng.handle_cmd_key("SEND_KEY", {"vk": 0}) == 0
    assert eng.handle_cmd_key("SEND_KEY", {"vk": "13"}) == 0
    assert eng.handle_cmd_key("SEND_KEY", {}) == 0
    assert eng.handle_cmd_key("SEND_COMBO", {"vk": 13, "modifiers": ["META"]}) == 0
    assert eng.handle_cmd_key("SEND_COMBO", {"vk": 13, "modifiers": "CTRL"}) == 0
    assert eng.handle_cmd_key("SEND_TEXT", {"text": 5}) == 0
    assert eng.unknown_key_hits == 0
    # A valid wire VK with no KEY_MAP name falls back to raw VK injection.
    recorder.events.clear()
    assert eng.handle_cmd_key("SEND_KEY", {"vk": 0x90}) == 2  # VK_NUMLOCK
    assert [event["wVk"] for event in recorder.events] == [0x90, 0x90]


def test_config_defaults() -> None:
    assert KeyboardEngineConfig().release_on_disconnect is True
    assert KeyboardEngine().config.release_on_disconnect is True
