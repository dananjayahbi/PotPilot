# Doc 05: Flutter App Boilerplate, Dependencies & Root Navigation Shell
> Part of PotPilot plan-series · Category A · Session 1 Wave 1.A · Flutter App

## 1. Purpose & Scope
Scaffolds the `mobile_app/` Flutter project (Android-first bedroom remote) and its root shell:
- `pubspec.yaml` with the frozen core dependency set (`flutter_riverpod`, `web_socket_channel`, `mobile_scanner`, `phone_state`, `vibration`, `shared_preferences`).
- `analysis_options.yaml` implementing Doc 01's Dart lint contract.
- `lib/main.dart` root navigation shell: AMOLED MaterialApp hook + 4-destination `NavigationBar` (`Deck`, `Trackpad`, `Bed Mode`, `Library`) over an `IndexedStack` so per-tab state survives switching. Session 3 (Wave 3.A) replaces the placeholder bodies with the real feature screens. **(4-destination shape pre-round-6 — Bed Mode removed in round 6, 2026-10-18, now 3 destinations; see the round-6 amendment below.)**
- Android manifest permission declarations required by later features.

> **Round-6 amendment (2026-10-18):**
> - **Bed Mode tab removed** — the shell now has **3 tabs**: `AppTab { deck, trackpad, library }` with `kStartupTabIds = ['deck','trackpad','library']` (Doc 34). Every "4-destination" / `bedMode` / `_BedModePlaceholder` statement below is the original Wave 1.A shape, **deprecated in round 6 (2026-10-18)**; the replacement feature is the trackpad keyboard trigger zone ([37_flutter_full_pc_keyboard_sheet.md](37_flutter_full_pc_keyboard_sheet.md) §11).
> - **Dependency set** — the "frozen six" runtime deps gained a 7th in round 6: `screen_brightness: ^2.1.11` (§6.1; application-window brightness only, **no Android permission**), used by the DISPLAY settings card and re-applied at startup in `main()`.

**Out of scope:** OLED theme tokens ([29_flutter_oled_theme_design_system.md](29_flutter_oled_theme_design_system.md) — this doc only reserves the `ThemeData` injection point), all networking (Docs 30–34), all feature surfaces (Docs 35–45), hardware hooks (Docs 43–44), final tab wiring and `flutter build apk` (Session 3), iOS targets (§10).

## 2. File Ownership
**Create-only (owned by this doc):**

| Path | Purpose |
|---|---|
| `mobile_app/pubspec.yaml` | Package manifest + frozen dependency set |
| `mobile_app/analysis_options.yaml` | Lint rules per Doc 01 §4.5 |
| `mobile_app/lib/main.dart` | `main()`, `PotPilotApp`, `AppShell` navigation shell (created here; **extended** by Session 3 Wave 3.A, which may only replace the four placeholder `_*Placeholder` bodies inside the marked `// WIRING (Session 3)` region) |
| `mobile_app/android/app/src/main/AndroidManifest.xml` | Permission declarations (§5.2); if `flutter create` already generated the file, this doc only adds the `<uses-permission>` lines |
| `mobile_app/android/app/build.gradle.kts` | Only the `minSdkVersion` (≥ 21) and `namespace`/`applicationId` (`com.potpilot.remote`) lines required by §4.1 step 4; Gradle logic untouched |
| `mobile_app/test/app_shell_test.dart` | Shell widget suite |

**Reads / touched by other docs:** `mobile_app/lib/core/theme/oled_theme.dart` (Doc 29 — imported by `main.dart` once it exists; until then a local fallback `ThemeData.dark()` is used, guarded by the Session-3 wiring region); `lib/network/*` (Docs 30–33) and `lib/features/*` (Docs 35–45) create their own files in their own waves; Docs 42–44 add nothing to the manifest (covered by §5.2).

