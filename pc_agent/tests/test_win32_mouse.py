"""Doc 06 conformance suite: non-invasive SendInput recorder tests (no real input)."""

import ctypes
import pathlib

import pytest

from pc_agent.input_engine import win32_mouse
from pc_agent.input_engine.win32_mouse import (
    INPUT,
    INPUT_MOUSE,
    MOUSEEVENTF_HWHEEL,
    MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MIDDLEUP,
    MOUSEEVENTF_MOVE,
    MOUSEEVENTF_RIGHTUP,
    MOUSEEVENTF_WHEEL,
    MouseEngine,
    MouseEngineConfig,
)


class MouseInputRecorder:
    """Snapshots each INPUT at call time (the engine reuses one buffer)."""

    def __init__(self, return_value: int = 1) -> None:
        self.return_value = return_value
        self.events: list[dict[str, int]] = []
        self.call_sizes: list[int] = []

    def __call__(self, c_inputs: int, p_inputs: object, cb_size: int) -> int:
        assert c_inputs == 1
        self.call_sizes.append(cb_size)
        inp = ctypes.cast(p_inputs, ctypes.POINTER(INPUT)).contents  # type: ignore[arg-type]
        mouse = inp.union.mi
        self.events.append(
            {
                "type": inp.type,
                "dx": mouse.dx,
                "dy": mouse.dy,
                "mouseData": ctypes.c_int32(mouse.mouseData).value,
                "dwFlags": mouse.dwFlags,
            }
        )
        return self.return_value


@pytest.fixture()
def recorder(monkeypatch: pytest.MonkeyPatch) -> MouseInputRecorder:
    """Doc 06 §9 seam: replace user32.SendInput with an INPUT recorder returning 1."""
    rec = MouseInputRecorder()
    monkeypatch.setattr(ctypes.windll.user32, "SendInput", rec)
    return rec


def test_input_struct_size_x64() -> None:
    assert ctypes.sizeof(INPUT) == 40  # Doc 06 §8 acceptance criterion


