# Doc 21: PotPlayer File Launcher
> Part of PotPilot plan-series · Category D · Session 2 Wave 2.A · PC Agent

## 1. Purpose & Scope
**Delivers**
- A `CMD_MEDIA` `LAUNCH_MEDIA` handler that takes any indexed (or raw) video file path, validates it, launches it in **`PotPlayer64.exe` in fullscreen mode**, then automatically triggers the primary-monitor snap so the picture lands on the bedroom screen (fullscreen + snap are implicit side effects — Doc 03 §5.5 pins the payload to `{path}` only).
- HWND readiness polling (via Doc 08's locator) before snapping (via Doc 11), with a bounded timeout and a truthful `snapped` result.

**Out of scope**
- Play/pause/speed/seek once playing — Doc 09 (`WM_COMMAND`/`WM_USER`) owns playback commands.
- Building the file list / search UI — Docs 20 and 45 own the library; we only consume a path.
- Finding `PotPlayer64.exe` via installer-registry scraping — config path + known default (see §10 A1).
- Drag-drop/file-association fallback to another player — PotPlayer only, by product definition.

## 2. File Ownership
**Owns (create-only)**

| Path | Role |
|---|---|
| `pc_agent/media/file_launcher.py` | Validation, subprocess launch, snap orchestration, `LaunchResult` |
| `pc_agent/tests/test_file_launcher.py` | Unit tests |

**Reads / touches (owned by other docs)**

| Path | Owner | What we consume |
|---|---|---|
| `pc_agent/media/library_scanner.py` | Doc 20 | `VIDEO_EXTENSIONS` / `is_supported_video()` (single source of extension truth) |
| `pc_agent/potplayer/hwnd_locator.py` | Doc 08 | `find_potplayer_hwnd()` readiness check after spawn |
| `pc_agent/display_power/monitor_snapper.py` | Doc 11 | `snap_to_primary()` after the window appears |
| `pc_agent/network/ws_server_router.py` | Doc 14 | Dispatches `LAUNCH_MEDIA`; returns responses |
| `pc_agent/core/config_manager.py` | Doc 26 | `potplayer_exe_path: str` config key (see §10 A2) |
| `pc_agent/potplayer/telemetry_poller.py` | Doc 10 | Indirect: after launch, `file_title`/`position_ms` flow into telemetry (Docs 10/18) |

## 3. Public Contract
```python
ACT_LAUNCH_MEDIA: str = "LAUNCH_MEDIA"
FULLSCREEN_SWITCH: str = "/fullscreen"
HWND_WAIT_TIMEOUT_S: float = 5.0
HWND_POLL_INTERVAL_S: float = 0.1
DEFAULT_PLAYER_PATH: str  # fallback install path; overridden by config (see §10 A1)

class FileLaunchError(Exception):
    code: str  # "E_FILE_NOT_FOUND" | "E_UNSUPPORTED_TYPE" | "E_PLAYER_NOT_FOUND"
               # | "E_LAUNCH_FAILED" | "E_BAD_PAYLOAD"

@dataclass(frozen=True, slots=True)
class LaunchResult:
    path: str          # absolute normalized path that was launched
    launched: bool     # subprocess spawned successfully
    hwnd: int | None   # PotPlayer HWND found within timeout, else None
    snapped: bool      # snap_to_primary() executed successfully
    elapsed_ms: int    # end-to-end latency of launch() including the wait

class FileLauncher:
    def __init__(self, locator: "HwndLocator", snapper: "MonitorSnapper",
                 config: "ConfigManager", *, hwnd_timeout_s: float = HWND_WAIT_TIMEOUT_S) -> None:
        """Validate paths, spawn PotPlayer64.exe, wait for its HWND, snap to primary."""
    async def launch(self, path: str) -> LaunchResult:
        """Full pipeline: validate → spawn → wait HWND → snap. Raises FileLaunchError on failure."""
    def resolve_player_exe(self) -> str:
        """Config potplayer_exe_path, else DEFAULT_PLAYER_PATH; raises E_PLAYER_NOT_FOUND if neither exists."""
```

## 4. Internal Design
1. **Validate path** — must be non-empty str; reject directories; `os.path.isfile`; `is_supported_video()` (Doc 20's set); normalize to absolute. Any failure raises before touching PotPlayer.
2. **Resolve player** — `config["potplayer_exe_path"]` if set and existing, else `DEFAULT_PLAYER_PATH`; verify `os.path.isfile`; missing → `E_PLAYER_NOT_FOUND` with the tried path in `detail`.
3. **Spawn** — `asyncio.to_thread(subprocess.run, [exe, path, FULLSCREEN_SWITCH], timeout=10)` using `subprocess.run` (not `Popen`) deliberately: PotPlayer's **single-instance** behavior means a second invocation forwards the file to the running instance and exits quickly (see §10 A3). `CREATE_NO_WINDOW`-style flags are unnecessary — the agent has no console in the packaged build (`--noconsole`).
4. **Wait for HWND** — poll Doc 08's `find_potplayer_hwnd()` every `HWND_POLL_INTERVAL_S` until found or `HWND_WAIT_TIMEOUT_S` elapses. When a **previous** PotPlayer window already exists, the locator may return the old HWND immediately — acceptable: it is the window that will play the file.
5. **Snap** — on HWND found, call Doc 11's `snap_to_primary()` in a worker thread; success sets `snapped:true`. Timeout → `launched:true, hwnd:null, snapped:false` (soft degradation, §7).
6. **Respond** — router echoes request `id`/`action` with `LAUNCH_MEDIA_RESULT {"ok": true}` (§5.8 default). `LaunchResult` fields (`hwnd`/`snapped`/`elapsed_ms`) stay in logs/latency metrics, never on the wire (E2E budget: launch→HWND < 5 s, snap < 500 ms after HWND).

```mermaid
flowchart TD
    A[LAUNCH_MEDIA {path}] --> B{Valid video path?<br/>isfile + VIDEO_EXTENSIONS}
    B -->|no| X1[E_FILE_NOT_FOUND /<br/>E_UNSUPPORTED_TYPE / E_BAD_PAYLOAD]
    B -->|yes| C{resolve_player_exe}
    C -->|missing| X2[E_PLAYER_NOT_FOUND]
    C -->|ok| D["subprocess.run [exe, path, /fullscreen]<br/>(to_thread)"]
    D -->|spawn error| X3[E_LAUNCH_FAILED]
    D -->|ok| G["Poll Doc 08 locator ≤5 s"]
    G -->|timeout| F["RESULT {ok:true}<br/>log: snapped:false"]
    G -->|hwnd found| H[Doc 11 snap_to_primary]
    H -->|ok| I["RESULT {ok:true}<br/>log: snapped:true"]
    H -->|error| J["RESULT {ok:true}<br/>log: snapped:false + warning"]
```

**State:** none beyond constructor wiring — each `launch()` is self-contained (concurrent launches are serialized by a module-level `asyncio.Lock`; last request wins by arrival order).

## 5. Protocol & Data Compliance
Command uses envelope `type: "CMD_MEDIA"`; response echoes request `id`/`action` (convention per Doc 19 A1).

**Command (exact action name):**

| Action | Payload (request) | Success response payload |
|---|---|---|
| `LAUNCH_MEDIA` | `{"path": str}` (absolute file inside a configured dir) | `{"ok": true}` |

Fullscreen launch + primary-monitor snap are implicit side effects (Doc 03 §5.5); `hwnd`/`snapped`/`elapsed_ms` detail stays in logs and the internal `LaunchResult`, not on the wire.

Error payload: `{"ok": false, "error": <code>, "detail": str}` with `code` ∈ `E_FILE_NOT_FOUND`, `E_UNSUPPORTED_TYPE`, `E_PLAYER_NOT_FOUND`, `E_LAUNCH_FAILED`, `E_BAD_PAYLOAD`.

**Constants (exact names):** `ACT_LAUNCH_MEDIA = "LAUNCH_MEDIA"`, `FULLSCREEN_SWITCH = "/fullscreen"`, `HWND_WAIT_TIMEOUT_S`, `HWND_POLL_INTERVAL_S`, `DEFAULT_PLAYER_PATH`, `ERR_FILE_NOT_FOUND`, `ERR_UNSUPPORTED_TYPE`, `ERR_PLAYER_NOT_FOUND`, `ERR_LAUNCH_FAILED`, `ERR_BAD_PAYLOAD`. Extension set is **imported** from Doc 20 (`VIDEO_EXTENSIONS`) — never redefined.

No new `TELEMETRY_SYNC` keys: after a successful launch Doc 10 picks up the new `file_title`/`position_ms` and Doc 18 broadcasts deltas as usual.

## 6. Dependencies & Integration Points
**Internal**
- [20_pc_local_media_scanner_service.md](20_pc_local_media_scanner_service.md) — `VIDEO_EXTENSIONS` / `is_supported_video()` import.
- [08_potplayer_hwnd_locator.md](08_potplayer_hwnd_locator.md) — post-spawn HWND readiness.
- [11_multi_monitor_window_snapper.md](11_multi_monitor_window_snapper.md) — `snap_to_primary()` (maximize/move onto primary bedroom display).
- [14_pc_websocket_server_router.md](14_pc_websocket_server_router.md) — command dispatch + response.
- [26_pc_config_persistence_manager.md](26_pc_config_persistence_manager.md) — `potplayer_exe_path`.
- [09_potplayer_wm_command_dispatcher.md](09_potplayer_wm_command_dispatcher.md), [10_potplayer_wm_user_telemetry_poller.md](10_potplayer_wm_user_telemetry_poller.md) — post-launch playback/telemetry (no direct calls from here).
- [45_flutter_in_app_movie_browser.md](45_flutter_in_app_movie_browser.md) → actual file [45_flutter_in_app_movie_library_browser.md](45_flutter_in_app_movie_library_browser.md) — command sender.

**External** — stdlib only: `asyncio`, `subprocess`, `os`, `time`, `dataclasses`.

**Platform** — Windows process creation (`CreateProcessW` via `subprocess`); PotPlayer64 command-line switches (`/fullscreen`); documented single-instance file hand-off.

## 7. Edge Cases & Failure Handling
- **Path missing on disk (deleted after indexing)** — `E_FILE_NOT_FOUND`; Doc 45 shows "file missing, rescan?" toast; no process spawned.
- **Directory or unsupported extension passed** — `E_UNSUPPORTED_TYPE` / `E_BAD_PAYLOAD`; extension check is case-insensitive (`.MKV` fine, `.txt` rejected).
- **`potplayer_exe_path` config wrong / player uninstalled** — `E_PLAYER_NOT_FOUND` with the tried path so Doc 24 can prompt to fix it.
- **Subprocess spawn fails (AV block, corrupt exe)** — `E_LAUNCH_FAILED`; original exception string in `detail`, sanitized of control chars.
- **PotPlayer already running playing another file** — single-instance hand-off opens the new file in the existing window; snap still runs (window repositions to primary monitor).
- **HWND not found within 5 s** — response is still `LAUNCH_MEDIA_RESULT {"ok":true}`; internal `LaunchResult` records `hwnd:null, snapped:false`; playback may proceed headlessly; user-visible picture may need a manual snap (logged as warning).
- **Snap raises (no primary monitor change race)** — `snapped:false` + warning; launch result stays positive (file is playing).
- **Concurrent `LAUNCH_MEDIA` requests** — serialized by `asyncio.Lock`; no interleaved subprocess/hwnd confusion.
- **Path with spaces/Unicode (e.g. `E:\Фильмы\Тест фильм.mkv`)** — passed as a single argv element; `subprocess` handles quoting; no shell (`shell=False`) so no injection surface.
- **Agent runs unelevated** — no elevation needed; PotPlayer launched in the interactive session.

## 8. Acceptance Criteria
- `LAUNCH_MEDIA` with an existing `.mkv` path → PotPlayer opens it **fullscreen** on the primary monitor; response `{"ok":true}`; internal result records `snapped:true` and a non-zero `hwnd`.
- Launch latency (subprocess spawn → HWND observed) logged in `elapsed_ms`; end-to-end `launch()` < 5 s on a warm system.
- `.txt`, a directory, and a nonexistent path produce the exact error codes from §5, with no process spawned.
- The wire payload is exactly `{"path"}` — `/fullscreen` and the Doc 11 snap always run; no flags cross the wire (fast path still < 1 s).
- After launch, Doc 18 telemetry shows `file_title` changing to the new file within 2 launches × 250 ms ticks.
- With wrong `potplayer_exe_path`, response is `E_PLAYER_NOT_FOUND` naming the bad path; with correct config, the configured exe is used (verified via process command line).
- No shell string interpolation anywhere (argv list only).

## 9. Test Plan
`pc_agent/tests/test_file_launcher.py` (pytest; `tmp_path` fake video files; monkeypatched `subprocess.run`, locator, snapper, config):
- `test_rejects_unsupported_extension` — `.txt` → `E_UNSUPPORTED_TYPE`.
- `test_rejects_missing_file` — deleted path → `E_FILE_NOT_FOUND`.
- `test_rejects_directory` — dir path → `E_UNSUPPORTED_TYPE`/`E_FILE_NOT_FOUND`.
- `test_builds_launch_command_with_fullscreen_flag` — argv == `[exe, path, "/fullscreen"]` always (no wire flags; implicit side effect per Doc 03).
- `test_uses_configured_player_path_over_default` — config path wins; both-missing → `E_PLAYER_NOT_FOUND`.
- `test_snap_invoked_after_hwnd_resolved` — fake locator returns hwnd after 2 polls → `snapped:true`, snapper called once.
- `test_timeout_returns_launched_without_snap` — locator always `None` → `launched:true, snapped:false`, bounded by `hwnd_timeout_s` (fake clock).
- `test_concurrent_launches_serialized` — two overlapping `launch()` calls execute strictly sequentially (lock).
- `test_spawn_exception_maps_to_launch_failed` — `subprocess.run` raising → `E_LAUNCH_FAILED`.

**Manual (hardware/real player required)** — with real PotPlayer installed: launch from the Doc 45 grid → verify fullscreen on primary; launch while another video plays → window reuses instance and re-snaps; close PotPlayer, launch again → cold start path; temporarily rename the exe → `E_PLAYER_NOT_FOUND`; launch a Unicode/long-path filename → opens correctly.

## 10. Assumptions & Open Questions
- **A1:** `DEFAULT_PLAYER_PATH` = the standard 64-bit install location (`C:\Program Files\DAUM\PotPlayer\PotPlayer64.exe`). This is the only hardcoded path in the module; it is overridable via config and recorded here because the overview blueprint does not specify one.
- **A2:** `potplayer_exe_path` is a new config key beyond Doc 26's catalog baseline (ports/token/movie dirs/startup) — registered as an additive key; Doc 24's settings surface should expose it.
- **A3:** PotPlayer's single-instance hand-off for a second `PotPlayer64.exe <file>` invocation is relied upon (default PotPlayer behavior). If a user disables single-instance, the result is still correct — a new fullscreen window that Doc 08 will locate.
- **A4:** `/fullscreen` is the accepted PotPlayer command-line switch (per PotPlayer documentation). A fallback (`config["potplayer_fullscreen"]=false` + a Doc 09 fullscreen toggle after HWND-ready) is specced but not implemented unless field testing disproves the switch.
- **A5:** "Primary monitor snapping" reuses Doc 11 verbatim; no extra geometry logic lives here.
- **Q1 (open):** Should the launcher optionally pre-warm PotPlayer at agent startup (spawn with no file) to cut first-launch latency? Deferred — measured cold start is expected < 2 s on the target bedroom PC.
