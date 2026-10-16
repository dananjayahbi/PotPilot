"""Doc 20 unit tests: local media library scanner (fixture trees only, no network)."""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from pc_agent.media import library_scanner as scanner_module
from pc_agent.media.library_scanner import (
    ACT_LIST_MEDIA,
    ACT_RESCAN_MEDIA,
    PAGE_LIMIT_DEFAULT,
    PAGE_LIMIT_MAX,
    PHASE_DONE,
    PHASE_STATTING,
    PHASE_WALKING,
    SORT_MODIFIED_DESC,
    SORT_SIZE_DESC,
    SORT_TITLE_ASC,
    LibraryScanner,
)
from pc_agent.network.ws_server_router import WsRouter, WsSession, parse_envelope


class FakeConfig:
    """ConfigManager stand-in exposing only the ``get().movie_dirs`` seam."""

    def __init__(self, movie_dirs: list[str]) -> None:
        self._dirs = list(movie_dirs)

    def get(self) -> SimpleNamespace:
        return SimpleNamespace(movie_dirs=list(self._dirs))


class FakeSocket:
    """Minimal ``websockets`` connection stand-in (records anything written to it)."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


async def wait_until(predicate: Callable[[], bool], max_wait: float = 5.0) -> None:
    deadline = time.monotonic() + max_wait
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError("condition not met before timeout")
        await asyncio.sleep(0.005)


def _write(path: Path, size: int, mtime: int | None = None) -> Path:
    """Create a file of ``size`` bytes (optionally pinning mtime for sort tests)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def _scan(config: FakeConfig) -> LibraryScanner:
    """Run one full rescan synchronously; returns the scanned scanner."""

    async def run() -> LibraryScanner:
        scanner = LibraryScanner(config)
        await scanner.rescan()
        return scanner

    return asyncio.run(run())


def _envelope(action: str, payload: dict[str, Any]) -> Any:
    return parse_envelope(
        json.dumps(
            {
                "id": str(uuid.uuid4()),
                "type": "CMD_MEDIA",
                "action": action,
                "payload": payload,
                "timestamp": int(time.time()),
            }
        )
    )


def test_walk_indexes_supported_extensions_only(tmp_path: Path) -> None:
    root = tmp_path / "movies"
    _write(root / "a.mp4", 10)
    _write(root / "sub" / "b.mkv", 20)
    _write(root / "c.avi", 30)
    _write(root / "d.webm", 40)
    _write(root / "notes.txt", 5)
    _write(root / "setup.exe", 5)
    _write(root / "loose.srt", 5)
    _write(root / "clip.mov", 5)

    scanner = _scan(FakeConfig([str(root)]))
    _, page = scanner.query(limit=PAGE_LIMIT_MAX)
    assert sorted(entry.title for entry in page) == ["a", "b", "c", "d"]
    stats = scanner.stats()
    assert stats["total"] == 4
    assert stats["errors"] == []
    assert stats["last_error"] is None


def test_extension_case_insensitive(tmp_path: Path) -> None:
    root = tmp_path / "case"
    _write(root / "Upper.MKV", 10)
    _write(root / "Mixed.Mp4", 10)
    _write(root / "lower.avi", 10)
    _write(root / "notvideo.MOV", 10)

    scanner = _scan(FakeConfig([str(root)]))
    _, page = scanner.query(limit=PAGE_LIMIT_MAX)
    assert sorted(entry.title for entry in page) == ["Mixed", "Upper", "lower"]


def test_stat_fields_match_os(tmp_path: Path) -> None:
    root = tmp_path / "stat"
    target = _write(root / "Measured.mkv", 1234, mtime=1_700_000_000)

    scanner = _scan(FakeConfig([str(root)]))
    entry = scanner.get(str(target))
    assert entry is not None
    ground = os.stat(target)
    assert entry.size_bytes == ground.st_size
    assert entry.modified_at == int(ground.st_mtime)
    assert entry.title == "Measured"


def test_srt_detection_variants(tmp_path: Path) -> None:
    root = tmp_path / "subs"
    _write(root / "Film.mkv", 10)
    _write(root / "Film.srt", 5)
    _write(root / "Alt.mkv", 10)
    _write(root / "Alt.en.srt", 5)
    _write(root / "Up.mkv", 10)
    _write(root / "UP.SRT", 5)
    _write(root / "AssOnly.mkv", 10)
    _write(root / "AssOnly.ass", 5)
    _write(root / "NoSubs.avi", 10)

    scanner = _scan(FakeConfig([str(root)]))
    _, page = scanner.query(limit=PAGE_LIMIT_MAX)
    flags = {entry.title: entry.has_srt for entry in page}
    assert flags["Film"] is True
    assert flags["Alt"] is True
    assert flags["Up"] is True
    assert flags["AssOnly"] is False  # .ass deliberately does not count (§7/A3)
    assert flags["NoSubs"] is False


