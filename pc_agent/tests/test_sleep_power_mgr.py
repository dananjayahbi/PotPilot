"""Doc 22 unit tests: sleep timer & power manager (fake clock, runner, poller, no power)."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from types import SimpleNamespace
from typing import Any

import pytest

from pc_agent.display_power import sleep_power_mgr as spm
from pc_agent.display_power.sleep_power_mgr import (
    ACT_CANCEL_SLEEP_TIMER,
    ACT_START_SLEEP_TIMER,
    DEFAULT_PROGRESS_THRESHOLD_PCT,
    ERR_BAD_PAYLOAD,
    MODE_COUNTDOWN,
    MODE_MOVIE_PROGRESS,
    PHASE_ARMED,
    PHASE_FIRED,
    PHASE_IDLE,
    PHASE_TRIGGERING,
    POWER_HIBERNATE,
    POWER_SHUTDOWN,
    POWER_SLEEP,
    SHUTDOWN_GRACE_S,
    SleepTimerManager,
    TimerState,
)
from pc_agent.network.telemetry_broadcaster import SOURCE_SLEEP, TelemetryBroadcaster
from pc_agent.network.ws_server_router import WsRouter, WsSession, parse_envelope

IDLE_STATE = TimerState(False, None, None, None, None)


class FakeClock:
    """Monotonic loop.time() replacement; only the test moves it."""

    def __init__(self) -> None:
        self.t = 0.0

    def now(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


class RecordingRunner:
    """PowerActionRunner stand-in recording calls — never touches Windows power."""

    def __init__(self) -> None:
        self.sleeps = 0
        self.hibernates = 0
        self.shutdowns: list[int] = []
        self.aborts = 0
        self.fail_hibernate = False
        self.on_call: Any = None

    def _record(self) -> None:
        if self.on_call is not None:
            self.on_call()

    async def sleep(self) -> None:
        self.sleeps += 1
        self._record()

    async def hibernate(self) -> None:
        self.hibernates += 1
        self._record()
        if self.fail_hibernate:
            raise RuntimeError("hibernation disabled")

    async def shutdown(self, grace_s: int) -> None:
        self.shutdowns.append(grace_s)
        self._record()

    async def abort_shutdown(self) -> None:
        self.aborts += 1


class CountingProvider:
    """Doc 10 progress_provider stand-in replaying samples (the last one repeats)."""

    def __init__(self, samples: list[Any]) -> None:
        self._samples = list(samples)
        self.calls = 0

    async def __call__(self) -> Any:
        self.calls += 1
        if len(self._samples) == 1:
            return self._samples[0]
        return self._samples.pop(0)


async def _no_progress() -> tuple[int, int, bool]:
    """Countdown-only provider: no movie, never a fire trigger."""
    return (0, 0, False)


class FakeSocket:
    """Minimal ``websockets`` connection stand-in for the router-level tests."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, text: str) -> None:
        self.sent.append(text)


class FakeWs:
    """Telemetry client stand-in recording parsed broadcast frames."""

    def __init__(self) -> None:
        self.frames: list[dict[str, Any]] = []

    async def send(self, text: str) -> None:
        self.frames.append(json.loads(text))


@pytest.fixture(autouse=True)
def powers(monkeypatch: Any) -> SimpleNamespace:
    """Intercept subprocess + ctypes.windll for EVERY test — no real power events."""
    env = SimpleNamespace(
        argvs=[], suspend_calls=[], returncode=0, suspend_ok=True, on_suspend=None
    )

    def fake_run(argv: list[str], **kwargs: Any) -> SimpleNamespace:
        del kwargs
        env.argvs.append(list(argv))
        return SimpleNamespace(returncode=env.returncode)

    def fake_suspend(*args: Any) -> bool:
        env.suspend_calls.append(tuple(args))
        if env.on_suspend is not None:
            env.on_suspend(*args)
        return bool(env.suspend_ok)

    monkeypatch.setattr(spm, "subprocess", SimpleNamespace(run=fake_run))
    fake_dll = SimpleNamespace(SetSuspendState=fake_suspend)
    # Real ctypes resolves both "powrprof" and "powrprof.dll" — expose both spellings.
    fake_windll = SimpleNamespace(
        powrprof=fake_dll, **{spm.WIN_POWRPROF_DLL: fake_dll}
    )
    monkeypatch.setattr(spm, "ctypes", SimpleNamespace(windll=fake_windll))
    return env


