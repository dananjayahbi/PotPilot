# PotPilot: Zero-Latency PC & PotPlayer Bedroom Controller
**Master Architecture & Multi-Agent Orchestration Plan (`overview.md`)**

---

## 1. Executive Summary & System Vision
**PotPilot** is a bespoke, ultra-low-latency remote control ecosystem engineered for controlling a Windows PC and **PotPlayer (64-bit)** from bed over local Wi-Fi. It eliminates the need to reach for a physical mouse or keyboard while providing two-way playback telemetry, blind bedroom ergonomics, multi-monitor management, and hardware-level monitor dimming.

### Core Architectural Pillars
1. **Hybrid Dual-Socket Transport:**
   * **UDP Fire-and-Forget Stream (`Port 50505`):** Handles high-frequency (60Hz–120Hz) relative trackpad deltas, two-finger scroll ticks, and live timeline scrubbing with `< 2ms` serialization overhead.
   * **WebSocket Bi-Directional Pipe (`Port 50506`):** Handles guaranteed-delivery keyboard injection, direct PotPlayer Win32 API commands, media library browsing, and real-time PC-to-phone state broadcasting.
2. **Kernel-Level & Direct Win32 Hooks (Zero Focus Loss):**
   * Uses `ctypes.windll.user32.SendInput` for raw hardware-level mouse/keyboard injection (bypassing slow libraries like `pyautogui`).
   * Uses `pywin32` (`FindWindow("PotPlayer64", None)` + `SendMessage`) to dispatch `WM_COMMAND` and `WM_USER` messages directly to PotPlayer's engine, even when PotPlayer is unfocused or behind another window.
3. **Bedroom-First Mobile UX (Flutter):**
   * Pure `#000000` AMOLED pitch-black interface to preserve night vision.
   * Full-screen "Blind Bed Mode" gesture canvas with distinct haptic feedback ticks, hardware volume button hijacking, and automatic movie pausing on incoming phone/WhatsApp calls.

---

## 2. Multi-Agent Parallel Execution Strategy

This project is decomposed into **46 isolated micro-documents**. To maximize token throughput and allow the **Main Orchestrator Agent** to spawn **5 to 6 Subagents in parallel** without file-lock conflicts or broken imports, the architecture enforces three rules:

1. **Contract-First Freeze:** The binary UDP packet structure and WebSocket JSON schemas are locked in Phase 0 (`02_binary_udp_protocol_spec.md` and `03_websocket_json_schema_spec.md`). Once locked, Python PC Subagents and Dart Flutter Subagents can build in 100% parallel without waiting on each other.
2. **Strict File-Per-Micro-Doc Ownership:** Every micro-document maps to a dedicated file or isolated module directory. Two parallel subagents will **never** edit the same file in the same wave.
3. **3-Session Execution Cadence:**
   * **Session 1 (Foundation, Core Engines & Networking):** Setup boilerplate + 2 parallel waves of 5–6 subagents building the core Win32 hooks, UDP/WS sockets, and Flutter core networking.
   * **Session 2 (Feature Modules, UI Surfaces & Bedroom Ergonomics):** 2 parallel waves of 6 subagents building all UI screens, blind gestures, monitor dimming, media scanner, and hardware hooks.
   * **Session 3 (System Tray, Packaging, InnoSetup & E2E Integration):** 1 parallel wave of 5–6 subagents wiring the dependency injection registries, building the CustomTkinter GUI, compiling via PyInstaller + InnoSetup, and running E2E integration.

---

## 3. Monorepo Directory Blueprint

All subagents must strictly adhere to this directory tree:

