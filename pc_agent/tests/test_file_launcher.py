"""Doc 21 unit tests: PotPlayer file launcher (subprocess, HWND and snapper all faked)."""

from __future__ import annotations

import asyncio
import json
import subprocess
import time
import uuid
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from pc_agent.media import file_launcher as fl
from pc_agent.media.file_launcher import (
    ACT_LAUNCH_MEDIA,
    ERR_FILE_NOT_FOUND,
    ERR_LAUNCH_FAILED,
    ERR_PLAYER_NOT_FOUND,
    ERR_UNSUPPORTED_TYPE,
    FileLauncher,
    FileLaunchError,
)
from pc_agent.network.ws_server_router import WsRouter, WsSession, parse_envelope


class FakeLocator:
    """Doc 08 locator stand-in: scripted ``find()`` results (last value repeats)."""

    def __init__(self, results: list[int | None]) -> None:
        self._results = list(results)
        self.calls = 0

    def find(self, *, force: bool = False) -> int | None:
        del force
        self.calls += 1
        if not self._results:
            return None
        if len(self._results) == 1:
            return self._results[0]
        return self._results.pop(0)


class FakeSnapper:
    """Doc 11 snapper stand-in recording invocations (no monitor APIs touched)."""

    def __init__(self, ok: bool = True) -> None:
        self.ok = ok
        self.calls = 0

    def snap_to_primary(self, *, maximize: bool = True) -> SimpleNamespace:
        del maximize
        self.calls += 1
        return SimpleNamespace(ok=self.ok, detail="snapped" if self.ok else "verify_failed")


class FakeConfig:
    """ConfigManager stand-in exposing only ``get().potplayer_exe_path`` (§10 A2)."""

    def __init__(self, player_path: str | None = None) -> None:
        self._player = player_path

    def get(self) -> SimpleNamespace:
        app = SimpleNamespace()
        if self._player is not None:
            app.potplayer_exe_path = self._player
        return app