def test_move_single_input(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.move_relative(10, -5) == 1
    assert len(recorder.events) == 1
    event = recorder.events[0]
    assert event["type"] == INPUT_MOUSE
    assert event["dwFlags"] == MOUSEEVENTF_MOVE
    assert event["dx"] == 10
    assert event["dy"] == -5
    assert recorder.call_sizes == [40]


def test_click_down_up_pair(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.button(1, 3) == 2
    assert [event["dwFlags"] for event in recorder.events] == [
        MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_LEFTUP,
    ]
    assert eng.held_buttons == frozenset()
    # Doc 06 A3: the pair is injected back-to-back; no sleep call anywhere in the module.
    source = pathlib.Path(win32_mouse.__file__).read_text(encoding="utf-8")
    assert "time.sleep" not in source
    assert "Sleep(" not in source


def test_down_up_tracking(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.button(1, 1) == 1
    for dx in (5, 6, 7):
        assert eng.move_relative(dx, 0) == 1
    assert eng.button(1, 2) == 1
    assert eng.held_buttons == frozenset()
    # Down + 3 moves + Up: one INPUT per packet, never coalesced (Doc 06 §4.2).
    assert [event["dwFlags"] for event in recorder.events] == [
        MOUSEEVENTF_LEFTDOWN,
        MOUSEEVENTF_MOVE,
        MOUSEEVENTF_MOVE,
        MOUSEEVENTF_MOVE,
        MOUSEEVENTF_LEFTUP,
    ]


def test_up_without_down_still_injected_once(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.button(2, 2) == 1
    assert [event["dwFlags"] for event in recorder.events] == [MOUSEEVENTF_RIGHTUP]
    assert eng.held_buttons == frozenset()


def test_invalid_button_args_rejected(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.button(4, 1) == 0
    assert eng.button(1, 9) == 0
    assert eng.button(1, 1) == 1  # valid control still works
    assert recorder.events[0]["dwFlags"] == MOUSEEVENTF_LEFTDOWN


def test_drag_lock_latch_cycle(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine(MouseEngineConfig(drag_lock_enabled=True))
    # First Click latches: one DOWN, button reports held.
    assert eng.button(1, 3) == 1
    assert recorder.events[0]["dwFlags"] == MOUSEEVENTF_LEFTDOWN
    assert eng.drag_locked_button == 1
    assert eng.held_buttons == frozenset({1})
    # Moves keep dragging without extra button events.
    sent = len(recorder.events)
    assert eng.move_relative(3, 4) == 1
    assert [event["dwFlags"] for event in recorder.events[sent:]] == [MOUSEEVENTF_MOVE]
    # Stray click on a different button is ignored while latched.
    assert eng.button(2, 3) == 0
    # Second Click on the latched button releases the latch (drag ends).
    assert eng.button(1, 3) == 1
    assert recorder.events[-1]["dwFlags"] == MOUSEEVENTF_LEFTUP
    assert eng.drag_locked_button is None
    assert eng.held_buttons == frozenset()
    # Up also clears the latch, and release_all clears a re-latched drag.
    assert eng.button(3, 3) == 1
    assert eng.drag_locked_button == 3
    assert eng.release_all() == 1
    assert eng.drag_locked_button is None
    assert eng.held_buttons == frozenset()


def test_toggle_drag_lock_explicit_latch(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()  # drag_lock_enabled=False: Click stays a plain click...
    assert eng.button(1, 3) == 2
    assert eng.drag_locked_button is None
    # ...but the explicit toggle latches regardless of the config knob (Doc 06 A2).
    assert eng.toggle_drag_lock(2) is True
    assert eng.drag_locked_button == 2
    assert eng.held_buttons == frozenset({2})
    # A latched button releases via Up, and invalid ids never latch.
    assert eng.toggle_drag_lock(9) is False
    assert eng.button(2, 2) == 1
    assert eng.drag_locked_button is None
    assert eng.held_buttons == frozenset()


def test_scroll_chunking_and_axes(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.scroll(5, 0) == 5
    assert len(recorder.events) == 5
    assert all(event["dwFlags"] == MOUSEEVENTF_WHEEL for event in recorder.events)
    assert all(event["mouseData"] == 120 for event in recorder.events)

    recorder.events.clear()
    assert eng.scroll(0, -2) == 2
    assert len(recorder.events) == 2
    assert all(event["dwFlags"] == MOUSEEVENTF_HWHEEL for event in recorder.events)
    assert all(event["mouseData"] == -120 for event in recorder.events)

    # Sign-preserving chunk split: -3 ticks -> -120, -120, -120 (Doc 06 §7).
    recorder.events.clear()
    assert eng.scroll(-3, 0) == 3
    assert [event["mouseData"] for event in recorder.events] == [-120, -120, -120]

    # Tick clamp at max_ticks_per_packet=20: 10_000 -> 20 ticks -> 20 chunks.
    recorder.events.clear()
    assert eng.scroll(10_000, 0) == 20
    assert len(recorder.events) == 20
    assert all(abs(event["mouseData"]) <= 120 for event in recorder.events)

    # Both axes in one call: vertical event first, then horizontal.
    recorder.events.clear()
    assert eng.scroll(1, -1) == 2
    assert [event["dwFlags"] for event in recorder.events] == [
        MOUSEEVENTF_WHEEL,
        MOUSEEVENTF_HWHEEL,
    ]

    # Zero ticks on both axes: no-op, no syscall.
    recorder.events.clear()
    assert eng.scroll(0, 0) == 0
    assert recorder.events == []


def test_failure_counter_no_raise() -> None:
    rec = MouseInputRecorder(return_value=0)
    eng = MouseEngine(send_input=rec)  # injection seam (Doc 06 §9 mock)
    assert eng.move_relative(1, 1) == 0
    assert eng.button(1, 1) == 0
    assert eng.scroll(1, 0) == 0
    assert eng.send_failures == 3
    # Bookkeeping stays consistent; release_all still clears without raising.
    assert eng.held_buttons == frozenset({1})
    assert eng.release_all() == 0
    assert eng.held_buttons == frozenset()
    assert eng.drag_locked_button is None


def test_int16_clamp_and_zero_move(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.move_relative(40_000, -40_000) == 1
    event = recorder.events[0]
    assert event["dx"] == 32767
    assert event["dy"] == -32767
    assert eng.move_relative(-40_000, 40_000) == 1
    assert recorder.events[1]["dx"] == -32767
    assert recorder.events[1]["dy"] == 32767
    # Zero delta is a no-op with zero syscalls.
    sent = len(recorder.events)
    assert eng.move_relative(0, 0) == 0
    assert len(recorder.events) == sent


def test_middle_click_flags(recorder: MouseInputRecorder) -> None:
    eng = MouseEngine()
    assert eng.button(3, 3) == 2
    assert [event["dwFlags"] for event in recorder.events] == [
        win32_mouse.MOUSEEVENTF_MIDDLEDOWN,
        MOUSEEVENTF_MIDDLEUP,
    ]