def test_missing_watch_dir_recorded_not_fatal(tmp_path: Path) -> None:
    good = tmp_path / "good"
    _write(good / "Kept.mkv", 10)
    missing = tmp_path / "gone"

    scanner = _scan(FakeConfig([str(good), str(missing)]))
    stats = scanner.stats()
    assert stats["total"] == 1  # the healthy root still indexed
    assert any(str(missing) in err for err in stats["errors"])  # §7 stats()["errors"]
    assert stats["last_error"] is not None and str(missing) in stats["last_error"]
    _, page = scanner.query(limit=PAGE_LIMIT_MAX)
    assert [entry.title for entry in page] == ["Kept"]


def test_deleted_file_mid_scan_skipped(tmp_path: Path, monkeypatch: Any) -> None:
    root = tmp_path / "vanish"
    _write(root / "Keep.mkv", 10)
    vanish = _write(root / "Vanish.mkv", 10)
    target_key = os.path.normcase(os.path.abspath(os.fspath(vanish)))
    real_stat = os.stat

    def stat_wrapper(path: Any, *args: Any, **kwargs: Any) -> Any:
        try:
            key = os.path.normcase(os.path.abspath(os.fspath(path)))
        except TypeError:
            return real_stat(path, *args, **kwargs)  # e.g. fd int — not our target
        if key == target_key:
            raise FileNotFoundError(os.fspath(path))
        return real_stat(path, *args, **kwargs)

    monkeypatch.setattr(os, "stat", stat_wrapper)
    scanner = _scan(FakeConfig([str(root)]))
    _, page = scanner.query(limit=PAGE_LIMIT_MAX)
    assert [entry.title for entry in page] == ["Keep"]  # vanished file silently skipped


def test_dedupe_same_file_two_roots(tmp_path: Path) -> None:
    base = tmp_path / "library"
    _write(base / "Action" / "Shared.mkv", 10)

    scanner = _scan(FakeConfig([str(base), str(base / "Action")]))
    total, page = scanner.query(limit=PAGE_LIMIT_MAX)
    assert total == 1  # same file reachable via two roots counts once (§4.4)
    assert len(page) == 1
    assert page[0].title == "Shared"


def test_query_pagination_and_sorts(tmp_path: Path) -> None:
    root = tmp_path / "sort"
    _write(root / "Alpha.mkv", 300, mtime=1_700_000_100)
    _write(root / "Beta.mkv", 100, mtime=1_700_000_300)
    _write(root / "Gamma.mkv", 200, mtime=1_700_000_200)

    scanner = _scan(FakeConfig([str(root)]))
    _, by_modified = scanner.query(sort=SORT_MODIFIED_DESC, limit=PAGE_LIMIT_MAX)
    assert [entry.title for entry in by_modified] == ["Beta", "Gamma", "Alpha"]
    _, by_title = scanner.query(sort=SORT_TITLE_ASC, limit=PAGE_LIMIT_MAX)
    assert [entry.title for entry in by_title] == ["Alpha", "Beta", "Gamma"]
    _, by_size = scanner.query(sort=SORT_SIZE_DESC, limit=PAGE_LIMIT_MAX)
    assert [entry.title for entry in by_size] == ["Alpha", "Gamma", "Beta"]

    total, page1 = scanner.query(offset=0, limit=2)
    assert total == 3 and len(page1) == 2
    total2, page2 = scanner.query(offset=2, limit=2)
    assert total2 == 3 and len(page2) == 1
    total3, page3 = scanner.query(offset=99, limit=2)
    assert total3 == 3 and page3 == []  # beyond range: empty items, stable total


def test_query_case_insensitive_substring(tmp_path: Path) -> None:
    root = tmp_path / "search"
    _write(root / "Avatar.mkv", 10)
    _write(root / "The AaVaTaR Returns.avi", 10)
    _write(root / "Unrelated.mkv", 10)

    scanner = _scan(FakeConfig([str(root)]))
    total, page = scanner.query(query="aVaTar", limit=PAGE_LIMIT_MAX)
    assert total == 2
    assert {entry.title for entry in page} == {"Avatar", "The AaVaTaR Returns"}


