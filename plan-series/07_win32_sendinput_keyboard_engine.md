# Doc 07: Win32 SendInput Keyboard Engine

> Part of PotPilot plan-series · Category B · Session 1 Wave 1.B · PC Agent

## 1. Purpose & Scope

**Delivers:** `pc_agent/input_engine/win32_keyboard.py` — a Win32 `KEYBDINPUT` injection engine that
turns `CMD_KEY` WebSocket commands into hardware-level keystrokes: Unicode string injection
(`KEYEVENTF_UNICODE`, surrogate-pair safe), virtual-keycode (`VK_*`) dispatch with extended-key
handling, and modifier combos (`Ctrl`, `Alt`, `Shift`, `Win`) with sticky-modifier tracking.

**In scope**
- `send_text()` for arbitrary UTF-8 strings typed into the focused app.
- `key_down` / `key_up` / `tap` for named keys (`ESC`, `TAB`, `ENTER`, `F1–F12`, arrows, `WIN`, …).
- `hotkey()` combos pressed/released in correct order, preserving pre-held modifiers.
- `release_all()` safety hook so a dropped connection never leaves a stuck Ctrl/Win key.

**Out of scope (owned elsewhere)**
- WebSocket envelope parsing, auth, action routing → [03](03_websocket_json_schema_spec.md),
  [14](14_pc_websocket_server_router.md), [15](15_pc_token_auth_middleware.md).
- Which keys the phone UI offers (Esc/Tab/Win/Alt+F4/F1–F12/arrows/text) → Flutter
  [37](37_flutter_full_pc_keyboard_sheet.md); this doc only guarantees the `KEY_MAP` covers it.
- Mouse buttons/movement → [06_win32_sendinput_mouse_engine.md](06_win32_sendinput_mouse_engine.md).
- Scan-code/game input, IME composition, on-screen keyboard display.

## 2. File Ownership

**Creates (create-only):**
- `pc_agent/input_engine/win32_keyboard.py`

**Reads / touches (owned by other docs):**
- `pc_agent/network/ws_server_router.py` ([14](14_pc_websocket_server_router.md)) — sole caller;
  resolves `CMD_KEY` envelopes to the methods below and calls `release_all()` on disconnect.
- `shared_specs/ws_command_schema.json` ([03](03_websocket_json_schema_spec.md)) — canonical action
  enum/payload schema this contract is aligned with (read-only).
- `pc_agent/core/config_manager.py` ([26](26_pc_config_persistence_manager.md)) — optional overrides;
  engine runs on inline defaults when config is absent.

## 3. Public Contract

```python
# pc_agent/input_engine/win32_keyboard.py

class KeyboardEngineConfig:
    """Frozen knobs; inline defaults are shipped values."""
    release_on_disconnect: bool = True   # router calls release_all() when a WS client drops

class KeyboardEngine:
    def __init__(self, config: KeyboardEngineConfig | None = None) -> None:
        """Allocate reusable ctypes INPUT buffers; no Win32 call until first key."""
    def send_text(self, text: str) -> int:
        """Inject text as UTF-16 code units via KEYEVENTF_UNICODE; returns INPUT count sent."""
    def key_down(self, key: str) -> bool:
        """Press a named key from KEY_MAP; returns False (and counts) on unknown name."""
    def key_up(self, key: str) -> bool:
        """Release a named key from KEY_MAP; returns False on unknown name."""
    def tap(self, key: str) -> int:
        """key_down + key_up back-to-back; returns INPUT count (2 on success, 0 on miss)."""
    def hotkey(self, *keys: str) -> int:
        """Press modifiers (CTRL, ALT, SHIFT, WIN) in order, tap the final key, release in reverse."""
    def release_all(self) -> int:
        """Release held modifiers first, then other held keys; clears all state; returns count."""
    @property
    def held_keys(self) -> frozenset[str]:
        """Named keys currently tracked as down (modifiers included)."""
    @property
    def send_failures(self) -> int:
        """Monotonic count of SendInput calls that injected fewer events than requested."""
    @property
    def unknown_key_hits(self) -> int:
        """Monotonic count of dropped key names that are absent from KEY_MAP."""

engine: KeyboardEngine
"""Module singleton consumed by ws_server_router.py (Doc 14)."""
```