```text
potpilot/
├── docs/
│   ├── overview.md
│   └── micro/                        # All 46 micro-documents live here
├── shared_specs/
│   ├── udp_packet_layout.json        # Byte-offset source of truth
│   ├── ws_command_schema.json        # WebSocket JSON RPC contract
│   └── potplayer_wm_codes.json       # Win32 WM_COMMAND / WM_USER hex table
├── pc_agent/                         # Python 3.11+ Windows Server
│   ├── main.py                       # Entry point & orchestration lifecycle
│   ├── requirements.txt
│   ├── core/
│   │   ├── config_manager.py         # Doc 26
│   │   ├── auth_middleware.py        # Doc 15
│   │   └── qr_payload_gen.py         # Doc 17
│   ├── input_engine/
│   │   ├── win32_mouse.py            # Doc 06 (ctypes SendInput)
│   │   └── win32_keyboard.py         # Doc 07 (ctypes SendInput)
│   ├── potplayer/
│   │   ├── hwnd_locator.py           # Doc 08
│   │   ├── wm_dispatcher.py          # Doc 09
│   │   └── telemetry_poller.py       # Doc 10
│   ├── display_power/
│   │   ├── monitor_snapper.py        # Doc 11
│   │   ├── blackout_overlay.py       # Doc 12
│   │   ├── ddcci_brightness.py       # Doc 19
│   │   ├── sleep_power_mgr.py        # Doc 22
│   │   └── audio_endpoint.py         # Doc 23
│   ├── media/
│   │   ├── library_scanner.py        # Doc 20
│   │   └── file_launcher.py          # Doc 21
│   ├── network/
│   │   ├── udp_server.py             # Doc 13
│   │   ├── ws_server_router.py       # Doc 14
│   │   ├── mdns_broadcaster.py       # Doc 16
│   │   └── telemetry_broadcaster.py  # Doc 18
│   ├── gui/
│   │   ├── dashboard_window.py       # Doc 24 (CustomTkinter)
│   │   └── tray_daemon.py            # Doc 25 (pystray)
│   └── installer/
│       ├── potpilot_agent.spec       # Doc 27 (PyInstaller)
│       └── setup.iss                 # Doc 28 (InnoSetup)
└── mobile_app/                       # Flutter 3.x (Dart) Client
    ├── pubspec.yaml                  # Doc 05
    └── lib/
        ├── main.dart
        ├── core/
        │   ├── theme/oled_theme.dart          # Doc 29
        │   ├── storage/connection_cache.dart  # Doc 34
        │   └── haptics/haptic_engine.dart     # Doc 42
        ├── network/
        │   ├── udp_sender.dart                # Doc 30
        │   ├── ws_client.dart                 # Doc 31
        │   ├── pairing_scanner.dart           # Doc 32
        │   └── telemetry_provider.dart        # Doc 33
        ├── features/
        │   ├── trackpad/virtual_trackpad.dart # Doc 35
        │   ├── deck/potplayer_deck.dart       # Doc 36
        │   ├── keyboard/full_keyboard.dart    # Doc 37
        │   ├── hud/scrub_speed_hud.dart       # Doc 38
        │   ├── tracks/audio_sub_modal.dart    # Doc 39
        │   ├── display/monitor_power_sheet.dart # Doc 40
        │   ├── bed_mode/blind_gesture_pad.dart  # Doc 41
        │   └── library/movie_browser.dart     # Doc 45
        └── hardware_hooks/
            ├── volume_button_hijack.dart      # Doc 43
            └── call_autopause_hook.dart       # Doc 44
```

---

## 4. Shared Wire Protocol Summary (Single Source of Truth)

All micro-documents must adhere to these exact wire formats:

### 4.1 UDP Binary Packet (`8 Bytes` Fixed Length, Little-Endian `<BBhhH`)
* `Byte 0` (`uint8`): **Packet Type**
  * `0x01`: Mouse Relative Move (`arg1 = dx`, `arg2 = dy`)
  * `0x02`: Mouse Scroll (`arg1 = vertical_delta`, `arg2 = horizontal_delta`)
  * `0x03`: Mouse Click/Button (`arg1 = button_id [1:L, 2:R, 3:M]`, `arg2 = state [1:Down, 2:Up, 3:Click]`)
  * `0x04`: Fast Scrubbing Seek (`arg1 = target_seconds_high`, `arg2 = target_seconds_low`)
* `Byte 1` (`uint8`): **Auth Session Byte** (8-bit XOR checksum of pairing token)
* `Bytes 2–3` (`int16`): **Payload Arg 1** (`dx` or primary value)
* `Bytes 4–5` (`int16`): **Payload Arg 2** (`dy` or secondary value)
* `Bytes 6–7` (`uint16`): **Sequence Number** (monotonic packet counter to drop out-of-order UDP datagrams)

