"""Doc 04 §9 — frozen dependency manifests (§6.1 core 8 + dev tooling)."""

import re
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_CORE = (
    "pywin32",
    "customtkinter",
    "pystray",
    "websockets",
    "zeroconf",
    "monitorcontrol",
    "qrcode",
    "pillow",
    # Doc 23 §6.1 "later appends (by owning doc)": CoreAudio pair.
    "pycaw",
    "comtypes",
)
_DEV = ("pytest", "pytest-asyncio", "ruff")
_PIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*(>=|==|~=|<=|>|<)\S+$")


def _entries(path: Path) -> list[str]:
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    return entries


def _names(entries: list[str]) -> list[str]:
    return [re.split(r"[<>=!~\[\s;]", entry, maxsplit=1)[0] for entry in entries]


def test_core_requirements_are_frozen_eight_plus_doc23_append():
    entries = _entries(_REPO_ROOT / "pc_agent" / "requirements.txt")
    assert len(entries) == 10  # Doc 04 §6.1 core 8 + Doc 23 pycaw/comtypes append
    assert set(_names(entries)) == set(_CORE)
    for entry in entries:
        assert _PIN_RE.match(entry), f"missing non-empty pin: {entry!r}"


def test_dev_requirements_contain_tooling():
    entries = _entries(_REPO_ROOT / "pc_agent" / "requirements-dev.txt")
    assert set(_DEV) <= set(_names(entries))
    for entry in entries:
        assert _PIN_RE.match(entry), f"missing non-empty pin: {entry!r}"
