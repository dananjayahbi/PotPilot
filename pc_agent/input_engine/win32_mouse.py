"""Doc 06: Win32 SendInput mouse engine.

Converts validated UDP wire values (packet types 0x01-0x03, already unpacked by
Doc 13) into hardware-level ``user32.SendInput`` mouse events: relative cursor
movement, left/right/middle button Down/Up/Click, opt-in latched drag-lock, and
sign-correct chunked wheel scrolling on both axes.

Hot-path discipline: no sleeps, no buffering, no exceptions - failures only
bump the ``send_failures`` counter; ``release_all()`` is the safety teardown
called by the network layer on shutdown or client disconnect.
"""

from __future__ import annotations

import ctypes
import logging
import sys
from collections.abc import Callable
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# --- Win32 constants (Doc 06 §5) -----------------------------------------------

INPUT_MOUSE = 0x0000
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_HWHEEL = 0x1000
WHEEL_DELTA = 120

INT16_MAX = 32767
INT16_MIN = -32767  # Doc 06 §4.2 clamps to the symmetric int16 wire range

# Wire button ids (packet 0x03 arg1) and states (arg2).
BUTTON_LEFT = 1
BUTTON_RIGHT = 2
BUTTON_MIDDLE = 3
STATE_DOWN = 1
STATE_UP = 2
STATE_CLICK = 3


# --- Win32 structs (x64: MOUSEINPUT 32, KEYBDINPUT 24, INPUT 40 bytes) ----------


