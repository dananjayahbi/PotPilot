# Doc 27: PyInstaller Build Spec (`potpilot_agent.spec`)

> Part of PotPilot plan-series · Category E · Session 3 Wave 3.A · PC Agent

## 1. Purpose & Scope

Configures `pc_agent/installer/potpilot_agent.spec` so a single command — `pyinstaller --noconfirm installer/potpilot_agent.spec` run from `pc_agent/` — produces the console-free agent bundle at `dist/PotPilotAgent/PotPilotAgent.exe` (onedir; an opt-in onefile switch is included). The spec bundles CustomTkinter's asset tree, the tray/GUI icon files, and declares the hidden `pywin32`/`pystray` imports that static analysis misses, so the installed app runs with `--noconsole` semantics (no black console window).

Delivered:
- Complete spec: `Analysis → PYZ → EXE → (COLLECT | onefile)` with `console=False`.
- `HIDDEN_IMPORTS` and `DATA_FILES` tables (pywin32 COM modules, `pystray._win32`, CustomTkinter assets, icons).
- Deterministic build procedure + smoke checklist feeding Doc 28's installer.

Out of scope:
- Source-code changes to any agent module; InnoSetup packaging ([28](28_pc_innosetup_installer_script.md)); code signing/AV whitelist submission; Flutter APK builds.

## 2. File Ownership

**Creates (create-only):**
- `pc_agent/installer/potpilot_agent.spec`.

**Reads / touches (owned by other docs):**
- `pc_agent/main.py` (Analysis entry, Session 3 wiring) and every imported agent module — read-only for dependency scanning.
- `pc_agent/requirements.txt` — version source for PyInstaller/hooks ([04](04_pc_agent_boilerplate_deps.md)).
- `pc_agent/gui/dashboard_window.py`, `pc_agent/gui/tray_daemon.py` — CustomTkinter/pystray/PIL usage forcing datas/hiddenimports ([24](24_pc_customtkinter_dashboard_ui.md), [25](25_pc_pystray_background_daemon.md)).
- `pc_agent/core/config_manager.py` — confirms runtime config stays in `%APPDATA%`, never frozen into the bundle ([26](26_pc_config_persistence_manager.md)).
- Icon asset `pc_agent/assets/potpilot_icon.ico` (assumed, see §10) — consumed as `icon=` and data file.
- Build outputs `pc_agent/build/`, `pc_agent/dist/PotPilotAgent/` — generated, consumed by [28](28_pc_innosetup_installer_script.md).

## 3. Public Contract

The spec is itself the artifact; its externally observable contract:

```python
# potpilot_agent.spec exported knobs (module-level constants)
ONEFILE: bool = False                # True -> single PotPilotAgent.exe via MERGE+one-EXE; False -> onedir COLLECT
APP_NAME: str = "PotPilotAgent"      # EXE/COLLECT/product name; dist folder name; installer [Files] source
ICON_PATH: str = "../assets/potpilot_icon.ico"   # relative to spec dir; falls back to PyInstaller default if absent

def hidden_imports() -> list[str]    # pywin32, pystray backend, PIL, comtypes/pycaw — see table §5
def data_files() -> list[tuple]      # collect_data_files("customtkinter") + icon dir
```

Build interface:
- Command: `pyinstaller --noconfirm installer/potpilot_agent.spec` (cwd = `pc_agent/`).
- Outputs: `dist/PotPilotAgent/PotPilotAgent.exe` (+ `_internal/` payload in onedir mode) or `dist/PotPilotAgent.exe` in onefile mode.
- Behavior flags fixed by the spec: `console=False`, `upx=False`, `strip=False`, windowed subsystem (no console allocation at all).

## 4. Internal Design

