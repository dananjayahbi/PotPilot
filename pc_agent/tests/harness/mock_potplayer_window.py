"""Doc 46 §4.3 — mock ``PotPlayer64`` Win32 window harness.

Registers a real window class whose class name is exactly ``PotPlayer64``
(Doc 08 locates via ``FindWindow("PotPlayer64", None)``), creates one
zero-size top-level window, and pumps its message queue on a daemon thread:

* ``WM_COMMAND``  → append ``wparam`` to the log, toggle the fake play-state bit;
* ``WM_USER``     → log ``(msg, wparam)``/``lparam``; reply to getter queries
  from a monotonic-clock model (position advances in real time while playing);
  values delivered to setter messages are forwarded to the optional
  ``on_wm_user_value`` callback;
* ``WM_DESTROY``  → ``PostQuitMessage`` so :func:`win32gui.PumpMessages` returns.

The window is created with ``WS_VISIBLE`` but zero width/height plus
``WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`` — Doc 08's locator only accepts
visible windows, while a 0×0 tool window paints nothing, never appears in the
taskbar/Alt-Tab, and never activates: the "hidden, no focus stealing"
guarantee of the spec with discoverability preserved. Nothing ever calls
``SetForegroundWindow``/``ShowWindow``.

Captured-table note: the real table in ``shared_specs/potplayer_wm_codes.json``
routes getters as ``(WM_USER, wparam, 0)`` with distinct POT_GET_* wparams
(0x5004/0x5002/0x5006/0x5000/0x5015), so replies are keyed directly by
wparam. ``POT_SET_PLAY_STATUS`` (0x5007) applies lparam 0/1/2 as
toggle/paused/running; values delivered to other setters are forwarded to the
optional ``on_wm_user_value`` callback (e.g. seek → position).
"""

from __future__ import annotations

import os
import threading
import time
from collections.abc import Callable

import win32api
import win32gui
import win32process

CLASS_NAME = "PotPlayer64"
WINDOW_TITLE = "PotPlayer64 (QA harness)"

WM_CLOSE = 0x0010
WM_DESTROY = 0x0002
WM_COMMAND = 0x0111
WM_USER = 0x0400

# Real-table POT_* wparams (shared_specs/potplayer_wm_codes.json).
GETTER_WPARAMS: dict[int, str] = {
    0x5004: "GET_POSITION_MS",
    0x5002: "GET_DURATION_MS",
    0x5006: "GET_PLAY_STATE",
    0x5000: "GET_VOLUME",
    0x5015: "GET_SPEED",
}
SET_PLAY_STATUS = 0x5007  # lparam 0 toggle / 1 paused / 2 running

WS_VISIBLE = 0x10000000
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_NOACTIVATE = 0x08000000

_STATE_PLAYING = 2
_STATE_PAUSED = 1
_READY_TIMEOUT_S = 5.0
_JOIN_TIMEOUT_S = 5.0

_active: MockPotPlayerWindow | None = None
_class_lock = threading.Lock()
_class_registered = False


