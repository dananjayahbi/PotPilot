# Doc 36: PotPlayer Remote Deck Grid

> Part of PotPilot plan-series · Category G · Session 2 Wave 2.A · Flutter App

## 1. Purpose & Scope
**Delivers** `potplayer_deck.dart` — the dedicated PotPlayer remote grid rendered as the app's primary control tab: a large centered **Play/Pause** toggle, seek keys **−5s / +5s / −30s / +30s**, speed keys **−0.1x / Reset 1.0x / +0.1x**, **Next/Prev Frame**, **Fullscreen** toggle, and **Aspect Ratio** cycle. All keys dispatch guaranteed-delivery WebSocket `CMD_POTPLAYER` commands and give instant optimistic feedback, reconciled by 250 ms telemetry.

**Out of scope:**
- Timeline scrubber and speed/volume OSD badges → [38_flutter_live_scrub_bar_speed_hud.md](38_flutter_live_scrub_bar_speed_hud.md) (deck may embed its widget as a header, but owns neither its logic nor its file)
- PC keyboard overlay → [37_flutter_full_pc_keyboard_sheet.md](37_flutter_full_pc_keyboard_sheet.md); audio/subtitle sheet → [39_flutter_audio_subtitle_sync_modal.md](39_flutter_audio_subtitle_sync_modal.md); monitor/power drawer → [40_flutter_multi_monitor_power_sheet.md](40_flutter_multi_monitor_power_sheet.md)
- Blind-mode gesture control → [41_flutter_blind_bed_mode_gestures.md](41_flutter_blind_bed_mode_gestures.md)
- PC-side `WM_COMMAND` codes and speed range enforcement → [09_potplayer_wm_command_dispatcher.md](09_potplayer_wm_command_dispatcher.md)
- Tab/navigation hosting of the deck in `mobile_app/lib/main.dart` → Session 3 master-shell wiring

## 2. File Ownership
**Creates (create-only):**
- `mobile_app/lib/features/deck/potplayer_deck.dart`

**Reads / integrates (owned by other docs):**
- `mobile_app/lib/network/telemetry_provider.dart` — Doc 33: `TelemetryState` fields `isPlaying`, `speed`, `durationMs`, `fileTitle`, `isConnected`, plus staleness clock, drive glyphs, badge text, and key gating
- `mobile_app/lib/network/ws_client.dart` — Doc 31: `WsClient.send(type, action, payload)` + connected flag for disabling keys
- `mobile_app/lib/core/theme/oled_theme.dart` — Doc 29: `#000000` background, night-vision accent tokens
- `mobile_app/lib/core/haptics/haptic_engine.dart` — Doc 42: tap tick, play/pause thud, speed-reset double-tick
- `mobile_app/lib/features/hud/scrub_speed_hud.dart` — Doc 38: optional embedded `ScrubSpeedHud` header widget
- `mobile_app/pubspec.yaml` — Doc 05: `flutter_riverpod` dependency

## 3. Public Contract
```dart
/// Every dispatchable deck key. Wire mapping lives in §5.
enum DeckAction {
  playPause, seekBack5, seekFwd5, seekBack30, seekFwd30,
  speedDown, speedReset, speedUp, framePrev, frameNext,
  fullscreen, aspectCycle,
}

/// Immutable declarative spec for one grid cell (glyph/label, action, column span, gating rule).
class DeckKeySpec {
  const DeckKeySpec({required this.action, required this.label,
    required this.span, this.requiresMedia});
}

/// Root deck widget: consumes TelemetryNotifier (Doc 33), hosts optional HUD header + DeckGrid.
class PotPlayerDeck extends ConsumerWidget {
  const PotPlayerDeck({super.key});
}

/// Responsive N-column grid materialising a fixed [DeckKeySpec] table.
class DeckGrid extends StatelessWidget {
  const DeckGrid({super.key, required this.specs, required this.onTap});
  final List<DeckKeySpec> specs;
  final ValueChanged<DeckAction> onTap;
}

/// Single tactile key: OLED rest/pressed states, disabled styling, haptic tick on tap.
class DeckButton extends StatelessWidget {
  const DeckButton({super.key, required this.spec, required this.enabled,
    required this.onPressed});
}

/// Payload builder + dispatch gate for one deck action (WS only, no UDP).
class PotPlayerDeckController {
  /// Maps [action] to the Doc 03 frozen registry envelope and sends via Doc 31
  /// `WsClient.send("CMD_POTPLAYER", action, payload)`; reads [state] for speed math.
  Future<void> dispatch(DeckAction action, TelemetryState state);
  /// Returns current ± [delta] rounded to 0.1 and clamped to PotPlayer's 0.2x–4.0x range
  /// (SET_SPEED always carries an absolute `multiplier` per Doc 03).
  double stepSpeed(double current, double delta);
}
```

