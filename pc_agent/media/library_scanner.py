"""Doc 20: asynchronous local media scanner (in-memory index over ``movie_dirs``).

Walks the configured movie directories for ``.mp4/.mkv/.avi/.webm`` files,
stat-probes size/mtime and companion ``<stem>*.srt`` subtitles, then swaps the
fresh list into the in-memory index atomically.  Owns the frozen ``CMD_MEDIA``
wire surface consumed by Doc 14: ``RESCAN_MEDIA`` queues a background walk and
acks ``{"ok": true, "queued": true}``; ``LIST_MEDIA`` returns the frozen paged
result ``{folders, items, total, offset, limit}`` with each item serialized as
Doc 03 §5.5 ``{name, path, size_bytes, modified_at, has_subs}`` (internal
``title``/``has_srt`` map to wire ``name``/``has_subs``).  Scan progress is
PC-side only — logged and offered to :meth:`LibraryScanner.on_progress`
callbacks; Doc 03 defines no scan-progress frame, so nothing progress-shaped
ever reaches the wire.

Stdlib only (deliberately no ``watchdog``/``aiofiles``): the directory walk runs
in ``asyncio.to_thread``, stat + subtitle probes run in ``WALK_CHUNK``-sized
chunks that yield back to the event loop between chunks, and the progress
emitter is throttled to at most one event per ``PROGRESS_MIN_INTERVAL_S`` with
an unconditional final ``done`` event.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from pc_agent.core.config_manager import ConfigManager
    from pc_agent.network.ws_server_router import WsEnvelope, WsSession

log = logging.getLogger(__name__)

# ------------------------------------------------------------------
# Frozen constants (Doc 20 §3 / §5)
# ------------------------------------------------------------------
VIDEO_EXTENSIONS: frozenset[str] = frozenset({".mp4", ".mkv", ".avi", ".webm"})
SUBTITLE_EXTENSION: str = ".srt"
PAGE_LIMIT_DEFAULT: int = 50
PAGE_LIMIT_MAX: int = 200
ACT_RESCAN_MEDIA: str = "RESCAN_MEDIA"
ACT_LIST_MEDIA: str = "LIST_MEDIA"
SORT_MODIFIED_DESC: str = "modified_desc"
SORT_TITLE_ASC: str = "title_asc"
SORT_SIZE_DESC: str = "size_desc"
ERR_BAD_PAYLOAD: str = "E_BAD_PAYLOAD"
WALK_CHUNK: int = 100
PROGRESS_MIN_INTERVAL_S: float = 0.25

PHASE_WALKING: str = "walking"
PHASE_STATTING: str = "statting"
PHASE_DONE: str = "done"


def is_supported_video(path: str) -> bool:
    """True when the path's lowercase extension is in :data:`VIDEO_EXTENSIONS`."""
    extension = os.path.splitext(path)[1].lower().strip()
    return extension in VIDEO_EXTENSIONS


def _sanitize_title(stem: str) -> str:
    """Replace lone surrogates with U+FFFD so downstream JSON never fails (§7)."""
    try:
        stem.encode("utf-8")
    except UnicodeEncodeError:
        return stem.encode("utf-8", "surrogatepass").decode("utf-8", "replace")
    return stem


@dataclass(frozen=True, slots=True)
class MediaEntry:
    """One indexed video file (internal record; wire fields differ)."""

    path: str  # absolute, normalized (backslashes) file path
    title: str  # filename stem, sanitized for JSON
    size_bytes: int  # os.stat st_size at scan time
    modified_at: int  # unix seconds, os.stat st_mtime
    has_srt: bool  # companion <stem>*.srt exists (case-insensitive)


@dataclass(frozen=True, slots=True)
class ScanProgress:
    """PC-side scan progress sample; never serialized onto the wire (§4.7)."""

    phase: str  # "walking" | "statting" | "done"
    scanned: int  # files seen so far (extension-qualified)
    found: int  # MediaEntry count so far