class MockPotPlayerWindow:
    """Hidden zero-size ``PotPlayer64`` window recording WM_COMMAND / WM_USER traffic."""

    def __init__(
        self,
        *,
        duration_ms: int = 600_000,
        position_ms: int = 0,
        playing: bool = False,
        volume: int = 50,
        speed: float = 1.0,
    ) -> None:
        """Configure the fake playback model; no Win32 call until :meth:`start`."""
        self._lock = threading.Lock()
        self._commands: list[int] = []
        self._command_times: list[float] = []
        self._user_msgs: list[tuple[int, int]] = []
        self._user_times: list[float] = []
        self._user_details: list[tuple[int, int, int]] = []
        self._position_ms = max(0, int(position_ms))
        self._duration_ms = max(0, int(duration_ms))
        self._playing = bool(playing)
        self._volume = min(max(int(volume), 0), 100)
        self._speed = float(speed)
        self._anchor = time.monotonic()
        self.on_wm_user_value: Callable[[int], None] | None = None
        self._hwnd = 0
        self._thread: threading.Thread | None = None
        self._ready = threading.Event()
        self._start_error: str | None = None

    # ------------------------------------------------------------- lifecycle

    def start(self) -> None:
        """Collision-check, register the class, create the window, start the pump thread."""
        global _active
        if self._thread is not None:
            raise RuntimeError("mock PotPlayer window already started")
        with _class_lock:
            if _active is not None:
                raise RuntimeError(
                    "another MockPotPlayerWindow is active in this process; stop it first"
                )
            self._ensure_no_real_player()
            _register_class()
            _active = self
        self._ready = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name="potpilot-mock-potplayer", daemon=True
        )
        self._thread.start()
        try:
            if not self._ready.wait(_READY_TIMEOUT_S):
                raise RuntimeError("mock PotPlayer64 window did not come up within 5 s")
            if self._hwnd == 0:
                raise RuntimeError(
                    f"mock PotPlayer64 window creation failed: {self._start_error or 'unknown'}"
                )
            if not win32gui.FindWindow(CLASS_NAME, None):
                raise RuntimeError(
                    "locator sanity check failed: FindWindow('PotPlayer64', None) == 0"
                )
        except Exception:
            self.stop()
            raise

    def stop(self) -> None:
        """Post WM_CLOSE, join the pump, release the active slot; idempotent."""
        global _active
        thread, self._thread = self._thread, None
        if thread is None:
            return
        hwnd = self._hwnd
        if hwnd and win32gui.IsWindow(hwnd):
            try:
                win32gui.PostMessage(hwnd, WM_CLOSE, 0, 0)
            except win32gui.error:  # pragma: no cover - window already gone
                pass
        thread.join(_JOIN_TIMEOUT_S)
        with _class_lock:
            if _active is self:
                _active = None
        if thread.is_alive():
            raise RuntimeError("mock PotPlayer window pump did not stop within 5 s")

    # ----------------------------------------------------------- model access

    @property
    def hwnd(self) -> int:
        """HWND of the live mock window (0 before start / after stop)."""
        return self._hwnd

    @property
    def position_ms(self) -> int:
        """Current model position; advances in real time while playing."""
        with self._lock:
            return self._position_locked()

    def set_position_ms(self, ms: int) -> None:
        """Drive the position model (re-anchors the monotonic clock)."""
        with self._lock:
            self._position_ms = max(0, int(ms))
            self._anchor = time.monotonic()

    @property
    def playing(self) -> bool:
        with self._lock:
            return self._playing

    def set_playing(self, playing: bool) -> None:
        """Flip play state without letting the position jump across the transition."""
        with self._lock:
            self._set_playing_locked(bool(playing))

    @property
    def duration_ms(self) -> int:
        return self._duration_ms

    @property
    def volume(self) -> int:
        return self._volume

    @property
    def speed(self) -> float:
        return self._speed

    # ----------------------------------------------------------- message logs

    @property
    def received_commands(self) -> list[int]:
        """Every ``WM_COMMAND`` wparam received, in arrival order."""
        with self._lock:
            return list(self._commands)

    @property
    def received_command_times(self) -> list[float]:
        """``time.monotonic()`` receipt stamp for each ``WM_COMMAND`` entry."""
        with self._lock:
            return list(self._command_times)

    @property
    def received_user_msgs(self) -> list[tuple[int, int]]:
        """Every ``WM_USER`` entry as ``(msg, wparam)`` per Doc 46 §3."""
        with self._lock:
            return list(self._user_msgs)

    @property
    def received_user_times(self) -> list[float]:
        """``time.monotonic()`` receipt stamp for each ``WM_USER`` entry."""
        with self._lock:
            return list(self._user_times)

    @property
    def received_user_details(self) -> list[tuple[int, int, int]]:
        """Richer ``WM_USER`` log as ``(msg, wparam, lparam)`` (lparam = value)."""
        with self._lock:
            return list(self._user_details)

    # ---------------------------------------------------------------- internals

    def _ensure_no_real_player(self) -> None:
        """Doc 46 §4.3: abort on class collision with a real (or stale) PotPlayer."""
        hwnd = int(win32gui.FindWindow(CLASS_NAME, None) or 0)
        if not hwnd:
            return
        try:
            _thread_id, pid = win32process.GetWindowThreadProcessId(hwnd)
        except (win32process.error, OSError):  # pragma: no cover - exotic window death
            pid = -1
        if pid == os.getpid():
            raise RuntimeError(
                f"stale mock PotPlayer window hwnd={hwnd} left in this process — "
                "restart the test session"
            )
        raise RuntimeError(
            f"a real PotPlayer64 window is open (hwnd={hwnd}, pid={pid}) — "
            "close PotPlayer64 for harness runs"
        )

    def _run(self) -> None:
        """Pump thread: create the window, then block in the message loop."""
        try:
            hwnd = win32gui.CreateWindowEx(
                WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                CLASS_NAME,
                WINDOW_TITLE,
                WS_VISIBLE,
                0,
                0,  # zero size: discoverable by Doc 08 (visible) yet unpaintable
                0,
                0,
                0,
                0,
                win32api.GetModuleHandle(None),
                None,
            )
        except Exception as exc:  # surface any creation failure to start()
            self._start_error = str(exc)
            self._ready.set()
            return
        self._hwnd = int(hwnd)
        self._ready.set()
        win32gui.PumpMessages()  # returns after WM_DESTROY → PostQuitMessage

    def _record_command(self, wparam: int) -> None:
        with self._lock:
            self._commands.append(int(wparam))
            self._command_times.append(time.monotonic())
            self._set_playing_locked(not self._playing)  # fake play-state toggle bit

    def _record_user(self, wparam: int, lparam: int) -> int:
        wparam, lparam = int(wparam), int(lparam)
        with self._lock:
            self._user_msgs.append((WM_USER, wparam))
            self._user_times.append(time.monotonic())
            self._user_details.append((WM_USER, wparam, lparam))
            getter_name = GETTER_WPARAMS.get(wparam)
            if getter_name is not None and lparam == 0:
                return self._getter_value_locked(getter_name)
            if wparam == SET_PLAY_STATUS:
                self._apply_play_status_locked(lparam)
                return 1
            callback = self.on_wm_user_value
        if callback is not None:
            callback(lparam)  # outside the lock: callback may call set_position_ms
        return 1  # non-zero LRESULT = "handled" (ack path, Doc 09)

    def _apply_play_status_locked(self, value: int) -> None:
        """POT_SET_PLAY_STATUS semantics: 0 toggle, 1 paused, 2 running."""
        if value == 0:
            self._set_playing_locked(not self._playing)
        elif value == 1:
            self._set_playing_locked(False)
        elif value == 2:
            self._set_playing_locked(True)

    def _getter_value_locked(self, name: str) -> int:
        if name == "GET_POSITION_MS":
            return self._position_locked()
        if name == "GET_DURATION_MS":
            return self._duration_ms
        if name == "GET_PLAY_STATE":
            return _STATE_PLAYING if self._playing else _STATE_PAUSED
        if name == "GET_VOLUME":
            return self._volume
        return int(round(self._speed * 1000))  # GET_SPEED, speed_milli units

    def _position_locked(self) -> int:
        if not self._playing:
            return int(self._position_ms)
        elapsed_ms = (time.monotonic() - self._anchor) * 1000.0 * self._speed
        return int(min(self._position_ms + elapsed_ms, float(self._duration_ms)))

    def _set_playing_locked(self, playing: bool) -> None:
        if playing == self._playing:
            return
        self._position_ms = self._position_locked()  # freeze progress at the flip
        self._anchor = time.monotonic()
        self._playing = playing


def _register_class() -> None:
    """Register ``PotPlayer64`` once per process; fail loudly on any collision."""
    global _class_registered
    if _class_registered:
        return
    wc = win32gui.WNDCLASS()
    wc.hInstance = win32api.GetModuleHandle(None)
    wc.lpszClassName = CLASS_NAME
    wc.lpfnWndProc = _window_proc
    try:
        win32gui.RegisterClass(wc)
    except win32gui.error as exc:
        raise RuntimeError(
            f"window class {CLASS_NAME!r} already registered in this process "
            f"(stale harness state?) — restart the test session: {exc}"
        ) from exc
    _class_registered = True


def _window_proc(hwnd: int, msg: int, wparam: int, lparam: int, *_args: object) -> int:
    """Single process-wide WNDPROC dispatching to the active mock instance."""
    instance = _active
    if instance is not None:
        if msg == WM_COMMAND:
            instance._record_command(wparam)
            return 0
        if msg == WM_USER:
            return instance._record_user(wparam, lparam)
        if msg == WM_DESTROY and hwnd == instance.hwnd:
            win32gui.PostQuitMessage(0)
            return 0
    return int(win32gui.DefWindowProc(hwnd, msg, wparam, lparam))