`KEY_MAP: dict[str, tuple[int, bool]]` maps normalized key name → `(vk_code, extended_flag)`.
Action names consumed from the WS envelope are listed in §5.

## 4. Internal Design

1. **Name normalization.** Trim, uppercase, alias (`"CONTROL"`→`CTRL`, `"ESC"`→`ESCAPE`,
   `" "`→`SPACE`, `"CMD"`→`WIN`); miss in `KEY_MAP` → `unknown_key_hits += 1`, return `False`/`0`
   (never raise on the async hot path).
2. **VK event build.** One `INPUT(type=INPUT_KEYBOARD)` per transition with
   `KEYBDINPUT(wVk=vk, wScan=0, dwFlags=KEYEVENTF_EXTENDEDKEY? | KEYEVENTF_KEYUP?, …)`; modifiers
   (`CTRL/ALT/SHIFT/WIN`) additionally toggle membership in `held_keys`.
3. **Unicode path (`send_text`).** Walk the string as UTF-16 code units so astral characters
   (emoji, CJK ext) become surrogate pairs — each unit is one down+up `KEYEVENTF_UNICODE` pair:

```python
def send_text(self, text: str) -> int:
    if not text:
        return 0
    units = text.encode("utf-16-le")
    sent = 0
    for i in range(0, len(units), 2):
        cp = units[i] | (units[i + 1] << 8)
        sent += self._send_vk_event(wVk=0, wScan=cp,
                                    flags=KEYEVENTF_UNICODE)                 # down
        sent += self._send_vk_event(wVk=0, wScan=cp,
                                    flags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)  # up
    return sent
```

