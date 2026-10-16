"""Doc 20/45 unit tests: ffmpeg thumbnail cache (fake extractor, no real ffmpeg)."""

from __future__ import annotations

import base64
import os
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from pc_agent.media import thumb_cache as tc
from pc_agent.media.thumb_cache import ThumbCache, default_cache_dir

JPEG_BYTES = b"\xff\xd8" + b"x" * 120 + b"\xff\xd9"  # plausible small JPEG stand-in
JPEG_B64 = base64.b64encode(JPEG_BYTES).decode("ascii")


def _cache(tmp_path: Path, *, ffmpeg: str | None = "C:\\fake\\ffmpeg.exe") -> ThumbCache:
    """ThumbCache with a fake extractor: writes JPEG_BYTES to the target."""
    cache = ThumbCache(None, cache_dir=tmp_path / "thumbs", ffmpeg=ffmpeg)

    def fake_extract(ffmpeg_bin: str, source: str, target: Path) -> bytes:
        del ffmpeg_bin, source
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(JPEG_BYTES)
        return JPEG_BYTES

    cache._extract = fake_extract  # type: ignore[method-assign]
    return cache


def _wait_for(predicate: Any, max_wait: float = 3.0) -> None:
    deadline = time.monotonic() + max_wait
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        time.sleep(0.01)


