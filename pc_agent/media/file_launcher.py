"""Doc 21: PotPlayer file launcher (validate → spawn fullscreen → HWND wait → snap).

Owns the frozen ``CMD_MEDIA``/``LAUNCH_MEDIA`` wire surface dispatched by Doc 14:
the request payload is exactly ``{"path": str}`` (Doc 03 §5.5 pins all flags off
the wire) and the success response is exactly ``{"ok": true, "started": true}``
— ``hwnd``, ``snapped`` and ``elapsed_ms`` live only in the internal
:class:`LaunchResult` and the module log.  ``started`` tells the client the
spawn/hand-off completed before the ack was sent (Doc 45 confirms the actual
playback via telemetry).

Pipeline (§4): validate the path against Doc 20's extension set → resolve the
player exe (config ``potplayer_exe_path`` else ``DEFAULT_PLAYER_PATH``) → spawn
``[exe, path, /fullscreen]`` with ``subprocess.Popen`` in a worker thread and
wait out the single-instance hand-off for at most ``HANDOFF_GRACE_S`` (a
cold-started primary player outlives the grace window and is reaped by a
background thread — it is never killed) → poll Doc 08's locator
every ``HWND_POLL_INTERVAL_S`` until ``HWND_WAIT_TIMEOUT_S`` → Doc 11
``snap_to_primary()`` in a worker thread.  Every failure is a
:class:`FileLaunchError` with a frozen ``E_*`` code; HWND timeout and snap
failures degrade softly (launch still succeeds, ``snapped:false`` logged).
Concurrent launches serialize on a module-level ``asyncio.Lock``.
"""

from __future__ import annotations

import asyncio
import logging
import os
import subprocess
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from pc_agent.media.library_scanner import VIDEO_EXTENSIONS, is_supported_video

if TYPE_CHECKING:
    from pc_agent.core.config_manager import ConfigManager
    from pc_agent.display_power.monitor_snapper import MonitorSnapper
    from pc_agent.network.ws_server_router import WsEnvelope, WsSession
    from pc_agent.potplayer.hwnd_locator import PotPlayerLocator

log = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Frozen constants (Doc 21 §3 / §5)
# ------------------------------------------------------------------
ACT_LAUNCH_MEDIA: str = "LAUNCH_MEDIA"
FULLSCREEN_SWITCH: str = "/fullscreen"
HWND_WAIT_TIMEOUT_S: float = 5.0
HWND_POLL_INTERVAL_S: float = 0.1
DEFAULT_PLAYER_PATH: str = r"C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe"
# Probed in order when no potplayer_exe_path is configured (§7): the 64-bit
# default first, then the common 32-bit "Program Files (x86)" install layout.
_DEFAULT_FALLBACK_PATHS: tuple[str, ...] = (
    r"C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe",
    r"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
    r"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayer64.exe",
)


def default_player_candidates() -> tuple[str, ...]:
    """Config-absent probe order; ``DEFAULT_PLAYER_PATH`` first (patchable in tests)."""
    return (DEFAULT_PLAYER_PATH, *_DEFAULT_FALLBACK_PATHS)
ERR_FILE_NOT_FOUND: str = "E_FILE_NOT_FOUND"
ERR_UNSUPPORTED_TYPE: str = "E_UNSUPPORTED_TYPE"
ERR_PLAYER_NOT_FOUND: str = "E_PLAYER_NOT_FOUND"
ERR_LAUNCH_FAILED: str = "E_LAUNCH_FAILED"
ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"

PLAYER_PATH_KEY: str = "potplayer_exe_path"  # Doc 26 additive config key (A2)
HANDOFF_GRACE_S: float = 1.0  # bound on waiting for the single-instance hand-off

# §4 State: concurrent launches serialize here — never two subprocess/HWND
# sequences interleaved.  Created at import (no loop binding since 3.10).
_launch_lock = asyncio.Lock()


