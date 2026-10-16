"""Doc 07: Win32 SendInput keyboard engine.

Turns validated ``CMD_KEY`` WebSocket commands (Doc 14 routes ``SEND_KEY`` /
``SEND_COMBO`` / ``SEND_TEXT`` payloads here) into hardware-level keystrokes:
Unicode string injection via ``KEYEVENTF_UNICODE`` (UTF-16 surrogate-pair safe),
virtual-key dispatch with extended-key handling, and modifier combos pressed and
released in the correct order while preserving pre-held modifiers.

Hot path never raises: unknown key names and failed injections only bump
monotonic counters; ``release_all()`` is the disconnect safety hook so a dropped
connection can never leave a stuck Ctrl/Win key.
"""

from __future__ import annotations

import ctypes
import logging
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# --- Win32 constants (Doc 07 §5) -----------------------------------------------

INPUT_KEYBOARD = 0x0001
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004

# Wire payload bounds (shared_specs/ws_command_schema.json: vk 1-254).
VK_MIN = 1
VK_MAX = 254


# --- Win32 structs (x64: MOUSEINPUT 32, KEYBDINPUT 24, INPUT 40 bytes) ----------


class MOUSEINPUT(ctypes.Structure):
    """Win32 ``MOUSEINPUT`` (32 bytes on x64; union member keeps INPUT at 40)."""

    _fields_ = [
        ("dx", ctypes.c_int32),
        ("dy", ctypes.c_int32),
        ("mouseData", ctypes.c_uint32),
        ("dwFlags", ctypes.c_uint32),
        ("time", ctypes.c_uint32),
        ("dwExtraInfo", ctypes.c_size_t),
    ]


class KEYBDINPUT(ctypes.Structure):
    """Win32 ``KEYBDINPUT`` (24 bytes on x64)."""

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
    """Win32 ``INPUT`` discriminated union (40 bytes on x64)."""

    _anonymous_ = ("union",)
    _fields_ = [("type", ctypes.c_uint32), ("union", _INPUTUNION)]


SendInputFn = Callable[[int, object, int], int]


def _default_send_input(c_inputs: int, p_inputs: object, cb_size: int) -> int:
    """Resolve ``user32.SendInput`` lazily so tests can monkeypatch it (Doc 07 §9).

    Import-time guard: off-Windows the engine stays inert instead of crashing
    the agent at import (Doc 07 §7).
    """
    if sys.platform != "win32":
        return 0
    return int(ctypes.windll.user32.SendInput(c_inputs, p_inputs, cb_size))  # type: ignore[no-any-return]


# --- Key map ----------------------------------------------------------------------


def _build_key_map() -> dict[str, tuple[int, bool]]:
    """Canonical key name -> (VK code, extended flag). Insertion order matters:
    the VK reverse lookup keeps the first (canonical) name per VK code."""
    key_map: dict[str, tuple[int, bool]] = {}
    # Letters A-Z (0x41-0x5A) and digits 0-9 (0x30-0x39): never extended.
    for code in range(ord("A"), ord("Z") + 1):
        key_map[chr(code)] = (code, False)
    for digit in range(10):
        key_map[str(digit)] = (0x30 + digit, False)
    # Function keys F1-F12 (0x70-0x7B): never extended.
    for number in range(1, 13):
        key_map[f"F{number}"] = (0x6F + number, False)
    key_map.update(
        {
            "ENTER": (0x0D, False),
            "ESCAPE": (0x1B, False),
            "BACKSPACE": (0x08, False),
            "TAB": (0x09, False),
            "SPACE": (0x20, False),
            "SHIFT": (0x10, False),
            "CTRL": (0x11, False),
            "ALT": (0x12, False),
            # Win keys are E0-prefixed scan codes -> extended.
            "WIN": (0x5B, True),
            "LWIN": (0x5B, True),
            "RWIN": (0x5C, True),
            # Nav cluster: E0-prefixed scan codes -> extended (avoids numpad aliasing).
            "INSERT": (0x2D, True),
            "DELETE": (0x2E, True),
            "HOME": (0x24, True),
            "END": (0x23, True),
            "PGUP": (0x21, True),
            "PGDN": (0x22, True),
            "UP": (0x26, True),
            "DOWN": (0x28, True),
            "LEFT": (0x25, True),
            "RIGHT": (0x27, True),
            # Right-hand modifiers are extended; left-hand ones are not.
            "LCTRL": (0xA2, False),
            "RCTRL": (0xA3, True),
            "LALT": (0xA4, False),
            # VK_RMENU is 0xA5 (Doc 07 §5 renders 0xA4, which is VK_LMENU).
            "RALT": (0xA5, True),
            # US-QWERTY OEM punctuation (Doc 07 §5).
            "SEMICOLON": (0xBA, False),
            "EQUAL": (0xBB, False),
            "COMMA": (0xBC, False),
            "MINUS": (0xBD, False),
            "PERIOD": (0xBE, False),
            "SLASH": (0xBF, False),
            "BACKTICK": (0xC0, False),
            "LBRACKET": (0xDB, False),
            "BACKSLASH": (0xDC, False),
            "RBRACKET": (0xDD, False),
            "QUOTE": (0xDE, False),
        }
    )
    return key_map