## 3. Public Contract
```dart
// mobile_app/lib/main.dart
void main() { runApp(const PotPilotApp()); }
    /// Entry point; no async bootstrap — providers (Doc 33) initialize lazily.

class PotPilotApp extends StatelessWidget
    /// Root MaterialApp: dark-only, pitch-black scaffold, delegates home to AppShell.

class AppShell extends StatefulWidget
    /// Persistent 4-tab shell (3 since round 6, 2026-10-18 — bedMode removed);
    /// body hosted in IndexedStack to preserve tab state.

enum AppTab { deck, trackpad, bedMode, library }
    /// Canonical tab order; index == NavigationBar destination index.
    /// (Removed in round 6, 2026-10-18: now `enum AppTab { deck, trackpad, library }`.)

class _AppShellState extends State<AppShell> {
  int _index;                     // selected tab, starts at AppTab.deck.index
  void _onDestinationSelected(int i);
}
```
Shell behavior contract:
- Tabs in fixed order: `0 Deck (PotPlayer)` · `1 Trackpad` · `2 Bed Mode` · `3 Movie Library` (matches Session 3 wiring list in overview §6). **(Removed in round 6, 2026-10-18: order is now `0 Deck · 1 Trackpad · 2 Movie Library` — no Bed Mode tab.)**
- `IndexedStack` keeps every tab alive; switching tabs never resets scroll/gesture state (required for blind-mode muscle memory).
- Bottom `NavigationBar` hides automatically once Bed Mode is active (full-screen gesture canvas, Doc 41) — the shell exposes `setTab(AppTab)` for programmatic pushes (e.g. QR pairing → Deck after Doc 32). **(Bed Mode removed in round 6, 2026-10-18 — auto-hide rule moot; `setTab` retained.)**
- No routing package: navigation is shell-index switching plus `Navigator` for modals/sheets (Docs 39/40/37).

## 4. Internal Design
### 4.1 Scaffolding steps
1. `flutter create --org com.potpilot --project-name potpilot_remote mobile_app` (Android platform only: `--platforms android`); abort if `mobile_app/pubspec.yaml` already exists (create-only discipline).
2. Replace generated `pubspec.yaml` with §6.1 manifest; run `flutter pub get`.
3. Write `analysis_options.yaml` (§4.3), overwrite `lib/main.dart` with the shell (§3), delete generated `test/widget_test.dart` counter demo.
4. Add §5.2 `<uses-permission>` entries to `AndroidManifest.xml`; verify `minSdkVersion` ≥ 21 in `build.gradle.kts` (mobile_scanner floor).
5. `flutter analyze` (0 issues) + `flutter test` (shell suite green) as the done gate.

### 4.2 Shell structure
```mermaid
flowchart TD
  M[main.dart: runApp] --> A[PotPilotApp MaterialApp dark-only]
  A --> S[AppShell: NavigationBar + IndexedStack]
  S --> T0[0 Deck — placeholder → Doc 36]
  S --> T1[1 Trackpad — placeholder → Doc 35]
  S --> T2[2 Bed Mode — placeholder → Doc 41 — removed in round 6, 2026-10-18]
  S --> T3[3 Library — placeholder → Doc 45]
  S -.setTab AppTab.deck.-> P[QR Pairing result path — Doc 32]
```
State machine (tab index): `deck ↔ trackpad ↔ bedMode ↔ library` via bar taps; `bedMode →` any tab via `setTab` only (bar hidden). System back button on tab 0 exits app; on other tabs returns to tab 0 (Android `PopScope`). **(Round 6, 2026-10-18: `bedMode` dropped — machine is `deck ↔ trackpad ↔ library`.)**

### 4.3 Lint contract (from Doc 01 §4.5)
`include: package:flutter_lints/flutter.yaml`; overrides: `prefer_single_quotes: true`, `always_declare_return_types: true`, `avoid_print: true`, `lines_longer_than_80_chars: false` (effective 100). `flutter analyze` exit 0 is CI law; ignores need same-line reasons.

### 4.4 Placeholder screen contract (Session 3 replaces bodies only)
Each tab initially hosts a minimal placeholder satisfying the shell contract so Session 3's wiring is a pure body-swap:
```dart
class _DeckPlaceholder extends StatelessWidget
    /// Tab 0 body — Session 3 wires Doc 36's PotPlayerDeck here.
class _TrackpadPlaceholder extends StatelessWidget
    /// Tab 1 body — Session 3 wires Doc 35's VirtualTrackpad here.
class _BedModePlaceholder extends StatelessWidget
    /// Tab 2 body — Session 3 wires Doc 41's BlindGesturePad here.
    /// (Removed in round 6, 2026-10-18 — bed mode tab deleted.)
class _LibraryPlaceholder extends StatelessWidget
    /// Tab 3 body — Session 3 wires Doc 45's MovieBrowser here.
```
Rules: placeholders render the AMOLED-black scaffold with a centered dim label; they hold **no** state and import nothing beyond Flutter SDK; the `// WIRING (Session 3)` comment in `main.dart` marks the exact swap region. After pairing (Doc 32) the shell must expose `AppShell.of(context).setTab(AppTab.deck)` for post-scan navigation — implemented as an `InheritedWidget`/`GlobalKey<AppShellState>` bridge owned by this doc.

