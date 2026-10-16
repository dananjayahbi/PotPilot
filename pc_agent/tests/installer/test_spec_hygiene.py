"""Doc 27 §9 — bundle hygiene: secrets/ports stay in code, one console flag."""

from __future__ import annotations

import re
from pathlib import Path

SPEC_PATH = Path(__file__).resolve().parents[2] / "installer" / "potpilot_agent.spec"
_SOURCE = SPEC_PATH.read_text(encoding="utf-8")


def test_no_token_or_config_literals_in_spec() -> None:
    """The frozen wire contract and user config never leak into the spec."""
    assert "auth_token" not in _SOURCE
    assert "config.json" not in _SOURCE
    assert "token" not in _SOURCE.lower()
    assert re.search(r"\b[0-9a-f]{32}\b", _SOURCE) is None  # no literal 128-bit secret


def test_no_port_overrides_in_spec() -> None:
    """Ports stay in the code/config (Docs 13/14/26), not the build spec."""
    assert "50505" not in _SOURCE
    assert "50506" not in _SOURCE


def test_console_false_appears_exactly_once() -> None:
    assert _SOURCE.count("console=False") == 1


def test_upx_disabled_everywhere() -> None:
    """UPX attracts AV false positives (Doc 27 §4.6); never enabled."""
    assert "upx=True" not in _SOURCE
    assert _SOURCE.count("upx=False") >= 2  # EXE + COLLECT
