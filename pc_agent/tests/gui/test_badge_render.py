"""Doc 24 §9 / §5 — badge state maps to the exact table colors and captions."""

from __future__ import annotations

import pytest

from pc_agent.gui.dashboard_window import BadgeState, ConnectionInfo, render_badge

# (state, device_ip, client_count, detail, fill, text, caption) from doc §5.
BADGE_TABLE = [
    (BadgeState.STARTING, None, 0, "", "#3A3A3E", "#D6CEC9", "Starting…"),
    (BadgeState.IDLE, None, 0, "", "#5E1F27", "#D6CEC9", "Waiting for phone"),
    (
        BadgeState.CONNECTED,
        "192.168.1.7",
        1,
        "",
        "#6E5016",
        "#F0E6DC",
        "Connected · 192.168.1.7 · 1 device(s)",
    ),
    (
        BadgeState.ERROR,
        None,
        0,
        "UDP 50505 unavailable",
        "#A63240",
        "#FFF3EE",
        "UDP 50505 unavailable",
    ),
]


@pytest.mark.parametrize(("state", "ip", "count", "detail", "fill", "text", "caption"), BADGE_TABLE)
def test_badge_render_matches_doc_table(
    state: BadgeState,
    ip: str | None,
    count: int,
    detail: str,
    fill: str,
    text: str,
    caption: str,
) -> None:
    spec = render_badge(ConnectionInfo(state, ip, count, detail))
    assert spec.fill == fill
    assert spec.text == text
    assert spec.caption == caption


def test_connected_caption_includes_ip_and_count() -> None:
    spec = render_badge(ConnectionInfo(BadgeState.CONNECTED, "10.0.0.42", 3, ""))
    assert "10.0.0.42" in spec.caption
    assert "3 device(s)" in spec.caption
    assert spec.caption.startswith("Connected · ")


def test_connected_caption_without_ip_still_renders() -> None:
    spec = render_badge(ConnectionInfo(BadgeState.CONNECTED, None, 2, ""))
    assert "unknown" in spec.caption
    assert "2 device(s)" in spec.caption


def test_error_caption_shows_detail() -> None:
    spec = render_badge(ConnectionInfo(BadgeState.ERROR, None, 0, "WS 50506 unavailable"))
    assert spec.caption == "WS 50506 unavailable"


def test_error_caption_defaults_when_detail_empty() -> None:
    spec = render_badge(ConnectionInfo(BadgeState.ERROR, None, 0, ""))
    assert spec.caption == "Error"