1. Spec runs from `pc_agent/installer/`; all relative paths anchored via `SPECPATH` so the command works from any cwd PyInstaller resolves.
2. `Analysis(['../main.py'], …)` with `datas=data_files()`, `hiddenimports=hidden_imports()`, `excludes=['tkinter.test', 'unittest', 'pydoc']` (shrinks bundle, avoids console-oriented modules under `--noconsole`).
3. CustomTkinter assets: `collect_data_files('customtkinter')` ships its `assets/` (icons, theme JSONs); without it the app raises `FileNotFoundError` at first paint on a clean machine.
4. `EXE(..., console=False, icon=icon_or_none, name=APP_NAME)`; onefile mode uses the MERGE'd PYZ bundle with `append_bundle=False`-style single EXE, onedir mode adds `COLLECT(exe, a.binaries, a.datas, name=APP_NAME)`.
5. A `ONEFILE` constant flips between the two topologies; **onedir is canonical** because it matches the Phase-3 milestone (`dist/PotPilotAgent/`) and starts faster (no temp extraction), while onefile is kept for portable-copy experiments.
6. UPX explicitly disabled: UPX-packed binaries attract AV false positives and occasionally break pywin32's DLL loading.
7. Version metadata (`version='file_version_info.txt'`-style) is optional; if the resource file is absent the spec degrades gracefully (assumption §10).

Build procedure (repeatable release path):
1. Activate the Doc 04 venv (`pc_agent/.venv`) with all `requirements.txt` packages installed.
2. From `pc_agent/`, run `pyinstaller --noconfirm installer/potpilot_agent.spec`.
3. Wait for `Building COLLECT ... completed successfully.` in the log.
4. Run the smoke checklist in §8/§9 against `dist/PotPilotAgent/`.
5. Hand `dist/PotPilotAgent/` to the Doc 28 installer build (`SourceDir` default points exactly there).

Expected onedir tree (post-build):

```text
dist/PotPilotAgent/
├── PotPilotAgent.exe          # windowed stub (console=False)
└── _internal/
    ├── customtkinter/…        # assets + themes (collect_data_files)
    ├── pywin32 DLLs (pywintypes*, pythoncom*)
    ├── websockets/ zeroconf/ monitorcontrol/ qrcode/ PIL/ …
    └── … transitive modules from Analysis
```

```mermaid
flowchart LR
  M[main.py + all agent modules] --> A[Analysis<br/>hiddenimports + datas]
  A --> P[PYZ pure-python archive]
  P --> E[EXE · console=False · icon]
  E --> C[COLLECT → dist/PotPilotAgent/] 
  E -. ONEFILE=True .-> F[dist/PotPilotAgent.exe]
  C --> I[setup.iss [Files] source]
```

Threading/runtime note: the bundle contains the asyncio loop thread, Tk thread, and pystray thread (Docs 24/25); the spec adds no runtime hooks — freezing only affects import/data resolution, not the thread model.

## 5. Protocol & Data Compliance

