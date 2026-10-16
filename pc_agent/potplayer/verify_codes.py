"""Live verification for ``shared_specs/potplayer_wm_codes.json`` (Doc 09 §9).

Runs the real ``WmDispatcher`` + ``TelemetryPoller`` path against a live
PotPlayer window and prints a PASS / FAIL / SENT / SKIP report:

* **PASS/FAIL** — machine-verifiable entries (getters, play status, seek,
  volume, speed via span-timing, frame step, fullscreen), checked via
  read-backs through the Doc 10 getters.
* **SENT** — entries whose effect is user-visible only (aspect / audio /
  subtitle cycling, subtitle visibility, sync nudge); dispatched successfully
  but confirmed manually on screen.
* **SKIP** — playback-dependent checks when no media is loaded, plus
  GET_SPEED (0x5015 never reports on the live build).

Volume, speed, play state and fullscreen are restored on exit. Run:

    python -m pc_agent.potplayer.verify_codes [--launch PATH] [--exe PATH]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import win32con
import win32gui

from pc_agent.potplayer.hwnd_locator import PotPlayerLocator
from pc_agent.potplayer.telemetry_poller import TelemetryPoller
from pc_agent.potplayer.wm_dispatcher import WmDispatcher

DEFAULT_EXE = r"C:\Program Files (x86)\DAUM\PotPlayer\PotPlayerMini.exe"
_ALT_EXE = r"C:\Program Files\DAUM\PotPlayer\PotPlayerMini64.exe"

READBACK_BUDGET_S = 3.0
READBACK_INTERVAL_S = 0.15

# Span-timing (speed checks): GET_SPEED never reports, so speed is proven by
# how long a fixed slice of content takes at each setting.
SPAN_SEEK_START_MS = 2_000
SPAN_CONTENT_MS = 8_000
SPAN_BUDGET_FACTOR = 4.0  # worst-case wall budget vs. the 1.0x expectation


class _MediaPreferringLocator:
    """Doc 08 locator variant that prefers the window carrying media.

    Multi-instance launches can leave an empty PotPlayer window ahead in
    z-order; verification must bind dispatcher, poller and probes to the
    same, media-loaded instance. Full Doc 08 contract: ``find(force=...)``
    + ``invalidate()``.
    """

    def __init__(self) -> None:
        self._base = PotPlayerLocator()
        self._hwnd: int | None = None

    @staticmethod
    def _is_potplayer_class(class_name: str) -> bool:
        from pc_agent.potplayer.hwnd_locator import WINDOW_CLASSES

        return class_name in WINDOW_CLASSES or class_name.lower().startswith("potplayer")

    def _find_media_window(self) -> int | None:
        picked: int | None = None

        def _pick(hwnd: int, _lparam: object) -> bool:
            nonlocal picked
            try:
                if (
                    picked is None
                    and self._is_potplayer_class(win32gui.GetClassName(hwnd))
                    and win32gui.IsWindowVisible(hwnd)
                    and " - PotPlayer" in win32gui.GetWindowText(hwnd)
                ):
                    picked = int(hwnd)
            except win32gui.error:  # pragma: no cover - window died mid-enum
                pass
            return True

        win32gui.EnumWindows(_pick, None)
        return picked

    def find(self, *, force: bool = False) -> int | None:
        if not force and self._hwnd and win32gui.IsWindowVisible(self._hwnd):
            return self._hwnd
        media = self._find_media_window()
        if media is not None:
            self._hwnd = media
            return media
        self._hwnd = self._base.find(force=force)
        return self._hwnd

    def invalidate(self) -> None:
        self._hwnd = None
        self._base.invalidate()


@dataclass
class Check:
    name: str
    status: str  # PASS | FAIL | SENT | SKIP
    detail: str = ""


class _LiveVerifier:
    """One verification session bound to a single live PotPlayer window."""

    def __init__(self) -> None:
        self.locator = _MediaPreferringLocator()
        self.poller = TelemetryPoller(self.locator)
        # Same wiring as main.py: steps-mode SET_SPEED needs the telemetry speed.
        self.dispatcher = WmDispatcher(
            self.locator, speed_provider=lambda: self._speed_provider()
        )
        self.checks: list[Check] = []
        self._hwnd: int | None = None
        self._restored_volume: int | None = None
        self._restored_speed: float | None = None
        self._restored_playing: bool | None = None
        self._fullscreen_toggled = False

    # ------------------------------------------------------------- plumbing

    def _speed_provider(self) -> float:
        snapshot = self.poller.latest
        return float(snapshot.speed) if snapshot is not None else 1.0

    def _snapshot(self):
        self.poller.poll_once()
        return self.poller.latest

    def _until(self, predicate, budget_s: float = READBACK_BUDGET_S):
        deadline = time.monotonic() + budget_s
        while time.monotonic() < deadline:
            snapshot = self._snapshot()
            if snapshot is not None and predicate(snapshot):
                return snapshot
            time.sleep(READBACK_INTERVAL_S)
        return self._snapshot()

    def _record(self, name: str, ok: bool, detail: str = "", *, sent: bool = False) -> None:
        status = "SENT" if sent and ok else ("FAIL" if not ok else "PASS")
        self.checks.append(Check(name, status, detail))
        print(f"  [{status}] {name}{f' — {detail}' if detail else ''}")

    def _dispatch(
        self, name: str, command: str, *, value: int | None = None, sent: bool = False
    ) -> bool:
        result = self.dispatcher.dispatch(command, value=value)
        self._record(name, result.ok, str(result.detail), sent=sent)
        return result.ok

    # -------------------------------------------------------------- checks

    def check_locate(self) -> bool:
        self._hwnd = self.locator.find(force=True)
        ok = bool(self._hwnd)
        title = win32gui.GetWindowText(self._hwnd) if self._hwnd else ""
        self._record("locate window", ok, f"hwnd={self._hwnd} title={title!r}")
        return ok

    def check_getters(self) -> tuple[bool, bool]:
        """Returns (healthy, media_loaded)."""
        snapshot = self._until(lambda s: s.healthy, budget_s=1.5)
        healthy = bool(snapshot and snapshot.healthy)
        if healthy and snapshot is not None and snapshot.duration_ms == 0:
            # Fresh launches expose the media title before decoding starts —
            # give the getters a beat to report the duration.
            snapshot = self._until(lambda s: s.duration_ms > 0, budget_s=8.0) or snapshot
        media = bool(snapshot and snapshot.duration_ms > 0)
        if snapshot is None:
            self._record("telemetry getters", False, "no snapshot")
            return False, False
        self._record(
            "telemetry getters",
            healthy,
            f"pos={snapshot.position_ms} ms dur={snapshot.duration_ms} ms "
            f"playing={snapshot.is_playing} vol={snapshot.volume} speed={snapshot.speed}",
        )
        if not media:
            self.checks.append(Check("media-loaded", "SKIP", "no media; playback checks skipped"))
            print("  [SKIP] media-loaded — no media; playback checks skipped")
        return healthy, media

    def check_play_status(self, media: bool) -> None:
        if not media:
            for name in ("PLAY_PAUSE", "PAUSE", "PLAY"):
                self.checks.append(Check(name, "SKIP", "no media"))
                print(f"  [SKIP] {name}")
            return
        started = self._snapshot()
        self._restored_playing = bool(started.is_playing) if started else None

        result = self.dispatcher.play_pause()
        after = self._until(lambda s: s.is_playing != (started.is_playing if started else True))
        flipped = result.ok and after is not None and after.is_playing != started.is_playing
        state = f"{started.is_playing} -> {after.is_playing if after else '?'}"
        self._record("PLAY_PAUSE", flipped, state)

        result = self.dispatcher.dispatch("PAUSE")
        paused = self._until(lambda s: not s.is_playing)
        self._record("PAUSE", result.ok and paused is not None and not paused.is_playing)

        result = self.dispatcher.dispatch("PLAY")
        playing = self._until(lambda s: s.is_playing)
        self._record("PLAY", result.ok and playing is not None and playing.is_playing)

    def check_seek(self, media: bool) -> None:
        if not media:
            self.checks.append(Check("SEEK", "SKIP", "no media"))
            print("  [SKIP] SEEK")
            return
        snapshot = self._until(lambda s: s.duration_ms > 0, budget_s=1.0)
        target = 60_000 if snapshot.duration_ms > 90_000 else snapshot.duration_ms // 2
        result = self.dispatcher.seek_ms(target)
        reached = self._until(
            lambda s: target - 500 <= s.position_ms <= target + 2500,
            budget_s=READBACK_BUDGET_S,
        )
        detail = f"target={target} ms got={reached.position_ms if reached else '?'} ms"
        self._record("SEEK", result.ok and reached is not None, detail)

    def check_volume(self) -> None:
        before = self._until(lambda s: True, budget_s=0.5)
        self._restored_volume = before.volume if before else None
        result = self.dispatcher.dispatch("SET_VOLUME", value=73)
        after = self._until(lambda s: s.volume == 73)
        self._record("SET_VOLUME", result.ok and after is not None and after.volume == 73,
                     f"read-back {after.volume if after else '?'}")

    def check_speed(self, media: bool) -> None:
        """Span-timing: 0x5015 never reports speed, so each change is proven by
        measuring how long SPAN_CONTENT_MS of content takes at the new rate."""
        snap = self._snapshot()
        self.checks.append(
            Check(
                "GET_SPEED",
                "SKIP",
                f"0x5015 unreported on this build (normalized {snap.speed if snap else '?'})",
            )
        )
        print(
            f"  [SKIP] GET_SPEED — 0x5015 unreported on this build "
            f"(normalized {snap.speed if snap else '?'})"
        )
        if not media:
            for name in ("SET_SPEED", "SPEED_UP", "SPEED_DOWN"):
                self.checks.append(Check(name, "SKIP", "no media for span timing"))
                print(f"  [SKIP] {name} — no media for span timing")
            return

        # Deterministic resync: 'Z' restores default 1.0x, aligning reality with
        # the fresh dispatcher's speed belief before measuring.
        reset = self.dispatcher.dispatch("SPEED_DEFAULT")
        if not reset.ok:
            self._record("SET_SPEED", False, f"speed reset failed: {reset.detail}")
            return
        self._restored_speed = 1.0
        time.sleep(0.3)

        baseline = self._measure_span()
        if baseline is None:
            self._record("SET_SPEED", False, "baseline span stalled (is playback alive?)")
            return

        # SET_SPEED 1.5 -> five async +0.1x steps; expect span ≈ baseline / 1.5.
        result = self.dispatcher.set_speed(1.5)
        time.sleep(0.4)  # let the step worker finish posting
        up_span = self._measure_span()
        r15 = (baseline / up_span) if up_span else 0.0
        ok_15 = bool(result.ok) and up_span is not None and 1.28 <= r15 <= 1.72
        # Return trip -> five -0.1x steps; expect the baseline span back.
        result_b = self.dispatcher.set_speed(1.0)
        time.sleep(0.4)
        back_span = self._measure_span()
        r10 = (baseline / back_span) if back_span else 0.0
        ok_10 = bool(result_b.ok) and back_span is not None and 0.90 <= r10 <= 1.11
        self._record(
            "SET_SPEED",
            ok_15 and ok_10,
            f"res {result.detail}/{result_b.detail}; "
            f"span {baseline:.1f}s -> {up_span if up_span else float('nan'):.1f}s "
            f"(x{r15:.2f}), return {back_span if back_span else float('nan'):.1f}s (x{r10:.2f})",
        )

        # Raw transports: three +0.1x posts (x1.3), then three -0.1x (back to x1.0).
        for _ in range(3):
            self.dispatcher.dispatch("SPEED_UP")
            time.sleep(0.05)
        time.sleep(0.3)
        raw_up = self._measure_span()
        r_up = (baseline / raw_up) if raw_up else 0.0
        self._record(
            "SPEED_UP",
            raw_up is not None and 1.15 <= r_up <= 1.45,
            f"3 posts: span {raw_up if raw_up else float('nan'):.1f}s (x{r_up:.2f})",
        )
        for _ in range(3):
            self.dispatcher.dispatch("SPEED_DOWN")
            time.sleep(0.05)
        time.sleep(0.3)
        raw_down = self._measure_span()
        r_down = (baseline / raw_down) if raw_down else 0.0
        self._record(
            "SPEED_DOWN",
            raw_down is not None
            and 0.90 <= r_down <= 1.11
            and raw_up is not None
            and raw_down > raw_up * 1.08,
            f"3 posts: span {raw_down if raw_down else float('nan'):.1f}s (x{r_down:.2f})",
        )

    def _measure_span(self) -> float | None:
        """Wall seconds for SPAN_CONTENT_MS of content; None if playback stalls."""
        seek = self.dispatcher.seek_ms(SPAN_SEEK_START_MS)
        if not seek.ok:
            return None
        # Wait for the seek to LAND (position near the target from any higher
        # pre-seek value) — a "position >= start" predicate would accept the
        # stale pre-seek reading and silently measure a much longer span.
        start = self._until(
            lambda s: s.is_playing and s.position_ms <= SPAN_SEEK_START_MS + 400,
            budget_s=2.0,
        )
        if start is None or not start.is_playing:
            return None
        target = start.position_ms + SPAN_CONTENT_MS
        began = time.monotonic()
        budget = SPAN_CONTENT_MS / 1000.0 * SPAN_BUDGET_FACTOR + 4.0
        while time.monotonic() - began < budget:
            snapshot = self._snapshot()
            if snapshot is not None and snapshot.position_ms >= target:
                return time.monotonic() - began
            if snapshot is not None and not snapshot.is_playing:
                return None
            time.sleep(0.05)
        return None

    def check_frame_step(self, media: bool) -> None:
        if not media:
            self.checks.append(Check("FRAME_STEP", "SKIP", "no media"))
            print("  [SKIP] FRAME_STEP")
            return
        self.dispatcher.dispatch("PAUSE")
        paused = self._until(lambda s: not s.is_playing)
        if paused is None or paused.is_playing:
            self._record("FRAME_STEP", False, "could not pause for stepping")
            return
        base = paused.position_ms
        result = self.dispatcher.frame_step("FORWARD")
        fwd = self._until(lambda s: s.position_ms > base, budget_s=1.5)
        if not result.ok or fwd is None:
            self._record("FRAME_STEP", False, "position did not advance")
            return
        back = self.dispatcher.frame_step("BACKWARD")
        back_snap = self._until(lambda s: s.position_ms < fwd.position_ms, budget_s=1.5)
        ok = back.ok and back_snap is not None
        back_pos = back_snap.position_ms if back_snap else "?"
        self._record("FRAME_STEP", ok, f"fwd +{fwd.position_ms - base} ms, back -> {back_pos} ms")

    def check_fullscreen(self) -> None:
        hwnd = int(self._hwnd or 0)
        style_before = win32gui.GetWindowLong(hwnd, win32con.GWL_STYLE)
        caption_before = bool(style_before & win32con.WS_CAPTION)
        result = self.dispatcher.dispatch("TOGGLE_FULLSCREEN")

        def caption_visible() -> bool:
            style = win32gui.GetWindowLong(hwnd, win32con.GWL_STYLE)
            return bool(style & win32con.WS_CAPTION)

        def style_changed(snapshot):
            del snapshot
            return caption_visible() != caption_before

        self._until(style_changed, budget_s=2.0)
        changed = caption_visible() != caption_before
        self._fullscreen_toggled = changed
        self._record("TOGGLE_FULLSCREEN", result.ok and changed,
                     "style toggled" if changed else "no style change")

    def check_sent_actions(self) -> None:
        """Dispatch-only entries: effect is visible on the PC, not machine-readable."""
        for name, command in (
            ("CYCLE_ASPECT_RATIO", "CYCLE_ASPECT_RATIO"),
            ("CYCLE_AUDIO", "CYCLE_AUDIO"),
            ("CYCLE_SUBS", "CYCLE_SUBS"),
        ):
            self._dispatch(name, command, sent=True)
        up = self.dispatcher.adjust_subtitle_delay(500)
        down = self.dispatcher.adjust_subtitle_delay(-500) if up.ok else None
        self._record(
            "SUB_SYNC_ADJUST ±500 (nudged and restored)",
            up.ok and down is not None and down.ok,
            f"{up.detail}/{down.detail if down else '-'}",
            sent=True,
        )
        result = self.dispatcher.set_subtitles(True)  # belief: visible -> no-op
        self._record("SET_SUBS", result.ok, str(result.detail), sent=True)

    # ------------------------------------------------------------- lifecycle

    def restore(self) -> None:
        """Best-effort restore of everything this session changed."""
        if self._restored_volume is not None:
            self.dispatcher.dispatch("SET_VOLUME", value=int(self._restored_volume))
        if self._restored_speed is not None:
            self.dispatcher.set_speed(float(self._restored_speed))
        if self._fullscreen_toggled:
            self.dispatcher.dispatch("TOGGLE_FULLSCREEN")
        if self._restored_playing:
            snap = self._snapshot()
            if snap is not None and not snap.is_playing:
                self.dispatcher.dispatch("PLAY")

    def run(self, *, launch: str | None, exe: str) -> int:
        if launch:
            _launch_player(exe, launch)
        if not self.check_locate():
            print("PotPlayer window not found — is it running?")
            return 1
        healthy, media = self.check_getters()
        try:
            if media:
                snap = self._snapshot()
                if snap is not None and not snap.is_playing:
                    self.dispatcher.dispatch("PLAY")
                    self._until(lambda s: s.is_playing, budget_s=2.0)
            self.check_volume()
            self.check_speed(media)
            self.check_fullscreen()
            if media:
                self.check_play_status(True)
                self.check_seek(True)
                self.check_frame_step(True)
            else:
                for name in ("PLAY_PAUSE", "PAUSE", "PLAY", "SEEK", "FRAME_STEP"):
                    self.checks.append(Check(name, "SKIP", "no media"))
                    print(f"  [SKIP] {name}")
            self.check_sent_actions()
        finally:
            self.restore()

        failed = [c for c in self.checks if c.status == "FAIL"]
        sent = sum(1 for c in self.checks if c.status == "SENT")
        skipped = sum(1 for c in self.checks if c.status == "SKIP")
        passed = sum(1 for c in self.checks if c.status == "PASS")
        print(
            f"\n{passed} passed, {len(failed)} failed, "
            f"{sent} sent (manual), {skipped} skipped; healthy_telemetry={healthy}"
        )
        return 1 if failed or not healthy else 0


def _visible_potplayer_windows() -> list[int]:
    """All visible top-level windows whose class matches Doc 08's PotPlayer rule."""
    from pc_agent.potplayer.hwnd_locator import WINDOW_CLASSES

    found: list[int] = []

    def _cb(hwnd: int, _lparam: object) -> bool:
        try:
            class_name = win32gui.GetClassName(hwnd)
        except win32gui.error:  # pragma: no cover - window died mid-enum
            return True
        if class_name in WINDOW_CLASSES or class_name.lower().startswith("potplayer"):
            if win32gui.IsWindowVisible(hwnd):
                found.append(int(hwnd))
        return True

    win32gui.EnumWindows(_cb, None)
    return found


def _launch_player(exe: str, media: str) -> None:
    path = Path(media)
    if not path.is_file():
        raise SystemExit(f"media file not found: {path}")
    exe_path = exe if Path(exe).is_file() else _ALT_EXE
    if not Path(exe_path).is_file():
        raise SystemExit(f"PotPlayer executable not found: {exe}")
    print(f"launching {exe_path} {path}")
    subprocess.Popen([exe_path, str(path)])
    # Wait for the window that actually carries the media title, so later
    # checks cannot bind to an empty pre-existing instance.
    deadline = time.monotonic() + 15.0
    while time.monotonic() < deadline:
        for hwnd in _visible_potplayer_windows():
            if path.stem in win32gui.GetWindowText(hwnd):
                print(f"media window ready: hwnd={hwnd}")
                return
        time.sleep(0.3)
    print("warning: launched, but no titled media window detected within 15 s")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--launch", metavar="FILE", help="open this media file in PotPlayer first")
    parser.add_argument("--exe", default=DEFAULT_EXE, help="PotPlayer executable for --launch")
    args = parser.parse_args(argv)
    return _LiveVerifier().run(launch=args.launch, exe=args.exe)


if __name__ == "__main__":
    sys.exit(main())
