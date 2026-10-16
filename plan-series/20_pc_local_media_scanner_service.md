# Doc 20: Local Media Scanner Service
> Part of PotPilot plan-series · Category D · Session 2 Wave 2.A · PC Agent

## 1. Purpose & Scope
**Delivers**
- An asynchronous indexing service that recursively walks the user-configured movie directories (`movie_directories` from Doc 26), selects files with extensions **`.mp4`, `.mkv`, `.avi`, `.webm`**, and extracts per file: absolute path, display title, **file size**, **modified date**, and **companion `.srt` presence**.
- Queryable in-memory library over `CMD_MEDIA` (`RESCAN_MEDIA`, `LIST_MEDIA`) with case-insensitive title search and pagination (server default order: newest modified first) — the data source for the phone's Netflix-style browser ([45_flutter_in_app_movie_library_browser.md](45_flutter_in_app_movie_library_browser.md)).
- Async rescans: `RESCAN_MEDIA` acks `{"ok": true, "queued": true}`, the index swaps atomically, and clients re-query `LIST_MEDIA` for fresh data. Scan progress is logged PC-side only (Doc 03 defines no scan-progress frame).

**Out of scope**
- Launching files into PotPlayer — [21_pc_potplayer_file_launcher.md](21_pc_potplayer_file_launcher.md) owns `LAUNCH_MEDIA`.
- Watching directories for filesystem events (no `watchdog`) — rescans are explicit or on config change.
- Extracting video duration, resolution, codecs, thumbnails, or posters — metadata is limited to size/date/srt per the catalog.
- Persisting the index to disk — in-memory only; rebuilt on demand (see §10 A4).
- GUI folder pickers — Doc 24 owns them; they only write the `movie_directories` config key we read.

## 2. File Ownership
**Owns (create-only)**

| Path | Role |
|---|---|
| `pc_agent/media/library_scanner.py` | Scanner service, index, query engine, `VIDEO_EXTENSIONS` |
| `pc_agent/tests/test_library_scanner.py` | Unit tests |

**Reads / touches (owned by other docs)**

| Path | Owner | What we consume |
|---|---|---|
| `pc_agent/core/config_manager.py` | Doc 26 | `movie_directories: list[str]` config key |
| `pc_agent/network/ws_server_router.py` | Doc 14 | Dispatches `RESCAN_MEDIA` / `LIST_MEDIA` |
| `pc_agent/media/file_launcher.py` | Doc 21 | Imports `VIDEO_EXTENSIONS` and `is_supported_video()` from this module |
| `pc_agent/gui/dashboard_window.py` | Doc 24 | Indirect: config changes trigger our rescan hook |
| `mobile_app/lib/features/library/movie_browser.dart` | Doc 45 | Consumes `LIST_MEDIA` responses |

## 3. Public Contract
```python
VIDEO_EXTENSIONS: frozenset[str]            # {".mp4", ".mkv", ".avi", ".webm"}
SUBTITLE_EXTENSION: str = ".srt"
PAGE_LIMIT_DEFAULT: int = 50
PAGE_LIMIT_MAX: int = 200
ACT_RESCAN_MEDIA: str = "RESCAN_MEDIA"
ACT_LIST_MEDIA: str = "LIST_MEDIA"

def is_supported_video(path: str) -> bool:
    """True when the path's lowercase extension is in VIDEO_EXTENSIONS."""

@dataclass(frozen=True, slots=True)
class MediaEntry:
    path: str          # absolute, normalized (backslashes) file path
    title: str         # filename stem, sanitized for JSON
    size_bytes: int    # os.stat st_size at scan time
    modified_at: int   # unix seconds, os.stat st_mtime
    has_srt: bool      # companion <stem>*.srt exists (case-insensitive)

@dataclass(frozen=True, slots=True)
class ScanProgress:
    phase: str         # "walking" | "statting" | "done"
    scanned: int       # files seen so far (extension-qualified)
    found: int         # MediaEntry count so far

class LibraryScanner:
    def __init__(self, config: "ConfigManager") -> None:
        """Own the in-memory index; read movie_directories lazily per scan."""
    async def rescan(self, *, force: bool = False) -> dict[str, Any]:
        """Walk all configured dirs off-loop; return stats {ok, found, duration_ms, errors}."""
    def is_scanning(self) -> bool:
        """True while a rescan is in flight (re-entrancy guard for the router)."""
    def query(self, *, query: str | None = None, offset: int = 0,
              limit: int = PAGE_LIMIT_DEFAULT, sort: str = "modified_desc") -> tuple[int, list[MediaEntry]]:
        """Case-insensitive title substring search, sorted page; returns (total, page)."""
    def get(self, path: str) -> MediaEntry | None:
        """Exact lookup by absolute path, or None."""
    def on_progress(self, callback: Callable[[ScanProgress], Awaitable[None]]) -> None:
        """Register a progress callback — PC-side logging only; no wire frames."""
    def stats(self) -> dict[str, Any]:
        """Snapshot: {scanning, last_scan_at, total, watch_dirs, last_error}."""
```