Hidden-import table (each row: module PyInstaller's static scan under-detects → runtime symptom if omitted):

| Hidden import | Used by | Symptom if missing |
|---|---|---|
| `win32api`, `win32con`, `win32gui`, `win32process`, `win32ui` | Docs 06–12 Win32 engines | `ImportError` at engine load |
| `pythoncom`, `pywintypes` | pywin32 COM initialization (DDC/CI, shell) | `pywintypes.XXX.dll` not found |
| `win32com`, `win32com.shell` | shell/startup helpers | attribute errors post-freeze |
| `pystray._win32` | [25](25_pc_pystray_background_daemon.md) backend (selected dynamically) | tray silently absent |
| `PIL`, `PIL.Image`, `PIL.ImageTk` | QR `CTkImage` (17→24), tray icons (25) | QR panel blank / icon fallback |
| `qrcode` | [17](17_pc_qr_connection_payload_gen.md) | pairing QR never renders |
| `websockets`, `zeroconf` | [14](14_pc_websocket_server_router.md), [16](16_pc_zeroconf_mdns_broadcaster.md) | servers fail to bind/start |
| `monitorcontrol` (+ hid backend) | [19](19_pc_ddcci_monitor_brightness.md) | brightness slider dead |
| `comtypes`, `pycaw` | [23](23_pc_windows_audio_endpoint_control.md) | audio control fails (assumed deps, §10) |

Data files: `collect_data_files('customtkinter')` → `_internal/customtkinter/...`; `icon.ico` copied beside the exe for the tray `icon_factory` (Doc 25) with the runtime path resolved via `sys._MEIPASS`/exe-dir logic in the wiring layer.

Frozen wire contract is unaffected: ports `50505/50506`, the 8-byte `<BBhhH>` packet, and the WS envelope are pure code constants; the spec never embeds a config file (user config lives at `%APPDATA%\PotPilot\config.json` per [26](26_pc_config_persistence_manager.md)), so two installs or an upgrade cannot clobber user settings.

Excerpt (≤ 25 lines):

```python
# potpilot_agent.spec (excerpt)
ONEFILE = False
APP_NAME = "PotPilotAgent"

a = Analysis(
    ["../main.py"],
    pathex=[],
    binaries=[],
    datas=collect_data_files("customtkinter") + extra_datas(),
    hiddenimports=hidden_imports(),
    excludes=["tkinter.test", "unittest", "pydoc"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=not ONEFILE,
          console=False, icon=icon_or_none(), name=APP_NAME)
if not ONEFILE:
    coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name=APP_NAME)
```

Bundle hygiene rules:
- No `config.json`, log, or token may appear inside `dist/` (config lives in `%APPDATA%` per [26](26_pc_config_persistence_manager.md)).
- `excludes` prunes test/doc modules that would otherwise inflate the bundle and are useless under a windowed exe.
- Icon asset is referenced by relative path resolved from `SPECPATH`, so the build is cwd-independent.
- Spec must not import agent modules (no side effects at spec time); it only references paths and hook helpers.

## 6. Dependencies & Integration Points

**Internal:** [04_pc_agent_boilerplate_deps.md](04_pc_agent_boilerplate_deps.md) (requirements/venv), [24_pc_customtkinter_dashboard_ui.md](24_pc_customtkinter_dashboard_ui.md) + [25_pc_pystray_background_daemon.md](25_pc_pystray_background_daemon.md) (datas/hiddenimports drivers), [26_pc_config_persistence_manager.md](26_pc_config_persistence_manager.md) (runtime data-dir contract), [28_pc_innosetup_installer_script.md](28_pc_innosetup_installer_script.md) (consumes `dist/PotPilotAgent\*`), [15_pc_token_auth_middleware.md](15_pc_token_auth_middleware.md)/[17_pc_qr_connection_payload_gen.md](17_pc_qr_connection_payload_gen.md)/[19_pc_ddcci_monitor_brightness.md](19_pc_ddcci_monitor_brightness.md)/[20_pc_local_media_scanner_service.md](20_pc_local_media_scanner_service.md)/[23_pc_windows_audio_endpoint_control.md](23_pc_windows_audio_endpoint_control.md) (import graph).

**External:** `pyinstaller` ≥ 6.x + bundled `pyinstaller-hooks-contrib` (supplies the pywin32/PIL hooks), `customtkinter`, `pillow`, `qrcode`, `pywin32`, `pystray`, `websockets`, `zeroconf`, `monitorcontrol`, `pycaw`/`comtypes` — all version-pinned in Doc 04's `requirements.txt`.

**Platform:** Windows 10/11 x64 PE output (`--target-arch` default); windowed subsystem; no installer involvement at this stage.

## 7. Edge Cases & Failure Handling

- Icon file absent → spec passes `icon=None`; build succeeds with the default PyInstaller icon (tray falls back to Doc 25's PIL glyph).
- CustomTkinter assets omitted by a hooks regression → post-build smoke step asserts `_internal/customtkinter/assets` exists (checklist §8).
- `pywintypesXX.dll` not found on target PC → covered by hiddenimports + hooks-contrib; smoke test starts the exe on a clean VM.
- AV heuristic quarantine (common for PyInstaller) → UPX off, stable `APP_NAME`, documented manual unblock; signing is post-v1.
- Port 50505/50506 busy at smoke-test time → not a packaging fault; smoke script tolerates "already in use" error in the log and continues checks.
- Build from a dirty tree → spec reads only files on disk; release discipline: tag commit before building (process note).
- Re-running the build → `--noconfirm` overwrites `build/` and `dist/PotPilotAgent/`; no stale-file merging.
- Onefile mode temp-extraction blocked by Controlled Folder Access → documented; onedir remains the shipped topology.
- `sys.frozen` differences (path to icon/config) → wiring layer must branch on `getattr(sys, "frozen", False)`; spec itself needs no logic.

## 8. Acceptance Criteria

- [ ] `pyinstaller --noconfirm installer/potpilot_agent.spec` exits 0 from `pc_agent/` and yields `dist/PotPilotAgent/PotPilotAgent.exe`.
- [ ] Launching the exe opens **no console window**; tray icon + dashboard appear (Docs 24/25 functional inside the bundle).
- [ ] `_internal/customtkinter/` assets present; QR panel renders; tray icon file resolves.
- [ ] `win32gui.FindWindow` path works: background `WM_COMMAND` reaches PotPlayer from the frozen exe (Doc 09 manual check).
- [ ] UDP 50505 + WS 50506 listen after launch (`netstat -an | findstr "50505 50506"`).
- [ ] Fresh VM without Python/venv runs the exe and pairs via QR (token from `%APPDATA%\PotPilot\config.json`).
- [ ] `ONEFILE=True` variant also builds and runs (portable smoke), while the shipped default stays onedir.
- [ ] No secrets/config frozen into the bundle (no `config.json` inside `dist/`).

## 9. Test Plan

- `pc_agent/tests/installer/test_spec_static.py` — parses `potpilot_agent.spec` with `ast`: asserts `console=False`, `ONEFILE` default False, `APP_NAME == "PotPilotAgent"`, and that `hidden_imports()` contains every module in the §5 table.
- `pc_agent/tests/installer/test_spec_data_files.py` — mocks `PyInstaller.utils.hooks.collect_data_files` to assert CustomTkinter collection and icon inclusion logic.
- `pc_agent/tests/installer/test_spec_hygiene.py` — asserts the spec contains no literal token/port overrides (frozen contract stays in code, not the spec) and `console=False` appears exactly once in the EXE call.

Manual/build verification:
1. Clean venv from `requirements.txt` → run spec command → inspect `dist/` tree against checklist.
2. `PotPilotAgent.exe` on a VM with no Python: tray icon, QR pair with the Flutter app, play/pause works.
3. `--noconsole` proof: no `conhost.exe` child process; Task Manager shows one `PotPilotAgent.exe` plus threads (Tk/asyncio/tray alive).
4. Hand the `dist/PotPilotAgent/` folder to the Doc 28 installer build as its `Source` payload.

## 10. Assumptions & Open Questions

- Assumed icon source path `pc_agent/assets/potpilot_icon.ico` (not in the overview tree) — either add it via Doc 01 scaffolding or omit gracefully; recorded as an extension.
- Assumed `pycaw`/`comtypes` enter `requirements.txt` via Doc 23; if Doc 23 uses a different audio stack, prune those hiddenimports.
- Assumed PyInstaller ≥ 6.x spec syntax (`PYZ`, `COLLECT` without `exclude_binaries` legacy flags) and hooks-contrib availability.
- Assumed version-resource metadata is optional for v1; product version can be added later without topology changes.
- Open: whether release builds should be Authenticode-signed (needs a cert) — affects AV reputation but not the spec layout.