async def _settle(iterations: int = 10) -> None:
    for _ in range(iterations):
        await asyncio.sleep(0)


async def _drive(
    clock: FakeClock, predicate: Any, *, step: float = 1.5, max_steps: int = 600
) -> None:
    """Advance fake time past each 1 s tick until ``predicate`` holds (§9 fake clock)."""
    if predicate():
        return
    for _ in range(max_steps):
        clock.advance(step)
        await _settle(10)
        if predicate():
            return
    raise AssertionError("condition not met within fake-time budget")


async def _drive_steps(clock: FakeClock, steps: int, *, step: float = 1.5) -> None:
    for _ in range(steps):
        clock.advance(step)
        await _settle(10)


def _envelope(action: str, payload: dict[str, Any]) -> Any:
    return parse_envelope(
        json.dumps(
            {
                "id": str(uuid.uuid4()),
                "type": "CMD_SYSTEM",
                "action": action,
                "payload": payload,
                "timestamp": int(time.time()),
            }
        )
    )


def _router(manager: SleepTimerManager) -> WsRouter:
    router = WsRouter()
    router.register("CMD_SYSTEM", ACT_START_SLEEP_TIMER, manager.handle_start_sleep_timer)
    router.register("CMD_SYSTEM", ACT_CANCEL_SLEEP_TIMER, manager.handle_cancel_sleep_timer)
    return router


def test_countdown_fires_at_zero() -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> tuple[str, TimerState]:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        armed = await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=1)
        assert armed.active and armed.mode == MODE_COUNTDOWN
        assert armed.power_action == POWER_SHUTDOWN and armed.threshold_pct is None
        assert armed.remaining_s == 60  # 1 minute on the monotonic clock (§8)
        await _drive_steps(clock, 5)
        ticking = manager.state()
        assert ticking.active and ticking.remaining_s is not None
        assert ticking.remaining_s < 60  # remaining decreases while armed
        await _drive(clock, lambda: runner.shutdowns, max_steps=100)
        return manager.phase, manager.state()

    phase, final = asyncio.run(scenario())
    assert runner.shutdowns == [SHUTDOWN_GRACE_S]  # fired exactly once at zero
    assert runner.sleeps == 0 and runner.hibernates == 0 and runner.aborts == 0
    assert phase == PHASE_FIRED
    assert final.active is False  # FIRED reads back as idle


def test_cancel_prevents_fire() -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> tuple[str, TimerState]:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=1)
        await _drive_steps(clock, 20)  # t = 30 fake-s — cancel at half the window
        cancelled = await manager.cancel()
        await _drive_steps(clock, 40)  # run far past t = 60 s
        return manager.phase, cancelled

    phase, cancelled = asyncio.run(scenario())
    assert runner.shutdowns == []  # no power action after cancel (§7)
    assert runner.sleeps == 0 and runner.hibernates == 0
    assert runner.aborts == 0  # nothing was pending — cancel needs no /a
    assert phase == PHASE_IDLE
    assert cancelled == IDLE_STATE


def test_rearm_replaces_existing_timer() -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> str:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=10)
        await _drive_steps(clock, 20)  # t = 30 s of the original 600 s window
        assert runner.shutdowns == []
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=2)  # replaces at t = 30
        await _drive(clock, lambda: runner.shutdowns, max_steps=150)
        await _drive_steps(clock, 400)  # push past the ORIGINAL 600 s deadline
        return manager.phase

    phase = asyncio.run(scenario())
    assert runner.shutdowns == [SHUTDOWN_GRACE_S]  # only the 2-minute timer fired
    assert phase == PHASE_FIRED


def test_progress_fires_at_threshold_crossing() -> None:
    clock = FakeClock()
    runner = RecordingRunner()
    provider = CountingProvider([(98999, 100000, True), (99000, 100000, True)])

    async def scenario() -> int:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(provider, runner)
        armed = await manager.arm(MODE_MOVIE_PROGRESS, POWER_SLEEP)
        assert armed.threshold_pct == DEFAULT_PROGRESS_THRESHOLD_PCT  # default 99
        assert armed.remaining_s is None  # progress mode has no countdown (§3)
        await _drive(clock, lambda: runner.sleeps, max_steps=50)
        return provider.calls

    calls = asyncio.run(scenario())
    assert runner.sleeps == 1  # fires within the poll that crosses 99000/100000 ms
    assert calls == 2  # first poll (98999) stayed armed — second poll fired
    assert runner.shutdowns == [] and runner.hibernates == 0


