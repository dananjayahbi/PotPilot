# Doc 28: InnoSetup Installer Script (`setup.iss`)

> Part of PotPilot plan-series · Category E · Session 3 Wave 3.A · PC Agent

## 1. Purpose & Scope

Provides the complete `pc_agent/installer/setup.iss` that turns the PyInstaller output into `PotPilot_Setup.exe`: it bundles `dist/PotPilotAgent/`, creates Desktop and Start-Menu shortcuts, registers per-user Windows Firewall rules for the agent's two listening sockets (`UDP 50505` inbound, `TCP 50506` inbound), and offers a post-install launch of the agent.

Delivered:
- Full InnoSetup 6 script: `[Setup]`, `[Files]`, `[Icons]`, `[Tasks]`, `[Code]` firewall helpers, uninstall cleanup.
- Firewall rule specs (name/port/protocol/direction/scope) with add-on-install and delete-on-uninstall.
- Deterministic compile command `ISCC.exe pc_agent/installer/setup.iss` → `PotPilot_Setup.exe`.

Out of scope:
- Producing the PyInstaller bundle itself ([27](27_pc_pyinstaller_build_spec.md)); code signing; service/DriverStore installation; macOS/Android packaging; firewall rules for outbound (default-allow).

## 2. File Ownership

**Creates (create-only):**
- `pc_agent/installer/setup.iss`.

**Reads / touches (owned by other docs):**
- `pc_agent/dist/PotPilotAgent/**` — payload consumed via `[Files]` ([27](27_pc_pyinstaller_build_spec.md)).
- `pc_agent/assets/potpilot_icon.ico` (assumed) — `SetupIconFile`/shortcut icon.
- Runtime artifact: `%APPDATA%\PotPilot\config.json` — deliberately **not** touched; survives uninstall ([26](26_pc_config_persistence_manager.md)).
- Installer output `pc_agent/installer/Output/PotPilot_Setup.exe` — generated here.

## 3. Public Contract

InnoSetup directives are the contract; the externally visible surface:

| Directive / symbol | Value |
|---|---|
| `AppId` | `{{7C3A1E52-9D4B-4C7A-B6E0-5A1F0C2D8E91}` (stable GUID — fixed once, never change) |
| `AppName` / `AppVersion` | `PotPilot` / injected from a `Version` preprocessor define |
| `DefaultDirName` | `{autopf}\PotPilot` (→ `C:\Program Files\PotPilot` on x64) |
| `OutputBaseFilename` | `PotPilot_Setup` |
| `PrivilegesRequired` | `admin` (firewall + Program Files write) |
| `ArchitecturesInstallIn64BitMode` | `x64compatible` |
| Exe launched | `{app}\PotPilotAgent.exe` |
| Desktop / Start-Menu shortcuts | `PotPilot` → `{app}\PotPilotAgent.exe` |

Compile interface:
- Command: `ISCC.exe pc_agent/installer/setup.iss` (cwd = repo root or any; paths anchored to the `.iss`).
- Output: `pc_agent/installer/Output/PotPilot_Setup.exe`.
- Optional defines: `/DAppVersion=x.y.z`, `/DSourceDir=..\dist\PotPilotAgent` (defaults baked in).

## 4. Internal Design

1. `[Setup]` configures 64-bit install mode, admin privileges, LZMA2 compression, `CloseApplications=yes`, and per-machine uninstall entry in Programs & Features.
2. `[Files]` copies the entire PyInstaller onedir folder `Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion`.
3. `[Tasks]` offers optional shortcuts (`desktopicon`, `startupmenu`) and an opt-in `startup` task that adds the `HKCU\...\Run\PotPilot` autostart entry (mirrors the tray toggle; user can still change it later in-app).
4. `[Icons]` creates Start-Menu and Desktop entries pointing at `{app}\PotPilotAgent.exe` with `WorkingDir: {app}`.
5. `[Code]` `CurStepChanged(ssPostInstall)` runs `netsh advfirewall` twice (UDP 50505, TCP 50506) via `Exec`, checking each exit code; failures produce a non-fatal warning dialog with a "re-run as admin" hint — install still completes.
6. `[Code]` `CurUninstallStepChanged(ssUninstall)` deletes both firewall rules by name and leaves `%APPDATA%\PotPilot` intact (documented user-data policy).
7. `[Run]` offers the post-install "Launch PotPilot" checkbox (`Flags: nowait postinstall skipifsilent`), so an unattended `/SILENT` install never pops a window.
8. The installer performs **no** config seeding; first run lets the agent create `%APPDATA%\PotPilot\config.json` with Doc 26 defaults.