def test_list_media_result_shape(tmp_path: Path) -> None:
    root = tmp_path / "shape"
    _write(root / "Action" / "Raid.mkv", 512, mtime=1_700_000_000)
    _write(root / "Drama.mkv", 256, mtime=1_700_000_100)

    scanner = _scan(FakeConfig([str(root)]))
    result = scanner.list_media({})
    assert set(result) == {"folders", "items", "total", "offset", "limit"}
    assert result["folders"] == ["Action"]  # first-level dirs; root files excluded
    assert result["limit"] == PAGE_LIMIT_DEFAULT  # default 50
    assert result["offset"] == 0
    assert result["total"] == 2
    assert result["items"][0]["name"] == "Drama"  # default newest-first order
    assert set(result["items"][0]) == {
        "name",
        "path",
        "size_bytes",
        "modified_at",
        "has_subs",
    }  # Doc 03 §5.5 frozen item fields
    assert scanner.list_media({"limit": PAGE_LIMIT_MAX + 300})["limit"] == PAGE_LIMIT_MAX
    assert scanner.list_media({"limit": 0})["limit"] == 1  # clamps to 1–200
    beyond = scanner.list_media({"offset": 99})
    assert beyond["items"] == [] and beyond["total"] == 2

    async def scenario() -> tuple[dict[str, Any], dict[str, Any]]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_LIST_MEDIA, scanner.handle_list_media)
        router.register("CMD_MEDIA", ACT_RESCAN_MEDIA, scanner.handle_rescan_media)
        session = WsSession(FakeSocket())
        good = await router.dispatch(session, _envelope(ACT_LIST_MEDIA, {}))
        bad = await router.dispatch(session, _envelope(ACT_LIST_MEDIA, {"offset": "x"}))
        return good, bad

    good, bad = asyncio.run(scenario())
    assert good["action"] == "LIST_MEDIA_RESULT"
    assert set(good["payload"]) == {"ok", "folders", "items", "total", "offset", "limit"}
    assert good["payload"]["ok"] is True
    assert bad["payload"] == {
        "ok": False,
        "error": "E_BAD_PAYLOAD",
        "detail": "offset must be an integer",
    }


def test_handle_list_media_attaches_thumbnail_b64(tmp_path: Path) -> None:
    """The wire handler enriches items with the optional Doc 45 field while
    the pure query API keeps the frozen Doc 03 §5.5 item field set."""
    root = tmp_path / "attach"
    _write(root / "Film.mkv", 64, mtime=1_700_000_000)
    scanner = _scan(FakeConfig([str(root)]))

    class _StubThumbs:
        def attach(self, items: list[dict[str, Any]]) -> None:
            for item in items:
                item["thumbnail_b64"] = "ZmFrZQ=="

    scanner._thumbs = _StubThumbs()  # attribute seam — no ffmpeg in this test

    async def scenario() -> dict[str, Any]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_LIST_MEDIA, scanner.handle_list_media)
        session = WsSession(FakeSocket())
        return await router.dispatch(session, _envelope(ACT_LIST_MEDIA, {}))

    reply = asyncio.run(scenario())
    assert reply["action"] == "LIST_MEDIA_RESULT"
    assert set(reply["payload"]) == {"ok", "folders", "items", "total", "offset", "limit"}
    assert reply["payload"]["items"][0]["thumbnail_b64"] == "ZmFrZQ=="
    pure = scanner.list_media({})
    assert set(pure["items"][0]) == {
        "name",
        "path",
        "size_bytes",
        "modified_at",
        "has_subs",
    }  # list_media() itself never attaches thumbnails


def test_handle_rescan_media_warms_thumbs_after_the_walk(tmp_path: Path) -> None:
    """Once a LIST_MEDIA created the cache, a user RESCAN queues thumbnail
    generation for the whole index when that walk lands (Doc 45 §4.2.5)."""
    root = tmp_path / "warm"
    _write(root / "Film.mkv", 64, mtime=1_700_000_000)
    scanner = LibraryScanner(FakeConfig([str(root)]))

    class _StubThumbs:
        def __init__(self) -> None:
            self.pairs: list[tuple[str, int]] = []

        def request_many(self, pairs: Any) -> None:
            self.pairs = list(pairs)

    stub = _StubThumbs()
    scanner._thumbs = stub  # a LIST_MEDIA happened earlier (lazy cache seam)

    async def scenario() -> dict[str, Any]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_RESCAN_MEDIA, scanner.handle_rescan_media)
        session = WsSession(FakeSocket())
        reply = await router.dispatch(session, _envelope(ACT_RESCAN_MEDIA, {}))
        task = scanner._scan_task
        assert task is not None
        await task
        await asyncio.sleep(0)  # flush the done-callback that queues the warm-up
        await asyncio.sleep(0)
        return reply

    reply = asyncio.run(scenario())
    assert reply["payload"]["ok"] is True and reply["payload"]["queued"] is True
    assert stub.pairs == [(str(root / "Film.mkv"), 1_700_000_000)]