class FileLaunchError(Exception):
    """Domain error carrying a frozen wire error code (§3)."""

    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(detail or code)
        self.code = code
        self.detail = detail or code


@dataclass(frozen=True, slots=True)
class LaunchResult:
    """Internal launch outcome — logged, never serialized onto the wire (§5.6)."""

    path: str  # absolute normalized path that was launched
    launched: bool  # subprocess spawned successfully
    hwnd: int | None  # PotPlayer HWND found within timeout, else None
    snapped: bool  # snap_to_primary() executed successfully
    elapsed_ms: int  # end-to-end latency of launch() including the wait


def _sanitize_detail(message: str) -> str:
    """Strip control characters so error details stay single-line wire-safe (§7)."""
    return "".join(char for char in message if char.isprintable())


def _spawn_player(argv: list[str]) -> None:
    """Spawn the player and wait out the single-instance hand-off (§4.3).

    Runs in a worker thread.  A secondary instance that forwards the file to
    the running primary exits on its own — a normal exit within the grace
    window ends the wait; a cold-started primary outlives it and is reaped by
    a background thread (never killed).  A nonzero exit inside the grace window
    means the hand-off/spawn itself failed → :class:`FileLaunchError`.
    """
    proc = subprocess.Popen(argv)
    try:
        returncode = proc.wait(timeout=HANDOFF_GRACE_S)
    except subprocess.TimeoutExpired:
        # Primary instance still running (or a slow hand-off): reap in the
        # background so the process handle never leaks.
        threading.Thread(
            target=proc.wait, name="potpilot-player-reap", daemon=True
        ).start()
        return
    if returncode not in (0, None):
        raise FileLaunchError(
            ERR_LAUNCH_FAILED, f"player exited with code {returncode}"
        )


