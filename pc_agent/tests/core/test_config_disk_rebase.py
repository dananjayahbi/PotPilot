"""Disk re-baseline: update() must not clobber keys a stale snapshot never saw.

Regression for the 2026-10-16 incident: a process holding a pre-`movie_dirs`
snapshot wrote config back through update(), wiping the user's watched folder.
"""

import json
from pathlib import Path
from typing import Any

from pc_agent.core.config_manager import ConfigManager


def _write(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def test_update_preserves_disk_keys_missing_from_stale_memory(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    # Memory baseline: added before the watched folder existed.
    mgr = ConfigManager(config_path=path)
    mgr.update(auth_token="a" * 32, movie_dirs=[])
    # Another process wrote the folder meanwhile.
    raw = json.loads(path.read_text(encoding="utf-8"))
    raw["movie_dirs"] = [r"F:\FILES\FILMS"]
    _write(path, raw)

    mgr.update(minimize_to_tray=False)  # unrelated key, stale memory

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["movie_dirs"] == [r"F:\FILES\FILMS"]  # survived the clobber
    assert on_disk["minimize_to_tray"] is False  # explicit change applied


def test_explicit_change_still_overwrites_disk_value(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    _write(path, {"movie_dirs": [r"F:\FILES\FILMS"]})
    mgr = ConfigManager(config_path=path)

    mgr.update(movie_dirs=[r"F:\OTHER"])  # explicit clear/replace wins

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["movie_dirs"] == [r"F:\OTHER"]


def test_unreadable_disk_keeps_memory_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    mgr = ConfigManager(config_path=path)
    mgr.update(movie_dirs=[r"F:\FILES\FILMS"])
    path.write_text("{not json", encoding="utf-8")  # corrupt: no quarantine here

    mgr.update(minimize_to_tray=False)  # must not raise, memory kept

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["movie_dirs"] == [r"F:\FILES\FILMS"]


def test_missing_disk_file_keeps_memory_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    mgr = ConfigManager(config_path=path)
    mgr.update(movie_dirs=[r"F:\FILES\FILMS"])
    path.unlink()

    mgr.update(minimize_to_tray=False)

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["movie_dirs"] == [r"F:\FILES\FILMS"]
    assert on_disk["minimize_to_tray"] is False


def test_extra_keys_rebaselined_from_disk(tmp_path: Path) -> None:
    """Additive keys (potplayer_exe_path, ...) written elsewhere survive updates."""
    path = tmp_path / "config.json"
    mgr = ConfigManager(config_path=path)
    mgr.update(auth_token="b" * 32)
    _write(
        path,
        {
            **json.loads(path.read_text(encoding="utf-8")),
            "potplayer_exe_path": r"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe",
        },
    )

    mgr.update(udp_port=50505)

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["potplayer_exe_path"].endswith("PotPlayerMini.exe")
