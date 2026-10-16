"""Doc 26 §9 — HKCU Run sync exercised against a fake winreg module."""

import json
from pathlib import Path

import pytest

from pc_agent.core.config_manager import RUN_VALUE_NAME, StartupRegistrationError

from .helpers import install_fake_winreg, make_manager

_EXE = Path(r"C:\Program Files\PotPilot\PotPilotAgent.exe")


def test_set_startup_writes_quoted_data_and_persists(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()

    mgr.set_startup_enabled(True, _EXE)

    assert fake.values[RUN_VALUE_NAME] == f'"{_EXE}" --minimized'
    assert mgr.get().run_on_startup is True
    data = json.loads(mgr.config_path().read_text(encoding="utf-8"))
    assert data["run_on_startup"] is True


def test_clear_startup_removes_value_and_persists(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()

    mgr.set_startup_enabled(True, _EXE)
    mgr.set_startup_enabled(False, _EXE)

    assert RUN_VALUE_NAME not in fake.values
    assert mgr.get().run_on_startup is False


def test_is_startup_enabled_reflects_value_presence(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()

    assert mgr.is_startup_enabled() is False
    fake.values[RUN_VALUE_NAME] = '"x.exe" --minimized'
    assert mgr.is_startup_enabled() is True


def test_oserror_on_write_raises_and_rolls_back(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()
    fake.fail_on.add("SetValueEx")

    with pytest.raises(StartupRegistrationError):
        mgr.set_startup_enabled(True, _EXE)

    assert mgr.get().run_on_startup is False  # registry actual state: absent


def test_oserror_on_delete_rolls_back_to_registry_state(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()
    mgr.set_startup_enabled(True, _EXE)
    fake.fail_on.add("DeleteValue")

    with pytest.raises(StartupRegistrationError):
        mgr.set_startup_enabled(False, _EXE)

    assert mgr.get().run_on_startup is True  # registry still holds the value


def test_resync_rewrites_missing_value(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()
    mgr.update(run_on_startup=True)
    assert RUN_VALUE_NAME not in fake.values

    mgr.resync_startup()

    assert RUN_VALUE_NAME in fake.values
    assert fake.values[RUN_VALUE_NAME].endswith(" --minimized")


def test_resync_noop_when_disabled_or_value_present(tmp_path, monkeypatch):
    fake = install_fake_winreg(monkeypatch)
    mgr = make_manager(tmp_path)
    mgr.load()

    mgr.resync_startup()  # flag false -> nothing written
    assert RUN_VALUE_NAME not in fake.values

    mgr.update(run_on_startup=True)
    fake.values[RUN_VALUE_NAME] = '"C:\\other.exe" --minimized'
    mgr.resync_startup()  # value present -> untouched
    assert fake.values[RUN_VALUE_NAME] == '"C:\\other.exe" --minimized'