def test_progress_ignores_zero_duration() -> None:
    clock = FakeClock()
    runner = RecordingRunner()
    provider = CountingProvider([(0, 0, False)])

    async def scenario() -> tuple[str, int, bool]:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(provider, runner)
        await manager.arm(MODE_MOVIE_PROGRESS, POWER_SHUTDOWN)
        await _drive_steps(clock, 15)  # ~14 polls of "no movie"
        return manager.phase, provider.calls, manager.state().active

    phase, calls, active = asyncio.run(scenario())
    assert phase == PHASE_ARMED and active  # stays armed indefinitely (§7)
    assert calls >= 10
    assert runner.sleeps == 0 and runner.shutdowns == [] and runner.hibernates == 0


def test_progress_fires_immediately_when_already_past() -> None:
    clock = FakeClock()
    runner = RecordingRunner()
    provider = CountingProvider([(99500, 100000, True)])

    async def scenario() -> int:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(provider, runner)
        await manager.arm(MODE_MOVIE_PROGRESS, POWER_SLEEP, threshold_pct=99)
        await _drive(clock, lambda: runner.sleeps, max_steps=50)
        return provider.calls

    calls = asyncio.run(scenario())
    assert calls == 1  # already past 99% at arm → first poll fires (§10 A4)
    assert runner.sleeps == 1


def test_hibernate_fallback_to_shutdown_h(powers: SimpleNamespace) -> None:
    clock = FakeClock()
    runner = RecordingRunner()
    runner.fail_hibernate = True  # SetSuspendState-style failure from the seam

    async def scenario() -> str:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        await manager.arm(MODE_COUNTDOWN, POWER_HIBERNATE, minutes=1)
        await _drive(clock, lambda: powers.argvs, max_steps=100)
        return manager.phase

    phase = asyncio.run(scenario())
    assert runner.hibernates == 1  # primary attempt first (§4.4)
    assert powers.argvs == [[spm.WIN_SHUTDOWN_EXE, "/h"]]  # fallback attempted
    assert phase == PHASE_FIRED  # fallback succeeded → FIRED, not ERROR
    assert powers.suspend_calls == []  # default runner never touched (injected one used)


def test_shutdown_command_args(powers: SimpleNamespace) -> None:
    clock = FakeClock()

    async def scenario() -> str:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress)  # default runner, mocked externals
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=1)
        await _drive(clock, lambda: powers.argvs, max_steps=100)
        return manager.phase

    phase = asyncio.run(scenario())
    assert powers.argvs == [
        [spm.WIN_SHUTDOWN_EXE, "/s", "/t", "30", "/c", "PotPilot sleep timer"]
    ]  # argv exactly per §4.4 / §8
    assert phase == PHASE_FIRED
    assert powers.suspend_calls == []


def test_cancel_uses_abort_in_grace() -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> tuple[str, TimerState]:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=1)
        await _drive(clock, lambda: runner.shutdowns, max_steps=100)
        assert manager.phase == PHASE_FIRED  # shutdown accepted, /t 30 grace open
        cancelled = await manager.cancel()
        await manager.cancel()  # second cancel is a no-op (§5)
        return manager.phase, cancelled

    phase, cancelled = asyncio.run(scenario())
    assert runner.shutdowns == [SHUTDOWN_GRACE_S]
    assert runner.aborts == 1  # shutdown.exe /a issued exactly once via the seam
    assert phase == PHASE_IDLE
    assert cancelled == IDLE_STATE