## 4. Internal Design
1. **Dir snapshot** — read `movie_directories` from config once at scan start; a mid-scan config change takes effect on the *next* scan (§7).
2. **Walk phase** (`asyncio.to_thread`) — `os.walk(dir, followlinks=False)` per root; skip unreadable dirs with an error entry; lowercase-compare extensions against `VIDEO_EXTENSIONS` (handles `.MKV`).
3. **Stat & subtitle phase** — process candidates in chunks of 100 with `await asyncio.sleep(0)` between chunks to keep the event loop responsive. For each candidate: `os.stat` (size, mtime); `has_srt` = any file in the same directory whose name matches `<stem>*.srt` case-insensitively (covers `Film.srt`, `Film.en.srt`, `FILM.SRT`). Files vanishing between walk and stat are skipped.
4. **Dedupe** — key = `os.path.normcase(os.path.abspath(path))`; the same file reachable via two configured roots counts once.
5. **Swap** — build a fresh list, then atomically replace `self._index` (list + dict + sorted-key views) so `query()` never sees a half-built index.
6. **Incremental reuse** — entries whose `(size_bytes, modified_at)` match the previous index reuse the previous `has_srt` (subtitle presence rarely changes without mtime change).
7. **Progress (PC-side only)** — throttled to ≤ 4 emits/s via a monotonic timestamp gate; always a final `phase:"done"`. Feeds logs/Dashboard status only — never sent over WS (no scan-progress frame in Doc 03).

```mermaid
flowchart LR
    C[config: movie_directories] --> W["Walk (to_thread)<br/>ext filter + dedupe"]
    W --> S["Stat + SRT probe<br/>chunks of 100"]
    S -.-> L[Progress log (PC-side only)]
    S --> I[(Atomic index swap)]
    Q[LIST_MEDIA] --> F[Filter / sort / paginate]
    I --> F
    F --> R[Doc 14 → Phone Doc 45]
```

**State:** `_index: list[MediaEntry]`, `_by_path: dict[str, MediaEntry]`, `_scanning: bool`, `_last_scan_at: int | None`, `_last_error: str | None`. No persistence.

## 5. Protocol & Data Compliance
Commands use envelope `type: "CMD_MEDIA"`; responses echo request `id`/`action` with `payload.ok` (convention per Doc 19 A1).

**Commands (exact action names):**

| Action | Payload (request) | Response payload |
|---|---|---|
| `RESCAN_MEDIA` | `{}` | `{"ok": true, "queued": true}` |
| `LIST_MEDIA` | `{"path": str?, "query": str?, "offset": int?, "limit": int?}` (`limit` 1–200, default 50) | `{"folders": [str], "items": [MediaEntryJSON], "total": int, "offset": int, "limit": int}` |

`MediaEntryJSON` (exact frozen fields, Doc 03 §5.5): `{"name": str, "path": str, "size_bytes": int, "modified_at": int, "has_subs": bool}` — serialization maps internal `title` → `name`, `has_srt` → `has_subs`. `folders` = sub-folder names under `path` (empty at leaf). Paging echoes `offset`/`limit`; `total` counts matches before paging.

