"""Doc 09: PotPlayer WM_COMMAND / WM_USER command dispatcher.

Table-driven, fire-and-forget delivery of the frozen ``CMD_POTPLAYER`` action set into
PotPlayer's message queue. All PotPlayer-specific message IDs live in
``shared_specs/potplayer_wm_codes.json`` (source of truth, Doc 09); this module contains
no hard-coded command hex. Delivery uses only ``PostMessage`` (async hot path) and
``SendMessageTimeoutW`` (ack path with a hang budget) — neither activates the target
window, so background control never steals focus.
"""

from __future__ import annotations

import ctypes
import json
import logging
import math
import threading
import time
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import win32gui

if TYPE_CHECKING:
    from pc_agent.potplayer.hwnd_locator import PotPlayerLocator

log = logging.getLogger(__name__)

POTPILOT_WM_CODES_PATH: Path = Path("shared_specs/potplayer_wm_codes.json")

SPEED_MIN, SPEED_MAX, SPEED_DEFAULT = 0.2, 4.0, 1.0
SUB_DELAY_STEP_MS = 500
SEND_TIMEOUT_MS = 100  # SendMessageTimeoutW budget, SMTO_ABORTIFHUNG
STEP_INTERVAL_S = 0.01  # rate limit between speed step posts

SMTO_BLOCK = 0x0001
SMTO_ABORTIFHUNG = 0x0002

SEEK_MAX_MS = 2**31 - 1
SUB_DELAY_MAX_MS = 10000

# POT_SEND_VIRTUAL_KEY (0x5010) payloads: PotPlayer default hotkeys, with the
# public modifier flags OR'd in (InternalSimpleCmd.h, available since 2023-08-30).
VK_FLAG_SHIFT = 0x0100
VK_FLAG_CONTROL = 0x0200
VK_FLAG_ALT = 0x0400
VK_FRAME_STEP_FWD = 0x46  # F: frame step forward
VK_FRAME_STEP_BACK = 0x44  # D: frame step backward
VK_SUB_DELAY_FASTER = 0xBE  # '.': subtitle sync +0.5 s per press
VK_SUB_DELAY_SLOWER = 0xBC  # ',': subtitle sync -0.5 s per press

_VALID_PARAMS = {None, "wparam", "lparam", "lparam_loword", "lparam_hiword"}
_VALID_MODES = {"direct", "steps"}
_VALID_STATUS = {"verified", "capture_required"}

# Wire action -> table entry aliases (Doc 09 seed names an internal entry per command;
# the router still speaks the frozen wire names from Doc 03 §5.3).
_ACTION_ALIASES = {"SUB_SYNC_ADJUST": "SUB_DELAY_DELTA"}


class CodeTableError(RuntimeError):
    """Raised at construction when the JSON table is missing/invalid."""


@dataclass(frozen=True)
class DispatchResult:
    """Immutable outcome of one dispatch."""

    ok: bool
    command: str
    hwnd: int | None
    detail: str  # "posted" | "acked" | "no_window" | "unknown_command" | "bad_value"
    #                  | "timeout" | "code_table_unavailable"


def _default_codes_path() -> Path:
    if POTPILOT_WM_CODES_PATH.is_file():
        return POTPILOT_WM_CODES_PATH
    return Path(__file__).resolve().parents[2] / POTPILOT_WM_CODES_PATH


def _parse_hex(name: str, field: str, raw: object) -> int:
    if not isinstance(raw, str):
        raise CodeTableError(f"entry {name!r}: {field!r} must be a hex string, got {raw!r}")
    try:
        return int(raw, 0)
    except ValueError as exc:
        raise CodeTableError(f"entry {name!r}: {field!r} is not parseable: {raw!r}") from exc


