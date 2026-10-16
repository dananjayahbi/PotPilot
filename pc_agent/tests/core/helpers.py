"""Shared helpers for Doc 26 config tests (isolated paths and a fake winreg)."""

from __future__ import annotations

import sys
import types
from pathlib import Path

from pc_agent.core.config_manager import ConfigManager


def make_manager(tmp_path: Path) -> ConfigManager:
    """Manager rooted at an isolated tmp path so tests never touch %APPDATA%."""
    return ConfigManager(tmp_path / "PotPilot" / "config.json")


class FakeWinreg(types.ModuleType):
    """In-memory stand-in for winreg so tests never touch the real registry."""

    def __init__(self) -> None:
        super().__init__("winreg")
        self.HKEY_CURRENT_USER = 0x80000001
        self.KEY_SET_VALUE = 0x0002
        self.REG_SZ = 1
        self.values: dict[str, str] = {}
        self.calls: list[tuple[str, ...]] = []
        self.fail_on: set[str] = set()

    def _maybe_fail(self, op: str) -> None:
        if op in self.fail_on:
            raise OSError(f"simulated {op} denial")

    def CreateKeyEx(self, key: object, sub_key: str, reserved: int = 0, access: int = 0) -> str:
        self.calls.append(("CreateKeyEx", sub_key))
        self._maybe_fail("CreateKeyEx")
        return "HKCU_RUN_HANDLE"

    def SetValueEx(
        self, key: object, name: str, reserved: int, typ: int, data: str
    ) -> None:
        self.calls.append(("SetValueEx", name, data))
        self._maybe_fail("SetValueEx")
        self.values[name] = data

    def OpenKey(self, key: object, sub_key: str, reserved: int = 0, access: int = 0) -> _FakeKey:
        self.calls.append(("OpenKey", sub_key))
        self._maybe_fail("OpenKey")
        return _FakeKey()

    def CloseKey(self, key: object) -> None:
        self.calls.append(("CloseKey",))

    def DeleteValue(self, key: object, name: str) -> None:
        self.calls.append(("DeleteValue", name))
        self._maybe_fail("DeleteValue")
        if name not in self.values:
            raise FileNotFoundError(name)
        del self.values[name]

    def QueryValueEx(self, key: object, name: str) -> tuple[str, int]:
        self.calls.append(("QueryValueEx", name))
        self._maybe_fail("QueryValueEx")
        if name not in self.values:
            raise FileNotFoundError(name)
        return (self.values[name], self.REG_SZ)


class _FakeKey:
    """Context-manager handle returned by FakeWinreg.OpenKey."""

    def __enter__(self) -> _FakeKey:
        return self

    def __exit__(self, *exc: object) -> bool:
        return False


def install_fake_winreg(monkeypatch: object) -> FakeWinreg:
    """Shadow the real winreg import for the duration of a test."""
    fake = FakeWinreg()
    monkeypatch.setitem(sys.modules, "winreg", fake)
    return fake