**No push frames:** `RESCAN_MEDIA` merely queues; progress is PC-side logging; clients re-query `LIST_MEDIA` for fresh data.

**Constants (exact names):** `VIDEO_EXTENSIONS`, `SUBTITLE_EXTENSION`, `PAGE_LIMIT_DEFAULT`, `PAGE_LIMIT_MAX`, `ACT_RESCAN_MEDIA`, `ACT_LIST_MEDIA`, `SORT_MODIFIED_DESC = "modified_desc"`, `SORT_TITLE_ASC = "title_asc"`, `SORT_SIZE_DESC = "size_desc"` (internal default order only — no wire `sort` field), `ERR_BAD_PAYLOAD = "E_BAD_PAYLOAD"`, `WALK_CHUNK = 100`, `PROGRESS_MIN_INTERVAL_S = 0.25`.

## 6. Dependencies & Integration Points
**Internal**
- [26_pc_config_persistence_manager.md](26_pc_config_persistence_manager.md) — `movie_directories` source of truth; Doc 24 writes it, we re-read per scan and via a change hook.
- [14_pc_websocket_server_router.md](14_pc_websocket_server_router.md) — command dispatch + response routing (no push transport — scanning has no wire frames).
- [21_pc_potplayer_file_launcher.md](21_pc_potplayer_file_launcher.md) — imports `VIDEO_EXTENSIONS` / `is_supported_video()` from this module (single source of truth for the extension set).
- [45_flutter_in_app_movie_library_browser.md](45_flutter_in_app_movie_library_browser.md) — consumer of `LIST_MEDIA` / `RESCAN_MEDIA`.
- [18_pc_telemetry_broadcast_loop.md](18_pc_telemetry_broadcast_loop.md) — cross-reference only (no telemetry keys produced here).

**External** — stdlib only: `asyncio`, `os`, `time`, `dataclasses`. No new packages (deliberately avoids `watchdog`/`aiofiles`; `os.walk` + `os.stat` run in `asyncio.to_thread`).

**Platform** — Windows filesystem semantics: NTFS timestamps, case-insensitive names, UNC paths allowed if configured.

## 7. Edge Cases & Failure Handling
- **Watch dir missing / unreadable** — skipped, recorded in `stats()["errors"]`; scan continues for remaining roots; the `RESCAN_MEDIA` ack stays `{"ok":true,"queued":true}` (errors visible via `stats()`).
- **Config change mid-scan** — current scan finishes with its original dir list; next scan picks up new config (no partial-scan corruption).
- **File deleted between walk and stat** — `FileNotFoundError` → silently skipped; a later rescan drops it from the index.
- **File replaced mid-scan** — stat reflects whichever version exists; next rescan normalizes.
- **Duplicate across roots (junction/symlink)** — `followlinks=False` prevents cycles; `normcase` dedupe handles intentional duplicates.
- **Extension case / trailing spaces** — extension compared as `lower()`; `.MKV` matches; stem keeps original case.
- **Companion subtitle variants** — `Film.srt`, `Film.en.srt`, `Film.SRT` all set `has_srt:true` (prefix match on stem + `.srt`, case-insensitive). `.sub`/`.ass` files do **not** count (recorded in §10 A3).
- **Non-UTF8 / ANSI filenames** — title sanitized with U+FFFD replacement before JSON so Doc 33/45 never hit encode errors; raw `path` kept exact for launching.
- **Empty/absent `movie_directories`** — walk is a no-op (`found:0`); `RESCAN_MEDIA` still acks `{"ok":true,"queued":true}`; `LIST_MEDIA` returns an empty page (`total:0`).
- **Re-entrant scan request** — a second `RESCAN_MEDIA` during a scan acks `{"ok":true,"queued":true}` and is coalesced; never runs two walks concurrently (index swap stays atomic).
- **Very large libraries (50k+ files)** — chunked processing keeps loop latency bounded; pagination keeps responses compact; no full-index transfer ever.