KEY_MAP: dict[str, tuple[int, bool]] = _build_key_map()
"""Normalized key name -> (vk_code, extended_flag), Doc 07 §3."""

_KEY_ALIASES: dict[str, str] = {
    "CONTROL": "CTRL",
    "LCONTROL": "LCTRL",
    "RCONTROL": "RCTRL",
    "ESC": "ESCAPE",
    "RETURN": "ENTER",
    "DEL": "DELETE",
    "INS": "INSERT",
    "PAGEUP": "PGUP",
    "PAGEDOWN": "PGDN",
    "CMD": "WIN",
    "WINDOWS": "WIN",
    " ": "SPACE",
    "ARROWUP": "UP",
    "ARROWDOWN": "DOWN",
    "ARROWLEFT": "LEFT",
    "ARROWRIGHT": "RIGHT",
}

_VK_TO_NAME: dict[int, str] = {}
for _key_name, (_key_vk, _key_extended) in KEY_MAP.items():
    _VK_TO_NAME.setdefault(_key_vk, _key_name)

# Modifiers understood by hotkey()/SEND_COMBO, in canonical press order.
MODIFIER_ORDER: tuple[str, ...] = ("CTRL", "ALT", "SHIFT", "WIN")
MODIFIERS: frozenset[str] = frozenset(MODIFIER_ORDER)

# Extended keys when dispatching raw wire VK codes (Doc 37 VK set + right mods).
_RAW_EXTENDED_VKS: frozenset[int] = frozenset(
    {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B, 0x5C, 0xA3, 0xA5}
)


def _normalize_key(name: str) -> str | None:
    """Trim, uppercase, and alias a key name; None for non-string input."""
    if not isinstance(name, str):
        return None
    upper = name.upper()
    upper = _KEY_ALIASES.get(upper, upper)
    stripped = upper.strip()
    return _KEY_ALIASES.get(stripped, stripped)


@dataclass(frozen=True, slots=True)
class KeyboardEngineConfig:
    """Frozen knobs; inline defaults are the shipped values (Doc 07 §3)."""

    release_on_disconnect: bool = True


