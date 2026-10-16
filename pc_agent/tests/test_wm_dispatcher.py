"""Doc 09 unit tests: table-driven WM_COMMAND / WM_USER dispatcher (fully mocked Win32)."""

from __future__ import annotations

import json
import pathlib
import time
from pathlib import Path

import pytest

from pc_agent.potplayer import wm_dispatcher
from pc_agent.potplayer.wm_dispatcher import SEND_TIMEOUT_MS, CodeTableError, WmDispatcher, _pack

REPO_SPECS = (
    pathlib.Path(__file__).resolve().parents[2] / "shared_specs" / "potplayer_wm_codes.json"
)
TABLE = json.loads(REPO_SPECS.read_text(encoding="utf-8"))
WM_COMMAND = int(TABLE["base"]["WM_COMMAND"], 0)
WM_USER = int(TABLE["base"]["WM_USER"], 0)

FORBIDDEN_APIS = ("SetForegroundWindow", "ShowWindow", "SetCapture")


class FakeLocator:
    """Scriptable stand-in for PotPlayerLocator (Doc 08 public contract subset)."""

    def __init__(self, hwnd: int | None = 1234) -> None:
        self.hwnd = hwnd
        self.next_hwnd: int | None = hwnd  # what find() returns after invalidate()
        self.invalidations = 0
        self.find_calls = 0

    def find(self, *, force: bool = False) -> int | None:
        self.find_calls += 1
        return self.hwnd

    def invalidate(self) -> None:
        # Re-acquisition semantics: a fresh find() may return a new live handle
        # (or None if the app is truly gone) — modeled by the `next_hwnd` knob.
        self.invalidations += 1
        self.hwnd = self.next_hwnd


class DyingLocator:
    """Returns a live window for the first `allow` find() calls, then reports it gone."""

    def __init__(self, allow: int, hwnd: int = 4321) -> None:
        self.allow = allow
        self.hwnd = hwnd
        self.invalidations = 0

    def find(self, *, force: bool = False) -> int | None:
        if self.allow > 0:
            self.allow -= 1
            return self.hwnd
        return None

    def invalidate(self) -> None:
        self.invalidations += 1


@pytest.fixture
def posts(monkeypatch):
    recorded: list[tuple[int, int, int, int]] = []

    def fake_post(hwnd, msg, wparam, lparam):
        recorded.append((hwnd, msg, wparam, lparam))

    monkeypatch.setattr(wm_dispatcher.win32gui, "PostMessage", fake_post)
    return recorded


@pytest.fixture
def acks(monkeypatch):
    """Mocked SendMessageTimeoutW: returns scripted delivery results, records calls."""
    state = {"results": [1], "calls": []}

    def fake_send(hwnd, msg, wparam, lparam, timeout_ms):
        state["calls"].append((hwnd, msg, wparam, lparam, timeout_ms))
        result = state["results"].pop(0) if len(state["results"]) > 1 else state["results"][0]
        return result

    monkeypatch.setattr(wm_dispatcher, "_send_message_timeout", fake_send)
    return state


def make_dispatcher(locator=None, path=REPO_SPECS, speed_provider=None) -> WmDispatcher:
    return WmDispatcher(locator or FakeLocator(), codes_path=path, speed_provider=speed_provider)