def test_handle_rescan_media_skips_warmup_before_any_list(tmp_path: Path) -> None:
    """No LIST_MEDIA yet → no thumb cache → the rescan never starts ffmpeg."""
    root = tmp_path / "cold"
    _write(root / "Film.mkv", 64)
    scanner = LibraryScanner(FakeConfig([str(root)]))

    async def scenario() -> dict[str, Any]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_RESCAN_MEDIA, scanner.handle_rescan_media)
        session = WsSession(FakeSocket())
        reply = await router.dispatch(session, _envelope(ACT_RESCAN_MEDIA, {}))
        task = scanner._scan_task
        if task is not None:
            await task
        await asyncio.sleep(0)
        return reply

    reply = asyncio.run(scenario())
    assert reply["payload"]["ok"] is True
    assert scanner._thumbs is None  # warm-up no-oped: nothing queued, no worker


def test_reentrant_scan_guard(tmp_path: Path, monkeypatch: Any) -> None:
    root = tmp_path / "reentry"
    _write(root / "One.mkv", 10)
    scanner = LibraryScanner(FakeConfig([str(root)]))
    original_walk = scanner._walk_blocking
    calls = {"count": 0}

    def slow_walk(roots: Any) -> Any:
        calls["count"] += 1
        time.sleep(0.1)  # keep the walk in flight while the second ack lands
        return original_walk(roots)

    monkeypatch.setattr(scanner, "_walk_blocking", slow_walk)

    async def scenario() -> tuple[dict[str, Any], dict[str, Any]]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_RESCAN_MEDIA, scanner.handle_rescan_media)
        session = WsSession(FakeSocket())
        first = await router.dispatch(session, _envelope(ACT_RESCAN_MEDIA, {}))
        second = await router.dispatch(session, _envelope(ACT_RESCAN_MEDIA, {}))
        await wait_until(lambda: not scanner.is_scanning())
        return first, second

    first, second = asyncio.run(scenario())
    assert first["payload"] == {"ok": True, "queued": True}
    assert second["payload"] == {"ok": True, "queued": True}  # coalesced, still queued
    assert calls["count"] == 1  # never two concurrent walks (§7)
    assert scanner.stats()["total"] == 1


def test_progress_throttle_and_done_event(tmp_path: Path, monkeypatch: Any) -> None:
    root = tmp_path / "progress"
    for index in range(6):
        _write(root / f"Clip{index}.mkv", 10 + index)
    scanner = LibraryScanner(FakeConfig([str(root)]))
    events: list[tuple[float, str]] = []
    clock = {"t": 0.0}

    def tick() -> float:
        clock["t"] += 0.1
        return clock["t"]

    scanner._now = tick  # deterministic progress-gate clock (§4.7)

    async def on_progress(progress: Any) -> None:
        events.append((clock["t"], progress.phase))

    scanner.on_progress(on_progress)
    monkeypatch.setattr(scanner_module, "WALK_CHUNK", 1)  # one stat chunk per file

    async def scenario() -> tuple[dict[str, Any], list[str]]:
        router = WsRouter()
        router.register("CMD_MEDIA", ACT_RESCAN_MEDIA, scanner.handle_rescan_media)
        socket = FakeSocket()
        session = WsSession(socket)
        reply = await router.dispatch(session, _envelope(ACT_RESCAN_MEDIA, {}))
        await wait_until(lambda: not scanner.is_scanning())
        return reply, list(socket.sent)

    reply, sent = asyncio.run(scenario())
    assert reply["payload"] == {"ok": True, "queued": True}
    assert sent == []  # progress never reaches the wire (no scan-progress frame)

    phases = [phase for _, phase in events]
    assert phases.count(PHASE_DONE) == 1  # exactly one terminal done event
    assert phases[-1] == PHASE_DONE
    assert PHASE_WALKING in phases and PHASE_STATTING in phases
    gaps = [
        events[index][0] - events[index - 1][0]
        for index in range(1, len(events))
        if events[index][1] != PHASE_DONE and events[index - 1][1] != PHASE_DONE
    ]
    assert gaps, "expected throttled progress events"
    assert all(gap >= 0.25 - 1e-9 for gap in gaps)  # ≥ 250 ms spacing (§4.7)
    assert len(phases) < 9  # the gate dropped intermediate emits
