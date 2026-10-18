# potpilot_agent.spec — PotPilot PC agent build spec (Doc 27).
#
# Build (from pc_agent/, ALWAYS with the project venv python):
#   ..\.venv\Scripts\python.exe -m PyInstaller --noconfirm installer/potpilot_agent.spec
# Run from pc_agent/: PyInstaller's default distpath is CWD-relative, so this
# lands in pc_agent/dist (where setup.iss expects it) — and the venv
# interpreter is mandatory: a PATH `python` that is not the venv silently
# drops runtime-only deps (qrcode etc.) out of the bundle and the agent
# crashes at startup with ModuleNotFoundError (round-7 incident).
# Output (onedir, canonical): dist/PotPilotAgent/PotPilotAgent.exe
# Topology flips through the ONEFILE knob below (onedir ships; onefile is the
# portable-copy experiment).  All paths anchor on SPECPATH so the spec is
# source-path-correct regardless of cwd (Doc 27 §4.1).

import sys as _sys
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

# Fail fast when built under the wrong interpreter (the guard above made
# concrete): these must import HERE or the shipped agent will not start.
for _dep in ("qrcode", "customtkinter", "websockets", "PIL", "zeroconf"):
    try:
        __import__(_dep)
    except ImportError as _exc:
        raise SystemExit(
            f"Missing dependency {_dep!r} in {_sys.executable!r}.\n"
            "Build with the project venv instead (from pc_agent/):\n"
            "  ..\\.venv\\Scripts\\python.exe -m PyInstaller "
            "--noconfirm installer/potpilot_agent.spec"
        ) from _exc

ONEFILE: bool = False
APP_NAME: str = "PotPilotAgent"
ICON_PATH: str = "../assets/potpilot_icon.ico"  # relative to this spec; absent -> PyInstaller default

_SPEC_DIR = Path(SPECPATH).resolve()
_PKG_DIR = _SPEC_DIR.parent          # pc_agent/
_REPO_ROOT = _PKG_DIR.parent         # repository root (imports pc_agent.*)
_ENTRY = str(_PKG_DIR / "main.py")


def hidden_imports() -> list[str]:
    """Modules static analysis under-detects (Doc 27 §5 table)."""
    return [
        "win32api",
        "win32con",
        "win32gui",
        "win32process",
        "win32ui",
        "pythoncom",
        "pywintypes",
        "win32com",
        "win32com.shell",
        "pystray._win32",
        "PIL",
        "PIL.Image",
        "PIL.ImageTk",
        "qrcode",
        "websockets",
        "zeroconf",
        "monitorcontrol",
        "monitorcontrol.vcp",
        "comtypes",
        "pycaw",
    ]


def icon_or_none() -> str | None:
    """Bundle icon path when the asset exists; otherwise degrade to the default."""
    icon = (_SPEC_DIR / ICON_PATH).resolve()
    return str(icon) if icon.is_file() else None


def data_files() -> list[tuple]:
    """CustomTkinter assets + shared_specs tables + the icon dir (when present)."""
    datas: list[tuple] = list(collect_data_files("customtkinter"))
    specs_dir = _REPO_ROOT / "shared_specs"
    if specs_dir.is_dir():
        datas.append((str(specs_dir), "shared_specs"))
    assets_dir = _PKG_DIR / "assets"
    if assets_dir.is_dir():
        datas.append((str(assets_dir), "assets"))
    return datas


a = Analysis(
    [_ENTRY],
    pathex=[str(_REPO_ROOT)],
    binaries=[],
    datas=data_files(),
    hiddenimports=hidden_imports(),
    excludes=["tkinter.test", "unittest", "pydoc"],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    # onefile embeds binaries + datas in the single EXE; onedir collects them.
    *([a.binaries, a.datas] if ONEFILE else []),
    exclude_binaries=not ONEFILE,
    console=False,
    icon=icon_or_none(),
    name=APP_NAME,
    debug=False,
    strip=False,
    upx=False,
)
if not ONEFILE:
    coll = COLLECT(
        exe,
        a.binaries,
        a.datas,
        strip=False,
        upx=False,
        name=APP_NAME,
    )
