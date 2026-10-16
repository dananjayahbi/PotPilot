"""Doc 20 companion: on-demand video thumbnail cache (ffmpeg frame extraction).

Owns the JPEG frame cache under ``%APPDATA%\\PotPilot\\thumbs`` and the
optional ``thumbnail_b64`` enrichment of Doc 03 §5.5 ``LIST_MEDIA`` items:

* One file per source: ``<sha256(normcase path)>_<mtime>.jpg`` — embedding
  the source mtime in the name makes a changed video miss the cache with no
  sidecar bookkeeping; stale-named leftovers are trimmed loosely to
  :data:`CACHE_MAX_BYTES`.
* Extractor discovery (§3): config ``ffmpeg_path`` (Doc 26 additive key, the
  same extras pattern as ``potplayer_exe_path``) → ``shutil.which`` → the
  known default install path.  When nothing resolves every lookup returns
  ``None`` and callers degrade to their placeholder UI — no errors, no queue.
* Three lookup speeds: :meth:`get` (cache only), :meth:`make_now` (one
  synchronous extraction, for a per-request budget) and :meth:`request`
  (enqueue to a single daemon worker that fills the cache in the background).
  :meth:`attach` applies that policy across one ``LIST_MEDIA`` page: at most
  :data:`SYNC_BUDGET` synchronous extractions, everything else queued.
* Wire safety: every emitted JPEG is re-encoded down to
  ≤ :data:`MAX_THUMB_BYTES` and ≤ :data:`MAX_THUMB_WIDTH` px; :meth:`attach`
  also stops adding thumbnails past :data:`ATTACH_BUDGET_BYTES` so a
  pathological page can never exceed ``max_frame_bytes``.

All public methods swallow per-item failures (log + placeholder) — a broken
ffmpeg or an unreadable file must never fail the ``LIST_MEDIA`` reply itself.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import os
import queue
import shutil
import subprocess
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import TYPE_CHECKING, Any

from pc_agent.core.config_manager import default_config_root

if TYPE_CHECKING:
    from pc_agent.core.config_manager import ConfigManager

log = logging.getLogger(__name__)

FFMPEG_PATH_KEY: str = "ffmpeg_path"  # Doc 26 additive config key (A2 pattern)
DEFAULT_FFMPEG_PATH: str = r"C:\ffmpeg-master-latest-win64-gpl\bin\ffmpeg.exe"
THUMB_DIR_NAME: str = "thumbs"

MAX_THUMB_BYTES: int = 15 * 1024  # Doc 45 wire budget per thumbnail (≤ 15 KB)
MAX_THUMB_WIDTH: int = 320  # px; output width pinned to this value (height scales)
SYNC_BUDGET: int = 4  # synchronous extractions allowed per LIST_MEDIA reply
ATTACH_BUDGET_BYTES: int = int(1.5 * 1024 * 1024)  # base64 budget per reply
CACHE_MAX_BYTES: int = 64 * 1024 * 1024  # loose on-disk bound (trim waterfall)
TRIM_EVERY: int = 32  # generations between two size trims
FFMPEG_TIMEOUT_S: float = 8.0  # per extraction attempt
PROBE_TTL_S: float = 5.0  # ffmpeg re-probe interval while unresolved

_SEEK_LADDER: tuple[str, ...] = ("5", "0")  # frame near 5 s, then first frame
_QUALITY_LADDER: tuple[str, ...] = ("6", "10", "14")  # -q:v attempts while over budget


def default_cache_dir() -> Path:
    """``%APPDATA%\\PotPilot\\thumbs`` (same config root as ``config.json``)."""
    return default_config_root() / THUMB_DIR_NAME


def _configured_ffmpeg(config: Any) -> str | None:
    """Read ``ffmpeg_path`` tolerantly: attribute, extras dict, or mapping (§3)."""
    sources: list[Any] = []
    getter = getattr(config, "get", None)
    if callable(getter):
        try:
            sources.append(getter())
        except TypeError:
            pass  # plain dict.get() needs a key — the mapping branch covers it
    extra = getattr(config, "_extra", None)
    if extra is not None:
        sources.append(extra)
    if isinstance(config, Mapping):
        sources.append(config)
    for source in sources:
        if source is None:
            continue
        if isinstance(source, Mapping):
            value = source.get(FFMPEG_PATH_KEY)
        else:
            value = getattr(source, FFMPEG_PATH_KEY, None)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


class ThumbCache:
    """Thread-safe JPEG frame cache with a single background worker."""

    def __init__(
        self,
        config: ConfigManager | None = None,
        *,
        cache_dir: Path | None = None,
        ffmpeg: str | None = None,
    ) -> None:
        """Bind the config seam; no disk or process work happens at construction."""
        self._config = config
        self._cache_dir = Path(cache_dir) if cache_dir is not None else default_cache_dir()
        self._explicit_ffmpeg = ffmpeg
        self._resolved_ffmpeg: str | None = None
        self._probed_at: float = -PROBE_TTL_S  # force the first probe
        self._queue: queue.Queue[tuple[str, str, int]] = queue.Queue()
        self._inflight: set[str] = set()
        self._lock = threading.Lock()
        self._worker: threading.Thread | None = None
        self._generations = 0
        self._now: Callable[[], float] = time.monotonic  # probe-TTL seam

    # ------------------------------------------------------------ discovery

    def ffmpeg_path(self) -> str | None:
        """Config ``ffmpeg_path`` → PATH → known default install; ``None`` = degraded (§3)."""
        if self._explicit_ffmpeg is not None:
            return self._explicit_ffmpeg
        now = self._now()
        if self._resolved_ffmpeg is not None and now - self._probed_at < PROBE_TTL_S:
            return self._resolved_ffmpeg
        candidate = _configured_ffmpeg(self._config) or shutil.which("ffmpeg")
        if candidate is None and os.path.isfile(DEFAULT_FFMPEG_PATH):
            candidate = DEFAULT_FFMPEG_PATH
        self._resolved_ffmpeg = candidate
        self._probed_at = now
        return candidate

    # ------------------------------------------------------------- lookup

    def cache_file(self, source: str, mtime: int) -> Path:
        """Deterministic cache path for one (path, mtime) pair — the mtime in
        the name is the invalidation (a re-encoded/edited source misses)."""
        normalized = os.path.normcase(os.path.abspath(source))
        digest = hashlib.sha256(normalized.encode("utf-8", "surrogatepass")).hexdigest()
        return self._cache_dir / f"{digest[:24]}_{int(mtime)}.jpg"

    def get(self, source: str, mtime: int) -> bytes | None:
        """Cached JPEG bytes, or ``None`` (missing/unreadable — never raises)."""
        try:
            target = self.cache_file(source, mtime)
            return target.read_bytes() if target.is_file() else None
        except OSError:
            return None

    def make_now(self, source: str, mtime: int) -> bytes | None:
        """Extract synchronously (call from a worker thread) and cache the JPEG.

        Returns ``None`` when ffmpeg is unavailable, the source has no
        decodable frame, or the output stays unreadable — degraded, never raised.
        """
        ffmpeg = self.ffmpeg_path()
        if ffmpeg is None:
            return None
        try:
            target = self.cache_file(source, mtime)
            if target.is_file():
                return target.read_bytes()
            data = self._extract(ffmpeg, source, target)
            if data is None:
                return None
            self._after_generation()
            return data
        except Exception:
            log.warning("thumbnail generation failed for %s", source, exc_info=True)
            return None

    def request(self, source: str, mtime: int) -> None:
        """Queue a cache-miss to the background worker (idempotent per target)."""
        if self.ffmpeg_path() is None:
            return
        try:
            target = self.cache_file(source, mtime)
            if target.is_file():
                return
            key = str(target)
            with self._lock:
                if key in self._inflight:
                    return
                self._inflight.add(key)
            self._ensure_worker()
            self._queue.put((source, key, int(mtime)))
        except OSError:
            return  # unstat-able source — placeholder forever (§7)

    def request_many(self, pairs: Iterable[tuple[str, int]]) -> None:
        """Queue many ``(path, mtime)`` pairs — the post-scan warm-up hook."""
        for source, mtime in pairs:
            self.request(source, mtime)

    def attach(self, items: list[dict[str, Any]]) -> None:
        """Add ``thumbnail_b64`` to one LIST_MEDIA page's item dicts in place.

        Policy (§1): cache hits are free; the first :data:`SYNC_BUDGET` misses
        extract inline (the caller is already on a worker thread), the rest go
        to the background worker; past :data:`ATTACH_BUDGET_BYTES` of base64
        nothing new is attached so the frame stays under ``max_frame_bytes``.
        Per-item failures are swallowed — the reply always ships.
        """
        budget = SYNC_BUDGET
        attached_bytes = 0
        for item in items:
            try:
                source = item["path"]
                mtime = int(item["modified_at"])
                data = self.get(source, mtime)
                if data is None and budget > 0:
                    data = self.make_now(source, mtime)
                    budget -= 1
                if data is None:
                    self.request(source, mtime)
                    continue
                encoded = base64.b64encode(data).decode("ascii")
                if attached_bytes + len(encoded) > ATTACH_BUDGET_BYTES:
                    continue  # page budget spent — placeholders for the tail
                item["thumbnail_b64"] = encoded
                attached_bytes += len(encoded)
            except Exception:
                log.debug("thumbnail attach skipped for item %r", item, exc_info=True)

    # ------------------------------------------------------------- worker

    def _ensure_worker(self) -> None:
        with self._lock:
            if self._worker is None or not self._worker.is_alive():
                self._worker = threading.Thread(
                    target=self._worker_loop, name="potpilot-thumbs", daemon=True
                )
                self._worker.start()

    def _worker_loop(self) -> None:
        while True:
            source, target, mtime = self._queue.get()
            try:
                if not os.path.isfile(target):
                    ffmpeg = self.ffmpeg_path()
                    if ffmpeg is not None:
                        self._extract(ffmpeg, source, Path(target))
                        self._after_generation()
            except Exception:
                log.warning("background thumbnail failed for %s", source, exc_info=True)
            finally:
                with self._lock:
                    self._inflight.discard(target)
                self._queue.task_done()

    # ---------------------------------------------------------- extraction

    def _extract(self, ffmpeg: str, source: str, target: Path) -> bytes | None:
        """ffmpeg frame grab (seek ladder + quality ladder); caches + returns the JPEG."""
        target.parent.mkdir(parents=True, exist_ok=True)
        # Temp must end in .jpg: ffmpeg infers the muxer from the extension and
        # dies instantly on ".tmp" ("unable to find a suitable output format").
        tmp = target.with_name(f"{target.stem}.{uuid.uuid4().hex}.tmp.jpg")
        best: bytes | None = None
        try:
            for seek in _SEEK_LADDER:
                if not self._run_ffmpeg(ffmpeg, source, seek, _QUALITY_LADDER[0], tmp):
                    continue
                best = _read_smallest(tmp, best)
                if best is not None and len(best) <= MAX_THUMB_BYTES:
                    break
                for quality in _QUALITY_LADDER[1:]:
                    if not self._run_ffmpeg(ffmpeg, source, seek, quality, tmp):
                        break
                    candidate = _read_smallest(tmp, best)
                    if candidate is not None:
                        best = candidate
                    if best is not None and len(best) <= MAX_THUMB_BYTES:
                        break
                break  # this seek produced a frame — never fall through
            if best is None:
                return None
            os.replace(tmp, target)  # atomic publish (readers never see partial)
            return best
        finally:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:  # pragma: no cover - best-effort tmp cleanup
                pass

    @staticmethod
    def _run_ffmpeg(
        ffmpeg: str, source: str, seek: str, quality: str, out: Path
    ) -> bool:
        """One bounded ffmpeg attempt; True when ``out`` holds a non-empty JPEG."""
        argv = [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            seek,
            "-i",
            source,
            "-frames:v",
            "1",
            "-vf",
            f"scale={MAX_THUMB_WIDTH}:-2",
            "-q:v",
            quality,
            "-an",
            str(out),
        ]
        try:
            subprocess.run(  # noqa: S603 - local trusted binary, fixed argv
                argv,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=FFMPEG_TIMEOUT_S,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        try:
            return out.is_file() and out.stat().st_size > 0
        except OSError:
            return False

    # ------------------------------------------------------------- upkeep

    def _after_generation(self) -> None:
        """Count one generation and occasionally trim the cache to its loose bound."""
        self._generations += 1
        if self._generations % TRIM_EVERY == 0:
            try:
                self._trim()
            except OSError:  # pragma: no cover - trim is best-effort
                pass

    def _trim(self) -> None:
        """Delete oldest cache files until the directory fits :data:`CACHE_MAX_BYTES`."""
        if not self._cache_dir.is_dir():
            return
        files: list[tuple[float, int, Path]] = []
        total = 0
        for entry in os.scandir(self._cache_dir):
            if not entry.is_file() or not entry.name.endswith(".jpg"):
                continue
            try:
                stat = entry.stat()
            except OSError:  # pragma: no cover - raced deletion
                continue
            files.append((stat.st_mtime, stat.st_size, Path(entry.path)))
            total += stat.st_size
        if total <= CACHE_MAX_BYTES:
            return
        target = int(CACHE_MAX_BYTES * 0.8)
        for _mtime, size, path in sorted(files):  # oldest first
            if total <= target:
                break
            try:
                path.unlink()
            except OSError:  # pragma: no cover - raced deletion
                continue
            total -= size


def _read_smallest(path: Path, incumbent: bytes | None) -> bytes | None:
    """Read ``path``; return whichever of (incumbent, new) is smaller."""
    try:
        data = path.read_bytes()
    except OSError:
        return incumbent
    if incumbent is None or len(data) < len(incumbent):
        return data
    return incumbent


__all__ = [
    "ATTACH_BUDGET_BYTES",
    "CACHE_MAX_BYTES",
    "DEFAULT_FFMPEG_PATH",
    "FFMPEG_PATH_KEY",
    "MAX_THUMB_BYTES",
    "MAX_THUMB_WIDTH",
    "SYNC_BUDGET",
    "ThumbCache",
    "default_cache_dir",
]
