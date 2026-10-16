"""Doc 26 §9 — port clamps, token regex, movie dirs, strict bools."""

import json
from pathlib import Path

import pytest

from pc_agent.core.config_manager import ConfigError, ConfigManager

from .helpers import make_manager


def test_ports_clamped_on_update(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    assert mgr.update(udp_port=99).udp_port == 1024
    assert mgr.update(ws_port=70000).ws_port == 65535


def test_ports_clamped_on_load(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"udp_port": 99, "ws_port": 70000}), encoding="utf-8")

    cfg = ConfigManager(path).load()

    assert cfg.udp_port == 1024
    assert cfg.ws_port == 65535


def test_string_port_coerced_on_load(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"udp_port": "20000"}), encoding="utf-8")

    assert ConfigManager(path).load().udp_port == 20000


def test_equal_ports_rejected_on_update(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    with pytest.raises(ConfigError):
        mgr.update(udp_port=50506)  # collides with the default ws_port

    assert mgr.get().udp_port == 50505


def test_equal_ports_on_load_fall_back_to_defaults(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"udp_port": 50506, "ws_port": 50506}), encoding="utf-8")

    cfg = ConfigManager(path).load()

    assert (cfg.udp_port, cfg.ws_port) == (50505, 50506)
    assert list(tmp_path.glob("config.json.corrupt-*"))


def test_non_numeric_port_raises_config_error(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    with pytest.raises(ConfigError):
        mgr.update(udp_port="not-a-port")


def test_token_regex_accepts_lowercase_hex_only(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()
    valid = "0123456789abcdef" * 2

    assert mgr.update(auth_token=valid).auth_token == valid
    # invalid format is treated as absent, per Doc 26 §4.4
    assert mgr.update(auth_token="XYZ").auth_token == ""
    assert mgr.update(auth_token="0123456789ABCDEF" * 2).auth_token == ""


def test_movie_dirs_normalized_and_deduped(tmp_path, monkeypatch):
    monkeypatch.setenv("POTPLOT_TEST_MOVIES", str(tmp_path / "env"))
    mgr = make_manager(tmp_path)
    mgr.load()
    first = str(tmp_path / "Movies")

    cfg = mgr.update(
        movie_dirs=[first, "", "~/Movies", "%POTPLOT_TEST_MOVIES%", first.upper()]
    )

    out = cfg.movie_dirs
    assert out[0] == first
    assert out.count(first) == 1  # case-insensitive dedupe dropped first.upper()
    assert str(tmp_path / "env") in out  # environment variables expanded
    assert "" not in out
    assert len(out) == 3
    assert all(Path(entry).is_absolute() for entry in out)


def test_strict_bool_checks(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    with pytest.raises(ConfigError):
        mgr.update(minimize_to_tray=1)
    with pytest.raises(ConfigError):
        mgr.update(run_on_startup="true")

    assert mgr.get().minimize_to_tray is True
    assert mgr.get().run_on_startup is False
