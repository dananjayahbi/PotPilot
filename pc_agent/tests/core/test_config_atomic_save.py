"""Doc 26 §9 — atomic, pretty, sorted writes with failure safety."""

import json
import os

import pytest

from pc_agent.core.config_manager import ConfigError

from .helpers import make_manager


def test_save_produces_sorted_pretty_json_with_trailing_newline(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    mgr.update(udp_port=50505)  # first mutation persists to disk

    text = mgr.config_path().read_text(encoding="utf-8")
    assert text.endswith("\n")
    data = json.loads(text)
    assert set(data) == {
        "schema_version",
        "udp_port",
        "ws_port",
        "auth_token",
        "movie_dirs",
        "run_on_startup",
        "minimize_to_tray",
    }
    assert text == json.dumps(data, indent=2, sort_keys=True) + "\n"
    assert '"udp_port": 50505' in text


def test_failure_before_replace_leaves_original_intact(tmp_path, monkeypatch):
    mgr = make_manager(tmp_path)
    mgr.load()
    mgr.update(udp_port=20000)
    original = mgr.config_path().read_text(encoding="utf-8")

    def boom(src, dst):
        raise OSError("simulated crash before os.replace")

    monkeypatch.setattr(os, "replace", boom)
    with pytest.raises(ConfigError):
        mgr.update(udp_port=30000)
    monkeypatch.undo()

    assert mgr.config_path().read_text(encoding="utf-8") == original
    assert mgr.get().udp_port == 20000  # in-memory snapshot rolled back too


def test_stale_tmp_file_overwritten_on_next_save(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()
    tmp = mgr.config_path().with_name("config.json.tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text("stale", encoding="utf-8")

    mgr.update(udp_port=40000)

    data = json.loads(mgr.config_path().read_text(encoding="utf-8"))
    assert data["udp_port"] == 40000
    assert not tmp.exists()