## 8. Acceptance Criteria
- Scanning a fixture tree with `.mp4/.mkv/.avi/.webm` (+ ignored `.txt/.exe/.srt` files) indexes exactly the videos; `size_bytes`/`modified_at` match `os.stat` ground truth.
- `.MKV` and `.Mp4` (uppercase) are indexed; `.mov` is not.
- `has_srt` is true for `Film.srt`, `Film.en.srt`, `Film.SRT`; false when only `Film.ass` exists.
- `LIST_MEDIA` pagination: `folders` + `items` + `total` present per the frozen result shape; `total` is stable across pages; `offset` beyond range returns empty `items` with correct `total`; `limit` defaults to 50 and clamps to 1–200.
- `query:"avatar"` matches titles case-insensitively; default server order is `modified_at` descending.
- During a scan of ≥ 200 files, the event loop still services a ping command in < 50 ms (chunking works).
- A second `RESCAN_MEDIA` during a scan still acks `{"ok":true,"queued":true}` and does not corrupt the index.
- After `RESCAN_MEDIA`, `LIST_MEDIA` reflects the new index only after the atomic swap (never a half-built index); progress numbers appear only in PC-side logs.

## 9. Test Plan
`pc_agent/tests/test_library_scanner.py` (pytest; `tmp_path` fixture trees; fake `ConfigManager`):
- `test_walk_indexes_supported_extensions_only` — mixed tree → only the 4 extensions present.
- `test_extension_case_insensitive` — `.MKV`/`.Mp4` indexed.
- `test_stat_fields_match_os` — `size_bytes`/`modified_at` equal `os.stat` values.
- `test_srt_detection_variants` — `Film.srt` / `Film.en.srt` / `Film.SRT` → true; `Film.ass` → false.
- `test_missing_watch_dir_recorded_not_fatal` — error listed, other roots still indexed.
- `test_deleted_file_mid_scan_skipped` — monkeypatched stat raising `FileNotFoundError`.
- `test_dedupe_same_file_two_roots` — same file via two roots → one entry.
- `test_query_pagination_and_sorts` — all three internal sorts; offset/limit math; total stability.
- `test_query_case_insensitive_substring` — mixed-case needle.
- `test_list_media_result_shape` — result keys exactly `folders`/`items`/`total`/`offset`/`limit`; item keys exactly `name`/`path`/`size_bytes`/`modified_at`/`has_subs` (Doc 03 §5.5).
- `test_reentrant_scan_guard` — concurrent rescan → coalesced `{"ok":true,"queued":true}` ack, single walk.
- `test_progress_throttle_and_done_event` — internal log spacing ≥ 250 ms; single `done` (no wire frames emitted).

**Manual** — configure two real folders (one with nested subfolders and `Film.en.srt` files) via Doc 24 GUI, send `RESCAN_MEDIA` from the Doc 45 browser, confirm the queued ack, then grid population on the next `LIST_MEDIA`; rename a file on disk, rescan, confirm size/date refresh; remove a folder from config, rescan, confirm its entries are gone.

## 10. Assumptions & Open Questions
- **A1:** The 4 extensions are exhaustive; archives (`.iso`, `.rar`) and streaming URLs are out of scope.
- **A2:** Index is in-memory only — restart means a rescan (fast: stat-only, ~thousands of files/second). A disk cache was rejected as unnecessary complexity for a bedroom-local library.
- **A3:** "Companion `.srt`" means any `<stem>*.srt` sibling; other subtitle formats (`.ass`, `.sub`) are deliberately ignored to match the catalog wording.
- **A4:** `title` = filename stem exactly as stored (no fuzzy "S01E02" parsing, no year extraction) — display polish belongs to Doc 45.
- **A5:** Paths are returned Windows-native (backslashes, absolute) and trusted as server-local; Doc 45 must not string-manipulate them beyond display.
- **Q1 (open):** Should `RESCAN_MEDIA` support `{"dir": str}` to rescan a single root? Defer until Doc 45 UX review; the API is additive and non-breaking.
