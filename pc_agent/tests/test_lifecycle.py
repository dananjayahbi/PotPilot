"""Doc 04 §9 — lifecycle registry behaviour: order, rollback, timeouts, idle exit."""

import asyncio
import logging
import signal

import pytest

from pc_agent import main as agent_main


class FakeService:
    """Records start/stop calls; can fail on start or stop slowly."""

    def __init__(self, name, calls, *, fail_start=False, stop_delay=0.0):
        self.name = name
        self.calls = calls
        self.fail_start = fail_start
        self.stop_delay = stop_delay

    async def start(self):
        self.calls.append(("start", self.name))
        if self.fail_start:
            raise RuntimeError(f"{self.name} failed to start")

    async def stop(self):
        if self.stop_delay:
            await asyncio.sleep(self.stop_delay)
        self.calls.append(("stop", self.name))


@pytest.fixture(autouse=True)
def isolated_agent_env(tmp_path, monkeypatch):
    """Keep %APPDATA%, the config singleton, and the service registry off shared state."""
    monkeypatch.setenv("APPDATA", str(tmp_path / "AppData"))
    monkeypatch.setattr(agent_main.ConfigManager, "_instance", None)
    agent_main.service_registry.reset()
    yield
    agent_main.service_registry.reset()


def test_start_in_registration_order_stop_in_reverse():
    calls = []
    for name in ("a", "b", "c"):
        agent_main.register_service(FakeService(name, calls))
    agent_main.service_registry.request_shutdown()  # idle phase returns immediately

    code = asyncio.run(agent_main.run_agent([]))

    assert code == 0
    assert calls == [
        ("start", "a"),
        ("start", "b"),
        ("start", "c"),
        ("stop", "c"),
        ("stop", "b"),
        ("stop", "a"),
    ]


def test_failing_start_rolls_back_started_services():
    calls = []
    agent_main.register_service(FakeService("a", calls))
    agent_main.register_service(FakeService("b", calls, fail_start=True))
    agent_main.register_service(FakeService("c", calls))

    code = asyncio.run(agent_main.run_agent([]))

    assert code == 1
    assert calls == [("start", "a"), ("start", "b"), ("stop", "a")]


def test_stop_timeout_is_cancelled_and_loop_continues(monkeypatch):
    monkeypatch.setattr(agent_main, "SHUTDOWN_TIMEOUT_S", 0.05)
    calls = []
    agent_main.register_service(FakeService("fast", calls))
    agent_main.register_service(FakeService("slow", calls, stop_delay=30.0))
    agent_main.service_registry.request_shutdown()

    code = asyncio.run(agent_main.run_agent([]))

    # Reverse order: "slow" stops first and times out; "fast" is still stopped after it.
    assert code == 0
    assert calls == [("start", "fast"), ("start", "slow"), ("stop", "fast")]


def test_shutdown_event_ends_run_agent_with_code_zero():
    agent_main.service_registry.request_shutdown()

    assert asyncio.run(agent_main.run_agent([])) == 0


def test_boot_logs_empty_registry(caplog):
    agent_main.service_registry.request_shutdown()
    with caplog.at_level(logging.INFO, logger="potpilot"):
        asyncio.run(agent_main.run_agent([]))

    assert "PotPilot Agent up (no services registered)" in caplog.text


def test_sigint_first_graceful_then_forced_cancel():
    async def scenario():
        registry = agent_main.service_registry
        restore = agent_main._install_sigint_handler(registry)
        try:
            handler = signal.getsignal(signal.SIGINT)
            handler(signal.SIGINT, None)  # first Ctrl+C -> graceful
            await asyncio.sleep(0.05)
            assert registry.shutdown_event.is_set()
            handler(signal.SIGINT, None)  # repeat Ctrl+C -> hard cancel
            await asyncio.sleep(0.05)
        except asyncio.CancelledError:
            return  # hard cancel reached the root task as designed
        finally:
            restore()
        raise AssertionError("second SIGINT must cancel the root task immediately")

    asyncio.run(scenario())


def test_auth_token_never_appears_in_log_lines(tmp_path, monkeypatch):
    monkeypatch.setenv("APPDATA", str(tmp_path))
    agent_main._configure_logging(False)
    agent_logger = logging.getLogger("potpilot")
    token = "0123456789abcdef0123456789abcdef"
    try:
        logging.getLogger("potpilot.core.qr").info(
            "pairing auth_token=%s bare %s", token, token
        )
        text = (tmp_path / "PotPilot" / "logs" / "agent.log").read_text(encoding="utf-8")
        assert token not in text
        assert "***" in text
    finally:
        for handler in agent_logger.handlers[:]:
            handler.close()
        agent_logger.handlers.clear()