class MOUSEINPUT(ctypes.Structure):
    """Win32 ``MOUSEINPUT`` (32 bytes on x64; includes ``time`` + ULONG_PTR)."""

    _fields_ = [
        ("dx", ctypes.c_int32),
        ("dy", ctypes.c_int32),
        ("mouseData", ctypes.c_uint32),
        ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class KEYBDINPUT(ctypes.Structure):
    """Win32 ``KEYBDINPUT`` (kept in the union so ``sizeof(INPUT) == 40``)."""

    _fields_ = [
        ("wVk", ctypes.c_uint16),
        ("wScan", ctypes.c_uint16),
        ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]


class INPUT(ctypes.Structure):
    """Win32 ``INPUT`` discriminated union (40 bytes on x64, Doc 06 §8)."""

    _anonymous_ = ("union",)
    _fields_ = [("type", ctypes.c_uint32), ("union", _INPUTUNION)]


SendInputFn = Callable[[int, object, int], int]


def _default_send_input(c_inputs: int, p_inputs: object, cb_size: int) -> int:
    """Resolve ``user32.SendInput`` lazily so tests can monkeypatch it (Doc 06 §9).

    Import-time guard: off-Windows the engine stays inert (returns 0) instead of
    crashing the agent at import.
    """
    if sys.platform != "win32":
        return 0
    return int(ctypes.windll.user32.SendInput(c_inputs, p_inputs, cb_size))  # type: ignore[no-any-return]


_BUTTON_DOWN_FLAGS = {
    BUTTON_LEFT: MOUSEEVENTF_LEFTDOWN,
    BUTTON_RIGHT: MOUSEEVENTF_RIGHTDOWN,
    BUTTON_MIDDLE: MOUSEEVENTF_MIDDLEDOWN,
}
_BUTTON_UP_FLAGS = {
    BUTTON_LEFT: MOUSEEVENTF_LEFTUP,
    BUTTON_RIGHT: MOUSEEVENTF_RIGHTUP,
    BUTTON_MIDDLE: MOUSEEVENTF_MIDDLEUP,
}


@dataclass(frozen=True, slots=True)
class MouseEngineConfig:
    """Frozen knobs; inline defaults are the shipped values (Doc 06 §3)."""

    wheel_units_per_tick: int = WHEEL_DELTA  # wheel units per scroll notch
    max_wheel_chunk: int = WHEEL_DELTA  # max units injected per single INPUT
    max_ticks_per_packet: int = 20  # clamp applied to int16 scroll args
    drag_lock_enabled: bool = False  # opt-in latched drag-lock Click semantics


class MouseEngine:
    """Synchronous, allocation-light mouse injection over ``user32.SendInput``.

    One reusable ``INPUT`` buffer is allocated per engine and mutated per event;
    ``SendInput(1, byref(buf), sizeof(INPUT))`` is called inline - no thread, no
    queue, no ``Sleep`` (serialization is the caller's job, Doc 06 §4.1).
    """

    def __init__(
        self,
        config: MouseEngineConfig | None = None,
        send_input: SendInputFn | None = None,
    ) -> None:
        """Allocate the reusable ctypes INPUT buffer; no Win32 call until first event."""
        self.config = config if config is not None else MouseEngineConfig()
        self._buf = INPUT()
        self._held: set[int] = set()
        self._latched: int | None = None
        self._send_failures = 0
        # Optional injection seam for tests; the default resolves the (patchable)
        # ctypes windll attribute at call time.
        self._send_input: SendInputFn = (
            send_input if send_input is not None else _default_send_input
        )

    # --- core injection ---------------------------------------------------------

    def _send_mouse(self, *, flags: int, dx: int = 0, dy: int = 0, data: int = 0) -> int:
        self._buf.type = INPUT_MOUSE
        # mouseData is a DWORD on the wire; wheel deltas are signed, so store the
        # full 32-bit two's-complement pattern (Windows reads HIWORD as a short).
        self._buf.union.mi = MOUSEINPUT(dx, dy, data & 0xFFFFFFFF, flags, 0, 0)
        sent = self._send_input(1, ctypes.byref(self._buf), ctypes.sizeof(INPUT))
        if sent != 1:
            # UIPI (elevated target), locked/RDP desktop, non-interactive session.
            self._send_failures += 1
            logger.debug("SendInput failed (flags=0x%04X dx=%d dy=%d data=%d)", flags, dx, dy, data)
            return 0
        return 1

    # --- public contract (Doc 06 §3) ---------------------------------------------

    def move_relative(self, dx: int, dy: int) -> int:
        """Inject one MOUSEEVENTF_MOVE; returns 1 accepted, 0 no-op/failure."""
        clamped_dx = max(INT16_MIN, min(INT16_MAX, int(dx)))
        clamped_dy = max(INT16_MIN, min(INT16_MAX, int(dy)))
        if clamped_dx == 0 and clamped_dy == 0:
            return 0
        return self._send_mouse(flags=MOUSEEVENTF_MOVE, dx=clamped_dx, dy=clamped_dy)

    def scroll(self, vertical_ticks: int, horizontal_ticks: int) -> int:
        """Convert wire ticks to wheel units and inject chunked WHEEL/HWHEEL events."""
        sent = self._scroll_axis(int(vertical_ticks), MOUSEEVENTF_WHEEL)
        sent += self._scroll_axis(int(horizontal_ticks), MOUSEEVENTF_HWHEEL)
        return sent

    def button(self, button_id: int, state: int) -> int:
        """Apply Down(1)/Up(2)/Click(3) to button 1:L 2:R 3:M; returns INPUT count."""
        down_flag = _BUTTON_DOWN_FLAGS.get(button_id)
        up_flag = _BUTTON_UP_FLAGS.get(button_id)
        if down_flag is None or up_flag is None or state not in (STATE_DOWN, STATE_UP, STATE_CLICK):
            logger.debug("button: rejected invalid args (button_id=%r state=%r)", button_id, state)
            return 0
        if state == STATE_DOWN:
            sent = self._send_mouse(flags=down_flag)
            self._held.add(button_id)  # idempotent if already held
            return sent
        if state == STATE_UP:
            sent = self._send_mouse(flags=up_flag)  # injected once even if not held
            self._held.discard(button_id)
            if self._latched == button_id:
                self._latched = None
            return sent
        return self._click(button_id, down_flag, up_flag)

    def toggle_drag_lock(self, button_id: int) -> bool:
        """Latch/unlatch a button as held-down drag lock; returns the new latched state."""
        if button_id not in _BUTTON_DOWN_FLAGS:
            return False
        if self._latched == button_id:
            # Unlatch = end of drag: inject the release and clear state.
            self._send_mouse(flags=_BUTTON_UP_FLAGS[button_id])
            self._held.discard(button_id)
            self._latched = None
            return False
        if self._latched is not None:
            return False  # single-latch semantics: another button holds the drag
        self._send_mouse(flags=_BUTTON_DOWN_FLAGS[button_id])
        self._held.add(button_id)
        self._latched = button_id
        return True

    def release_all(self) -> int:
        """Release every held/latched button; returns count of UP events injected."""
        buttons = set(self._held)
        if self._latched is not None:
            buttons.add(self._latched)
        released = 0
        for button_id in sorted(buttons):
            released += self._send_mouse(flags=_BUTTON_UP_FLAGS[button_id])
        self._held.clear()
        self._latched = None
        return released

    @property
    def held_buttons(self) -> frozenset[int]:
        """Buttons currently tracked as physically down."""
        return frozenset(self._held)

    @property
    def drag_locked_button(self) -> int | None:
        """Button id currently latched by drag-lock, if any."""
        return self._latched

    @property
    def send_failures(self) -> int:
        """Monotonic count of SendInput calls that returned 0."""
        return self._send_failures

    # --- internals -----------------------------------------------------------------

    def _scroll_axis(self, ticks: int, wheel_flag: int) -> int:
        cfg = self.config
        ticks = max(-cfg.max_ticks_per_packet, min(cfg.max_ticks_per_packet, ticks))
        if ticks == 0:
            return 0
        units = ticks * cfg.wheel_units_per_tick
        sent = 0
        chunk = cfg.max_wheel_chunk
        while units != 0:
            step = max(-chunk, min(chunk, units))  # sign-correct chunk split
            sent += self._send_mouse(flags=wheel_flag, data=step)
            units -= step
        return sent

    def _click(self, button_id: int, down_flag: int, up_flag: int) -> int:
        if self._latched is not None and self._latched != button_id:
            return 0  # stray tap while another button is latched (Doc 06 §7)
        if self.config.drag_lock_enabled and self._latched != button_id:
            # Drag-lock on, not latched on this button: press + latch (drag begins).
            sent = self._send_mouse(flags=down_flag)
            self._held.add(button_id)
            self._latched = button_id
            return sent
        if self._latched == button_id:
            # Latch already set on this button: release latch (drag ends).
            sent = self._send_mouse(flags=up_flag)
            self._held.discard(button_id)
            self._latched = None
            return sent
        # Drag-lock off: atomic DOWN then UP pair, zero delay (Doc 06 §4.3/A3).
        sent = self._send_mouse(flags=down_flag)
        sent += self._send_mouse(flags=up_flag)
        self._held.discard(button_id)  # final state is up even if it was held
        return sent


engine = MouseEngine()
"""Module singleton consumed directly by udp_server.py (Doc 13)."""