## 4. Internal Design
1. **Declarative key table:** module-level `const List<List<DeckKeySpec>> deckRows` defines 4 rows: transport row (Play/Pause spans 2), seek row (`−30s −5s +5s +30s`), speed row (`−0.1x 1.0x +0.1x`), utility row (`⏮ ⏭ ⛶ Aspect`). Rendering is pure data → widget; no hand-placed buttons.
2. **Tap pipeline:** `onTap` → per-action 80 ms debounce (last-tap-wins) → haptic (Doc 42 pattern per action) → build payload from current telemetry state → `WsClient.send("CMD_POTPLAYER", action, payload)` (Doc 31) → optimistic local update.
3. **Speed arithmetic:** `stepSpeed` computes `((current + delta) * 10).roundToDouble() / 10` then `clamp(0.2, 4.0)` — integer-tenth math avoids `0.30000000000000004` drift. Doc 03's `SET_SPEED` carries an **absolute** `multiplier`, so the controller always computes `current ± 0.1` (or `1.0` for reset) from the latest `TelemetryState.speed` and sends that value.
4. **Optimistic play-state flip:** `playPause` flips a local `assumedPlaying` flag immediately (glyph changes in the same frame); the next `TELEMETRY_SYNC` (≤250 ms, wire `is_playing`) overwrites it — telemetry always wins on mismatch.
5. **Gating:** keys with `requiresMedia: true` (seek ×4, frame ×2) render disabled when `durationMs <= 0` (wire `duration_ms`, −1/0 = none). `fullscreen`/`aspectCycle` remain enabled without media (PotPlayer window exists regardless). Speed keys disable when `speed` is unknown, when `potplayer_running` is false, or when the computed multiplier would equal the current one (already at 0.2x/4.0x bound).
6. **Staleness:** if the age of the last accepted telemetry `timestamp` (Doc 33 staleness clock) exceeds 1000 ms, the grid renders at 50 % opacity and `playPause` dispatches but the glyph holds the last known state.

```mermaid
flowchart LR
  T[DeckButton tap] --> D[80ms debounce]
  D --> H[HapticEngine 42]
  H --> P[Build payload from TelemetryState 33]
  P --> W[WsClient 31 send CMD_POTPLAYER]
  W --> PC[WS :50506 router 14]
  PC --> WM[WM_COMMAND dispatcher 09]
  TELEMETRY_SYNC 250ms -.reconciles glyphs.-> T
```

**Layout spec (portrait, 4 columns, 8 dp gutters):**

| Row | Cells (span) | Height |
|---|---|---|
| 0 | file-title caption strip (single line, ellipsised) | 24 dp |
| 1 | Play/Pause (2) + Speed badge (2, read-only from HUD or label) | 88 dp |
| 2 | −30s (1) −5s (1) +5s (1) +30s (1) | 64 dp |
| 3 | −0.1x (1) 1.0x (1) +0.1x (1) — speed row | 56 dp |
| 4 | ⏮ Frame (1) ⏭ Frame (1) ⛶ Fullscreen (1) Aspect (1) | 56 dp |

**Haptic mapping (via Doc 42, one per successful dispatch):**

| Action group | Pattern |
|---|---|
| `playPause` | `play(heavyThud)` |
| `seekBack*/seekFwd*` | `play(microTick)` |
| `speedDown/speedUp` | `play(microTick)` |
| `speedReset` | `play(doubleTick)` |
| `frame*/fullscreen/aspectCycle` | `play(microTick)` |
| disabled key pressed | nothing (silent reject) |

## 5. Protocol & Data Compliance
Action catalog is the frozen registry in [03_websocket_json_schema_spec.md](03_websocket_json_schema_spec.md) §5.3 (envelope fields `id/type/action/payload/timestamp` per overview §4.2); this doc **consumes** exactly:

