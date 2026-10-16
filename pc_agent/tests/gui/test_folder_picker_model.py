"""Doc 24 §9 — folder picker model: normalize, dedupe, persist-once, missing."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from pc_agent.core.config_manager import ConfigManager
from pc_agent.gui.dashboard_window import FolderPickerModel, FolderRowModel


class UpdateSpy:
    """Records ``ConfigManager.update`` calls while still persisting."""

    def __init__(self, config: ConfigManager) -> None:
        self.calls: list[dict[str, Any]] = []
        self._real_update = config.update

    def __call__(self, **changes: Any) -> Any:
        self.calls.append(changes)
        return self._real_update(**changes)


def make_config(tmp_path: Path) -> tuple[ConfigManager, UpdateSpy]:
    config = ConfigManager(tmp_path / "PotPilot" / "config.json")
    spy = UpdateSpy(config)
    config.update = spy  # type: ignore[method-assign]
    return config, spy


def test_normalize_strips_trailing_separator(tmp_path: Path) -> None:
    path = str(tmp_path / "movies")
    assert FolderRowModel.normalize(path + os.sep) == path
    assert FolderRowModel.normalize(path + "/") == path


def test_normalize_expands_environment_variables(monkeypatch: Any, tmp_path: Path) -> None:
    monkeypatch.setenv("POTP_TEST_MOVIE_ROOT", str(tmp_path))
    assert FolderRowModel.normalize("%POTP_TEST_MOVIE_ROOT%/films") == str(tmp_path / "films")


def test_construction_loads_config_without_persisting(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    config.update(movie_dirs=[str(existing) + os.sep])
    spy.calls.clear()
    model = FolderPickerModel(config)
    assert spy.calls == []
    assert model.paths == [str(existing)]
    assert model.rows == [FolderRowModel(str(existing), missing=False)]


def test_add_persists_exactly_once(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    model = FolderPickerModel(config)
    assert spy.calls == []
    change = model.add(str(existing))
    assert change.changed
    assert not change.duplicate
    assert change.notice is None
    assert spy.calls == [{"movie_dirs": [str(existing)]}]
    assert model.rows == [FolderRowModel(str(existing), missing=False)]


def test_add_duplicate_is_ignored_without_second_persist(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    model = FolderPickerModel(config)
    model.add(str(existing))
    change = model.add(str(existing) + os.sep)
    assert not change.changed
    assert change.duplicate
    assert change.notice is not None
    assert len(spy.calls) == 1
    assert model.paths == [str(existing)]


def test_add_invalid_path_is_ignored(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    model = FolderPickerModel(config)
    change = model.add("")
    assert not change.changed
    assert change.notice is not None
    assert spy.calls == []
    assert model.paths == []


def test_remove_persists_exactly_once(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    model = FolderPickerModel(config)
    model.add(str(existing))
    change = model.remove(str(existing) + os.sep)
    assert change.changed
    assert model.paths == []
    assert spy.calls == [
        {"movie_dirs": [str(existing)]},
        {"movie_dirs": []},
    ]


def test_remove_unknown_path_does_not_persist(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    model = FolderPickerModel(config)
    change = model.remove(str(tmp_path / "never-added"))
    assert not change.changed
    assert spy.calls == []


def test_set_paths_normalizes_dedupes_and_persists_once(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    first = tmp_path / "movies"
    second = tmp_path / "shows"
    first.mkdir()
    second.mkdir()
    model = FolderPickerModel(config)
    change = model.set_paths([str(first) + os.sep, str(first), str(second)])
    assert change.changed
    assert change.duplicate
    assert change.notice is not None
    assert model.paths == [str(first), str(second)]
    assert spy.calls == [{"movie_dirs": [str(first), str(second)]}]


def test_set_paths_unchanged_does_not_persist(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    model = FolderPickerModel(config)
    model.set_paths([str(existing)])
    change = model.set_paths([str(existing)])
    assert not change.changed
    assert len(spy.calls) == 1


def test_missing_flag_set_for_absent_path(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    model = FolderPickerModel(config)
    change = model.add(str(tmp_path / "ghost-drive"))
    assert change.changed
    assert model.rows[0].missing is True
    assert len(spy.calls) == 1


def test_refresh_missing_flips_flag_without_persisting(tmp_path: Path) -> None:
    config, spy = make_config(tmp_path)
    folder = tmp_path / "temp_media"
    folder.mkdir()
    model = FolderPickerModel(config)
    model.add(str(folder))
    assert model.rows[0].missing is False
    folder.rmdir()
    assert model.refresh_missing() is True
    assert model.rows[0].missing is True
    assert model.refresh_missing() is False
    assert len(spy.calls) == 1


def test_on_change_fires_once_per_change_with_paths(tmp_path: Path) -> None:
    config, _ = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    seen: list[list[str]] = []
    model = FolderPickerModel(config, on_change=seen.append)
    model.add(str(existing))
    model.add(str(existing) + os.sep)  # duplicate: no callback
    model.remove("nobody/added/this")  # unknown: no callback
    model.remove(str(existing))
    assert seen == [[str(existing)], []]


def test_on_change_runs_after_persist(tmp_path: Path) -> None:
    config, _ = make_config(tmp_path)
    existing = tmp_path / "movies"
    existing.mkdir()
    persisted_at_callback: list[list[str]] = []
    model = FolderPickerModel(
        config,
        on_change=lambda paths: persisted_at_callback.append(config.get().movie_dirs),
    )
    model.add(str(existing))
    assert persisted_at_callback == [[str(existing)]]