Preprocessor defines (top of `setup.iss`):

```iss
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\PotPilotAgent"
#endif
#define AppExe "PotPilotAgent.exe"
```

Key excerpts (each ≤ 25 lines):

```iss
[Setup]
AppId={{7C3A1E52-9D4B-4C7A-B6E0-5A1F0C2D8E91}
AppName=PotPilot
AppVersion={#AppVersion}
DefaultDirName={autopf}\PotPilot
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=PotPilot_Setup
CloseApplications=yes
LZMA2/useLZMA2 solid compression
```

```iss
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
[Icons]
Name: "{autoprograms}\PotPilot"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
Name: "{autodesktop}\PotPilot";  Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"
[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch PotPilot"; \
  Flags: nowait postinstall skipifsilent
```

`[Code]` firewall helpers (Pascal signatures; bodies execute `netsh` hidden and aggregate failures):

```pascal
function AddFirewallRule(const RuleName, Proto, Port: string): Boolean;
  // netsh advfirewall firewall add rule name=<RuleName> dir=in action=allow
  //   protocol=<Proto> localport=<Port> remoteip=localsubnet  (runhidden, waituntilterminated)
function DeleteFirewallRule(const RuleName: string): Boolean;
  // netsh advfirewall firewall delete rule name=<RuleName>  (ignore failure)
procedure CurStepChanged(CurStep: TSetupStep);      // ssPostInstall -> AddFirewallRule x2
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep); // ssUninstall -> DeleteFirewallRule x2
```

```mermaid
flowchart TD
  ISCC[ISCC.exe setup.iss] --> SM[PotPilot_Setup.exe]
  SM --> F[Copy dist/PotPilotAgent → {app}]
  F --> T[Tasks: shortcuts / autostart]
  T --> FW[netsh advfirewall add UDP 50505 in]
  FW --> FW2[netsh advfirewall add TCP 50506 in]
  FW2 --> LAUNCH{post-install Launch?}
  LAUNCH -- yes --> RUN[Start PotPilotAgent.exe]
  UN[Uninstall] --> UFW[netsh advfirewall delete rule]
  UFW --> KEEP[Keep %APPDATA%\PotPilot]
```

## 5. Protocol & Data Compliance

Firewall rule table (authoritative; both `dir=in`, `action=allow`, scoped to the local subnet so the bedroom LAN can reach the PC but the public interface stays closed):

| Rule name | Port | Protocol | Direction | Action | Scope | Notes |
|---|---|---|---|---|---|---|
| `PotPilot Agent - UDP Input (50505)` | `50505` | UDP | in | allow | `remoteip=localsubnet` | trackpad/scroll/click/scrub datagrams (overview §4.1) |
| `PotPilot Agent - TCP Input (50506)` | `50506` | TCP | in | allow | `remoteip=localsubnet` | WebSocket envelope + telemetry (overview §4.2) |

`netsh` invocation shape (executed from `[Code]`, quoted for spaces):

```ini
; added in CurStepChanged(ssPostInstall) via Exec, hidden window
Filename: "netsh.exe"
Parameters: "advfirewall firewall add rule name=""PotPilot Agent - UDP Input (50505)"" dir=in action=allow protocol=UDP localport=50505 remoteip=localsubnet"
```

Matching delete on uninstall: `netsh advfirewall firewall delete rule name="PotPilot Agent - UDP Input (50505)"` (and the TCP twin). No outbound rules are added (Windows default-outbound remains). The registry autostart task (if selected) writes the same `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\PotPilot` value Doc 26 owns, so the in-app toggle and installer task never disagree.

## 6. Dependencies & Integration Points

**Internal:** [27_pc_pyinstaller_build_spec.md](27_pc_pyinstaller_build_spec.md) (payload + `APP_NAME`), [26_pc_config_persistence_manager.md](26_pc_config_persistence_manager.md) (`%APPDATA%` config + HKCU Run key contract), [13_pc_asyncio_udp_receiver.md](13_pc_asyncio_udp_receiver.md) (UDP 50505), [14_pc_websocket_server_router.md](14_pc_websocket_server_router.md) (TCP 50506), [04_pc_agent_boilerplate_deps.md](04_pc_agent_boilerplate_deps.md) (build toolchain), [25_pc_pystray_background_daemon.md](25_pc_pystray_background_daemon.md) (post-install tray behavior).

**External:** InnoSetup 6.x (`ISCC.exe` compiler, `modern wizard`, `Code` Pascal support); Windows `netsh.exe` (shipped with OS); no third-party installer plug-ins required.

