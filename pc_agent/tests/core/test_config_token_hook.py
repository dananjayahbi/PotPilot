"""Doc 26 §9 — create-once auth-token storage hook."""

import threading

import pytest

from pc_agent.core.config_manager import ConfigError

from .helpers import make_manager

_VALID_TOKEN = "ab" * 16  # 32 lowercase hex chars


def test_generator_called_once_then_token_reused(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()
    calls = []

    def generator():
        calls.append(1)
        return _VALID_TOKEN

    assert mgr.ensure_auth_token(generator) == _VALID_TOKEN
    assert mgr.ensure_auth_token(generator) == _VALID_TOKEN
    assert len(calls) == 1
    # persisted: a fresh manager reads the same stored token
    assert make_manager(tmp_path).load().auth_token == _VALID_TOKEN


def test_generator_called_once_across_threads(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()
    barrier = threading.Barrier(8)
    calls = []
    results = []
    errors = []

    def generator():
        calls.append(1)
        return _VALID_TOKEN

    def worker():
        try:
            barrier.wait(timeout=30)
            results.append(mgr.ensure_auth_token(generator))
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)

    assert errors == []
    assert not any(thread.is_alive() for thread in threads)
    assert len(calls) == 1
    assert results == [_VALID_TOKEN] * 8


def test_invalid_generator_output_raises(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()

    with pytest.raises(ConfigError):
        mgr.ensure_auth_token(lambda: "not-a-valid-token")

    assert mgr.get().auth_token == ""