class FileLauncher:
    """Validate paths, spawn PotPlayer64.exe, wait for its HWND, snap to primary."""

    def __init__(
        self,
        locator: PotPlayerLocator,
        snapper: MonitorSnapper,
        config: ConfigManager,
        *,
        hwnd_timeout_s: float = HWND_WAIT_TIMEOUT_S,
    ) -> None:
        self._locator = locator
        self._snapper = snapper
        self._config = config
        self._hwnd_timeout_s = float(hwnd_timeout_s)
        self._now: Callable[[], float] = time.monotonic  # timeout clock seam

    # -------------------------------------------------------------- resolution

    def _configured_player(self) -> str | None:
        """Read ``potplayer_exe_path`` tolerantly: attribute, extras dict, or mapping (§10 A2)."""
        sources: list[Any] = []
        getter = getattr(self._config, "get", None)
        if callable(getter):
            try:
                sources.append(getter())
            except TypeError:
                pass  # plain dict.get() needs a key — the mapping branch below covers it
        extra = getattr(self._config, "_extra", None)
        if extra is not None:
            sources.append(extra)
        if isinstance(self._config, Mapping):
            sources.append(self._config)
        for source in sources:
            if source is None:
                continue
            if isinstance(source, Mapping):
                value = source.get(PLAYER_PATH_KEY)
            else:
                value = getattr(source, PLAYER_PATH_KEY, None)
            if isinstance(value, str) and value.strip():
                return value.strip()
        return None

    def resolve_player_exe(self) -> str:
        """Config ``potplayer_exe_path`` else the first existing default candidate.

        A configured-but-wrong path deliberately does **not** fall back to a
        default — §7 requires the error so Doc 24 can prompt the user to fix it.
        With no config key, known install layouts are probed (64-bit default,
        then the x86 install) so fresh installs resolve without setup.
        """
        configured = self._configured_player()
        if configured is not None:
            if os.path.isfile(configured):
                return configured
            raise FileLaunchError(
                ERR_PLAYER_NOT_FOUND, f"player executable not found: {configured}"
            )
        tried: list[str] = []
        for candidate in default_player_candidates():
            if os.path.isfile(candidate):
                return candidate
            tried.append(candidate)
        raise FileLaunchError(
            ERR_PLAYER_NOT_FOUND,
            "player executable not found: " + ", ".join(tried),
        )

    # -------------------------------------------------------------- pipeline

    @staticmethod
    def _validate_path(path: str) -> str:
        """Absolute-normalize a launchable video path; raises before touching PotPlayer (§4.1)."""
        if not isinstance(path, str) or not path.strip():
            raise FileLaunchError(ERR_BAD_PAYLOAD, "path must be a non-empty string")
        normalized = os.path.abspath(os.path.normpath(path))
        if os.path.isdir(normalized):
            raise FileLaunchError(ERR_UNSUPPORTED_TYPE, f"path is a directory: {normalized}")
        if not os.path.isfile(normalized):
            raise FileLaunchError(ERR_FILE_NOT_FOUND, f"media file not found: {normalized}")
        if not is_supported_video(normalized):
            extension = os.path.splitext(normalized)[1] or "(none)"
            supported = ", ".join(sorted(VIDEO_EXTENSIONS))
            raise FileLaunchError(
                ERR_UNSUPPORTED_TYPE,
                f"unsupported media type {extension}; supported: {supported}",
            )
        return normalized

    async def launch(self, path: str) -> LaunchResult:
        """Full pipeline: validate → spawn → wait HWND → snap. Raises FileLaunchError on failure."""
        started = self._now()
        normalized = self._validate_path(path)
        exe = self.resolve_player_exe()
        async with _launch_lock:
            argv = [exe, normalized, FULLSCREEN_SWITCH]
            try:
                await asyncio.to_thread(_spawn_player, argv)
            except FileLaunchError:
                raise
            except Exception as exc:
                detail = _sanitize_detail(str(exc)) or type(exc).__name__
                raise FileLaunchError(ERR_LAUNCH_FAILED, detail) from exc
            hwnd = await self._wait_for_hwnd()
            snapped = await self._snap_to_primary() if hwnd is not None else False
            elapsed_ms = int((self._now() - started) * 1000)
            log.info(
                "LAUNCH_MEDIA ok: hwnd=%s snapped=%s elapsed_ms=%d",
                hwnd,
                snapped,
                elapsed_ms,
            )
            return LaunchResult(
                path=normalized,
                launched=True,
                hwnd=hwnd,
                snapped=snapped,
                elapsed_ms=elapsed_ms,
            )

    async def _wait_for_hwnd(self) -> int | None:
        """Poll Doc 08's locator every ``HWND_POLL_INTERVAL_S`` until timeout (§4.4)."""
        wait_started = self._now()
        while True:
            hwnd = await asyncio.to_thread(self._locator.find)
            if hwnd:
                return int(hwnd)
            if self._now() - wait_started >= self._hwnd_timeout_s:
                log.warning(
                    "PotPlayer HWND not observed within %.1fs; skipping snap",
                    self._hwnd_timeout_s,
                )
                return None
            await asyncio.sleep(HWND_POLL_INTERVAL_S)

    async def _snap_to_primary(self) -> bool:
        """Doc 11 snap in a worker thread; failure degrades to ``snapped:false`` (§4.5/§7)."""
        try:
            result = await asyncio.to_thread(self._snapper.snap_to_primary)
        except Exception:
            log.warning("post-launch snap raised; window may stay off-primary", exc_info=True)
            return False
        if not getattr(result, "ok", False):
            log.warning("post-launch snap not applied: %s", getattr(result, "detail", "unknown"))
            return False
        return True

    # ------------------------------------------------------ Doc 14 wire seam

    async def handle_launch_media(
        self, session: WsSession, envelope: WsEnvelope
    ) -> dict[str, Any]:
        """``LAUNCH_MEDIA``: ``{"ok": true, "started": true}`` or frozen error payload (§5)."""
        del session
        try:
            await self.launch(envelope.payload.get("path"))
        except FileLaunchError as exc:
            return {"ok": False, "error": exc.code, "detail": exc.detail}
        return {"started": True}  # build_ack supplies ok:true