### 4.2 WebSocket JSON Envelope
```json
{
  "id": "uuid-v4",
  "type": "CMD_POTPLAYER | CMD_KEY | CMD_SYSTEM | CMD_MEDIA | TELEMETRY_SYNC",
  "action": "PLAY_PAUSE | SET_SPEED | CYCLE_SUBS | BLACKOUT_MONITORS | ...",
  "payload": {},
  "timestamp": 1760500000
}
```

---

## 5. Catalog of Micro-Documents (46 Docs)

Your specialized Doc-Generator Agents will generate the following 46 files inside `docs/micro/`:

### Category A: Foundation, Contracts & Scaffolding
1. `01_monorepo_structure.md` — Defines the root folder hierarchy, `.gitignore`, shared JSON schemas directory, and linting rules for Python and Dart.
2. `02_binary_udp_protocol_spec.md` — Specifies the 8-byte `<BBhhH` binary UDP packet format, sequence drop logic, and byte-level serialization for Python `struct` and Dart `ByteData`.
3. `03_websocket_json_schema_spec.md` — Defines all WebSocket request/response JSON schemas, authentication handshake payloads, and the 250ms telemetry state broadcast structure.
4. `04_pc_agent_boilerplate_deps.md` — Scaffolds `pc_agent/`, `requirements.txt` (`pywin32`, `customtkinter`, `pystray`, `websockets`, `zeroconf`, `monitorcontrol`, `qrcode`, `pillow`), and the async application lifecycle.
5. `05_flutter_app_boilerplate_deps.md` — Scaffolds `mobile_app/`, `pubspec.yaml` (`flutter_riverpod`, `web_socket_channel`, `mobile_scanner`, `phone_state`, `vibration`, `shared_preferences`), and root navigation shell.

### Category B: PC Agent — Core Input & Win32 PotPlayer Engine
6. `06_win32_sendinput_mouse_engine.md` — Implements zero-latency cursor movement, left/right/middle clicks, drag locks, and smooth wheel scrolling via `ctypes.windll.user32.SendInput`.
7. `07_win32_sendinput_keyboard_engine.md` — Implements Unicode string injection, virtual keycode (`VK_*`) dispatch, and modifier combos (`Ctrl`, `Alt`, `Shift`, `Win`) using Win32 `KEYBDINPUT`.
8. `08_potplayer_hwnd_locator.md` — Locates active `PotPlayer64` / `PotPlayer` window handles (`HWND`), caches process IDs, and monitors process health without stealing window focus.
9. `09_potplayer_wm_command_dispatcher.md` — Dispatches background `WM_COMMAND` and `WM_USER` messages directly to PotPlayer for play/pause, frame step, speed control (`0.2x`–`4.0x`), audio/subtitle track cycling, and subtitle delay (`+/- 500ms`).
10. `10_potplayer_wm_user_telemetry_poller.md` — Queries PotPlayer via `WM_USER` getters every 250ms for current playback position (ms), total duration (ms), play state, volume, and current playback speed multiplier.
11. `11_multi_monitor_window_snapper.md` — Enumerates connected Windows displays via `win32api.EnumDisplayMonitors` and moves/maximizes the PotPlayer window onto the primary bedroom monitor on command.
12. `12_secondary_monitor_blackout_overlay.md` — Spawns and toggles borderless, pure-black (`#000000`) topmost Tkinter overlay windows across all non-primary monitors to eliminate ambient room glare.