class FakeSocket:
    """Minimal ``websockets`` connection stand-in for the router-level check."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


@pytest.fixture(autouse=True)
def spawn(monkeypatch: Any) -> SimpleNamespace:
    """Patch ``subprocess.Popen`` for EVERY test — a real PotPlayer must never start.

    The fake process records ``start``/``end`` events inside ``wait()`` so the
    launch-sequencing tests keep their original blocking-run semantics.
    """
    env = SimpleNamespace(argvs=[], events=[], error=None, delay_s=0.0, exit_code=0)

    class _FakeProc:
        def __init__(self, argv: list[str]) -> None:
            self._argv = list(argv)
            self._started = False
            self._ended = False
            self._remaining = env.delay_s

        def wait(self, timeout: float | None = None) -> int:
            file = self._argv[1]
            if not self._started:
                self._started = True
                env.events.append(("start", file))
            if self._ended:
                return env.exit_code
            if timeout is not None and self._remaining > timeout:
                time.sleep(timeout)
                self._remaining -= timeout
                raise subprocess.TimeoutExpired(self._argv, timeout)
            if self._remaining:
                time.sleep(self._remaining)
                self._remaining = 0.0
            if not self._ended:
                self._ended = True
                env.events.append(("end", file))
            return env.exit_code

    def fake_popen(argv: list[str], **kwargs: Any) -> _FakeProc:
        del kwargs
        env.argvs.append(list(argv))
        if env.error is not None:
            raise env.error
        return _FakeProc(argv)

    monkeypatch.setattr(
        fl,
        "subprocess",
        SimpleNamespace(Popen=fake_popen, TimeoutExpired=subprocess.TimeoutExpired),
    )
    return env


def _video(tmp_path: Path, name: str = "Film.mkv") -> Path:
    path = tmp_path / name
    path.write_bytes(b"x" * 32)
    return path


def _exe(tmp_path: Path) -> Path:
    exe = tmp_path / "PotPlayer64.exe"
    exe.write_bytes(b"MZ")
    return exe


def _envelope(path: str) -> Any:
    return parse_envelope(
        json.dumps(
            {
                "id": str(uuid.uuid4()),
                "type": "CMD_MEDIA",
                "action": ACT_LAUNCH_MEDIA,
                "payload": {"path": path},
                "timestamp": int(time.time()),
            }
        )
    )


def test_rejects_unsupported_extension(
    tmp_path: Path, spawn: SimpleNamespace
) -> None:
    video = tmp_path / "notes.txt"
    video.write_text("not a video")
    launcher = FileLauncher(FakeLocator([None]), FakeSnapper(), FakeConfig())

    async def scenario() -> str:
        with pytest.raises(FileLaunchError) as excinfo:
            await launcher.launch(str(video))
        return excinfo.value.code

    assert asyncio.run(scenario()) == ERR_UNSUPPORTED_TYPE
    assert spawn.argvs == []  # rejected before any process is spawned


def test_rejects_missing_file(tmp_path: Path, spawn: SimpleNamespace) -> None:
    gone = tmp_path / "deleted.mkv"  # indexed earlier, gone from disk now (§7)
    launcher = FileLauncher(FakeLocator([None]), FakeSnapper(), FakeConfig())

    async def scenario() -> str:
        with pytest.raises(FileLaunchError) as excinfo:
            await launcher.launch(str(gone))
        return excinfo.value.code

    assert asyncio.run(scenario()) == ERR_FILE_NOT_FOUND
    assert spawn.argvs == []


def test_rejects_directory(tmp_path: Path, spawn: SimpleNamespace) -> None:
    folder = tmp_path / "folder"
    folder.mkdir()
    launcher = FileLauncher(FakeLocator([None]), FakeSnapper(), FakeConfig())

    async def scenario() -> str:
        with pytest.raises(FileLaunchError) as excinfo:
            await launcher.launch(str(folder))
        return excinfo.value.code

    # Doc 21 §9 accepts E_UNSUPPORTED_TYPE or E_FILE_NOT_FOUND for directories.
    assert asyncio.run(scenario()) in (ERR_UNSUPPORTED_TYPE, ERR_FILE_NOT_FOUND)
    assert spawn.argvs == []


def test_builds_launch_command_with_current_and_fullscreen_flags(
    tmp_path: Path, spawn: SimpleNamespace
) -> None:
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    locator = FakeLocator([12345])
    snapper = FakeSnapper()
    launcher = FileLauncher(locator, snapper, FakeConfig(str(exe)))

    async def scenario() -> tuple[Any, dict[str, Any]]:
        result = await launcher.launch(str(video))
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_LAUNCH_MEDIA, launcher.handle_launch_media)
        reply = await router.dispatch(WsSession(FakeSocket()), _envelope(str(video)))
        return result, reply

    result, reply = asyncio.run(scenario())
    expected = [str(exe), str(video), "/current", "/fullscreen"]
    assert spawn.argvs == [expected, expected]  # argv list only, no shell string (§8)
    assert result.launched is True
    assert result.hwnd == 12345
    assert result.snapped is True
    assert result.elapsed_ms >= 0
    assert reply["action"] == "LAUNCH_MEDIA_RESULT"
    assert reply["payload"] == {
        "ok": True,
        "started": True,
    }  # started = spawn/hand-off done; hwnd/snapped/elapsed never on the wire


def test_uses_configured_player_path_over_default(
    tmp_path: Path, monkeypatch: Any, spawn: SimpleNamespace
) -> None:
    configured = tmp_path / "custom_player.exe"
    configured.write_bytes(b"MZ")
    default = tmp_path / "default_player.exe"
    default.write_bytes(b"MZ")
    monkeypatch.setattr(fl, "DEFAULT_PLAYER_PATH", str(default))
    video = _video(tmp_path)

    launcher = FileLauncher(FakeLocator([99]), FakeSnapper(), FakeConfig(str(configured)))
    asyncio.run(launcher.launch(str(video)))
    assert spawn.argvs[0][0] == str(configured)  # config path wins over the default

    # Both configured and default missing → E_PLAYER_NOT_FOUND naming the bad path (§7).
    bad = tmp_path / "gone.exe"
    absent_default = str(tmp_path / "no_default.exe")
    monkeypatch.setattr(fl, "DEFAULT_PLAYER_PATH", absent_default)
    launcher2 = FileLauncher(FakeLocator([99]), FakeSnapper(), FakeConfig(str(bad)))
    with pytest.raises(FileLaunchError) as excinfo:
        asyncio.run(launcher2.launch(str(video)))
    assert excinfo.value.code == ERR_PLAYER_NOT_FOUND
    assert str(bad) in excinfo.value.detail

    # No config at all → default candidates are probed (patch to an absent set).
    absent_default = str(tmp_path / "no_default.exe")
    monkeypatch.setattr(fl, "DEFAULT_PLAYER_PATH", absent_default)
    monkeypatch.setattr(fl, "default_player_candidates", lambda: (absent_default,))
    launcher3 = FileLauncher(FakeLocator([99]), FakeSnapper(), FakeConfig(None))
    with pytest.raises(FileLaunchError) as excinfo2:
        asyncio.run(launcher3.launch(str(video)))
    assert excinfo2.value.code == ERR_PLAYER_NOT_FOUND
    assert absent_default in excinfo2.value.detail  # the tried path is named (§7)


def test_no_config_probes_known_install_candidates(
    tmp_path: Path, monkeypatch: Any, spawn: SimpleNamespace
) -> None:
    """Without a config key, the first *existing* default candidate wins."""
    missing1 = str(tmp_path / "absent_a.exe")
    present = tmp_path / "PotPlayerMini.exe"
    present.write_bytes(b"MZ")
    missing2 = str(tmp_path / "absent_b.exe")
    monkeypatch.setattr(
        fl, "default_player_candidates", lambda: (missing1, str(present), missing2)
    )
    video = _video(tmp_path)

    launcher = FileLauncher(FakeLocator([99]), FakeSnapper(), FakeConfig(None))
    asyncio.run(launcher.launch(str(video)))
    assert spawn.argvs[0][0] == str(present)  # skipped the missing one, stopped at first hit


def test_configured_wrong_path_does_not_fall_back_to_candidates(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """§7: configured-but-wrong → error naming it, even when a candidate exists."""
    present = tmp_path / "real_player.exe"
    present.write_bytes(b"MZ")
    monkeypatch.setattr(fl, "default_player_candidates", lambda: (str(present),))
    video = _video(tmp_path)

    launcher = FileLauncher(
        FakeLocator([99]), FakeSnapper(), FakeConfig(str(tmp_path / "gone.exe"))
    )
    with pytest.raises(FileLaunchError) as excinfo:
        asyncio.run(launcher.launch(str(video)))
    assert excinfo.value.code == ERR_PLAYER_NOT_FOUND
    assert "gone.exe" in excinfo.value.detail


def test_snap_invoked_after_hwnd_resolved(tmp_path: Path, spawn: SimpleNamespace) -> None:
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    locator = FakeLocator([None, 777])  # hwnd appears on the second poll
    snapper = FakeSnapper(ok=True)
    launcher = FileLauncher(locator, snapper, FakeConfig(str(exe)))

    result = asyncio.run(launcher.launch(str(video)))
    assert result.launched is True
    assert result.hwnd == 777
    assert result.snapped is True
    assert locator.calls == 2
    assert snapper.calls == 1  # exactly one snap, after the HWND resolved


def test_timeout_returns_launched_without_snap(
    tmp_path: Path, monkeypatch: Any, spawn: SimpleNamespace
) -> None:
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    locator = FakeLocator([None])  # never finds a window
    snapper = FakeSnapper()
    launcher = FileLauncher(locator, snapper, FakeConfig(str(exe)))

    clock = {"t": 0.0}

    def fake_now() -> float:
        clock["t"] += 6.0  # jump past HWND_WAIT_TIMEOUT_S (5 s) on the first check
        return clock["t"]

    launcher._now = fake_now  # fake clock: no real 5 s wait in the suite

    result = asyncio.run(launcher.launch(str(video)))
    assert result.launched is True
    assert result.hwnd is None
    assert result.snapped is False  # soft degradation (§7), still ok:true upstream
    assert snapper.calls == 0  # snap skipped without an HWND
    assert locator.calls == 1  # bounded by hwnd_timeout_s — not an endless poll
    assert result.elapsed_ms >= 0


def test_concurrent_launches_serialized(tmp_path: Path, spawn: SimpleNamespace) -> None:
    exe = _exe(tmp_path)
    video_a = _video(tmp_path, "A.mkv")
    video_b = _video(tmp_path, "B.mkv")
    spawn.delay_s = 0.1  # block inside the hand-off wait so overlap would be visible
    launcher = FileLauncher(FakeLocator([111]), FakeSnapper(), FakeConfig(str(exe)))

    async def scenario() -> list[Any]:
        return list(
            await asyncio.gather(
                launcher.launch(str(video_a)),
                launcher.launch(str(video_b)),
            )
        )

    results = asyncio.run(scenario())
    assert [result.launched for result in results] == [True, True]
    assert spawn.events == [
        ("start", str(video_a)),
        ("end", str(video_a)),
        ("start", str(video_b)),
        ("end", str(video_b)),
    ]  # strictly sequential — the module lock never interleaves two launches (§7)


def test_spawn_exception_maps_to_launch_failed(
    tmp_path: Path, spawn: SimpleNamespace
) -> None:
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    locator = FakeLocator([555])
    snapper = FakeSnapper()
    spawn.error = OSError("access\x07 denied")  # control char must be sanitized (§7)
    launcher = FileLauncher(locator, snapper, FakeConfig(str(exe)))

    with pytest.raises(FileLaunchError) as excinfo:
        asyncio.run(launcher.launch(str(video)))
    assert excinfo.value.code == ERR_LAUNCH_FAILED
    assert "access" in excinfo.value.detail
    assert "\x07" not in excinfo.value.detail
    assert locator.calls == 0  # failed spawn never reaches the HWND phase
    assert snapper.calls == 0


def test_nonzero_exit_within_grace_maps_to_launch_failed(
    tmp_path: Path, spawn: SimpleNamespace
) -> None:
    """A hand-off/crash that exits nonzero inside the grace window is an error."""
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    spawn.exit_code = 3
    launcher = FileLauncher(FakeLocator([123]), FakeSnapper(), FakeConfig(str(exe)))

    with pytest.raises(FileLaunchError) as excinfo:
        asyncio.run(launcher.launch(str(video)))
    assert excinfo.value.code == ERR_LAUNCH_FAILED
    assert "code 3" in excinfo.value.detail


def test_grace_timeout_keeps_player_alive_and_reaps_in_background(
    tmp_path: Path, spawn: SimpleNamespace, monkeypatch: Any
) -> None:
    """A cold-started primary player outlives the grace window: launch proceeds
    without waiting for it, and the process is reaped by a background thread —
    never killed (the old blocking run terminated playback at its timeout)."""
    exe = _exe(tmp_path)
    video = _video(tmp_path)
    monkeypatch.setattr(fl, "HANDOFF_GRACE_S", 0.01)
    spawn.delay_s = 0.15  # the primary instance keeps running past the grace
    locator = FakeLocator([321])
    snapper = FakeSnapper()
    launcher = FileLauncher(locator, snapper, FakeConfig(str(exe)))

    result = asyncio.run(launcher.launch(str(video)))
    assert result.launched is True
    assert result.hwnd == 321
    assert spawn.argvs == [[str(exe), str(video), "/current", "/fullscreen"]]
    assert ("start", str(video)) in spawn.events
    assert ("end", str(video)) not in spawn.events  # grace expired while running

    deadline = time.monotonic() + 2.0
    while ("end", str(video)) not in spawn.events and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ("end", str(video)) in spawn.events  # background reaper finished the wait
