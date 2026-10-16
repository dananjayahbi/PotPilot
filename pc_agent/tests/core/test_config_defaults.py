"""Doc 26 §9 — defaults, path resolution, read-only load."""

from pc_agent.core.config_manager import (
    CONFIG_DIR_NAME,
    CONFIG_FILE_NAME,
    AppConfig,
    ConfigManager,
)

from .helpers import make_manager


def test_config_path_follows_appdata(tmp_path, monkeypatch):
    monkeypatch.setenv("APPDATA", str(tmp_path))

    path = ConfigManager().config_path()

    assert path == tmp_path / CONFIG_DIR_NAME / CONFIG_FILE_NAME
    assert path.parts[-2:] == (CONFIG_DIR_NAME, CONFIG_FILE_NAME)


def test_config_path_falls_back_to_roaming_without_appdata(monkeypatch):
    monkeypatch.delenv("APPDATA", raising=False)

    path = ConfigManager().config_path()

    assert path.parts[-4:] == ("AppData", "Roaming", CONFIG_DIR_NAME, CONFIG_FILE_NAME)


def test_missing_file_loads_defaults_without_writing(tmp_path):
    mgr = make_manager(tmp_path)

    cfg = mgr.load()

    assert cfg == AppConfig()
    assert cfg.schema_version == 1
    assert cfg.udp_port == 50505
    assert cfg.ws_port == 50506
    assert cfg.auth_token == ""
    assert cfg.movie_dirs == []
    assert cfg.run_on_startup is False
    assert cfg.minimize_to_tray is True
    assert not mgr.config_path().exists()


def test_get_returns_independent_snapshots(tmp_path):
    mgr = make_manager(tmp_path)

    snap = mgr.get()
    snap.movie_dirs.append("mutated")
    snap.udp_port = 9

    fresh = mgr.get()
    assert fresh.movie_dirs == []
    assert fresh.udp_port == 50505