### Category C: PC Agent — Networking, Discovery & Security
13. `13_pc_asyncio_udp_receiver.md` — Implements the high-throughput `asyncio.DatagramProtocol` server on port `50505` that unpacks 8-byte packets and routes them directly to `win32_mouse.py`.
14. `14_pc_websocket_server_router.md` — Implements the `websockets` server on port `50506` with an async action router dispatching incoming JSON commands to PotPlayer, keyboard, media, and power handlers.
15. `15_pc_token_auth_middleware.md` — Generates a persistent 128-bit pairing token, validates WebSocket connection handshakes, and verifies the 1-byte XOR checksum on incoming UDP packets.
16. `16_pc_zeroconf_mdns_broadcaster.md` — Broadcasts the `_potpilot._tcp.local.` mDNS service on the local LAN so the Flutter app can auto-discover IP changes even when DHCP reassigns the PC's IP.
17. `17_pc_qr_connection_payload_gen.md` — Generates a high-contrast QR code image containing the PC's LAN IPv4 addresses, UDP/WS ports, hostname, and secret auth token for instant 1-scan pairing.
18. `18_pc_telemetry_broadcast_loop.md` — Diffs PotPlayer telemetry and system states every 250ms and pushes compact `TELEMETRY_SYNC` JSON frames to all connected WebSocket clients.

### Category D: PC Agent — Smart Environment, Media & Power
19. `19_pc_ddcci_monitor_brightness.md` — Wraps the `monitorcontrol` library to read and adjust physical external monitor hardware luminance (0%–100%) over DDC/CI from the phone slider.
20. `20_pc_local_media_scanner_service.md` — Asynchronously indexes user-configured movie directories (`.mp4`, `.mkv`, `.avi`, `.webm`), extracting file size, modified date, and companion `.srt` presence.
21. `21_pc_potplayer_file_launcher.md` — Launches any selected video file path directly into `PotPlayer64.exe` in fullscreen mode and automatically triggers primary monitor snapping.
22. `22_pc_sleep_timer_power_manager.md` — Manages countdown sleep timers (" Hibernate/Shutdown in X mins" or "Shutdown when current movie hits 99% completion") via `ctypes` power APIs and `shutdown.exe`.
23. `23_pc_windows_audio_endpoint_control.md` — Controls master Windows system volume and mute state via CoreAudio (`pycaw`) independently of PotPlayer's internal volume mixer.

### Category E: PC Agent — GUI, Tray Daemon & InnoSetup Packaging
24. `24_pc_customtkinter_dashboard_ui.md` — Builds the modern dark-mode `CustomTkinter` window displaying the pairing QR code, connection status badge, connected device IP, and watched media folder pickers.
25. `25_pc_pystray_background_daemon.md` — Integrates `pystray` so closing the GUI minimizes PotPilot to the Windows System Tray with quick actions ("Show QR", "Toggle Blackout", "Run on Startup", "Exit").
26. `26_pc_config_persistence_manager.md` — Persists user settings (ports, auth token, movie directories, startup registry key in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) in `%APPDATA%\PotPilot\config.json`.
27. `27_pc_pyinstaller_build_spec.md` — Configures the single-folder/single-file `potpilot_agent.spec` for PyInstaller (`--noconsole`, bundling CustomTkinter assets, icons, and hidden `pywin32` imports).
28. `28_pc_innosetup_installer_script.md` — Provides the complete `setup.iss` InnoSetup script that bundles the PyInstaller dist, creates desktop/start-menu shortcuts, adds Windows Firewall UDP/TCP rules (`netsh advfirewall`), and launches the agent post-install.

### Category F: Flutter App — Networking, Pairing & State Core
29. `29_flutter_oled_theme_design_system.md` — Implements the pure `#000000` AMOLED background theme, dim crimson/amber night-vision accent palette, and zero-glare typography tokens.
30. `30_flutter_udp_datagram_sender.md` — Implements Dart's `RawDatagramSocket` singleton capable of packing and firing 8-byte binary packets at up to 120Hz with zero garbage collection jitter.
31. `31_flutter_websocket_client_reconnect.md` — Implements the resilient WebSocket client with exponential backoff auto-reconnection, heartbeat ping/pong, and mDNS IP fallback resolution.
32. `32_flutter_qr_scanner_mdns_pairing.md` — Builds the onboarding QR scanner (`mobile_scanner`) and mDNS listener that validates the handshake and transitions directly to the controller deck.
33. `33_flutter_telemetry_state_provider.md` — Implements the Riverpod `TelemetryNotifier` that parses incoming `TELEMETRY_SYNC` packets into immutable reactive state (timestamp, duration, speed, volume, file title).
34. `34_flutter_local_storage_connection_cache.md` — Persists paired PC host records, auth tokens, trackpad sensitivity curves, and preferred startup tab in local storage.