class KeyboardEngine:
    """Win32 ``KEYBDINPUT`` injection: Unicode text, named keys, and combos.

    One reusable ``INPUT`` buffer is allocated per engine and mutated per event;
    every transition is one synchronous ``SendInput`` call - no thread, no queue,
    no ``Sleep`` (serialization is the caller's job).
    """

    def __init__(
        self,
        config: KeyboardEngineConfig | None = None,
        send_input: SendInputFn | None = None,
    ) -> None:
        """Allocate reusable ctypes INPUT buffers; no Win32 call until first key."""
        self.config = config if config is not None else KeyboardEngineConfig()
        self._buf = INPUT()
        self._held: dict[str, None] = {}  # ordered set of named keys currently down
        self._send_failures = 0
        self._unknown_key_hits = 0
        # Optional injection seam for tests; the default resolves the (patchable)
        # ctypes windll attribute at call time.
        self._send_input: SendInputFn = (
            send_input if send_input is not None else _default_send_input
        )

    # --- core injection ---------------------------------------------------------

    def _send_key_event(self, *, w_vk: int, w_scan: int, flags: int) -> int:
        self._buf.type = INPUT_KEYBOARD
        self._buf.union.ki = KEYBDINPUT(w_vk, w_scan, flags, 0, 0)
        sent = self._send_input(1, ctypes.byref(self._buf), ctypes.sizeof(INPUT))
        if sent != 1:
            # UIPI (elevated target), locked/RDP desktop, non-interactive session.
            self._send_failures += 1
            logger.debug(
                "SendInput failed (vk=0x%02X scan=0x%04X flags=0x%02X)", w_vk, w_scan, flags
            )
            return 0
        return 1

    def _resolve(self, key: str) -> str | None:
        name = _normalize_key(key)
        if name is None or name not in KEY_MAP:
            self._unknown_key_hits += 1
            return None
        return name

    def _press_name(self, name: str) -> int:
        vk, extended = KEY_MAP[name]
        flags = KEYEVENTF_EXTENDEDKEY if extended else 0
        sent = self._send_key_event(w_vk=vk, w_scan=0, flags=flags)
        if sent:
            self._held.setdefault(name, None)
        return sent

    def _release_name(self, name: str) -> int:
        vk, extended = KEY_MAP[name]
        flags = KEYEVENTF_KEYUP | (KEYEVENTF_EXTENDEDKEY if extended else 0)
        sent = self._send_key_event(w_vk=vk, w_scan=0, flags=flags)
        if sent:
            self._held.pop(name, None)
        return sent

    # --- public contract (Doc 07 §3) ---------------------------------------------

    def send_text(self, text: str) -> int:
        """Inject text as UTF-16 code units via KEYEVENTF_UNICODE; returns INPUT count."""
        if not isinstance(text, str) or not text:
            return 0
        units = text.encode("utf-16-le")
        sent = 0
        for i in range(0, len(units), 2):
            code_unit = units[i] | (units[i + 1] << 8)
            sent += self._send_key_event(w_vk=0, w_scan=code_unit, flags=KEYEVENTF_UNICODE)
            sent += self._send_key_event(
                w_vk=0, w_scan=code_unit, flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
            )
        return sent

    def key_down(self, key: str) -> bool:
        """Press a named key from KEY_MAP; False (and counted) on unknown name."""
        name = self._resolve(key)
        if name is None:
            return False
        return bool(self._press_name(name))

    def key_up(self, key: str) -> bool:
        """Release a named key from KEY_MAP; False on unknown name or failed inject."""
        name = self._resolve(key)
        if name is None:
            return False
        return bool(self._release_name(name))

    def tap(self, key: str) -> int:
        """key_down + key_up back-to-back; returns INPUT count (2 ok, 0 miss)."""
        name = self._resolve(key)
        if name is None:
            return 0
        return self._press_name(name) + self._release_name(name)

    def hotkey(self, *keys: str) -> int:
        """Press modifiers in fixed order, tap the final key, release pressed modifiers."""
        if not keys:
            return 0
        resolved: list[str] = []
        for key in keys:
            name = self._resolve(key)
            if name is None:
                return 0  # all-or-nothing: abort before injecting anything
            resolved.append(name)
        if len(resolved) == 1:
            return self._press_name(resolved[0]) + self._release_name(resolved[0])
        *modifier_names, final = resolved
        modifiers: list[str] = []
        for modifier in modifier_names:
            if modifier not in MODIFIERS:
                return 0  # misuse on the internal API; never raise
            if modifier not in modifiers:
                modifiers.append(modifier)
        # Press only unheld modifiers, in canonical CTRL -> ALT -> SHIFT -> WIN order;
        # pre-held modifiers stay held and are not released afterwards.
        pressed: list[str] = []
        count = 0
        for modifier in MODIFIER_ORDER:
            if modifier in modifiers and modifier not in self._held:
                sent = self._press_name(modifier)
                count += sent
                if sent:
                    pressed.append(modifier)
        count += self._press_name(final) + self._release_name(final)
        for modifier in reversed(pressed):
            count += self._release_name(modifier)
        return count

    def release_all(self) -> int:
        """Release held modifiers first, then other keys; clears all state."""
        held = list(self._held)
        modifiers = [name for name in held if name in MODIFIERS]
        others = [name for name in held if name not in MODIFIERS]
        released = 0
        for name in [*reversed(modifiers), *reversed(others)]:
            vk, extended = KEY_MAP[name]
            flags = KEYEVENTF_KEYUP | (KEYEVENTF_EXTENDEDKEY if extended else 0)
            released += self._send_key_event(w_vk=vk, w_scan=0, flags=flags)
        self._held.clear()  # cleared even on partial inject: safety hook is idempotent
        return released

    def handle_cmd_key(self, action: str, payload: Mapping[str, object]) -> int:
        """Route one validated CMD_KEY (action, payload) pair; returns INPUT count."""
        handler = CMD_KEY_HANDLERS.get(action)
        if handler is None:
            logger.debug("handle_cmd_key: unknown action %r", action)
            return 0
        return handler(self, payload)

    @property
    def held_keys(self) -> frozenset[str]:
        """Named keys currently tracked as down (modifiers included)."""
        return frozenset(self._held)

    @property
    def send_failures(self) -> int:
        """Monotonic count of SendInput calls that injected fewer events than requested."""
        return self._send_failures

    @property
    def unknown_key_hits(self) -> int:
        """Monotonic count of dropped key names that are absent from KEY_MAP."""
        return self._unknown_key_hits

    # --- internals -----------------------------------------------------------------

    def _tap_raw_vk(self, vk: int) -> int:
        """Press+release a raw wire VK code that has no KEY_MAP name."""
        base = KEYEVENTF_EXTENDEDKEY if vk in _RAW_EXTENDED_VKS else 0
        sent = self._send_key_event(w_vk=vk, w_scan=0, flags=base)
        sent += self._send_key_event(w_vk=vk, w_scan=0, flags=base | KEYEVENTF_KEYUP)
        return sent