4. **Modifier bookkeeping.** `key_down("CTRL")` marks it held; a later `hotkey("CTRL", "F4")` that
   finds CTRL already held will **not** press it again and will **not** release it afterwards
   (pre-held modifiers stay held — preserves the phone user's sticky-modifier mode).
5. **`hotkey(*keys)` algorithm.** Resolve all names first (any miss → abort with 0, no partial
   injection); press unheld leading modifiers in fixed order `CTRL → ALT → SHIFT → WIN`, tap the
   final key, then release only the modifiers *this call* pressed, in reverse order.
6. **`release_all()`.** Release modifiers first (prevents Ctrl/Win sticky state), then remaining
   keys in reverse insertion order; clear `held_keys`; idempotent.
7. **Failure accounting.** `SendInput` returning `< expected` increments `send_failures`; state
   bookkeeping still updated from what was actually sent.

```mermaid
flowchart TD
    A[CMD_KEY via Doc 14 router] --> B{action}
    B -->|SEND_TEXT| C[UTF-16 walk → KEYEVENTF_UNICODE pairs]
    B -->|SEND_KEY| D[KEY_MAP lookup → tap (down+up)]
    B -->|SEND_COMBO| E{resolve vk + modifiers}
    E -->|miss| F[unknown_key_hits++, return 0]
    E -->|ok| G[press unheld modifiers → tap → release pressed modifiers]
    C --> H[user32.SendInput]
    D --> H
    G --> H
    H --> I[send_failures on partial/zero inject]
```

## 5. Protocol & Data Compliance

**Consumed WebSocket envelope** (produced by Flutter [31](31_flutter_websocket_client_reconnect.md),
validated by [15](15_pc_token_auth_middleware.md), routed by [14](14_pc_websocket_server_router.md)):

| `type` | `action` | `payload` | Handler |
|---|---|---|---|
| `CMD_KEY` | `SEND_KEY` | `{"vk": 13}` (`vk` 1–254) | `tap(vk)` — press+release (`key_down`/`key_up` internals) |
| `CMD_KEY` | `SEND_COMBO` | `{"vk": 115, "modifiers": ["ALT"]}` (`modifiers` ⊆ `{"CTRL","ALT","SHIFT","WIN"}`, max 4) | `hotkey(*keys)` after `vk`/`modifiers` resolve to key names via `KEY_MAP` |
| `CMD_KEY` | `SEND_TEXT` | `{"text": "<utf-8 string>"}` (1–4096 chars) | `send_text(text)` |

Frozen action registry per Doc 03 §5.4 — no other `CMD_KEY` actions exist on the wire; named-key
internals (`key_down`/`key_up`/`tap`/`hotkey`) stay internal.

Envelope fields `id` (uuid-v4), `payload`, `timestamp` (unix) are handled by Doc 14; this module
receives only `(action, payload)`. Ports (`50505/50506`) and auth are upstream concerns.

**Win32 constants (exact names/values used):**

| Constant | Value | Constant | Value |
|---|---|---|---|
| `INPUT_KEYBOARD` | `0x0001` | `KEYEVENTF_KEYUP` | `0x0002` |
| `KEYEVENTF_EXTENDEDKEY` | `0x0001` | `KEYEVENTF_UNICODE` | `0x0004` |

**`KEY_MAP` guaranteed coverage (subset; full table lives in the module):** `A–Z` (`0x41–0x5A`),
`0–9` (`0x30–0x39`), `F1–F12` (`0x70–0x7B`), `ENTER 0x0D`, `ESC 0x1B`, `BACKSPACE 0x08`,
`TAB 0x09`, `SPACE 0x20`, `SHIFT 0x10`, `CTRL 0x11`, `ALT 0x12`, `LWIN 0x5B`, `RWIN 0x5C`,
`DELETE 0x2E`, `HOME 0x24`, `END 0x23`, `PGUP 0x21`, `PGDN 0x22`, `INSERT 0x2D`,
arrows `0x25–0x28` (**extended**), `RCTRL 0xA3` / `RALT 0xA4` (**extended**), OEM punctuation
(`; , - . / [ \ ] ' \`` and `=`) `0xBA–0xDE`, `0xBB`.

## 6. Dependencies & Integration Points

**Internal:** [03_websocket_json_schema_spec.md](03_websocket_json_schema_spec.md) (canonical action
enum), [14_pc_websocket_server_router.md](14_pc_websocket_server_router.md) (sole caller +
disconnect hook), [15_pc_token_auth_middleware.md](15_pc_token_auth_middleware.md) (auth upstream),
[04_pc_agent_boilerplate_deps.md](04_pc_agent_boilerplate_deps.md) (Python baseline),
[06_win32_sendinput_mouse_engine.md](06_win32_sendinput_keyboard_engine.md) (sibling engine, shared
release-on-disconnect contract), [37_flutter_full_keyboard_sheet.md](37_flutter_full_pc_keyboard_sheet.md)
(client that exercises every `KEY_MAP` entry).

**External packages:** none — Python 3.11 stdlib `ctypes` only.

**Win32 APIs:** `user32.dll!SendInput(UINT, LPINPUT, int)`; structs `INPUT` (union) and `KEYBDINPUT`;
`kernel32.dll!GetLastError` for diagnostics. `user32.dll!MapVirtualKeyW` is **not** used (`wScan=0`
for VK events; Unicode events carry the code point in `wScan`).

## 7. Edge Cases & Failure Handling

- **Unknown key name** → dropped, `unknown_key_hits += 1`, returns `False`/`0`; router may reply an
  error using its own envelope; never raises.
- **Empty / whitespace-only `send_text`** → returns 0, no syscall (whitespace itself *is* injected
  if present inside a larger string).
- **Astral characters (emoji, rare CJK)** → split into UTF-16 surrogate pairs, 4 INPUTs per
  character (down/up × 2 units) — no mojibake.
- **Ctrl/Win stuck after a phone disconnect** → Doc 14 calls `engine.release_all()` on WS drop;
  modifier released first, Start-menu/shortcut side effects avoided.
- **`hotkey` with an unknown member** → aborts *before* injecting anything (all-or-nothing).
- **Modifier pre-held by `key_down`, then used in a `hotkey`** → not re-pressed, not auto-released.
- **Bare `key_down("ALT")` with no key-up** → Alt menu-capture risk; mitigated by `release_all()` on
  disconnect and by the Flutter sheet always pairing down/up (`tap`/`hotkey`).
- **`SendInput` returns 0 or partial** (UIPI vs. elevated target, locked desktop) → `send_failures`
  counter, state still consistent, no exception.
- **`\n` / `\t` sent through `send_text`** → injected as raw Unicode LF/HT; apps that ignore them are
  served by `SEND_COMBO` with `ENTER`/`TAB` instead (Flutter sheet uses named keys for editing keys).
- **Non-Windows / non-interactive session** → import-time guard marks the engine inert; agent stays up.

## 8. Acceptance Criteria

- [ ] `send_text("Hi 🎬")` emits UTF-16 units `0x0048 0x0069 0x0020 0xD83C 0xDFAC` as
      down+up `KEYEVENTF_UNICODE` pairs (8 INPUTs) with `wVk == 0`.
- [ ] `tap("ENTER")` emits exactly 2 INPUTs (`VK_RETURN` down, then `KEYEVENTF_KEYUP`).
- [ ] `hotkey("ALT", "F4")` emits `ALT down → F4 down → F4 up → ALT up`; no `EXTENDEDKEY` on F4.
- [ ] Arrows and `RCTRL` carry `KEYEVENTF_EXTENDEDKEY`; letters and digits do not.
- [ ] Pre-held `CTRL` via `key_down` → `hotkey("CTRL","C")` does not release CTRL afterwards;
      `release_all()` then empties `held_keys`.
- [ ] Unknown key never raises; `unknown_key_hits` increments.
- [ ] `release_all()` after simulated disconnect leaves `held_keys == frozenset()`.
- [ ] Real check: typing over WS into Notepad renders the exact string; foreground window unchanged.

## 9. Test Plan

**Unit — `pc_agent/tests/test_win32_keyboard.py`** (pytest; monkeypatch
`ctypes.windll.user32.SendInput` with an INPUT recorder):
- `test_send_text_unicode_and_surrogates` — code-unit walk, flags, counts (§8 first bullet).
- `test_tap_sequence_and_extended_flags` — down/up order, extended-bit assertions.
- `test_hotkey_modifier_order_and_preheld` — press/release ordering, pre-held preservation,
  all-or-nothing on unknown member.
- `test_key_map_coverage_for_flutter_sheet` — every key name Doc 37 exposes resolves in `KEY_MAP`.
- `test_release_all_clears_state` + `test_unknown_key_counted_not_raised`.
- `test_partial_send_failures` — recorder returns 0 → `send_failures` grows, no exception.

**Manual (real desktop):**
1. Open Notepad unfocused-to-agent; send `SEND_TEXT "hello PotPilot 🎬"` over WS → text appears,
   no IME popup, no focus change initiated by the agent.
2. `SEND_COMBO {vk:115, modifiers:["ALT"]}` closes the active (non-elevated) window (F4 = VK 115) — verify combo timing feels
   instant; then reconnect and confirm no stuck Alt (menu not latched).
3. Pre-hold `CTRL` via internal `key_down` (test hook), click a file in Explorer — expect multi-select behavior
   (sticky modifier), then `release_all` via disconnect restores normal state.

## 10. Assumptions & Open Questions

- **A1:** The §5 action names (`SEND_KEY`, `SEND_COMBO`, `SEND_TEXT`) are Doc 03's frozen `CMD_KEY`
  registry (§5.4) consumed verbatim; handler signatures (`key_down`/`key_up`/`tap`/`hotkey`, named
  keys) are internal — `vk`/`modifiers` resolve through `KEY_MAP` at the wire boundary.
- **A2:** Unicode text and VK keys are disjoint paths: `send_text` never applies modifiers, and
  modifier combos always go through `hotkey()`/`key_down` (Flutter never mixes them in one envelope).
- **A3:** `wScan = 0` for VK events (layout-independent injection); games/scancode-only apps are
  explicitly out of scope.
- **A4:** `KEY_MAP` covers Doc 37's key set plus OEM punctuation for live text entry.
- **A5:** Test path `pc_agent/tests/` + dev-only `pytest` (batch-wide convention from Doc 06 A4).
- **Open:** none.