### Category G: Flutter App — Input Surfaces & PotPlayer Controls
35. `35_flutter_120hz_virtual_trackpad.md` — Builds the multi-touch virtual trackpad supporting velocity-accelerated cursor movement, tap-to-click, double-tap-and-hold drag, right-click two-finger tap, and two-finger inertia scroll.
36. `36_flutter_custom_potplayer_deck_ui.md` — Builds the dedicated PotPlayer remote grid: Play/Pause, `-5s/+5s`, `-30s/+30s`, Speed `-0.1x / +0.1x / Reset 1.0x`, Next/Prev Frame, Fullscreen, and Aspect Ratio cycle.
37. `37_flutter_full_pc_keyboard_sheet.md` — Builds a custom dark-themed PC keyboard overlay including `Esc`, `Tab`, `Win`, `Alt+F4`, Function keys (`F1`–`F12`), arrow cluster, and live text input forwarding.
38. `38_flutter_live_scrub_bar_speed_hud.md` — Renders the two-way interactive movie timeline scrubber (`01:24:10 / 02:15:00`) and live OSD badges showing current playback speed (`1.4x`) and volume percentage.
39. `39_flutter_audio_subtitle_sync_modal.md` — Builds the bottom sheet for cycling Audio Streams, cycling Subtitle Tracks, toggling Subtitles On/Off, and nudging Subtitle Sync (`-0.5s` / `+0.5s`).
40. `40_flutter_multi_monitor_power_sheet.md` — Builds the quick-control drawer for "Snap PotPlayer to Main Screen", "Blackout Other Monitors", DDC/CI Monitor Brightness slider, and the "Fall Asleep" Shutdown Timer.

### Category H: Flutter App — Bedroom Ergonomics & Hardware Hooks
41. `41_flutter_blind_bed_mode_gestures.md` — Implements the eyes-free full-screen gesture canvas: single tap (Play/Pause), horizontal swipe/hold (scrubbing with minute ticks), two-finger vertical slide (Volume), and right-edge slide (Monitor DDC/CI Brightness).
42. `42_flutter_haptic_feedback_engine.md` — Creates differentiated tactile feedback patterns (sharp micro-tick for 5s seek, heavy thud for Play/Pause, rhythmic pulse during continuous scrubbing, double-tick on 1.0x speed reset).
43. `43_flutter_hardware_volume_button_hijack.md` — Intercepts physical Android hardware Volume Up/Down key events while the app is foregrounded to adjust PC/PotPlayer volume (or seek on long-press) without looking at the screen.
44. `44_flutter_incoming_call_autopause_hook.md` — Listens to Android `PhoneState` events (`RINGING`, `OFFHOOK`, `IDLE`) and automatically dispatches a `PAUSE` command to PotPlayer when a call arrives, optionally resuming on hangup.
45. `45_flutter_in_app_movie_library_browser.md` — Builds the searchable "Netflix-style" local file browser that queries the PC's indexed movie folders and launches any video into PotPlayer with a single tap.

### Category I: End-to-End Integration & QA
46. `46_e2e_latency_benchmark_and_qa_suite.md` — Defines the automated UDP round-trip latency test (`< 5ms` LAN target), PotPlayer mock window harness, and final wiring verification checklist.

---

## 6. Parallel Session Execution Plan (5–6 Subagents per Wave)

Because the Main Agent can spawn **5 to 6 Subagents concurrently**, the implementation is organized into **3 Macro Sessions** (with 2 parallel waves per session).

### Pre-Session Phase: Micro-Document Generation
Before coding begins, your **Doc-Generator Agents** create the 46 micro-documents in `docs/micro/` in batches using the exact specifications in Section 4 and Section 5.

---

### SESSION 1: Foundation, Core Win32 Engines & Dual-Socket Networking
**Goal:** Establish the monorepo, lock the binary/JSON schemas, and build the entire backend core + mobile networking core in parallel.