# --- CMD_KEY handler table (Doc 07 §5; consumed by Doc 14's router) ---------------


def _payload_vk(payload: Mapping[str, object]) -> int | None:
    vk = payload.get("vk")
    if isinstance(vk, bool) or not isinstance(vk, int):
        return None
    if not (VK_MIN <= vk <= VK_MAX):
        return None
    return vk


def _handle_send_key(kbd: KeyboardEngine, payload: Mapping[str, object]) -> int:
    vk = _payload_vk(payload)
    if vk is None:
        return 0
    name = _VK_TO_NAME.get(vk)
    if name is not None:
        return kbd.tap(name)
    return kbd._tap_raw_vk(vk)


def _handle_send_combo(kbd: KeyboardEngine, payload: Mapping[str, object]) -> int:
    vk = _payload_vk(payload)
    if vk is None:
        return 0
    name = _VK_TO_NAME.get(vk)
    if name is None:
        return 0
    modifiers = payload.get("modifiers", [])
    if isinstance(modifiers, (str, bytes)) or not isinstance(modifiers, Sequence):
        return 0
    resolved: list[str] = []
    for modifier in modifiers:
        normalized = _normalize_key(modifier)
        if normalized not in MODIFIERS:
            return 0
        if normalized not in resolved:
            resolved.append(normalized)
    if len(resolved) > 4:
        return 0
    return kbd.hotkey(*resolved, name)


def _handle_send_text(kbd: KeyboardEngine, payload: Mapping[str, object]) -> int:
    text = payload.get("text")
    if not isinstance(text, str):
        return 0
    return kbd.send_text(text)


CMD_KEY_HANDLERS: dict[str, Callable[[KeyboardEngine, Mapping[str, object]], int]] = {
    "SEND_KEY": _handle_send_key,
    "SEND_COMBO": _handle_send_combo,
    "SEND_TEXT": _handle_send_text,
}
"""Frozen CMD_KEY action registry (Doc 03 §5.4) -> engine dispatch."""


engine = KeyboardEngine()
"""Module singleton consumed by ws_server_router.py (Doc 14)."""