**Platform APIs:** Windows Firewall with Advanced Security (`netsh advfirewall`), `{autopf}`/`{userappdata}` folder constants, Programs & Features uninstall registration, HKCU Run key.

## 7. Edge Cases & Failure Handling

- Firewall rule denied (UAC declined / policy lockdown) → `Exec` exit code ≠ 0 → non-fatal `MsgBox` with manual `netsh` commands; install continues, agent still binds but phone cannot connect until rules are added manually.
- `netsh` not on PATH (hardened PATH) → invoke via `%WinDir%\System32\netsh.exe` full path.
- Reinstall/upgrade → `netsh add rule` with the same name replaces the existing rule (idempotent); no duplicate rules accumulate.
- App already running during upgrade → `CloseApplications=yes` prompts to close; silent install force-closes via the documented `AppMutex`/process close.
- `dist/PotPilotAgent/` missing (spec not built) → `ISCC` fails with a clear "Source files not found" error; build order enforced by the Session 3 plan.
- User declines the autostart task → no `HKCU\...\Run\PotPilot` value written; in-app toggle still works later.
- Uninstall while agent running → `[UninstallRun]`/close step ends `PotPilotAgent.exe` before removing files (tray icon disappears with process).
- Non-admin user runs installer → `PrivilegesRequired=admin` triggers UAC; cancellation aborts cleanly without partial firewall state.
- Controlled Folder Access blocks `%APPDATA%` write → agent surfaces Doc 26's `ConfigError`; installer does not pre-create or pre-approve the directory (documented limitation).
- Offline / no-LAN at install time → firewall rules still valid; QR pairing works as soon as Wi-Fi connects.

## 8. Acceptance Criteria

- [ ] `ISCC.exe pc_agent/installer/setup.iss` exits 0 and produces `PotPilot_Setup.exe` (x64).
- [ ] Install creates `{app}\PotPilotAgent.exe` plus `_internal` payload; Desktop + Start-Menu shortcuts launch it with no console window.
- [ ] `netsh advfirewall firewall show rule name="PotPilot Agent - UDP Input (50505)"` and the TCP twin both exist, `in`/`allow`/`localsubnet`.
- [ ] Post-install "Launch PotPilot" starts the agent; tray icon visible; QR pairs with the Flutter app over the LAN (rules actually permissive).
- [ ] Selecting the autostart task writes `HKCU\...\Run\PotPilot`; declining leaves it absent.
- [ ] Uninstall removes both firewall rules and both shortcuts, keeps `%APPDATA%\PotPilot\config.json`.
- [ ] Silent install (`/SILENT`) completes with no dialogs and no auto-launch.
- [ ] Reinstall does not create duplicate firewall rules.

## 9. Test Plan

- `pc_agent/tests/installer/test_iss_static.py` — textual asserts on `setup.iss`: `PrivilegesRequired=admin`, `ArchitecturesInstallIn64BitMode=x64compatible`, both firewall rule names present with correct `localport`/`protocol`/`dir=in`/`remoteip=localsubnet`, matching delete strings, `postinstall skipifsilent` on the launch entry.
- `pc_agent/tests/installer/test_iss_paths.py` — asserts `DefaultDirName`, `OutputBaseFilename=PotPilot_Setup`, `[Files]` `Source` points at `dist\PotPilotAgent`, icon path resolves relative to the `.iss`.

Manual/installer smoke (automation impractical for real `netsh`/Explorer):
1. Build spec (Doc 27) → compile `setup.iss` → run `PotPilot_Setup.exe` on a clean Win 10/11 VM snapshot.
2. Verify shortcuts, firewall rules, tray icon, QR pairing from a phone on the same LAN.
3. Reboot → launch from shortcut; uninstall → rules gone (`netsh advfirewall firewall show rule name=all | findstr PotPilot` empty), config preserved.
4. Reinstall → confirm single rule per port (upgrade idempotence).

## 10. Assumptions & Open Questions

- Assumed `pc_agent/assets/potpilot_icon.ico` exists (shared with Doc 27); if absent, remove `SetupIconFile` and accept the default InnoSetup icon.
- Assumed installer version comes from an `/DAppVersion` define rather than a version file in the tree.
- Assumed per-machine (`admin`) install is acceptable; a per-user `PrivilegesRequired=lowest` variant would forfeit `netsh` firewall writes — not pursued.
- Assumed the autostart `[Tasks]` entry is opt-in and mirrors Doc 26's value so the tray toggle and installer never conflict.
- Open: whether release builds should be Authenticode-signed (affects SmartScreen warnings, not functionality).