def test_state_machine_transitions(powers: SimpleNamespace) -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> int:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)

        # -- IDLE + the exact Doc 18 snapshot contract (§5 / §8) ---------------
        assert manager.phase == PHASE_IDLE
        assert manager.state() == IDLE_STATE
        snapshot = manager.snapshot()
        assert set(snapshot) == {
            "sleep_timer_active",
            "sleep_timer_mode",
            "sleep_timer_remaining_s",
        }
        assert isinstance(snapshot["sleep_timer_active"], bool)
        assert snapshot["sleep_timer_mode"] is None
        assert snapshot["sleep_timer_remaining_s"] is None

        # -- Doc 18 broadcaster picks up sleep_timer_active while ARMED --------
        broadcaster = TelemetryBroadcaster(SimpleNamespace(latest=None))
        broadcaster.register_source(SOURCE_SLEEP, manager.snapshot)
        ws = FakeWs()
        broadcaster.register_client(ws)
        await broadcaster.start()
        await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=1)
        assert manager.phase == PHASE_ARMED
        await _drive(
            clock,
            lambda: any(
                frame.get("payload", {}).get("sleep_timer_active") is True
                for frame in ws.frames
            ),
            max_steps=100,
        )
        await broadcaster.stop()
        assert manager.phase == PHASE_ARMED
        await manager.cancel()  # ARMED → IDLE
        assert manager.phase == PHASE_IDLE and manager.state() == IDLE_STATE
        frames_seen = len(ws.frames)

        # -- IDLE → ARMED → TRIGGERING → FIRED via mocked SetSuspendState -----
        manager2 = SleepTimerManager(_no_progress)  # default runner, mocked ctypes
        observed: list[str] = []
        powers.on_suspend = lambda *_args: observed.append(manager2.phase)

        await manager2.arm(MODE_COUNTDOWN, POWER_SLEEP, minutes=1)
        assert manager2.phase == PHASE_ARMED
        await _drive(clock, lambda: manager2.phase == PHASE_FIRED, max_steps=100)
        assert powers.suspend_calls[0] == (False, False, False)  # SLEEP args (§4.4)
        assert observed == [PHASE_TRIGGERING]  # captured mid power dispatch
        assert manager2.phase == PHASE_FIRED
        assert not manager2.state().active

        await manager2.arm(MODE_COUNTDOWN, POWER_HIBERNATE, minutes=5)  # re-arm
        assert manager2.phase == PHASE_ARMED
        await manager2.cancel()  # ARMED → IDLE
        assert manager2.phase == PHASE_IDLE and manager2.state() == IDLE_STATE

        await manager2.arm(MODE_COUNTDOWN, POWER_HIBERNATE, minutes=1)
        await _drive(
            clock,
            lambda: manager2.phase == PHASE_FIRED and len(powers.suspend_calls) >= 2,
            max_steps=100,
        )
        assert powers.suspend_calls[1] == (True, False, False)  # HIBERNATE args
        assert observed == [PHASE_TRIGGERING, PHASE_TRIGGERING]
        assert manager2.phase == PHASE_FIRED
        await manager2.cancel()  # FIRED → IDLE, no pending shutdown to abort
        assert manager2.phase == PHASE_IDLE
        assert runner.aborts == 0
        return frames_seen

    frames_seen = asyncio.run(scenario())
    assert frames_seen > 0  # Doc 18 frames carried the sleep_timer_* keys


def test_bad_payload_rejected() -> None:
    clock = FakeClock()
    runner = RecordingRunner()

    async def scenario() -> tuple[dict[str, Any], ...]:
        asyncio.get_running_loop().time = clock.now
        manager = SleepTimerManager(_no_progress, runner)
        router = _router(manager)
        session = WsSession(FakeSocket())

        idle_before = manager.state()
        zero = await router.dispatch(
            session,
            _envelope(
                ACT_START_SLEEP_TIMER,
                {"mode": MODE_COUNTDOWN, "target": POWER_SHUTDOWN, "minutes": 0},
            ),
        )
        unknown = await router.dispatch(
            session,
            _envelope(
                ACT_START_SLEEP_TIMER,
                {"mode": "EVERY_NIGHT", "target": POWER_SHUTDOWN, "minutes": 5},
            ),
        )
        progress_minutes = await router.dispatch(
            session,
            _envelope(
                ACT_START_SLEEP_TIMER,
                {"mode": MODE_MOVIE_PROGRESS, "target": POWER_SLEEP, "minutes": 5},
            ),
        )
        assert manager.state() == idle_before and manager.phase == PHASE_IDLE

        armed_before = await manager.arm(MODE_COUNTDOWN, POWER_SHUTDOWN, minutes=5)
        big = await router.dispatch(
            session,
            _envelope(
                ACT_START_SLEEP_TIMER,
                {"mode": MODE_COUNTDOWN, "target": POWER_SHUTDOWN, "minutes": 721},
            ),
        )
        assert manager.state() == armed_before  # running timer untouched (§7)
        assert manager.phase == PHASE_ARMED
        await manager.cancel()
        return zero["payload"], unknown["payload"], progress_minutes["payload"], big["payload"]

    payloads = asyncio.run(scenario())
    for payload in payloads:
        assert payload["ok"] is False
        assert payload["error"] == ERR_BAD_PAYLOAD
        assert isinstance(payload["detail"], str) and payload["detail"]