#### Wave 1.A — Scaffolding & Protocol Lock (3 Subagents in Parallel)
* **Subagent 1:** Executes `01_monorepo_structure.md` + `02_binary_udp_protocol_spec.md` + `03_websocket_json_schema_spec.md`
* **Subagent 2:** Executes `04_pc_agent_boilerplate_deps.md` + `26_pc_config_persistence_manager.md`
* **Subagent 3:** Executes `05_flutter_app_boilerplate_deps.md` + `29_flutter_oled_theme_design_system.md`
*(Barrier Sync: Wait for Wave 1.A to finish so folder structures and shared specs exist.)*

#### Wave 1.B — Core Input, Win32 Hooks & Socket Plumbing (6 Subagents in Parallel)
* **Subagent 1 (PC Input):** Executes `06_win32_sendinput_mouse_engine.md` + `07_win32_sendinput_keyboard_engine.md`
* **Subagent 2 (PC PotPlayer Hook):** Executes `08_potplayer_hwnd_locator.md` + `09_potplayer_wm_command_dispatcher.md` + `10_potplayer_wm_user_telemetry_poller.md`
* **Subagent 3 (PC Sockets):** Executes `13_pc_asyncio_udp_receiver.md` + `14_pc_websocket_server_router.md` + `18_pc_telemetry_broadcast_loop.md`
* **Subagent 4 (PC Auth & Discovery):** Executes `15_pc_token_auth_middleware.md` + `16_pc_zeroconf_mdns_broadcaster.md` + `17_pc_qr_connection_payload_gen.md`
* **Subagent 5 (Flutter Sockets):** Executes `30_flutter_udp_datagram_sender.md` + `31_flutter_websocket_client_reconnect.md`
* **Subagent 6 (Flutter State & Pairing):** Executes `32_flutter_qr_scanner_mdns_pairing.md` + `33_flutter_telemetry_state_provider.md` + `34_flutter_local_storage_connection_cache.md`

---

### SESSION 2: Desktop Environment Control, Mobile UI Surfaces & Bedroom Ergonomics
**Goal:** Build all multi-monitor controls, DDC/CI dimming, media browser, and the complete Flutter UI/gesture experience.

#### Wave 2.A — PC Smart Modules & Flutter Primary Surfaces (6 Subagents in Parallel)
* **Subagent 1 (PC Display Control):** Executes `11_multi_monitor_window_snapper.md` + `12_secondary_monitor_blackout_overlay.md` + `19_pc_ddcci_monitor_brightness.md`
* **Subagent 2 (PC Media & Power):** Executes `20_pc_local_media_scanner_service.md` + `21_pc_potplayer_file_launcher.md` + `22_pc_sleep_timer_power_manager.md` + `23_pc_windows_audio_endpoint_control.md`
* **Subagent 3 (Flutter Trackpad):** Executes `35_flutter_120hz_virtual_trackpad.md` + `42_flutter_haptic_feedback_engine.md`
* **Subagent 4 (Flutter PotPlayer Deck):** Executes `36_flutter_custom_potplayer_deck_ui.md` + `38_flutter_live_scrub_bar_speed_hud.md`
* **Subagent 5 (Flutter Keyboard):** Executes `37_flutter_full_pc_keyboard_sheet.md`
* **Subagent 6 (Flutter Modals):** Executes `39_flutter_audio_subtitle_sync_modal.md` + `40_flutter_multi_monitor_power_sheet.md`

#### Wave 2.B — Bedroom Ergonomics & Desktop GUI (5 Subagents in Parallel)
* **Subagent 1 (Flutter Blind Bed Mode):** Executes `41_flutter_blind_bed_mode_gestures.md`
* **Subagent 2 (Flutter Hardware Hooks):** Executes `43_flutter_hardware_volume_button_hijack.md` + `44_flutter_incoming_call_autopause_hook.md`
* **Subagent 3 (Flutter Movie Browser):** Executes `45_flutter_in_app_movie_library_browser.md`
* **Subagent 4 (PC CustomTkinter GUI):** Executes `24_pc_customtkinter_dashboard_ui.md`
* **Subagent 5 (PC System Tray Daemon):** Executes `25_pc_pystray_background_daemon.md`

---