## 5. Protocol & Data Compliance
### 5.1 Wire-constant usage (no host hardcoding)
The app must **never** hardcode a PC IP; connection endpoints come from QR scan (Doc 32) or mDNS `_potpilot._tcp.local.` (Doc 16/32) and are cached by Doc 34. Port constants used after pairing: `udpPort = 50505` and `wsPort = 50506` are defined in the codecs ([02](02_binary_udp_protocol_spec.md)/[03](03_websocket_json_schema_spec.md)) and imported, not re-declared. WS URL after pairing: `ws://<host>:50506/?auth=<token-hex>` (Doc 03 §4.2 handshake), built by Doc 31.

### 5.2 Android permissions (manifest, declared here once for the whole app)

| Permission | Consumer feature | Doc |
|---|---|---|
| `android.permission.INTERNET` | UDP + WebSocket | 30/31 |
| `android.permission.ACCESS_NETWORK_STATE` | Connectivity checks before send | 31 |
| `android.permission.ACCESS_WIFI_STATE` + `CHANGE_WIFI_MULTICAST_STATE` | mDNS discovery needs the multicast lock | 32 |
| `android.permission.CAMERA` | QR pairing scanner | 32 |
| `android.permission.READ_PHONE_STATE` | Incoming-call auto-pause listener | 44 |
| `android.permission.VIBRATE` | Haptic engine | 42 |

Runtime request timing: CAMERA at scanner open (Doc 32); READ_PHONE_STATE at first enable of auto-pause toggle (Doc 44); VIBRATE is install-time-granted on modern Android (no prompt).

## 6. Dependencies & Integration Points
### 6.1 `pubspec.yaml` (frozen core set; versions = provisional caret ranges, resolved at scaffold time)

| Package | Constraint | Purpose (doc) |
|---|---|---|
| `flutter_riverpod` | `^2.5.1` | State/DI: telemetry provider, connection cache (Docs 33/34) |
| `web_socket_channel` | `^3.0.0` | WS client transport on 50506 (Doc 31) |
| `mobile_scanner` | `^5.2.0` | QR pairing camera scanner (Doc 32) |
| `phone_state` | `^1.3.0` | Android telephony state stream (Doc 44) |
| `vibration` | `^2.0.0` | Haptic patterns (Doc 42) |
| `shared_preferences` | `^2.2.0` | Paired-PC cache, tokens, settings (Doc 34) |
| `screen_brightness` | `^2.1.11` | **(round 6, 2026-10-18)** Controller app-window brightness (Doc 34 key `pp.display.brightness`, `DisplaySettingsCard` slider key `settings_brightness`) — application mode only, **no Android permission**; applied at startup in `main()` |