def _wait_for_posts(posts, count, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(posts) >= count:
            return
        time.sleep(0.005)
    raise AssertionError(f"expected {count} posts, got {len(posts)}")


# ------------------------------------------------------------- Doc 09 §5 action registry

ACTION_CASES = [
    ("PLAY_PAUSE", "play_pause", "PLAY_PAUSE", (WM_COMMAND, 0, 0)),
    ("PLAY", "dispatch_play", "PLAY", (WM_COMMAND, 0, 0)),
    ("PAUSE", "dispatch_pause", "PAUSE", (WM_COMMAND, 0, 0)),
    ("SEEK", "seek", "SEEK", (WM_USER, 0, 8_410_000)),
    # Router-side SEEK_DELTA arithmetic (current from the Doc 10 snapshot) lands on SEEK.
    ("SEEK_DELTA", "seek_delta", "SEEK", (WM_USER, 0, 3_000)),
    ("SET_SPEED", "speed", "SET_SPEED", (WM_USER, 0, 1_400)),
    ("FRAME_STEP", "frame_fwd", "FRAME_STEP", (WM_USER, 0, 1)),
    ("TOGGLE_FULLSCREEN", "fullscreen", "TOGGLE_FULLSCREEN", (WM_COMMAND, 0, 0)),
    ("CYCLE_ASPECT_RATIO", "aspect", "CYCLE_ASPECT_RATIO", (WM_COMMAND, 0, 0)),
    ("SET_VOLUME", "volume", "SET_VOLUME", (WM_USER, 0, 42)),
    ("CYCLE_AUDIO", "audio", "CYCLE_AUDIO", (WM_COMMAND, 0, 0)),
    ("CYCLE_SUBS", "subs", "CYCLE_SUBS", (WM_COMMAND, 0, 0)),
    ("SET_SUBS", "set_subs", "SET_SUBS", (WM_USER, 0, 1)),
    ("SUB_SYNC_ADJUST", "sub_sync", "SUB_DELAY_DELTA", (WM_USER, 0, -500)),
]

INVOKERS = {
    "play_pause": lambda d: d.play_pause(),
    "dispatch_play": lambda d: d.dispatch("PLAY"),
    "dispatch_pause": lambda d: d.dispatch("PAUSE"),
    "seek": lambda d: d.seek_ms(8_410_000),
    "seek_delta": lambda d: d.seek_ms(max(0, 8_000 + (-5_000))),
    "speed": lambda d: d.set_speed(1.4),
    "frame_fwd": lambda d: d.frame_step("FORWARD"),
    "fullscreen": lambda d: d.dispatch("TOGGLE_FULLSCREEN"),
    "aspect": lambda d: d.dispatch("CYCLE_ASPECT_RATIO"),
    "volume": lambda d: d.dispatch("SET_VOLUME", value=42),
    "audio": lambda d: d.cycle_audio_track(),
    "subs": lambda d: d.cycle_subtitle_track(),
    "set_subs": lambda d: d.dispatch("SET_SUBS", value=True),
    "sub_sync": lambda d: d.adjust_subtitle_delay(-500),
}


@pytest.mark.parametrize(
    "action,invoker,entry_name,expected",
    ACTION_CASES,
    ids=[case[0] for case in ACTION_CASES],
)
def test_action_table_smoke(posts, acks, action, invoker, entry_name, expected):
    """Each Doc 03 §5.3 action produces exactly one correctly-named post."""
    dispatcher = make_dispatcher()
    result = INVOKERS[invoker](dispatcher)
    assert result.ok, (action, result.detail)
    assert result.command == entry_name, (result.command, entry_name)
    msg, wparam, lparam = expected
    if TABLE["commands"][entry_name]["needs_ack"]:
        assert result.detail == "acked"
        assert acks["calls"] == [(1234, msg, wparam, lparam, SEND_TIMEOUT_MS)]
        assert posts == []
    else:
        assert result.detail == "posted"
        assert posts == [(1234, msg, wparam, lparam)]


def test_generic_dispatch_alias_sub_sync_adjust(posts):
    dispatcher = make_dispatcher()
    result = dispatcher.dispatch("SUB_SYNC_ADJUST", value=-1500)
    assert result.ok and result.command == "SUB_DELAY_DELTA"
    assert posts == [(1234, WM_USER, 0, -1500)]


# ------------------------------------------------------------- value conditioning


def test_speed_clamp_and_round(posts, acks):
    dispatcher = make_dispatcher()
    cases = [(8.0, 4000), (0.05, 200), (1.3999, 1400), (1.45, 1500)]
    for multiplier, expected_lparam in cases:
        result = dispatcher.set_speed(multiplier)
        assert result.command == "SET_SPEED", multiplier
        _hwnd, msg, wparam, lparam, _timeout = acks["calls"][-1]
        assert (msg, wparam, lparam) == (WM_USER, 0, expected_lparam), multiplier
    assert posts == []  # needs_ack entries never use PostMessage


def test_sub_delay_rounding(posts):
    dispatcher = make_dispatcher()
    cases = [
        (-300, -500),
        (700, 500),
        (250, 500),
        (-250, -500),
        (12_000, 10_000),
        (-12_000, -10_000),
    ]
    for delta, expected_lparam in cases:
        result = dispatcher.adjust_subtitle_delay(delta)
        assert result.ok, delta
        assert posts[-1] == (1234, WM_USER, 0, expected_lparam), delta


def test_seek_clamps_overflow_and_negatives(posts):
    dispatcher = make_dispatcher()
    assert dispatcher.seek_ms(-500).ok
    assert posts[-1][3] == 0
    assert dispatcher.seek_ms(2**33).ok
    assert posts[-1][3] == 2**31 - 1


def test_volume_and_subs_clamps(posts):
    dispatcher = make_dispatcher()
    dispatcher.dispatch("SET_VOLUME", value=999)
    assert posts[-1][3] == 100
    dispatcher.dispatch("SET_SUBS", value=False)
    assert posts[-1][3] == 0


def test_frame_step_directions(posts):
    dispatcher = make_dispatcher()
    assert dispatcher.frame_step("FORWARD").ok
    assert posts[-1][3] == 1
    assert dispatcher.frame_step("BACKWARD").ok
    assert posts[-1][3] == -1
    bad = dispatcher.frame_step("SIDEWAYS")
    assert not bad.ok and bad.detail == "bad_value"


def test_toggle_subtitles(posts):
    dispatcher = make_dispatcher()
    result = dispatcher.toggle_subtitles()
    assert result.ok and result.command == "SET_SUBS_TOGGLE"
    assert posts == [(1234, WM_COMMAND, 0, 0)]


# ------------------------------------------------------------- packing modes


@pytest.mark.parametrize(
    "param,value,expected_wparam,expected_lparam",
    [
        ("wparam", 0x1234, 0x1234, 0xAAAA0001),
        ("lparam", 0x1234, 0x0, 0x1234),
        ("lparam_loword", 0xBEEF, 0x0, 0xAAAABEEF),
        ("lparam_hiword", 0xBEEF, 0x0, 0xBEEF0001),
    ],
)
def test_packing_modes(param, value, expected_wparam, expected_lparam):
    messages = {"WM_COMMAND": WM_COMMAND, "WM_USER": WM_USER}
    entry = {
        "message": "WM_USER",
        "wparam": "0x0",
        "lparam": "0xAAAA0001",
        "param": param,
    }
    msg, wparam, lparam = _pack(messages, entry, value)
    assert (msg, wparam, lparam) == (WM_USER, expected_wparam, expected_lparam)


# ------------------------------------------------------------- delivery & recovery


def test_no_window_returns_clean_result(posts):
    dispatcher = make_dispatcher(FakeLocator(hwnd=None))
    result = dispatcher.play_pause()
    assert not result.ok and result.detail == "no_window"
    assert posts == []


def test_dead_hwnd_invalidate_retry_once(posts, monkeypatch):
    locator = FakeLocator(hwnd=1234)
    dispatcher = make_dispatcher(locator)
    attempts = {"n": 0}

    def flaky_post(hwnd, msg, wparam, lparam):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise OSError(1400, "invalid window handle")
        posts.append((hwnd, msg, wparam, lparam))

    monkeypatch.setattr(wm_dispatcher.win32gui, "PostMessage", flaky_post)
    result = dispatcher.play_pause()
    assert result.ok and result.detail == "posted"
    assert locator.invalidations == 1
    assert posts == [(1234, WM_COMMAND, 0, 0)]

    # Persistent failure on a fresh dispatcher: attempt 1 fails -> invalidate +
    # retry; attempt 2 fails -> invalidate + clean no_window; no exception escapes.
    dead_locator = FakeLocator(hwnd=1234)
    dead_dispatcher = make_dispatcher(dead_locator)

    def always_dead(hwnd, msg, wparam, lparam):
        raise OSError(1400, "invalid window handle")

    monkeypatch.setattr(wm_dispatcher.win32gui, "PostMessage", always_dead)
    result = dead_dispatcher.play_pause()
    assert not result.ok and result.detail == "no_window"
    assert dead_locator.invalidations == 2
    assert dead_locator.find_calls == 2  # initial + exactly one retry


def test_unknown_command_and_bad_value():
    dispatcher = make_dispatcher()
    result = dispatcher.dispatch("NOT_A_COMMAND")
    assert not result.ok and result.detail == "unknown_command"
    # Parameterized entry without a value is bad_value, not a crash.
    result = dispatcher.dispatch("SET_VOLUME")
    assert not result.ok and result.detail == "bad_value"


def test_needs_ack_timeout_within_budget(posts, acks):
    acks["results"] = [0]  # SendMessageTimeoutW reports failure -> timeout
    dispatcher = make_dispatcher()
    started = time.perf_counter()
    result = dispatcher.set_speed(1.4)
    elapsed = time.perf_counter() - started
    assert not result.ok and result.detail == "timeout"
    assert elapsed < (SEND_TIMEOUT_MS + 20) / 1000.0
    assert posts == []


# ------------------------------------------------------------- table lifecycle


def test_corrupt_json_raises_at_init(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    with pytest.raises(CodeTableError):
        make_dispatcher(path=bad)
    missing = tmp_path / "missing.json"
    with pytest.raises(CodeTableError):
        make_dispatcher(path=missing)


def test_invalid_schema_raises_at_init(tmp_path):
    table = json.loads(REPO_SPECS.read_text(encoding="utf-8"))
    table["commands"]["PLAY_PAUSE"]["param"] = "lparam_lowordish"
    bad = tmp_path / "schema.json"
    bad.write_text(json.dumps(table), encoding="utf-8")
    with pytest.raises(CodeTableError):
        make_dispatcher(path=bad)


def test_reload_keeps_old_table_on_error(posts, tmp_path):
    good = tmp_path / "codes.json"
    table = json.loads(REPO_SPECS.read_text(encoding="utf-8"))
    table["commands"]["PLAY_PAUSE"]["lparam"] = "0x77"
    good.write_text(json.dumps(table), encoding="utf-8")
    dispatcher = make_dispatcher(path=good)
    dispatcher.reload_codes()
    assert dispatcher.play_pause().ok
    assert posts[-1][3] == 0x77
    # Corrupt the file at runtime: reload retains the old table and stays up.
    good.write_text("%%%", encoding="utf-8")
    dispatcher.reload_codes()
    result = dispatcher.play_pause()
    assert result.ok and result.detail == "posted"
    assert posts[-1][3] == 0x77


# ------------------------------------------------------------- steps-mode speed


def _steps_table(tmp_path) -> Path:
    table = json.loads(REPO_SPECS.read_text(encoding="utf-8"))
    table["commands"]["SET_SPEED"]["mode"] = "steps"
    path = tmp_path / "steps.json"
    path.write_text(json.dumps(table), encoding="utf-8")
    return path


def test_steps_mode_uses_speed_provider(posts, tmp_path):
    dispatcher = make_dispatcher(
        locator=FakeLocator(), path=_steps_table(tmp_path), speed_provider=lambda: 1.0
    )
    result = dispatcher.set_speed(1.3)  # round((1.3 - 1.0) / 0.1) == 3 steps up
    assert result.ok and result.detail == "posted"
    _wait_for_posts(posts, 3)
    time.sleep(0.05)
    assert len(posts) == 3  # exactly n step entries, no extras
    assert all(post[1:] == (WM_USER, 0, 0) for post in posts)  # SPEED_UP placeholders


def test_steps_mode_negative_steps(posts, tmp_path):
    dispatcher = make_dispatcher(
        locator=FakeLocator(), path=_steps_table(tmp_path), speed_provider=lambda: 1.3
    )
    result = dispatcher.set_speed(1.0)  # 3 steps down
    assert result.ok
    _wait_for_posts(posts, 3)
    time.sleep(0.05)
    assert len(posts) == 3


def test_steps_cancelled_when_window_vanishes(posts, tmp_path):
    # allow=3: result hwnd find + (worker find + dispatch find) for step 1 only.
    locator = DyingLocator(allow=3)
    dispatcher = make_dispatcher(
        locator=locator, path=_steps_table(tmp_path), speed_provider=lambda: 1.0
    )
    result = dispatcher.set_speed(2.0)  # 10 steps requested; window dies after step 1
    assert result.ok
    _wait_for_posts(posts, 1)
    time.sleep(0.2)  # give the worker time to attempt (and cancel) the remainder
    assert len(posts) == 1


def test_steps_mode_without_provider_is_bad_value(posts, tmp_path):
    dispatcher = make_dispatcher(path=_steps_table(tmp_path), speed_provider=None)
    result = dispatcher.set_speed(1.3)
    assert not result.ok and result.detail == "bad_value"
    assert posts == []
    assert not dispatcher.step_speed(0.1).ok


def test_direct_mode_step_speed_is_bad_value(posts):
    dispatcher = make_dispatcher()  # shipped table is direct mode
    result = dispatcher.step_speed(0.1)
    assert not result.ok and result.detail == "bad_value"


# ------------------------------------------------------------- focus discipline


def test_no_focus_apis():
    source_path = pathlib.Path(wm_dispatcher.__file__)
    if source_path.suffix == "c":  # running against a compiled cache
        source_path = source_path.with_suffix("")
    text = source_path.read_text(encoding="utf-8")
    for api in FORBIDDEN_APIS:
        assert api not in text, f"forbidden focus API referenced: {api}"