### SESSION 3: Final Integration, Installer Packaging & Verification
**Goal:** Wire `main.py` and `main.dart`, package the Python agent into a standalone `.exe` and InnoSetup Windows installer (`PotPilot_Setup.exe`), build the Flutter APK, and run E2E latency tests.

#### Wave 3.A — Wiring, Packaging & QA (4 Subagents in Parallel)
* **Subagent 1 (PC Master Wiring & PyInstaller):** Wires `pc_agent/main.py` connecting all routers/daemons and executes `27_pc_pyinstaller_build_spec.md`.
* **Subagent 2 (InnoSetup Installer):** Executes `28_pc_innosetup_installer_script.md` and compiles the installer via `ISCC.exe` (InnoSetup Command-Line Compiler).
* **Subagent 3 (Flutter Master Shell & APK Build):** Wires `mobile_app/lib/main.dart` navigation tabs (PotPlayer Deck, Blind Bed Mode, Trackpad, Movie Library) and runs `flutter analyze` + `flutter build apk --release`.
* **Subagent 4 (E2E Verification Suite):** Executes `46_e2e_latency_benchmark_and_qa_suite.md`.

---

## 7. Master Roadmap & Agent Progress Tracker

The Main Orchestrator Agent must update this checklist as each phase and wave completes:

### Phase 0: Micro-Document Generation
- [ ] **Batch 1 (Docs 01–12):** Contracts, Scaffolding, Win32 Mouse/Keyboard & PotPlayer Hooks generated.
- [ ] **Batch 2 (Docs 13–23):** PC UDP/WS Networking, Auth, mDNS, DDC/CI, Media Scanner & Power generated.
- [ ] **Batch 3 (Docs 24–34):** PC CustomTkinter GUI, Tray, PyInstaller, InnoSetup & Flutter Core Networking generated.
- [ ] **Batch 4 (Docs 35–46):** Flutter 120Hz Trackpad, Deck, Blind Gestures, Hardware Hooks & E2E QA generated.

### Phase 1: Session 1 Execution (Core Engine & Transport)
- [ ] **Wave 1.A Complete:** Monorepo structure, `shared_specs/*.json`, Python venv, and Flutter project initialized.
- [ ] **Wave 1.B Complete (PC):** `SendInput` mouse/keyboard, PotPlayer `HWND`/`WM_COMMAND`/`WM_USER` poller, UDP `50505` server, and WS `50506` server operational.
- [ ] **Wave 1.B Complete (Mobile):** Dart `RawDatagramSocket` sender, auto-reconnecting WebSocket client, QR scanner, and Riverpod telemetry state operational.
- [ ] **Session 1 Milestone Check:** Sending a mock 8-byte UDP packet moves the Windows cursor in `< 2ms`.

### Phase 2: Session 2 Execution (Features, Ergonomics & UI)
- [ ] **Wave 2.A Complete:** Multi-monitor snapper, secondary monitor blackout overlay, DDC/CI brightness, media scanner, 120Hz Flutter trackpad, and PotPlayer control deck built.
- [ ] **Wave 2.B Complete:** Blind Bed Mode gesture pad, hardware volume hijacking, incoming call auto-pause, Netflix-style local file browser, CustomTkinter QR dashboard, and System Tray daemon built.
- [ ] **Session 2 Milestone Check:** All Python modules pass `pytest` unit checks and all Dart widgets pass `flutter analyze` with zero errors.

### Phase 3: Session 3 Execution (Integration, InnoSetup & Release)
- [ ] **PC Agent Wired & Bundled:** `pyinstaller potpilot_agent.spec` produces a clean, console-free `dist/PotPilotAgent/` executable bundle.
- [ ] **InnoSetup Compiled:** `ISCC.exe pc_agent/installer/setup.iss` compiles `PotPilot_Setup.exe` with automatic Windows Firewall rule registration.
- [ ] **Flutter APK Built:** `flutter build apk --release` produces the production Android APK.
- [ ] **E2E Benchmark Passed:** Verified `< 5ms` UDP trackpad latency, background PotPlayer `WM_COMMAND` execution, and 250ms live scrub-bar sync.