| On-screen control | WS `type` | `action` | `payload` |
|---|---|---|---|
| Play/Pause | `CMD_POTPLAYER` | `PLAY_PAUSE` | `{}` |
| −5s / +5s | `CMD_POTPLAYER` | `SEEK_DELTA` | `{"delta_ms": -5000}` / `{"delta_ms": 5000}` |
| −30s / +30s | `CMD_POTPLAYER` | `SEEK_DELTA` | `{"delta_ms": -30000}` / `{"delta_ms": 30000}` |
| Speed −0.1x / +0.1x | `CMD_POTPLAYER` | `SET_SPEED` | `{"multiplier": <computed, e.g. 0.9 / 1.5>}` |
| Speed Reset 1.0x | `CMD_POTPLAYER` | `SET_SPEED` | `{"multiplier": 1.0}` |
| Prev / Next Frame | `CMD_POTPLAYER` | `FRAME_STEP` | `{"direction": "BACKWARD"}` / `{"direction": "FORWARD"}` |
| Fullscreen | `CMD_POTPLAYER` | `TOGGLE_FULLSCREEN` | `{}` |
| Aspect Ratio cycle | `CMD_POTPLAYER` | `CYCLE_ASPECT_RATIO` | `{}` |

**TELEMETRY_SYNC fields rendered (wire names, Doc 03 §5.6):** `is_playing` → `TelemetryState.isPlaying` (glyph ▶/⏸), `speed` (speed badge + step base, format `1.4x`), `duration_ms` (media gating; −1 = none), `file_title` (deck header), `potplayer_running` (whole-grid kill switch), `timestamp`/Doc 33 staleness clock (dimming).

## 6. Dependencies & Integration Points
- **Action catalog / envelope:** [03_websocket_json_schema_spec.md](03_websocket_json_schema_spec.md) — §5 table matches its frozen registry verbatim
- **Telemetry state:** [33_flutter_telemetry_state_provider.md](33_flutter_telemetry_state_provider.md) — `TelemetryState` consumed read-only
- **Command sender:** [31_flutter_websocket_client_reconnect.md](31_flutter_websocket_client_reconnect.md) — `WsClient.send("CMD_POTPLAYER", action, payload)` + connection status
- **Haptics:** [42_flutter_haptic_feedback_engine.md](42_flutter_haptic_feedback_engine.md) — `HapticEngine.play(HapticPattern.heavyThud | microTick | doubleTick)`
- **Theme:** [29_flutter_oled_theme_design_system.md](29_flutter_oled_theme_design_system.md) — color/typography tokens only
- **Embedded HUD (optional):** [38_flutter_live_scrub_bar_speed_hud.md](38_flutter_live_scrub_bar_speed_hud.md)
- **PC side:** [14_pc_websocket_server_router.md](14_pc_websocket_server_router.md) → [09_potplayer_wm_command_dispatcher.md](09_potplayer_wm_command_dispatcher.md)
- **External packages:** `flutter_riverpod` (ConsumerWidget/StateNotifier wiring); `vibration` used indirectly via Doc 42. No other packages.

## 7. Edge Cases & Failure Handling
- **WS reconnecting / offline (Doc 31 state ≠ connected):** grid renders disabled with a thin crimson "reconnecting" strip; no dispatch attempts (no client-side queueing — avoids stale play/pause after reconnect).
- **Telemetry stale (>1000 ms):** dim grid to 50 %, hold last glyph; speed keys disable (computed `multiplier` needs a known base); seeks still allowed if media was known (position-independent deltas). `potplayer_running == false` disables the whole grid with a "PotPlayer closed" caption.
- **Speed at bounds (0.2x / 4.0x):** the bound-adjacent key renders disabled — `stepSpeed` would return the current value, so no clamped no-op dispatch leaves the client.
- **Rapid double-taps:** 80 ms debounce per action id; `playPause` last-tap-wins so a double tap ends paused once, not twice-plus.
- **Zero-duration / no media (`duration_ms <= 0`):** seek and frame keys disabled; `PLAY_PAUSE`, fullscreen, aspect still dispatch (agent no-ops safely if no file loaded).
- **Optimistic mismatch:** if telemetry reports the opposite `is_playing` after 250 ms, glyph snaps back (telemetry authoritative); no retry loop.
- **`_ERROR` reply:** Doc 03 replies `PLAY_PAUSE_ERROR` etc. on the correlation id — deck ignores bodies (all actions are idempotent-safe no-ops on the PC side) but logs; UI stays optimistic until telemetry corrects it.
- **Floating-point display:** speed always formatted via `(speed * 10).round() / 10` → single decimal (`1.4x`, never `1.4000000000000001`).