def test_cache_file_is_hash_named_and_mtime_keyed(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    source = str(tmp_path / "Film.mkv")
    first = cache.cache_file(source, 100)
    assert first.parent == tmp_path / "thumbs"
    assert first.name.endswith("_100.jpg")
    assert first.stem.split("_")[0]  # digest part present
    # Same source, new mtime → different file (regeneration on change).
    assert cache.cache_file(source, 101) != first
    # Case-insensitive on Windows-style paths → same cache entry.
    assert cache.cache_file(source.upper() if source.isascii() else source, 100) == first


def test_get_miss_then_hit_after_generation(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    source = str(tmp_path / "Film.mkv")
    assert cache.get(source, 100) is None  # cold cache
    made = cache.make_now(source, 100)
    assert made == JPEG_BYTES
    assert cache.get(source, 100) == JPEG_BYTES  # now a plain cache hit
    # Stale mtime misses: the old file stays until trimmed, but never serves.
    assert cache.get(source, 200) is None


def test_make_now_degrades_without_ffmpeg(
    tmp_path: Path, monkeypatch: Any
) -> None:
    monkeypatch.setattr(tc.shutil, "which", lambda name: None)
    monkeypatch.setattr(tc, "DEFAULT_FFMPEG_PATH", str(tmp_path / "absent.exe"))
    cache = _cache(tmp_path, ffmpeg=None)
    calls: list[str] = []

    def fake_extract(ffmpeg_bin: str, source: str, target: Path) -> bytes:
        del ffmpeg_bin, source, target
        calls.append("extracted")
        return JPEG_BYTES

    cache._extract = fake_extract  # type: ignore[method-assign]
    assert cache.ffmpeg_path() is None  # nothing discoverable on this host
    assert cache.make_now(str(tmp_path / "Film.mkv"), 1) is None
    assert calls == []  # no extractor invocation when ffmpeg is unavailable
    cache.request(str(tmp_path / "Film.mkv"), 1)
    assert cache._queue.qsize() == 0  # nothing queued while degraded


def test_ffmpeg_discovery_order(tmp_path: Path, monkeypatch: Any) -> None:
    # 1. Config wins (extras dict — the potplayer_exe_path pattern).
    extra_cfg = SimpleNamespace(_extra={"ffmpeg_path": " C:\\cfg\\ffmpeg.exe "})
    assert ThumbCache(extra_cfg, ffmpeg=None).ffmpeg_path() == "C:\\cfg\\ffmpeg.exe"

    # 2. get() snapshot carrying the field also works.
    attr_cfg = SimpleNamespace(get=lambda: SimpleNamespace(ffmpeg_path="C:\\attr\\f.exe"))
    assert ThumbCache(attr_cfg, ffmpeg=None).ffmpeg_path() == "C:\\attr\\f.exe"

    # 3. PATH lookup.
    monkeypatch.setattr(tc.shutil, "which", lambda name: "C:\\path\\ffmpeg.exe")
    assert ThumbCache(None, ffmpeg=None).ffmpeg_path() == "C:\\path\\ffmpeg.exe"

    # 4. Known default install path (this machine's documented location).
    monkeypatch.setattr(tc.shutil, "which", lambda name: None)
    monkeypatch.setattr(tc, "DEFAULT_FFMPEG_PATH", str(tmp_path / "ffmpeg.exe"))
    (tmp_path / "ffmpeg.exe").write_bytes(b"MZ")
    assert ThumbCache(None, ffmpeg=None).ffmpeg_path() == str(tmp_path / "ffmpeg.exe")

    # 5. Nothing found → degraded (None).
    monkeypatch.setattr(tc, "DEFAULT_FFMPEG_PATH", str(tmp_path / "absent.exe"))
    assert ThumbCache(None, ffmpeg=None).ffmpeg_path() is None


def test_attach_budget_sync_then_background(tmp_path: Path, monkeypatch: Any) -> None:
    cache = _cache(tmp_path)
    cache._ensure_worker = lambda: None  # freeze the worker: queue contents stay observable
    monkeypatch.setattr(tc, "SYNC_BUDGET", 2)
    items = [
        {"path": str(tmp_path / f"F{i}.mkv"), "modified_at": 100 + i} for i in range(5)
    ]

    cache.attach(items)

    attached = [item for item in items if "thumbnail_b64" in item]
    assert len(attached) == 2  # sync budget spent on the first two misses
    assert all(item["thumbnail_b64"] == JPEG_B64 for item in attached)
    assert cache._queue.qsize() == 3  # the tail went to the background worker

    # Cache hits attach without consuming sync budget: re-attach with budget 0.
    monkeypatch.setattr(tc, "SYNC_BUDGET", 0)
    second = [
        {"path": str(tmp_path / f"F{i}.mkv"), "modified_at": 100 + i}
        for i in range(2)
    ]
    cache.attach(second)
    assert all("thumbnail_b64" in item for item in second)  # free cache hits


def test_attach_byte_budget_bounds_frame_size(tmp_path: Path, monkeypatch: Any) -> None:
    cache = _cache(tmp_path)
    monkeypatch.setattr(tc, "SYNC_BUDGET", 10)
    monkeypatch.setattr(tc, "ATTACH_BUDGET_BYTES", len(JPEG_B64) + 5)
    items = [
        {"path": str(tmp_path / f"F{i}.mkv"), "modified_at": 100 + i} for i in range(3)
    ]

    cache.attach(items)

    assert "thumbnail_b64" in items[0]
    assert "thumbnail_b64" not in items[1]  # page base64 budget spent
    assert "thumbnail_b64" not in items[2]


def test_attach_never_raises_on_bad_items(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    broken: list[dict[str, Any]] = [
        {},  # missing keys entirely
        {"path": None, "modified_at": "NaN"},  # wrong types
        {"path": str(tmp_path / "ok.mkv"), "modified_at": 100},  # healthy tail
    ]

    cache.attach(broken)  # must not raise — the LIST_MEDIA reply always ships

    assert "thumbnail_b64" not in broken[0]
    assert "thumbnail_b64" not in broken[1]
    assert broken[2]["thumbnail_b64"] == JPEG_B64


def test_request_deduplicates_while_inflight(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    cache._ensure_worker = lambda: None  # frozen worker: queue stays observable
    source = str(tmp_path / "Film.mkv")
    cache.request(source, 100)
    cache.request(source, 100)  # duplicate while inflight → single queue entry
    assert cache._queue.qsize() == 1
    assert str(cache.cache_file(source, 100)) in cache._inflight


def test_worker_generates_queued_target(tmp_path: Path) -> None:
    cache = _cache(tmp_path)
    source = str(tmp_path / "Film.mkv")
    cache.request(source, 100)

    target = cache.cache_file(source, 100)
    _wait_for(target.is_file)  # the daemon worker generated and published it
    assert cache.get(source, 100) == JPEG_BYTES
    _wait_for(lambda: cache._queue.qsize() == 0)
    _wait_for(lambda: str(target) not in cache._inflight)  # inflight released
    cache.request(source, 100)  # now cached → no new queue entry
    assert cache._queue.qsize() == 0


def test_trim_keeps_cache_within_loose_bound(tmp_path: Path, monkeypatch: Any) -> None:
    monkeypatch.setattr(tc, "CACHE_MAX_BYTES", 500)
    cache = _cache(tmp_path)
    cache_dir = tmp_path / "thumbs"
    cache_dir.mkdir(parents=True)
    for i in range(5):
        path = cache_dir / f"old_{i}.jpg"
        path.write_bytes(b"x" * 200)
        os.utime(path, (1_700_000_000 + i, 1_700_000_000 + i))

    cache._trim()  # 1000 B > 500 B → trimmed to the 80 % target (400 B)

    remaining = sorted(cache_dir.glob("*.jpg"))
    assert sum(path.stat().st_size for path in remaining) <= 500
    assert [path.name for path in remaining] == ["old_3.jpg", "old_4.jpg"]  # newest kept


def test_extract_temp_output_is_format_inferable(
    tmp_path: Path, monkeypatch: Any
) -> None:
    """Regression (2026-10-16): temp must end .jpg — ffmpeg exits instantly on
    '.tmp' (unknown output format), which silently produced zero thumbnails
    in production while fake-extractor unit tests stayed green."""
    cache = ThumbCache(cache_dir=tmp_path / "c", ffmpeg=r"C:\fake\ffmpeg.exe")
    seen: list[str] = []

    def fake_run(argv: list[str], **kwargs: Any) -> Any:
        out = argv[-1]
        seen.append(out)
        assert out.endswith(".jpg"), f"output not format-inferable: {out}"
        Path(out).write_bytes(JPEG_BYTES)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr("pc_agent.media.thumb_cache.subprocess.run", fake_run)
    source = str(tmp_path / "movie.mkv")
    data = cache._extract(r"C:\fake\ffmpeg.exe", source, tmp_path / "c" / "t.jpg")
    assert data == JPEG_BYTES
    assert seen and seen[0].endswith(".jpg")


def test_default_cache_dir_lives_under_config_root() -> None:
    thumbs = default_cache_dir()
    assert thumbs.name == "thumbs"
    assert thumbs.parent.name == "PotPilot"