def _load_table(path: Path) -> tuple[dict[str, int], dict[str, dict]]:
    """Parse and validate the command table; raises CodeTableError on any violation."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CodeTableError(f"command table unreadable: {path}: {exc}") from exc
    try:
        table = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CodeTableError(f"command table is not valid JSON: {path}: {exc}") from exc
    if not isinstance(table, dict):
        raise CodeTableError(f"command table must be a JSON object: {path}")

    base = table.get("base") or table.get("messages")
    if not isinstance(base, dict) or not base:
        raise CodeTableError("command table needs a non-empty 'base' messages object")
    messages: dict[str, int] = {}
    for name, value in base.items():
        messages[name] = _parse_hex("base", name, value)

    commands = table.get("commands")
    if not isinstance(commands, dict):
        raise CodeTableError("'commands' must be an object")
    for name, entry in commands.items():
        if not isinstance(entry, dict):
            raise CodeTableError(f"entry {name!r} must be an object")
        if entry.get("message") not in messages:
            raise CodeTableError(f"entry {name!r}: unknown message {entry.get('message')!r}")
        _parse_hex(name, "wparam", entry.get("wparam"))
        _parse_hex(name, "lparam", entry.get("lparam"))
        if entry.get("param") not in _VALID_PARAMS:
            raise CodeTableError(f"entry {name!r}: invalid param {entry.get('param')!r}")
        mode = entry.get("mode")
        if mode not in _VALID_MODES:
            raise CodeTableError(f"entry {name!r}: invalid mode {mode!r}")
        if not isinstance(entry.get("needs_ack"), bool):
            raise CodeTableError(f"entry {name!r}: needs_ack must be a bool")
        if entry.get("status") not in _VALID_STATUS:
            raise CodeTableError(f"entry {name!r}: invalid status {entry.get('status')!r}")
        if mode == "steps":
            for key in ("step_up", "step_down"):
                target = entry.get(key)
                if not isinstance(target, str) or target not in commands:
                    raise CodeTableError(f"entry {name!r}: steps mode requires valid {key!r}")
    return messages, dict(commands)


def _post_message(hwnd: int, msg: int, wparam: int, lparam: int) -> None:
    """Non-blocking delivery seam (tests monkeypatch this)."""
    win32gui.PostMessage(hwnd, msg, wparam, lparam)


def _send_message_timeout(hwnd: int, msg: int, wparam: int, lparam: int, timeout_ms: int) -> int:
    """Blocking delivery with hang budget (tests monkeypatch this); non-zero = delivered."""
    result = ctypes.c_size_t(0)
    delivered = ctypes.windll.user32.SendMessageTimeoutW(
        hwnd, msg, wparam, lparam, SMTO_ABORTIFHUNG | SMTO_BLOCK, int(timeout_ms),
        ctypes.byref(result),
    )
    return int(delivered)


def _pack(messages: dict[str, int], entry: dict, value: int | None) -> tuple[int, int, int]:
    msg = messages[entry["message"]]
    wparam, lparam = int(entry["wparam"], 0), int(entry["lparam"], 0)
    if value is not None:
        match entry.get("param"):
            case "wparam":
                wparam = value
            case "lparam":
                lparam = value
            case "lparam_loword":
                lparam = (lparam & ~0xFFFF) | (value & 0xFFFF)
            case "lparam_hiword":
                lparam = (lparam & 0xFFFF) | ((value & 0xFFFF) << 16)
    return msg, wparam, lparam


def _round_half_away(value: float, step: float) -> int:
    """Nearest multiple of step, halves away from zero (e.g. -300 -> -500, 700 -> 500)."""
    return int(math.copysign(math.floor(abs(value) / step + 0.5), value)) * step


def _clamp_speed(multiplier: float) -> float:
    clamped = min(max(float(multiplier), SPEED_MIN), SPEED_MAX)
    return math.floor(clamped * 10 + 0.5) / 10.0  # round to 0.1, half up


class WmDispatcher:
    """Dispatches the frozen CMD_POTPLAYER action set into PotPlayer's message queue."""

    def __init__(
        self,
        locator: PotPlayerLocator,
        codes_path: Path | None = None,
        speed_provider: Callable[[], float] | None = None,
    ) -> None:
        """Load and validate the table; inject locator; speed_provider is steps-mode only."""
        self._locator = locator
        self._speed_provider = speed_provider
        self._codes_path = codes_path if codes_path is not None else _default_codes_path()
        self._lock = threading.Lock()
        messages, commands = _load_table(self._codes_path)  # fail fast on invalid table
        self._messages = messages
        self._commands = commands
        # Belief-guard for SET_SUBS (no absolute set in the public API): PotPlayer
        # shows subtitles by default whenever the file provides a track.
        self._subs_visible = True
        # Speed belief: GET_SPEED is unreported on the live build (raw 0 ->
        # 1.0), so steps-mode math keeps the last applied target and only
        # resyncs from the provider when it reports a genuinely different value.
        self._speed_belief = SPEED_DEFAULT
        self.stats: Counter[str] = Counter()

    # ------------------------------------------------------------ table I/O

    def reload_codes(self) -> None:
        """Hot-reload the JSON table under a lock (used after live ID capture)."""
        try:
            messages, commands = _load_table(self._codes_path)
        except CodeTableError as exc:
            log.warning("reload_codes failed, keeping previous table: %s", exc)
            return
        with self._lock:
            self._messages = messages
            self._commands = commands
        log.info("PotPlayer command table reloaded from %s", self._codes_path)

    def _entry(self, command: str) -> tuple[str, dict] | None:
        name = _ACTION_ALIASES.get(command, command)
        with self._lock:
            entry = self._commands.get(name)
            messages = dict(self._messages)
        if entry is None:
            return None
        return name, {**entry, "__messages": messages}

    # ----------------------------------------------------------- dispatching

    def dispatch(self, command: str, *, value: int | None = None) -> DispatchResult:
        """Look up a table entry, clamp/pack value, post to PotPlayer; never raises."""
        resolved = self._entry(command)
        if resolved is None:
            self.stats["unknown_command"] += 1
            return DispatchResult(False, command, None, "unknown_command")
        name, entry = resolved
        messages: dict[str, int] = entry.pop("__messages")

        if value is not None:
            if isinstance(value, bool):
                value = int(value)
            elif isinstance(value, float):
                value = int(round(value))
            vmin, vmax = entry.get("value_min"), entry.get("value_max")
            if vmin is not None:
                value = max(int(vmin), value)
            if vmax is not None:
                value = min(int(vmax), value)

        if entry.get("param") is not None and value is None:
            self.stats["bad_value"] += 1
            return DispatchResult(False, name, None, "bad_value")
        if entry.get("mode") == "steps":
            # Steps-mode entries must be driven through set_speed()/step_speed().
            self.stats["bad_value"] += 1
            return DispatchResult(False, name, None, "bad_value")

        hwnd = self._locator.find()
        if not hwnd:
            self.stats["no_window"] += 1
            return DispatchResult(False, name, None, "no_window")

        msg, wparam, lparam = _pack(messages, entry, value)
        return self._deliver(name, entry, hwnd, msg, wparam, lparam)

    def _deliver(
        self, name: str, entry: dict, hwnd: int, msg: int, wparam: int, lparam: int
    ) -> DispatchResult:
        needs_ack = bool(entry.get("needs_ack"))
        for attempt in (1, 2):
            try:
                if needs_ack:
                    delivered = _send_message_timeout(hwnd, msg, wparam, lparam, SEND_TIMEOUT_MS)
                    detail = "acked" if delivered else "timeout"
                else:
                    _post_message(hwnd, msg, wparam, lparam)
                    detail = "posted"
            except OSError as exc:
                # Invalid/dead HWND (WinError 1400 family): re-locate and retry exactly once.
                log.debug("delivery failed (attempt %d) for %s: %s", attempt, name, exc)
                self._locator.invalidate()
                if attempt == 2:
                    self.stats["no_window"] += 1
                    return DispatchResult(False, name, None, "no_window")
                hwnd = self._locator.find()
                if not hwnd:
                    self.stats["no_window"] += 1
                    return DispatchResult(False, name, None, "no_window")
                continue
            ok = detail in ("posted", "acked")
            self.stats[detail] += 1
            return DispatchResult(ok, name, hwnd, detail)
        raise AssertionError("unreachable")  # pragma: no cover

    # -------------------------------------------------------- typed methods

    def play_pause(self) -> DispatchResult:
        """Toggle playback (PLAY_PAUSE)."""
        return self.dispatch("PLAY_PAUSE")

    def frame_step(self, direction: str = "FORWARD") -> DispatchResult:
        """Step one frame; direction is the frozen "FORWARD" | "BACKWARD" (F/D key)."""
        if direction == "FORWARD":
            value = VK_FRAME_STEP_FWD
        elif direction == "BACKWARD":
            value = VK_FRAME_STEP_BACK
        else:
            return DispatchResult(False, "FRAME_STEP", None, "bad_value")
        return self.dispatch("FRAME_STEP", value=value)

    def set_speed(self, multiplier: float) -> DispatchResult:
        """Set playback speed; clamps to 0.2–4.0, rounds to 0.1."""
        try:
            target = _clamp_speed(multiplier)
        except (TypeError, ValueError):
            return DispatchResult(False, "SET_SPEED", None, "bad_value")
        resolved = self._entry("SET_SPEED")
        if resolved is None:
            self.stats["unknown_command"] += 1
            return DispatchResult(False, "SET_SPEED", None, "unknown_command")
        name, entry = resolved
        entry.pop("__messages", None)
        if entry.get("mode") == "steps":
            return self._steps_toward(name, entry, target)
        result = self.dispatch("SET_SPEED", value=int(round(target * 1000)))
        if result.ok:
            self._speed_belief = target
        return result

    def step_speed(self, delta: float) -> DispatchResult:
        """Internal relative speed step; uses the last known speed state."""
        resolved = self._entry("SET_SPEED")
        if resolved is None:
            self.stats["unknown_command"] += 1
            return DispatchResult(False, "SET_SPEED", None, "unknown_command")
        name, entry = resolved
        entry.pop("__messages", None)
        if entry.get("mode") != "steps":
            return DispatchResult(False, name, None, "bad_value")
        current = self._current_speed()
        if current is None:
            return DispatchResult(False, name, None, "bad_value")
        try:
            target = _clamp_speed(current + float(delta))
        except (TypeError, ValueError):
            return DispatchResult(False, name, None, "bad_value")
        return self._steps_toward(name, entry, target)

    def cycle_audio_track(self) -> DispatchResult:
        """Cycle audio streams."""
        return self.dispatch("CYCLE_AUDIO")

    def cycle_subtitle_track(self) -> DispatchResult:
        """Cycle subtitle tracks."""
        return self.dispatch("CYCLE_SUBS")

    def toggle_subtitles(self) -> DispatchResult:
        """Toggle subtitles on/off (flips the tracked visibility belief)."""
        result = self.dispatch("SET_SUBS_TOGGLE")
        if result.ok:
            self._subs_visible = not self._subs_visible
        return result

    def set_subtitles(self, enabled: bool) -> DispatchResult:
        """Absolute show/hide: post a toggle only when the desired state differs
        from the tracked belief (best-effort — the public API has no absolute set)."""
        if not isinstance(enabled, bool):
            return DispatchResult(False, "SET_SUBS", None, "bad_value")
        if self._subs_visible == enabled:
            return DispatchResult(True, "SET_SUBS", self._locator.find(), "posted")
        result = self.dispatch("SET_SUBS_TOGGLE")
        if result.ok:
            self._subs_visible = enabled
        return DispatchResult(result.ok, "SET_SUBS", result.hwnd, result.detail)

    def adjust_subtitle_delay(self, delta_ms: int = SUB_DELAY_STEP_MS) -> DispatchResult:
        """Nudge subtitle sync; rounded to the nearest multiple of ±500 ms and
        replayed as that many default-key presses ('.' faster / ',' slower)."""
        try:
            rounded = _round_half_away(int(delta_ms), SUB_DELAY_STEP_MS)
        except (TypeError, ValueError):
            return DispatchResult(False, "SUB_DELAY_DELTA", None, "bad_value")
        if rounded == 0:
            return DispatchResult(False, "SUB_DELAY_DELTA", None, "bad_value")
        key = VK_SUB_DELAY_FASTER if rounded > 0 else VK_SUB_DELAY_SLOWER
        result = DispatchResult(False, "SUB_DELAY_DELTA", None, "bad_value")
        for _ in range(abs(rounded) // SUB_DELAY_STEP_MS):
            result = self.dispatch("SUB_DELAY_DELTA", value=key)
            if not result.ok:
                return result
        return result

    def seek_ms(self, position_ms: int) -> DispatchResult:
        """Absolute seek (UDP 0x04 target_seconds and scrub-bar taps)."""
        try:
            position = int(position_ms)
        except (TypeError, ValueError):
            return DispatchResult(False, "SEEK", None, "bad_value")
        position = min(max(position, 0), SEEK_MAX_MS)
        return self.dispatch("SEEK", value=position)

    # -------------------------------------------------------------- helpers

    def _current_speed(self) -> float | None:
        if self._speed_provider is None:
            return None
        try:
            value = float(self._speed_provider())
        except (TypeError, ValueError):
            return None
        if not math.isfinite(value) or value <= 0:
            return None
        value = _clamp_speed(value)
        if value != SPEED_DEFAULT:
            self._speed_belief = value  # provider reported a real speed: resync
            return value
        # Exactly 1.0 is ambiguous (true default vs unreported 0x5015): keep the
        # belief, otherwise every identical target would re-apply its steps.
        return self._speed_belief

    def _steps_toward(self, name: str, entry: dict, target: float) -> DispatchResult:
        current = self._current_speed()
        if current is None:
            return DispatchResult(False, name, None, "bad_value")
        steps = int(round((target - current) * 10))
        if steps == 0:
            return DispatchResult(True, name, self._locator.find(), "posted")
        step_name = entry.get("step_up") if steps > 0 else entry.get("step_down")
        if not isinstance(step_name, str) or step_name not in self._commands:
            return DispatchResult(False, name, None, "bad_value")
        count = abs(steps)

        def _worker() -> None:
            for _ in range(count):
                if self._locator.find() is None:
                    return  # window vanished mid-steps: cancel the remainder
                result = self.dispatch(step_name)
                if result.detail == "no_window":
                    return
                time.sleep(STEP_INTERVAL_S)

        threading.Thread(target=_worker, daemon=True, name="potpilot-speed-steps").start()
        self.stats["posted"] += 1
        self._speed_belief = target  # best-effort: applied steps may be cut short
        return DispatchResult(True, name, self._locator.find(), "posted")