## 8. Acceptance Criteria
- [ ] Tapping Play/Pause flips the glyph same-frame and emits exactly one `CMD_POTPLAYER`/`PLAY_PAUSE` envelope with fresh uuid id.
- [ ] ±5s and ±30s keys emit `SEEK_DELTA` with `delta_ms` exactly `∓5000` / `∓30000` (frozen Doc 03 payload) and are reconciled with PotPlayer (background window) in manual test.
- [ ] Speed keys send absolute `multiplier` values on the 0.1 grid, never outside 0.2–4.0, and Reset sends `{"multiplier": 1.0}` + Doc 42 `doubleTick` haptic.
- [ ] Frame step, Fullscreen, Aspect each dispatch their distinct action from §5 and work while PotPlayer is unfocused.
- [ ] Seek/Frame keys visually disabled when `durationMs <= 0`; speed keys disabled when `speed == null`; whole grid dimmed when telemetry age > 1000 ms or WS not connected.
- [ ] All surfaces use Doc 29 tokens on `#000000` (no glare-white fills); layout fits 360×800 dp without scrolling at default text scale.
- [ ] `flutter analyze` clean; all widget tests green.

## 9. Test Plan
- **`mobile_app/test/features/deck/potplayer_deck_test.dart`** (widget): pumps `PotPlayerDeck` with a fake `TelemetryNotifier`; for each of the 12 keys asserts exactly one captured command with the §5 `type/action/payload`; asserts seek/frame keys are `offstage`-disabled at `durationMs: 0`; asserts play glyph flips before any telemetry arrives.
- **`mobile_app/test/features/deck/deck_controller_test.dart`** (unit): `stepSpeed` cases — `1.0 + 0.1 → 1.1`, `4.0 + 0.1 → 4.0`, `0.2 − 0.1 → 0.2`, `1.35` display rounding, repeated ±0.1 ×30 stays on the 0.1 grid; `SET_SPEED` payload carries the absolute `multiplier`; debounce: two taps within 80 ms → one send.
- **`mobile_app/test/features/deck/deck_staleness_test.dart`** (widget): stale snapshot (age 1500 ms) → 50 % opacity + `speed == null` disables speed row.
- **Manual:** pair phone → hold Play/Pause while PotPlayer is behind other windows → playback toggles; kill agent → grid dims within 1 s and emits nothing; toggle play twice quickly → single effective toggle.

