"""Doc 04 §9 — main() entry guards and exit-code mapping."""

import sys

import pytest

from pc_agent import main as agent_main


@pytest.mark.parametrize("expected", [0, 1])
def test_main_maps_run_agent_exit_code(monkeypatch, expected):
    async def fake_run_agent(argv=None):
        return expected

    monkeypatch.setattr(agent_main, "run_agent", fake_run_agent)

    with pytest.raises(SystemExit) as excinfo:
        agent_main.main()

    assert excinfo.value.code == expected


def test_platform_guard_rejects_non_windows(monkeypatch, capsys):
    async def must_not_run(argv=None):
        raise AssertionError("run_agent must not run on non-Windows hosts")

    monkeypatch.setattr(agent_main, "run_agent", must_not_run)
    monkeypatch.setattr(sys, "platform", "linux")

    with pytest.raises(SystemExit) as excinfo:
        agent_main.main()

    assert excinfo.value.code == 2
    assert "Windows" in capsys.readouterr().err


def test_version_guard_rejects_python_310(monkeypatch, capsys):
    async def must_not_run(argv=None):
        raise AssertionError("run_agent must not run below Python 3.11")

    monkeypatch.setattr(agent_main, "run_agent", must_not_run)
    monkeypatch.setattr(sys, "version_info", (3, 10))

    with pytest.raises(SystemExit) as excinfo:
        agent_main.main()

    assert excinfo.value.code == 2
    assert "3.11" in capsys.readouterr().err