ProgressCallback = Callable[[ScanProgress], Awaitable[None]]


def _sort_key(sort: str) -> Callable[[MediaEntry], tuple[Any, ...]]:
    if sort == SORT_TITLE_ASC:
        return lambda entry: (entry.title.casefold(), entry.path.casefold())
    if sort == SORT_SIZE_DESC:
        return lambda entry: (-entry.size_bytes, entry.title.casefold(), entry.path.casefold())
    # SORT_MODIFIED_DESC and any unknown value: newest modified first.
    return lambda entry: (-entry.modified_at, entry.title.casefold(), entry.path.casefold())


class LibraryScanner:
    """In-memory media index with async rescans and a frozen paged query API."""

    def __init__(self, config: ConfigManager) -> None:
        """Own the in-memory index; read movie_directories lazily per scan."""
        self._config = config
        self._index: list[MediaEntry] = []
        self._by_path: dict[str, MediaEntry] = {}
        self._scanning = False
        self._scan_task: asyncio.Task[dict[str, Any]] | None = None
        self._scan_idle = asyncio.Event()
        self._scan_idle.set()
        self._last_scan_at: int | None = None
        self._last_error: str | None = None
        self._last_roots: list[str] = []
        self._last_stats: dict[str, Any] = {
            "ok": True,
            "found": 0,
            "duration_ms": 0,
            "errors": [],
        }
        self._progress_callbacks: list[ProgressCallback] = []
        self._last_progress_at: float | None = None
        self._now: Callable[[], float] = time.monotonic  # progress-gate seam

    # -------------------------------------------------------------- scanning

    async def rescan(self, *, force: bool = False) -> dict[str, Any]:
        """Walk all configured dirs off-loop; return ``{ok, found, duration_ms, errors}``.

        Re-entrant calls coalesce: a caller arriving while a walk is queued or
        in flight awaits that walk and receives its stats — never two walks.
        ``force=True`` skips the incremental subtitle-reuse cache and re-probes
        every companion ``.srt``.
        """
        task = self._scan_task
        if task is not None and task is not asyncio.current_task() and not task.done():
            result = await task
            return dict(result, errors=list(result["errors"]))
        if self._scanning:
            await self._scan_idle.wait()
            return dict(self._last_stats, errors=list(self._last_stats["errors"]))
        self._scanning = True
        self._scan_idle.clear()
        try:
            stats = await self._walk_all(force=force)
            self._last_stats = stats
            return dict(stats, errors=list(stats["errors"]))
        finally:
            self._scanning = False
            self._scan_idle.set()

    def queue_rescan(self) -> bool:
        """Start a background rescan unless one is queued/in flight; True when a walk was queued."""
        task = self._scan_task
        if self._scanning or (task is not None and not task.done()):
            return False  # coalesced: the existing walk covers this request (§7)
        scan = asyncio.create_task(self.rescan())
        self._scan_task = scan
        scan.add_done_callback(self._log_scan_task)
        return True

    @staticmethod
    def _log_scan_task(task: asyncio.Task[dict[str, Any]]) -> None:
        if not task.cancelled() and (exc := task.exception()) is not None:
            log.error("background media rescan failed: %s", exc)

    def is_scanning(self) -> bool:
        """True while a rescan is queued or in flight (re-entrancy guard)."""
        task = self._scan_task
        return self._scanning or (task is not None and not task.done())

    async def _walk_all(self, *, force: bool) -> dict[str, Any]:
        started = time.monotonic()
        roots = self._read_watch_dirs()
        self._last_roots = list(roots)
        self._last_progress_at = None
        errors: list[str] = []
        await self._emit_progress(PHASE_WALKING, 0, 0)
        candidates, walk_errors = await asyncio.to_thread(self._walk_blocking, roots)
        errors.extend(walk_errors)
        await self._emit_progress(PHASE_WALKING, len(candidates), 0)
        prev: dict[str, MediaEntry] = {}
        if not force:
            prev = {os.path.normcase(entry.path): entry for entry in self._index}
        entries: list[MediaEntry] = []
        seen: set[str] = set()
        dir_cache: dict[str, list[str]] = {}
        processed = 0
        for start in range(0, len(candidates), WALK_CHUNK):
            chunk = candidates[start : start + WALK_CHUNK]
            new_entries, chunk_errors = await asyncio.to_thread(
                self._stat_chunk, chunk, prev, dir_cache, seen
            )
            errors.extend(chunk_errors)
            entries.extend(new_entries)
            processed += len(chunk)
            await self._emit_progress(PHASE_STATTING, processed, len(entries))
            await asyncio.sleep(0)  # keep the event loop responsive (§4.3)
        # Atomic swap: list + lookup view replaced with no await in between, so
        # query() never observes a half-built index (§4.5).
        self._index = entries
        self._by_path = {os.path.normcase(entry.path): entry for entry in entries}
        stats: dict[str, Any] = {
            "ok": True,
            "found": len(entries),
            "duration_ms": int((time.monotonic() - started) * 1000),
            "errors": errors,
        }
        self._last_scan_at = int(time.time())
        self._last_error = errors[0] if errors else None
        self._last_stats = stats
        await self._emit_progress(PHASE_DONE, processed, len(entries))
        return stats

    def _read_watch_dirs(self) -> list[str]:
        """Snapshot the configured roots once per scan (mid-scan changes wait for the next walk)."""
        raw = list(self._config.get().movie_dirs)
        return [
            os.path.normpath(os.path.abspath(os.path.expanduser(str(item))))
            for item in raw
            if str(item).strip()
        ]

    def _walk_blocking(self, roots: Sequence[str]) -> tuple[list[str], list[str]]:
        """Worker thread: os.walk every root (followlinks=False), collect video candidates."""
        candidates: list[str] = []
        errors: list[str] = []

        def on_error(exc: OSError) -> None:
            errors.append(f"{getattr(exc, 'filename', None) or '?'}: {exc}")

        for root in roots:
            if not os.path.isdir(root):
                errors.append(f"{root}: not found")  # recorded, scan continues (§7)
                continue
            for dirpath, _dirnames, filenames in os.walk(
                root, followlinks=False, onerror=on_error
            ):
                for filename in filenames:
                    if is_supported_video(filename):
                        candidates.append(os.path.abspath(os.path.join(dirpath, filename)))
        return candidates, errors

    def _stat_chunk(
        self,
        chunk: Sequence[str],
        prev: Mapping[str, MediaEntry],
        dir_cache: dict[str, list[str]],
        seen: set[str],
    ) -> tuple[list[MediaEntry], list[str]]:
        """Worker thread: stat one chunk, probe subtitles, dedupe by normcase path."""
        entries: list[MediaEntry] = []
        errors: list[str] = []
        for path in chunk:
            key = os.path.normcase(path)
            if key in seen:
                continue  # same file reachable via two roots (§4.4)
            try:
                stat = os.stat(path)
            except (FileNotFoundError, NotADirectoryError):
                continue  # vanished between walk and stat — silently skipped (§7)
            except OSError as exc:
                errors.append(f"{path}: {exc}")
                continue
            seen.add(key)
            previous = prev.get(key)
            if (
                previous is not None
                and previous.size_bytes == stat.st_size
                and previous.modified_at == int(stat.st_mtime)
            ):
                has_srt = previous.has_srt  # incremental reuse (§4.6)
            else:
                has_srt = self._probe_srt(path, dir_cache)
            entries.append(
                MediaEntry(
                    path=path,
                    title=_sanitize_title(os.path.splitext(os.path.basename(path))[0]),
                    size_bytes=stat.st_size,
                    modified_at=int(stat.st_mtime),
                    has_srt=has_srt,
                )
            )
        return entries, errors

    @staticmethod
    def _probe_srt(video_path: str, dir_cache: dict[str, list[str]]) -> bool:
        """True when any ``<stem>*.srt`` sibling exists (case-insensitive prefix match)."""
        directory = os.path.dirname(video_path)
        names = dir_cache.get(directory)
        if names is None:
            try:
                names = os.listdir(directory)
            except OSError:
                names = []
            dir_cache[directory] = names
        stem = os.path.splitext(os.path.basename(video_path))[0].casefold()
        for name in names:
            lowered = name.casefold()
            if lowered.endswith(SUBTITLE_EXTENSION) and lowered.startswith(stem):
                return True
        return False

    # -------------------------------------------------------------- progress

    def on_progress(self, callback: ProgressCallback) -> None:
        """Register a PC-side progress callback (logging/Dashboard only; no wire frames)."""
        self._progress_callbacks.append(callback)

    async def _emit_progress(self, phase: str, scanned: int, found: int) -> None:
        now = self._now()
        throttled = (
            self._last_progress_at is not None
            and now - self._last_progress_at < PROGRESS_MIN_INTERVAL_S
        )
        if throttled and phase != PHASE_DONE:
            return
        self._last_progress_at = now
        progress = ScanProgress(phase=phase, scanned=scanned, found=found)
        log.debug("media scan progress: phase=%s scanned=%d found=%d", phase, scanned, found)
        for callback in list(self._progress_callbacks):
            try:
                await callback(progress)
            except Exception:
                log.exception("media scan progress callback failed")

    # ---------------------------------------------------------- query / stats

    def query(
        self,
        *,
        query: str | None = None,
        offset: int = 0,
        limit: int = PAGE_LIMIT_DEFAULT,
        sort: str = SORT_MODIFIED_DESC,
    ) -> tuple[int, list[MediaEntry]]:
        """Case-insensitive title substring search over a sorted page; returns ``(total, page)``."""
        return self._select(self._index, needle=query, offset=offset, limit=limit, sort=sort)

    @staticmethod
    def _normalize_paging(offset: Any, limit: Any) -> tuple[int, int]:
        """Validate + clamp the paging window: offset ≥ 0, limit 1–200 (§5)."""
        if isinstance(offset, bool) or not isinstance(offset, int):
            raise ValueError("offset must be an integer")
        if isinstance(limit, bool) or not isinstance(limit, int):
            raise ValueError("limit must be an integer")
        return max(0, offset), max(1, min(PAGE_LIMIT_MAX, limit))

    def _select(
        self,
        base: Sequence[MediaEntry],
        *,
        needle: str | None,
        offset: int,
        limit: int,
        sort: str,
    ) -> tuple[int, list[MediaEntry]]:
        if needle:
            folded = needle.casefold()
            matches = [entry for entry in base if folded in entry.title.casefold()]
        else:
            matches = list(base)
        matches.sort(key=_sort_key(sort))
        offset, limit = self._normalize_paging(offset, limit)
        return len(matches), matches[offset : offset + limit]

    def get(self, path: str) -> MediaEntry | None:
        """Exact (case-insensitive on Windows) lookup by absolute path, or None."""
        key = os.path.normcase(os.path.normpath(os.path.abspath(path)))
        return self._by_path.get(key)

    def list_media(self, payload: Mapping[str, Any]) -> dict[str, Any]:
        """Build the frozen ``LIST_MEDIA`` result dict for one validated payload (§5).

        ``{folders, items, total, offset, limit}`` — ``items`` use the Doc 03 §5.5
        wire field names; ``folders`` are the immediate sub-folder names under
        ``path`` (or under each configured root when ``path`` is omitted; empty
        at a leaf).  Raises :class:`ValueError` for structurally invalid fields.
        """
        path = payload.get("path")
        needle = payload.get("query")
        offset = payload.get("offset", 0)
        limit = payload.get("limit", PAGE_LIMIT_DEFAULT)
        if path is not None and not isinstance(path, str):
            raise ValueError("path must be a string")
        if needle is not None and not isinstance(needle, str):
            raise ValueError("query must be a string")
        offset, limit = self._normalize_paging(offset, limit)
        scope = self._validate_scope(path) if path else None
        base = self._scope_entries(scope)
        total, page = self._select(
            base, needle=needle, offset=offset, limit=limit, sort=SORT_MODIFIED_DESC
        )
        # folders derive from the whole scope (not the page) so they stay stable
        # across pages; empty at leaf per Doc 03 §5.5.
        return {
            "folders": self._folders(scope, base),
            "items": [
                {
                    "name": entry.title,
                    "path": entry.path,
                    "size_bytes": entry.size_bytes,
                    "modified_at": entry.modified_at,
                    "has_subs": entry.has_srt,
                }
                for entry in page
            ],
            "total": total,
            "offset": offset,
            "limit": limit,
        }

    def _validate_scope(self, path: str) -> str:
        norm = os.path.normpath(os.path.abspath(path))
        key = os.path.normcase(norm)
        for root in self._read_watch_dirs():
            root_key = os.path.normcase(root)
            if key == root_key or key.startswith(root_key + os.sep):
                return norm
        raise ValueError(f"path is outside the configured movie directories: {path}")

    def _scope_entries(self, scope: str | None) -> list[MediaEntry]:
        if scope is None:
            return list(self._index)
        key = os.path.normcase(scope)
        return [
            entry
            for entry in self._index
            if os.path.normcase(entry.path) == key
            or os.path.normcase(entry.path).startswith(key + os.sep)
        ]

    def _folders(self, scope: str | None, entries: Sequence[MediaEntry]) -> list[str]:
        watch = self._read_watch_dirs()
        found: dict[str, str] = {}
        for entry in entries:
            directory = os.path.dirname(entry.path)
            if scope is not None:
                if os.path.normcase(directory) == os.path.normcase(scope):
                    continue
                rel = os.path.relpath(directory, scope)
            else:
                root = self._root_for(directory, watch)
                if root is None:
                    continue
                rel = os.path.relpath(directory, root)
            if rel in ("", "."):
                continue
            first = rel.split(os.sep)[0]
            if not first or first.startswith(".."):
                continue
            found.setdefault(first.casefold(), first)
        return sorted(found.values(), key=str.casefold)

    @staticmethod
    def _root_for(directory: str, watch: Sequence[str]) -> str | None:
        """Longest configured root containing ``directory`` (case-insensitive)."""
        target = os.path.normcase(directory)
        best: str | None = None
        for root in watch:
            root_key = os.path.normcase(root)
            if target == root_key or target.startswith(root_key + os.sep):
                if best is None or len(root_key) > len(os.path.normcase(best)):
                    best = root
        return best

    def stats(self) -> dict[str, Any]:
        """Snapshot: ``{scanning, last_scan_at, total, watch_dirs, last_error, errors}``.

        The first five keys are the Doc 20 §3 contract; ``errors`` is the §7 list
        of walk/stat problems from the most recent scan (missing roots etc.).
        """
        return {
            "scanning": self.is_scanning(),
            "last_scan_at": self._last_scan_at,
            "total": len(self._index),
            "watch_dirs": list(self._last_roots),
            "last_error": self._last_error,
            "errors": list(self._last_stats.get("errors", [])),
        }

    # ------------------------------------------------------ Doc 14 wire seam

    async def handle_rescan_media(self, session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        """``RESCAN_MEDIA``: queue a background walk and ack immediately (§5)."""
        del session, envelope
        self.queue_rescan()
        return {"queued": True}  # build_ack supplies ok:true

    async def handle_list_media(self, session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        """``LIST_MEDIA``: frozen paged result, or the E_BAD_PAYLOAD error payload (§5)."""
        del session
        try:
            return self.list_media(envelope.payload)
        except ValueError as exc:
            return {"ok": False, "error": ERR_BAD_PAYLOAD, "detail": str(exc)}