## 10. Assumptions & Open Questions
- **Resolved against the freeze:** all eight actions and payloads in §5 are consumed verbatim from [03_websocket_json_schema_spec.md](03_websocket_json_schema_spec.md) §5.3 — notably `SEEK_DELTA` in **milliseconds** (±5000/±30000), `SET_SPEED` with absolute `multiplier` (client computes the ±0.1 step), `FRAME_STEP` with `"FORWARD"|"BACKWARD"`, and `CYCLE_ASPECT_RATIO`.
- **Assumption:** discrete ±5s/±30s use WS (guaranteed delivery, no position math); UDP `0x04` SCRUB_SEEK stays reserved for continuous drags in Docs 38/41.
- **Assumption:** speed step = 0.1x (batch brief), reset = 1.0x; agent re-clamps to 0.2–4.0 (Doc 09) as second line of defense.
- **Assumption:** debounce = 80 ms; `potplayer_running` false disables the grid (kill-switch semantics).
- **Note (cross-doc consistency):** [42_flutter_haptic_feedback_engine.md](42_flutter_haptic_feedback_engine.md)'s illustrative table says `SET_SPEED {speed:1.0}` — the frozen field name is `multiplier`; Doc 42's wording should follow Doc 03 (no payload crosses Doc 42's API, so no functional impact).
- **Open:** none blocking implementation.

## 11. Round-5 Addendum — Ruler Seek Slider, Volume Popup, Settings (2026-10-17)

User-driven redesign on top of §1–§10 (the generic top scrub track was "too small for a phone screen to slide precisely"):

- **Deck header row** (`deck_header_row.dart`): `DeckHeaderRow` = file caption (`deck_caption`) + `DeckVolumeButton` (`deck_volume_button`) + gear (`deck_settings_button`) → pushes `SettingsScreen`.
- **Volume popup** (`volume_popup.dart`): `showVolumePopup` keeps the old bottom-row semantics verbatim — optimistic drag preview, telemetry always wins, `SET_VOLUME {percent}` on release, WS-down/running gates; slider keys `deck_volume` / `deck_volume_value` preserved for tests.
- **Speed-sensing ruler** (`ruler/`), the bottom universal scrubber:
  - `seek_scale.dart` (pure Dart): 7 tiers (`1 s → 5 m` per 24 px notch; entries 0/150/400/800/1500/2500/4000 px/s), instant climb + 65 % drop hysteresis (`SeekTierResolver`, sign-agnostic so fast backward flicks climb too), `clampGestureMs` caps one gesture at ±5 min, `formatDeltaLabel` renders `+18 s` / `−2:34` (U+2212).
  - `ruler_painter.dart`: ticks scroll under a fixed amber centre needle + foot dot; major labels at `labelEvery` cadence so labels always read round numbers.
  - `ruler_seek_slider.dart`: EMA velocity picks the tier per notch; notch micro-ticks, tier double-ticks, minute ticks (shared engine); release projects a flick (`v · msPerPx · 0.12 s`); tap = fine jump in the tapped zone using track-space coordinates (`_trackKey`, padding-aware). Keys: `ruler_track` / `ruler_time` / `ruler_tier` / `ruler_delta` / `ruler_hint`.
  - All travel flows through `ScrubController.updateDragByMs` (scaled mode) → identical UDP preview throttle, WS `SEEK {position_ms}` commit, settle convergence, overshoot guard and minute haptics as the legacy track.
- **`ScrubTrack` + `_RailPainter` removed** from the Doc 38 HUD (dead once the ruler landed). The HUD keeps badges + time row and stays the telemetry→controller feed. **(Round 6, 2026-10-18: superseded — `ScrubTrack` restored as the top general seek bar, see §12.)**
- **`ScrubController._notify()` contract**: notifications raised mid-build (the HUD feeds telemetry from `build()`) defer to end-of-frame — sibling listeners (the ruler's `ListenableBuilder`) must never get `setState` during build; pure-Dart unit tests (no binding) still notify synchronously.
- **Settings screen** (`features/settings/settings_screen.dart`): trackpad cursor speed 0.2–3.0 (0.05 steps) with live `×N.NN` badge + Slow/Default/Fast/Max presets; write-through `ConnectionCache.saveTrackpadProfile` (Doc 34 key `pp.trackpad.profile.v1`); entries = deck header gear + library app-bar gear (`library_settings_button`).
- **PC seek chain (Doc 10 companion, agent side):** absolute `SEEK` and UDP `0x04` scrub targets rebase `SeekBaseTracker` after `ok` — ruler/tap commits can no longer be snapped back by the next `SEEK_DELTA`; `COALESCE_WINDOW_S` 0.8 s → 1.5 s so ~1 Hz human tap bursts stay chained. **(Round 7, 2026-10-18: superseded — the chain is now composed inside `SeekQueue`, see §13.)**
- **Tests:** new `test/features/deck/ruler/seek_scale_test.dart`, `test/features/deck/ruler/ruler_seek_slider_test.dart`, `test/features/settings/settings_screen_test.dart`; `scrub_speed_hud_test` now drives the ruler (the prod gesture surface); `deck_step_volume_test`'s volume group opens the popup via `deck_volume_button`.

## 12. Round-6 Addendum — Seek Bar Restore, Display Brightness *(brightness removed in round 7, 2026-10-18)*, Settings Persistence (2026-10-18)

- **Top general seek bar restored** alongside the round-5 ruler: `features/hud/scrub_track.dart` (`ScrubTrack` + its own `_RailPainter`, key `hud_track`) is rendered again by `ScrubSpeedHud`. The deck now has both surfaces: the top drag-anywhere **general** track (fast scrubbing anywhere on the bar) and the bottom **speed-sensing ruler** (`ruler_seek_slider.dart`, §11) as the precision zone/speed-sensing control — both drive the same `ScrubController`. The §11 "ScrubTrack removed" bullet is superseded as of round 6.
- **Settings screen** gains a **DISPLAY** section: `features/settings/display_settings_card.dart` (`DisplaySettingsCard`, slider key `settings_brightness`) below the TRACKPAD card. It uses the new `screen_brightness: ^2.1.11` dependency (Doc 05 §6.1) in **application-window mode only — no Android permission** — persists write-through `ConnectionCache.saveBrightness` (Doc 34 key `pp.display.brightness`, 0.05–1.0, default 1.0), and `main()` re-applies the saved value at startup via `applyBrightness()`. **(Entire brightness card removed in round 7, 2026-10-18 — the OS now owns screen brightness; `display_settings_card.dart` deleted, `screen_brightness` dropped from Doc 05, `pp.display.brightness`/`saveBrightness`/startup `applyBrightness` all gone. Settings has only the TRACKPAD card.)**
- **Round-6 settings all persist** write-through ConnectionCache: cursor speed (§11, `pp.trackpad.profile.v1`), brightness (`pp.display.brightness`) **(removed in round 7, 2026-10-18 — key deleted with the feature)**, startup tab (`pp.startup_tab`, validated against `kStartupTabIds` = `deck`/`trackpad`/`library` after Bed Mode removal).
- **Shell:** bed mode removed (Doc 41 banner) → 3 tabs (Deck · Trackpad · Library); replacement feature is the trackpad keyboard trigger zone (Doc 37 §11).

## 13. Round-7 Addendum — Seek-Jitter Fix: PC Request Queue + Phone Anchors (2026-10-18)

User report: rapid forward/backward taps "go here and there in short frames" (believed to be network delay). Traced root causes — seeks were **already serialized** on the single asyncio loop (network reordering ruled out); the real bugs were stale chain bases: (i) chain base falling back to the 250 ms-poll + ~500 ms-position-chunk telemetry snapshot at burst starts / chain expiry, (ii) absolute scrubs computed from lagging telemetry rebasing the chain backwards, (iii) frame steps invisible to the chain.

- **PC — `SeekQueue`** (new `pc_agent/potplayer/seek_queue.py`; full spec in Doc 09 §5 round-7 amendment): `SEEK_DELTA` → `queue.delta()` chains from the last *pending* target while a burst is open (never the stale snapshot mid-chain) — leading edge dispatches immediately (zero latency), further deltas within `BURST_COALESCE_MS = 150` ms accumulate and one trailing timer dispatches a single final seek (signals cannot mix, no seek thrash; 150 ms > phone 80 ms per-action debounce + RTT, < ~250 ms human deliberate tap spacing); `SEEK` (ruler/tap commit) and UDP `0x04` → `queue.absolute()` — flushes pending deltas first (request order preserved), dispatches immediately, rebases the chain; `FRAME_STEP` → `queue.flush()` before dispatch + `note_external_move()` after `ok` so the next delta trusts fresh telemetry. `SeekBaseTracker` (`seek_base.py`) kept (`COALESCE_WINDOW_S` 1.5 s unchanged) + new `invalidate()`; the queue composes it. `main.py` routes via a module-global `seek_queue` test seam; clamp moved inside the queue. Replaces the §11 bare-tracker chain.
- **Phone — hold-repeat seek anchor** (`hardware_hooks/volume_button_hijack.dart`, Doc 43 §4.2): new `_seekAnchorSec` captured on the first successful scrub of a hold and reused for every repeat (`raw = anchor + direction × seekStepSec × repeatIndex`, clamped; reset in `_beginHold`/`_release`/`_resetMachine`). Previously the LIVE telemetry position was re-read every repeat, so a mid-hold position update double-counted and skipped. Regression test: "round 7: mid-hold telemetry updates never re-base the seek anchor" → `[150, 180, 210]` despite telemetry moving to 150 s mid-hold.
- **Phone — `endDrag` no longer dual-sends** (`features/hud/scrub_speed_hud.dart`, Doc 38 §4): on a live WS the final floored-seconds UDP bridge packet is **not** sent — the WS ms-precision `SEEK` is authoritative; a late UDP packet landing after it could drag the PC-side chain back up to ~1 s (stale-source rebase). UDP final commit only when WS is DOWN (fallback).
- **Tests:** new `pc_agent/tests/test_seek_queue.py` (12); `test_wiring.py` chain block flushes before asserting the final target (`13_345`); `test_ws_dispatch_and_telemetry.py` §8 checklist entry `bed_mode/blind_gesture_pad.dart` (deleted round 6) → `features/trackpad/keyboard_trigger_overlay.dart`.
- **Gates (all green, 2026-10-18):** `ruff check pc_agent` clean; pytest **531 passed, 1 skipped** (baseline 519+1, +12 queue); `flutter analyze` No issues found; `flutter test` **555 passed** (brightness −3, hijack +1). Artifacts rebuilt: `app-release.apk` 65.0 MB, `PotPilotAgent.exe` 7.1 MB (onedir, 2026-10-18), `PotPilot_Setup.exe` 28.1 MB (repair/upgrade intact via `maintenance_mode.iss`, unchanged this round).