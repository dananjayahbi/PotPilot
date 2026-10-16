"""Doc 24 §9 — UiEvent queue: post/drain dispatch, coalescing, thread safety."""

from __future__ import annotations

import logging
import threading

import pytest

from pc_agent.gui.dashboard_window import (
    BadgeState,
    ConnectionInfo,
    UiEvent,
    UiEventPump,
    coalesce,
    ensure_tk_thread,
)

LOGGER_NAME = "potpilot.gui.dashboard_window"


def make_connection(
    state: BadgeState = BadgeState.CONNECTED,
    ip: str | None = "192.168.1.7",
    count: int = 1,
) -> ConnectionInfo:
    return ConnectionInfo(state, ip, count, "")


class Recorder:
    """Handler double that records every dispatched event."""

    def __init__(self) -> None:
        self.events: list[UiEvent] = []

    def __call__(self, event: UiEvent) -> None:
        self.events.append(event)


def make_pump() -> tuple[UiEventPump, dict[str, Recorder]]:
    pump = UiEventPump()
    handlers = {kind: Recorder() for kind in ("connection", "qr_refresh", "notice", "folders")}
    for kind, handler in handlers.items():
        pump.register(kind, handler)
    return pump, handlers


def test_post_enqueues_until_drain() -> None:
    pump, handlers = make_pump()
    events = [UiEvent("qr_refresh"), UiEvent("notice", message="hi"), UiEvent("folders")]
    for event in events:
        pump.post(event)
    assert pump.pending() == 3
    assert handlers["qr_refresh"].events == []
    assert pump.drain() == 3
    assert pump.pending() == 0
    assert handlers["qr_refresh"].events == [UiEvent("qr_refresh")]
    assert handlers["notice"].events == [UiEvent("notice", message="hi")]
    assert handlers["folders"].events == [UiEvent("folders")]


def test_drain_dispatches_each_kind_to_its_handler() -> None:
    pump, handlers = make_pump()
    connection = make_connection()
    pump.post(UiEvent("connection", connection=connection))
    pump.post(UiEvent("qr_refresh", message="ip-changed"))
    pump.post(UiEvent("notice", message="Settings reset"))
    pump.post(UiEvent("folders"))
    assert pump.drain() == 4
    assert [event.connection for event in handlers["connection"].events] == [connection]
    assert [event.message for event in handlers["qr_refresh"].events] == ["ip-changed"]
    assert [event.message for event in handlers["notice"].events] == ["Settings reset"]
    assert handlers["folders"].events == [UiEvent("folders")]


def test_connection_events_coalesce_last_write_wins() -> None:
    pump, handlers = make_pump()
    first = UiEvent("connection", connection=make_connection(BadgeState.IDLE, None, 0))
    second = UiEvent("connection", connection=make_connection(BadgeState.CONNECTED, "10.0.0.9", 2))
    pump.post(first)
    pump.post(second)
    pump.post(UiEvent("notice", message="keep"))
    # Two connection events + one notice collapse to two dispatches; the
    # newest connection event wins regardless of arrival order.
    assert pump.drain() == 2
    assert handlers["connection"].events == [second]
    assert [event.message for event in handlers["notice"].events] == ["keep"]


def test_coalesce_prefers_incoming_for_same_kind() -> None:
    older = UiEvent("connection", connection=make_connection(BadgeState.IDLE, None, 0))
    newer = UiEvent("connection", connection=ConnectionInfo(BadgeState.ERROR, None, 0, "bind"))
    assert coalesce(older, newer) is newer
    assert coalesce(UiEvent("qr_refresh"), UiEvent("qr_refresh")) == UiEvent("qr_refresh")


def test_coalesce_rejects_mixed_kinds() -> None:
    with pytest.raises(ValueError, match="cannot coalesce"):
        coalesce(UiEvent("qr_refresh"), UiEvent("notice", message="x"))


def test_unknown_kind_is_ignored_with_warning(caplog: pytest.LogCaptureFixture) -> None:
    pump, handlers = make_pump()
    pump.post(UiEvent("mystery"))
    with caplog.at_level(logging.WARNING, logger=LOGGER_NAME):
        assert pump.drain() == 0
    assert "mystery" in caplog.text
    assert all(not recorder.events for recorder in handlers.values())


def test_post_rejects_non_event_values() -> None:
    pump, _ = make_pump()
    with pytest.raises(TypeError, match="UiEvent expected"):
        pump.post("not-an-event")  # type: ignore[arg-type]


def test_post_from_background_thread_never_raises() -> None:
    pump, handlers = make_pump()
    errors: list[BaseException] = []

    def worker() -> None:
        try:
            for index in range(5):
                pump.post(UiEvent("connection", connection=make_connection(count=index)))
        except BaseException as exc:  # the failure IS the assertion here
            errors.append(exc)

    thread = threading.Thread(target=worker, name="asyncio-loop-sim")
    thread.start()
    thread.join(timeout=5)
    assert not thread.is_alive()
    assert errors == []
    assert pump.pending() == 5
    assert pump.drain() == 1  # coalesced to a single badge update
    assert handlers["connection"].events[0].connection.client_count == 4  # type: ignore[union-attr]


def test_ensure_tk_thread_accepts_expected_thread() -> None:
    ensure_tk_thread(threading.current_thread())


def test_ensure_tk_thread_rejects_widget_mutation_from_other_thread() -> None:
    main_thread = threading.current_thread()
    errors: list[RuntimeError] = []

    def worker() -> None:
        try:
            ensure_tk_thread(main_thread)
        except RuntimeError as exc:
            errors.append(exc)

    thread = threading.Thread(target=worker, name="not-the-tk-thread")
    thread.start()
    thread.join(timeout=5)
    assert not thread.is_alive()
    assert len(errors) == 1
    assert "Tk widget mutation" in str(errors[0])