Environment: `sdk: ">=3.5.0 <4.0.0"`, `flutter: ">=3.5.0"` (Flutter 3.x per overview; exact SDK pinned at scaffold). Dev: `flutter_test` (SDK), `flutter_lints: ^4.0.0`, `build_runner` **not** introduced (no codegen needed in Wave 1.A).
**Internal docs:** [01_monorepo_structure.md](01_monorepo_structure.md) (lint contract §4.5) · [02_binary_udp_protocol_spec.md](02_binary_udp_protocol_spec.md) · [03_websocket_json_schema_spec.md](03_websocket_json_schema_spec.md) · [29_flutter_oled_theme_design_system.md](29_flutter_oled_theme_design_system.md) · [30_flutter_udp_datagram_sender.md](30_flutter_udp_datagram_sender.md) · [31_flutter_websocket_client_reconnect.md](31_flutter_websocket_client_reconnect.md) · [32_flutter_qr_scanner_mdns_pairing.md](32_flutter_qr_scanner_mdns_pairing.md) · [33_flutter_telemetry_state_provider.md](33_flutter_telemetry_state_provider.md) · [34_flutter_local_storage_connection_cache.md](34_flutter_local_storage_connection_cache.md) · [35](35_flutter_120hz_virtual_trackpad.md)/[36](36_flutter_custom_potplayer_deck_ui.md)/[41](41_flutter_blind_bed_mode_gestures.md)/[45](45_flutter_in_app_movie_library_browser.md) (tab bodies).
**Platform APIs (via plugins):** Android CameraX (mobile_scanner), `TelephonyCallback`/`PhoneStateListener` (phone_state), `Vibrator`/`HapticFeedback` (vibration), `SharedPreferences` (shared_preferences), `MulticastLock` (WifiManager, via Doc 32's zeroconf-equivalent Dart handling).

## 7. Edge Cases & Failure Handling
- **Camera permission denied** (QR scanner) → scanner screen shows rationale + "Open Settings" button; app remains fully usable via mDNS/manual path (Doc 32 concern; shell must not deadlock on it).
- **No camera device** → `mobile_scanner` unavailable; Doc 32 falls back to mDNS-only pairing; shell unaffected.
- **Phone-state permission denied** → auto-pause hook (Doc 44) disabled with visible toggle-off; playback control unaffected.
- **`flutter create` version drift** (Gradle/plugin templates) → scaffold pins `minSdk 21`, verifies Kotlin DSL defaults; failures surface at `flutter analyze`/build gate in §4.1 step 5.
- **Tab body swap in Session 3** → placeholders implement the same `Widget build(BuildContext)` contract; wiring region comment marks the only editable zone to avoid clobbering `setTab` logic.
- **Back-press semantics** → `PopScope`: non-deck tabs pop to deck first, deck exits (no accidental app kill from Bed Mode). **(Bed Mode gone in round 6, 2026-10-18 — pop-to-deck rule retained.)**
- **Locale/text-scale** → MaterialApp forced `darkTheme` + `themeMode: dark`, `useMaterial3: true`; no light theme exists (AMOLED charter).
- **Hot-restart vs pairing state** → no persistent side effects in shell construction; all connection state lives in Riverpod (Doc 33/34).

## 8. Acceptance Criteria
- [ ] `flutter pub get` resolves with the §6.1 packages (**seven** since round 6, 2026-10-18 — `screen_brightness` added; originally six); `pubspec.yaml` contains no other runtime deps.
- [ ] `flutter analyze` exits 0 with Doc 01 lint overrides active.
- [ ] `flutter test` green: shell shows 4 destinations in order *(3 destinations since round 6, 2026-10-18 — Bed Mode removed)*, `IndexedStack` retains counter/state across tab switches, back-press pops to deck then exits.
- [ ] Manifest contains exactly the six §5.2 permissions; `minSdkVersion` ≥ 21.
- [ ] `main.dart` has no feature imports outside the `// WIRING (Session 3)` region; `setTab` is public on the shell for Doc 32.
- [ ] No PC IP/port/token hardcoded anywhere in `lib/`.
- [ ] `flutter build apk --debug` succeeds on the scaffold (release build is Session 3's gate).

## 9. Test Plan
| File | Asserts |
|---|---|
| `mobile_app/test/app_shell_test.dart` | Renders 4 `NavigationBar` destinations with correct labels *(3 since round 6, 2026-10-18)*; tapping switches `IndexedStack` child and retains per-tab state (elevated counter in placeholder survives two round-trips); `AppTab` indices match destination order; `PopScope` behavior on non-deck tabs |
| `mobile_app/test/manifest_permissions_test.dart` | Parses `AndroidManifest.xml` (path-assert) and verifies the six §5.2 permission strings are present, no more, no fewer |
Manual: `flutter run` on a physical Android device → dark splash, 4 tabs *(3 since round 6, 2026-10-18)*, tab state retention across 10 rapid switches; deny CAMERA → open scanner (Doc 32 later) still navigable; `flutter build apk --debug` installs and launches.

## 10. Assumptions & Open Questions
**Assumptions:** (a) Package name `potpilot_remote` with org `com.potpilot` (blueprint silent — chosen once, referenced by Doc 28/Gradle signing in Session 3). (b) Dependency versions are provisional caret ranges chosen at planning time; `flutter pub get` at scaffold resolves the latest compatible — exact pins committed via `pubspec.lock` (tracked, per Doc 01 §4.2). (c) No routing package (no `go_router`) — `IndexedStack` + `Navigator` suffice and keep the dependency set frozen. (d) iOS is out of charter (overview ships an APK); `Info.plist` camera key is a Session 3+ concern if iOS is ever added. (e) `main.dart` hosts both `PotPilotApp` and the shell (blueprint lists only `main.dart` at `lib/` root — no extra top-level file invented). (f) Doc 29's theme file may not exist in Wave 1.A; fallback dark theme bridges until Session 2 wiring. (g) `phone_state ^1.3.0`/`vibration ^2.0.0` ranges verified as existing pub.dev packages at planning time; if resolution fails at scaffold, keep the package name (frozen) and widen only the range.
**Open questions:** none blocking; exact Android `targetSdkVersion` is delegated to Session 3's release build doc.
